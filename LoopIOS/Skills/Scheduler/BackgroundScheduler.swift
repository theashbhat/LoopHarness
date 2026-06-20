//
//  BackgroundScheduler.swift
//  Loop
//
//  Built from LoopIOS/Specs/7_background_scheduler_spec.md.
//
//  Cross-platform scheduler that subsumes the old CronSkill. A ScheduledJob is
//  a deferred invocation of a skill (or an agent prompt) that runs around its
//  fire time and delivers the result as a notification.
//
//  The spec splits iOS execution into two coordinated UX paths:
//   - Happy path  — BGProcessingTask pre-generated the result before fire
//                   time; the placeholder notification's body has been replaced
//                   with the rich body, tapping it opens the stored transcript.
//   - Fallback    — pre-fetch never ran; the placeholder notification fires
//                   ("Tap to run your <title>"); tapping kicks off a live
//                   agent loop in the foreground.
//
//  On Mac there's no analog of BGProcessingTask budget pressure — a
//  DispatchSourceTimer fires at fire time, runs the payload, posts a
//  UNUserNotification, and stores the transcript.
//

import Foundation
import UserNotifications
#if os(iOS)
import BackgroundTasks
#elseif os(macOS)
import AppKit
#endif

// MARK: - Domain model

/// Top-level scheduled job. Mirrors the spec's `ScheduledJob` schema.
struct ScheduledJob: Codable, Identifiable {
    var id: String
    var title: String
    var trigger: Trigger
    var payload: Payload
    /// Hours before fire time iOS is allowed to pre-generate the result.
    /// Clamped to 0.5...12 on insert. See spec "Core model" for guidance.
    var prefetchWindowHours: Double
    /// Set on Mac to read the body aloud via MacTTS after firing. iOS ignores.
    var voiceDelivery: Bool
    var createdAt: Date
    var lastRunAt: Date?
    /// Short, human-readable result of the last run — surfaced in Settings.
    var lastResult: String?
    /// For bounded triggers, how many of the N occurrences have already fired.
    var firingsCompleted: Int

    static let minPrefetchHours: Double = 0.5
    static let maxPrefetchHours: Double = 12.0
    static let defaultPrefetchHours: Double = 4.0
}

/// When a job should fire. Daily-only for now; cadence is reserved for future
/// expansion (weekly/monthly).
struct Trigger: Codable {
    var hour: Int            // 0...23, local time
    var minute: Int          // 0...59
    /// nil = unbounded daily; 1 = one-shot; N = bounded daily for N firings.
    var occurrences: Int?
    /// Anchor for the first firing. nil = next future instance of hh:mm.
    var firstDate: Date?
    /// For unbounded jobs, whether the body should be regenerated each day
    /// (CronSkill's `regenerate` flag). Bounded/one-shot reuse the first body.
    /// Default true for prompt payloads (matches spec intent — "review my
    /// calendar each morning" needs fresh content).
    var regenerate: Bool
    /// Optional weekday filter. Each element is 1 (Sunday) through 7
    /// (Saturday), matching `Calendar.current.component(.weekday, from:)`.
    /// nil or empty = every day (backward-compatible default).
    var weekdays: [Int]? = nil

    var isUnbounded: Bool { occurrences == nil }

    /// Whether `date` falls on an allowed weekday.
    func isAllowedWeekday(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let days = weekdays, !days.isEmpty else { return true }
        let wd = calendar.component(.weekday, from: date)
        return days.contains(wd)
    }
}

/// What the job actually does when it fires.
enum Payload: Codable {
    /// Run a full agent turn with the user's prompt. The model picks tools.
    case prompt(user: String, system: String?)
    /// Invoke a specific skill function directly. The result message is the
    /// notification body. Faster + cheaper than `prompt` when the user named
    /// a specific skill.
    case skill(name: String, argumentsJSON: String)

    enum CodingKeys: String, CodingKey { case kind, user, system, name, argumentsJSON }
    enum Kind: String, Codable { case prompt, skill }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .prompt(let user, let system):
            try c.encode(Kind.prompt, forKey: .kind)
            try c.encode(user, forKey: .user)
            try c.encodeIfPresent(system, forKey: .system)
        case .skill(let name, let args):
            try c.encode(Kind.skill, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(args, forKey: .argumentsJSON)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .prompt:
            let user = try c.decode(String.self, forKey: .user)
            let system = try c.decodeIfPresent(String.self, forKey: .system)
            self = .prompt(user: user, system: system)
        case .skill:
            let name = try c.decode(String.self, forKey: .name)
            let args = try c.decode(String.self, forKey: .argumentsJSON)
            self = .skill(name: name, argumentsJSON: args)
        }
    }
}

/// Result of one job firing. The transcript itself is stored as a
/// SimpleConversation (so the conversation list renders it natively); this
/// record holds the pointer + the short body that went into the notification.
struct PrefetchedResult: Codable {
    let jobId: String
    let fireDate: Date
    let conversationId: String
    let body: String
    let generatedAt: Date
}

// MARK: - BackgroundScheduler

/// Singleton that owns scheduled jobs, pre-fetched results, and the
/// platform-specific scheduling primitives.
final class BackgroundScheduler {

    static let shared = BackgroundScheduler()

    // MARK: Storage keys

    private let jobsKey = "loop.scheduler.jobs"
    private let resultsKey = "loop.scheduler.results"
    private let legacyCronsKey = "loop.crons"

    // MARK: Identifiers (iOS BGTaskScheduler)

    /// Single BGProcessingTask identifier — coalesced across all jobs. The
    /// app must register this in Info.plist under
    /// BGTaskSchedulerPermittedIdentifiers AND call `registerBGTasks()` from
    /// `didFinishLaunchingWithOptions` (before the launch handler returns).
    static let bgProcessingIdentifier = "com.bhat.intel.scheduler.prefetch"

    private let center = UNUserNotificationCenter.current()

    /// Set true during a headless run so calls into the agent loop don't
    /// recursively schedule new jobs from inside one (e.g. the model tries to
    /// call `schedule_task` while pre-generating a briefing). Tools are
    /// filtered out at the schema level too — this is belt-and-suspenders.
    private(set) var isRunningHeadless = false

    private init() {}

    // MARK: - Bootstrap

    /// Call once from `application(_:didFinishLaunchingWithOptions:)`
    /// (iOS) / `applicationDidFinishLaunching(_:)` (Mac).
    ///
    /// Migrates CronSkill's UserDefaults payload, registers BG tasks (iOS),
    /// and starts the Mac timer loop.
    func bootstrap() {
        migrateLegacyCronsIfNeeded()

        #if os(iOS)
        registerBGTasks()
        #elseif os(macOS)
        startMacTimerLoop()
        #endif

        // First-pass reconciliation — ensures placeholders exist for every
        // saved job. Cheap to call repeatedly.
        reconcileAll()
    }

    // MARK: - CRUD

    func loadJobs() -> [ScheduledJob] {
        guard let data = UserDefaults.standard.data(forKey: jobsKey) else { return [] }
        return (try? JSONDecoder().decode([ScheduledJob].self, from: data)) ?? []
    }

    func saveJobs(_ jobs: [ScheduledJob]) {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        UserDefaults.standard.set(data, forKey: jobsKey)
    }

    @discardableResult
    func addJob(_ job: ScheduledJob) -> ScheduledJob {
        var jobs = loadJobs()
        jobs.append(job)
        saveJobs(jobs)
        registerPlaceholder(for: job)
        #if os(iOS)
        submitNextBGTask()
        #elseif os(macOS)
        scheduleMacTimer(for: job)
        #endif
        return job
    }

    func deleteJob(id: String) -> ScheduledJob? {
        var jobs = loadJobs()
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = jobs.remove(at: idx)
        saveJobs(jobs)
        removeAllNotifications(forJobId: id)
        clearResults(forJobId: id)
        #if os(macOS)
        cancelMacTimer(for: id)
        #endif
        return removed
    }

    func updateJob(_ job: ScheduledJob) {
        var jobs = loadJobs()
        guard let idx = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[idx] = job
        saveJobs(jobs)
    }

    // MARK: - Prefetched results

    func loadResults() -> [PrefetchedResult] {
        guard let data = UserDefaults.standard.data(forKey: resultsKey) else { return [] }
        return (try? JSONDecoder().decode([PrefetchedResult].self, from: data)) ?? []
    }

    func saveResults(_ results: [PrefetchedResult]) {
        guard let data = try? JSONEncoder().encode(results) else { return }
        UserDefaults.standard.set(data, forKey: resultsKey)
    }

    /// Insert or replace the result for a given (jobId, fireDate). Older
    /// records for the same job are pruned to a small rolling window so
    /// storage stays bounded.
    func storeResult(_ result: PrefetchedResult, keepPerJob: Int = 10) {
        var all = loadResults()
        all.removeAll { $0.jobId == result.jobId && Calendar.current.isDate($0.fireDate, inSameDayAs: result.fireDate) }
        all.append(result)

        let grouped = Dictionary(grouping: all, by: { $0.jobId })
        var trimmed: [PrefetchedResult] = []
        for (_, list) in grouped {
            let sorted = list.sorted { $0.fireDate > $1.fireDate }
            trimmed.append(contentsOf: sorted.prefix(keepPerJob))
        }
        saveResults(trimmed)
    }

    func result(for jobId: String, fireDate: Date) -> PrefetchedResult? {
        return loadResults().first {
            $0.jobId == jobId && Calendar.current.isDate($0.fireDate, inSameDayAs: fireDate)
        }
    }

    func clearResults(forJobId jobId: String) {
        let filtered = loadResults().filter { $0.jobId != jobId }
        saveResults(filtered)
    }

    // MARK: - Time helpers

    /// Next future instance of hh:mm that also falls on an allowed weekday.
    /// If hh:mm is later today (and today is allowed), returns today.
    /// Otherwise advances day-by-day until an allowed weekday is found.
    func nextFireDate(for trigger: Trigger, after now: Date = Date()) -> Date {
        let calendar = Calendar.current
        if let anchor = trigger.firstDate, anchor > now {
            // Advance the anchor forward if it doesn't land on an allowed day.
            return advanceToAllowedWeekday(anchor, trigger: trigger, calendar: calendar)
        }
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = trigger.hour
        comps.minute = trigger.minute
        comps.second = 0
        var candidate = calendar.date(from: comps) ?? now
        if candidate <= now {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return advanceToAllowedWeekday(candidate, trigger: trigger, calendar: calendar)
    }

    /// Skip forward day-by-day (up to 7 iterations) until the date lands on
    /// an allowed weekday. Returns the original date when weekdays is nil.
    private func advanceToAllowedWeekday(_ date: Date, trigger: Trigger, calendar: Calendar) -> Date {
        guard let days = trigger.weekdays, !days.isEmpty else { return date }
        var d = date
        for _ in 0..<7 {
            if days.contains(calendar.component(.weekday, from: d)) { return d }
            d = calendar.date(byAdding: .day, value: 1, to: d) ?? d
        }
        return d
    }

    /// Human-readable schedule label for the Settings list.
    func scheduleDescription(for job: ScheduledJob) -> String {
        let hhmm = String(format: "%02d:%02d", job.trigger.hour, job.trigger.minute)
        let daysSuffix = weekdaysSuffix(for: job.trigger)
        if let n = job.trigger.occurrences {
            if n == 1 { return "once at \(hhmm)\(daysSuffix)" }
            let left = n - job.firingsCompleted
            return "\(left)/\(n) firings left at \(hhmm)\(daysSuffix)"
        }
        return "daily at \(hhmm)\(daysSuffix)"
    }

    private static let shortDayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private func weekdaysSuffix(for trigger: Trigger) -> String {
        guard let days = trigger.weekdays, !days.isEmpty, days.sorted() != [1,2,3,4,5,6,7] else {
            return ""
        }
        let sorted = days.sorted()
        if sorted == [2,3,4,5,6] { return " (Mon–Fri)" }
        if sorted == [1,7] { return " (Sat–Sun)" }
        let names = sorted.compactMap { d -> String? in
            guard (1...7).contains(d) else { return nil }
            return Self.shortDayNames[d - 1]
        }
        return " (\(names.joined(separator: ", ")))"
    }

    // MARK: - Notification registration

    /// Register (or re-register) the placeholder UNCalendarNotificationTrigger
    /// for a job's next fire. `prefetched: false` until a pre-fetch swaps it
    /// out with the rich body.
    func registerPlaceholder(for job: ScheduledJob) {
        ensureAuthorization { granted in
            guard granted else { return }
            self.removeAllNotifications(forJobId: job.id)

            let content = UNMutableNotificationContent()
            content.title = job.title
            content.body = self.fallbackBody(for: job)
            content.sound = .default
            content.userInfo = [
                "loop_scheduler": true,
                "job_id": job.id,
                "prefetched": false,
                "fire_date": ISO8601DateFormatter().string(from: self.nextFireDate(for: job.trigger))
            ]

            var dc = DateComponents()
            dc.hour = job.trigger.hour
            dc.minute = job.trigger.minute

            let trigger: UNCalendarNotificationTrigger
            if let n = job.trigger.occurrences, n > 0 {
                // Bounded / one-shot — anchored to the specific fire date.
                let anchor = self.nextFireDate(for: job.trigger)
                let comps = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: anchor
                )
                trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            } else {
                trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
            }

            let request = UNNotificationRequest(
                identifier: self.placeholderIdentifier(for: job.id),
                content: content,
                trigger: trigger
            )
            self.center.add(request, withCompletionHandler: nil)
        }
    }

    /// Swap the pending placeholder for a job with a rich notification whose
    /// body is the generated result. Called from a pre-fetch path.
    func replaceWithRichNotification(jobId: String,
                                     fireDate: Date,
                                     title: String,
                                     body: String) {
        ensureAuthorization { granted in
            guard granted else { return }
            self.removeAllNotifications(forJobId: jobId)

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = [
                "loop_scheduler": true,
                "job_id": jobId,
                "prefetched": true,
                "fire_date": ISO8601DateFormatter().string(from: fireDate)
            ]

            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: self.placeholderIdentifier(for: jobId),
                content: content,
                trigger: trigger
            )
            self.center.add(request, withCompletionHandler: nil)
        }
    }

    private func placeholderIdentifier(for jobId: String) -> String {
        return "loop.scheduler.\(jobId)"
    }

    private func fallbackBody(for job: ScheduledJob) -> String {
        return "Tap to run your \(job.title)"
    }

    func removeAllNotifications(forJobId jobId: String) {
        let id = placeholderIdentifier(for: jobId)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    // MARK: - Reconciliation

    /// Make sure every saved job has a pending placeholder, and that bounded
    /// jobs whose firings are exhausted are GC'd. Cheap; safe to call on every
    /// app foreground.
    func reconcileAll() {
        let jobs = loadJobs()
        var survivors: [ScheduledJob] = []
        for job in jobs {
            if let n = job.trigger.occurrences, job.firingsCompleted >= n {
                // Bounded job fully fired — drop.
                removeAllNotifications(forJobId: job.id)
                continue
            }
            survivors.append(job)
            registerPlaceholder(for: job)
        }
        if survivors.count != jobs.count {
            saveJobs(survivors)
        }
    }

    // MARK: - Authorization

    func ensureAuthorization(_ completion: @escaping (Bool) -> Void) {
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                completion(true)
            case .denied:
                completion(false)
            case .notDetermined:
                self.center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    // Obtain & register the APNs token now that we're authorized.
                    if granted {
                        PushRegistration.shared.registerIfAuthorized()
                    }
                    completion(granted)
                }
            @unknown default:
                completion(false)
            }
        }
    }

    // MARK: - Migration from CronSkill

    /// Decode the legacy `loop.crons` UserDefaults payload (if present) and
    /// convert each cron into a ScheduledJob with payload.kind=prompt. After
    /// successful migration, the legacy key is removed so this is one-shot.
    private func migrateLegacyCronsIfNeeded() {
        let ud = UserDefaults.standard
        guard let data = ud.data(forKey: legacyCronsKey) else { return }

        struct LegacyCron: Codable {
            var id: String
            var title: String
            var prompt: String
            var hour: Int
            var minute: Int
            var regenerate: Bool?
            var occurrences: Int?
            var firstDate: Date?
            var createdAt: Date
        }

        guard let legacy = try? JSONDecoder().decode([LegacyCron].self, from: data) else {
            // Bad data — clear so we don't retry forever.
            ud.removeObject(forKey: legacyCronsKey)
            return
        }

        var jobs = loadJobs()
        for cron in legacy {
            // Don't double-migrate if the id is already in the new store.
            if jobs.contains(where: { $0.id == cron.id }) { continue }

            let job = ScheduledJob(
                id: cron.id,
                title: cron.title,
                trigger: Trigger(
                    hour: cron.hour,
                    minute: cron.minute,
                    occurrences: cron.occurrences,
                    firstDate: cron.firstDate,
                    regenerate: cron.regenerate ?? false
                ),
                payload: .prompt(user: cron.prompt, system: nil),
                prefetchWindowHours: ScheduledJob.defaultPrefetchHours,
                voiceDelivery: false,
                createdAt: cron.createdAt,
                lastRunAt: nil,
                lastResult: nil,
                firingsCompleted: 0
            )
            jobs.append(job)
        }
        saveJobs(jobs)
        ud.removeObject(forKey: legacyCronsKey)
        print("BackgroundScheduler: migrated \(legacy.count) legacy crons.")
    }

    // MARK: - Headless agent loop

    enum RunResult {
        case success(body: String, conversationId: String)
        case failure(reason: String)
    }

    /// Maximum number of model turns inside one job run before we give up.
    /// Real-world prompts usually settle in 1-3 turns; cap protects against
    /// runaway tool-call loops eating the BG budget.
    private static let maxTurns: Int = 8

    /// Per-run wall-clock budget. iOS BGProcessingTask gets minutes; we bail
    /// well before that.
    private static let runBudget: TimeInterval = 90

    /// Drive a single job through the agent loop, capture the transcript as a
    /// fresh SimpleConversation, and return the final body.
    func runJob(_ job: ScheduledJob,
                fireDate: Date,
                completion: @escaping (RunResult) -> Void) {
        let startedAt = Date()
        isRunningHeadless = true

        // Fresh scheduled job — reset the anti-loop guard so prior state
        // from interactive use doesn't falsely flag this run's tool calls.
        ToolCallGuard.shared.resetForNewTurn()

        // Fresh conversation so the user can scroll back to past briefings via
        // the normal conversation list. Title doubles as the notification's
        // visible title.
        let conversation = SimpleConversationManager.shared.createConversation(
            title: titleForConversation(job: job, fireDate: fireDate)
        )

        // Build initial messages.
        var messages: [MessageStruct] = []
        switch job.payload {
        case .prompt(let user, let system):
            if let s = system, !s.isEmpty {
                messages.append(MessageStruct(role: "system", content: s))
            }
            let userMsg = MessageStruct(role: "user", content: user)
            messages.append(userMsg)
            SimpleConversationManager.shared.addMessage(userMsg, to: conversation)

        case .skill(let name, let argsJSON):
            // Synthesize the function-call assistant turn so the dispatcher
            // can run it directly. No model turn needed for the skill itself.
            let args = parseJSON(argsJSON)
            let call = FunctionCallStruct(name: name, arguments: args)
            let assistantMsg = MessageStruct(
                role: "assistant",
                content: "",
                function: call
            )
            messages.append(assistantMsg)
            SimpleConversationManager.shared.addMessage(assistantMsg, to: conversation)
            SkillDispatcher.shared.dispatch(call) { [weak self] resultMsg in
                guard let self = self else { return }
                messages.append(resultMsg)
                SimpleConversationManager.shared.addMessage(resultMsg, to: conversation)
                // After the skill returns, ask the model to produce a short body.
                let askForBody = MessageStruct(
                    role: "user",
                    content: "Summarize the result above in one short notification body (under 120 characters)."
                )
                messages.append(askForBody)
                SimpleConversationManager.shared.addMessage(askForBody, to: conversation)
                self.runModelLoop(
                    messages: messages,
                    conversation: conversation,
                    startedAt: startedAt,
                    turnsRemaining: Self.maxTurns,
                    completion: completion
                )
            }
            return
        }

        runModelLoop(
            messages: messages,
            conversation: conversation,
            startedAt: startedAt,
            turnsRemaining: Self.maxTurns,
            completion: completion
        )
    }

    private func runModelLoop(messages: [MessageStruct],
                              conversation: SimpleConversation,
                              startedAt: Date,
                              turnsRemaining: Int,
                              completion: @escaping (RunResult) -> Void) {
        if turnsRemaining <= 0 {
            isRunningHeadless = false
            completion(.failure(reason: "ran out of turns"))
            return
        }
        if Date().timeIntervalSince(startedAt) > Self.runBudget {
            isRunningHeadless = false
            completion(.failure(reason: "exceeded time budget"))
            return
        }

        // Exclude scheduler tools so the headless run can't schedule more jobs.
        let filteredTools = AgentHarness.shared.toolSchemas.filter { schema in
            guard let fn = schema["function"] as? [String: Any],
                  let name = fn["name"] as? String else { return true }
            return !SchedulerSkill.allToolNames.contains(name)
        }

        var working = messages
        AgentHarness.shared.chat(messages: working, tools: filteredTools) { [weak self] response, error in
            guard let self = self else { return }
            guard let response = response else {
                self.isRunningHeadless = false
                completion(.failure(reason: error?.localizedDescription ?? "no response"))
                return
            }

            if let fn = response.function {
                working.append(response)
                SimpleConversationManager.shared.addMessage(response, to: conversation)
                SkillDispatcher.shared.dispatch(fn) { resultMsg in
                    working.append(resultMsg)
                    SimpleConversationManager.shared.addMessage(resultMsg, to: conversation)
                    self.runModelLoop(
                        messages: working,
                        conversation: conversation,
                        startedAt: startedAt,
                        turnsRemaining: turnsRemaining - 1,
                        completion: completion
                    )
                }
                return
            }

            // Final text response.
            working.append(response)
            SimpleConversationManager.shared.addMessage(response, to: conversation)
            self.isRunningHeadless = false
            completion(.success(
                body: Self.notificationBody(from: response.content),
                conversationId: conversation.id
            ))
        }
    }

    /// Compress a model reply into a short notification body. We trim to ~140
    /// chars on a word boundary so the result fits in a banner without
    /// looking awkwardly cut off.
    static func notificationBody(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 140 { return trimmed }
        let cap = trimmed.index(trimmed.startIndex, offsetBy: 140)
        var slice = String(trimmed[..<cap])
        if let lastSpace = slice.lastIndex(of: " ") {
            slice = String(slice[..<lastSpace])
        }
        return slice + "…"
    }

    private func titleForConversation(job: ScheduledJob, fireDate: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "\(job.title) — \(f.string(from: fireDate))"
    }

    private func parseJSON(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    // MARK: - Run-now driver (used by both pre-fetch and Settings "Run now")

    /// Public entry: generate (or regenerate) the result for `job` at the
    /// given fire date, store it, and replace the pending notification with
    /// the rich body. Idempotent — calling twice produces the same outcome.
    func prefetch(job: ScheduledJob,
                  fireDate: Date,
                  completion: ((RunResult) -> Void)? = nil) {
        // Skip if we already have a fresh result for this fire — keeps the
        // foreground-refresh path from re-running an already-prefetched job.
        if let _ = result(for: job.id, fireDate: fireDate) {
            completion?(.success(body: "", conversationId: ""))
            return
        }

        runJob(job, fireDate: fireDate) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let body, let conversationId):
                let record = PrefetchedResult(
                    jobId: job.id,
                    fireDate: fireDate,
                    conversationId: conversationId,
                    body: body,
                    generatedAt: Date()
                )
                self.storeResult(record)
                self.replaceWithRichNotification(
                    jobId: job.id,
                    fireDate: fireDate,
                    title: job.title,
                    body: body
                )
                // Update job stats.
                var stored = self.loadJobs()
                if let idx = stored.firstIndex(where: { $0.id == job.id }) {
                    stored[idx].lastRunAt = Date()
                    stored[idx].lastResult = body
                    self.saveJobs(stored)
                }
            case .failure(let reason):
                print("BackgroundScheduler: prefetch failed for '\(job.title)': \(reason)")
            }
            completion?(result)
        }
    }

    /// Iterate every job whose next fire is inside its own prefetch window
    /// and run it. Used by:
    ///   - BGProcessingTask handler (iOS happy path)
    ///   - sceneDidBecomeActive foreground refresh (iOS safety net)
    ///   - Mac timer (general execution)
    func runDueJobs(now: Date = Date(), completion: (() -> Void)? = nil) {
        let jobs = loadJobs()
        let due = jobs.filter { job in
            let fire = nextFireDate(for: job.trigger, after: now)
            let window = max(ScheduledJob.minPrefetchHours,
                             min(ScheduledJob.maxPrefetchHours, job.prefetchWindowHours))
            let secondsBefore = window * 3600
            return fire.timeIntervalSince(now) <= secondsBefore
                && fire > now
                && result(for: job.id, fireDate: fire) == nil
        }
        if due.isEmpty {
            completion?()
            return
        }

        // Run sequentially to stay within budget reliably.
        var queue = due
        func step() {
            guard !queue.isEmpty else { completion?(); return }
            let job = queue.removeFirst()
            let fire = nextFireDate(for: job.trigger, after: now)
            prefetch(job: job, fireDate: fire) { _ in step() }
        }
        step()
    }

    // MARK: - Tap routing

    /// Inspect a notification's userInfo and return whether it's a
    /// scheduler-owned notification (so the host's tap handler knows to route
    /// through `handleTap`).
    static func isSchedulerNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        return (userInfo["loop_scheduler"] as? Bool) == true
    }

    /// Resolve a tap. Returns the conversationId to open (if pre-fetched) or
    /// the job-id-to-run-now (if fallback). The host UI does the actual
    /// presenting/running.
    enum TapAction {
        /// The result was pre-fetched; open the stored conversation.
        case openConversation(id: String)
        /// No pre-fetch; the user wants live generation. Caller should run the
        /// job in the foreground and surface the result inline.
        case runJobLive(ScheduledJob, fireDate: Date)
        /// Notification doesn't belong to us or the job is gone.
        case unknown
    }

    func handleTap(userInfo: [AnyHashable: Any]) -> TapAction {
        guard Self.isSchedulerNotification(userInfo),
              let jobId = userInfo["job_id"] as? String else {
            return .unknown
        }
        let prefetched = (userInfo["prefetched"] as? Bool) ?? false
        let fireDate = (userInfo["fire_date"] as? String)
            .flatMap(ISO8601DateFormatter().date(from:)) ?? Date()

        if prefetched, let r = result(for: jobId, fireDate: fireDate) {
            return .openConversation(id: r.conversationId)
        }
        guard let job = loadJobs().first(where: { $0.id == jobId }) else {
            return .unknown
        }
        return .runJobLive(job, fireDate: fireDate)
    }

    // MARK: - Bookkeeping after firing

    /// Called after a notification fires (delivered or tapped) so bounded
    /// jobs decrement their remaining occurrences and we re-arm the next
    /// occurrence for unbounded jobs.
    func notificationDidFire(jobId: String) {
        var jobs = loadJobs()
        guard let idx = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        if let n = jobs[idx].trigger.occurrences {
            jobs[idx].firingsCompleted += 1
            if jobs[idx].firingsCompleted >= n {
                jobs.remove(at: idx)
                saveJobs(jobs)
                removeAllNotifications(forJobId: jobId)
                return
            }
            // Advance firstDate to tomorrow for the next firing.
            let cal = Calendar.current
            let prev = jobs[idx].trigger.firstDate ?? nextFireDate(for: jobs[idx].trigger)
            jobs[idx].trigger.firstDate = cal.date(byAdding: .day, value: 1, to: prev)
        }
        saveJobs(jobs)
        // Re-register so the next occurrence has a placeholder waiting.
        registerPlaceholder(for: jobs[idx])
        #if os(iOS)
        submitNextBGTask()
        #endif
    }

    // MARK: - Platform glue (definitions live in extensions below)

    #if os(iOS)

    /// Register the BGTaskScheduler launch handler. Must run BEFORE
    /// `application(_:didFinishLaunchingWithOptions:)` returns.
    func registerBGTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.bgProcessingIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self = self, let bgTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBGProcessingTask(bgTask)
        }
    }

    func handleBGProcessingTask(_ task: BGProcessingTask) {
        // Submit the next request immediately so iOS knows we still want
        // pre-fetch windows even if this run gets cut short.
        submitNextBGTask()

        task.expirationHandler = {
            // iOS is reclaiming our budget — mark whatever we have done.
            task.setTaskCompleted(success: false)
        }

        runDueJobs {
            task.setTaskCompleted(success: true)
        }
    }

    /// Compute the earliest "fire - window" across all jobs and submit one
    /// BGProcessingTaskRequest with that as earliestBeginDate. iOS only
    /// allows one pending request per identifier, so we coalesce.
    func submitNextBGTask() {
        let jobs = loadJobs()
        guard !jobs.isEmpty else { return }
        let now = Date()
        let earliest = jobs.compactMap { job -> Date? in
            let fire = nextFireDate(for: job.trigger, after: now)
            let window = max(ScheduledJob.minPrefetchHours,
                             min(ScheduledJob.maxPrefetchHours, job.prefetchWindowHours))
            return fire.addingTimeInterval(-window * 3600)
        }.min() ?? now.addingTimeInterval(60 * 60)

        let request = BGProcessingTaskRequest(identifier: Self.bgProcessingIdentifier)
        request.earliestBeginDate = max(earliest, now.addingTimeInterval(60))
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = true

        // Cancel the prior pending request so the new earliest wins.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.bgProcessingIdentifier)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("BackgroundScheduler: BGTaskScheduler.submit failed — \(error)")
        }
    }

    #endif

    #if os(macOS)

    /// Per-job DispatchSourceTimer keyed by job id. Suspended timers are
    /// rebuilt on every reschedule rather than reused — keeps the bookkeeping
    /// trivial.
    private var macTimers: [String: DispatchSourceTimer] = [:]
    private let macTimerQueue = DispatchQueue(label: "loop.scheduler.mac", qos: .utility)

    private func startMacTimerLoop() {
        for job in loadJobs() {
            scheduleMacTimer(for: job)
        }
    }

    fileprivate func scheduleMacTimer(for job: ScheduledJob) {
        cancelMacTimer(for: job.id)
        let fire = nextFireDate(for: job.trigger)
        let delay = max(1, fire.timeIntervalSinceNow)

        let timer = DispatchSource.makeTimerSource(queue: macTimerQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.macFire(jobId: job.id, fireDate: fire)
        }
        timer.resume()
        macTimers[job.id] = timer
    }

    private func cancelMacTimer(for id: String) {
        if let t = macTimers.removeValue(forKey: id) {
            t.cancel()
        }
    }

    /// Mac fire path: run the job, post a UNUserNotification with the result,
    /// store the transcript, re-arm the timer for the next occurrence.
    private func macFire(jobId: String, fireDate: Date) {
        guard let job = loadJobs().first(where: { $0.id == jobId }) else { return }
        runJob(job, fireDate: fireDate) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let body, let conversationId):
                let record = PrefetchedResult(
                    jobId: jobId,
                    fireDate: fireDate,
                    conversationId: conversationId,
                    body: body,
                    generatedAt: Date()
                )
                self.storeResult(record)
                self.postMacNotification(jobId: jobId, title: job.title, body: body, fireDate: fireDate)

                var stored = self.loadJobs()
                if let idx = stored.firstIndex(where: { $0.id == jobId }) {
                    stored[idx].lastRunAt = Date()
                    stored[idx].lastResult = body
                    self.saveJobs(stored)
                }
            case .failure(let reason):
                print("BackgroundScheduler[Mac]: run failed — \(reason)")
            }
            self.notificationDidFire(jobId: jobId)
            // Re-arm — notificationDidFire updates firstDate for bounded jobs,
            // so re-reading is the right move.
            if let refreshed = self.loadJobs().first(where: { $0.id == jobId }) {
                self.scheduleMacTimer(for: refreshed)
            }
        }
    }

    private func postMacNotification(jobId: String,
                                     title: String,
                                     body: String,
                                     fireDate: Date) {
        ensureAuthorization { granted in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = [
                "loop_scheduler": true,
                "job_id": jobId,
                "prefetched": true,
                "fire_date": ISO8601DateFormatter().string(from: fireDate)
            ]
            // Fire immediately — Mac uses the timer to gate execution; the
            // notification is just the surfacing.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(
                identifier: self.placeholderIdentifier(for: jobId),
                content: content,
                trigger: trigger
            )
            self.center.add(request, withCompletionHandler: nil)
        }
    }

    #endif
}
