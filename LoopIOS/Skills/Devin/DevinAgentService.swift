//
//  DevinAgentService.swift
//  Loop
//
//  Long-running engine behind `DevinSkill`. Dispatches a coding task to
//  Devin's hosted **v3 sessions API** (runs autonomously, opens pull requests
//  on GitHub), persists each dispatched session so it survives relaunch, polls
//  to capture the live transcript, and posts the PR link / outcome back into
//  the originating conversation.
//
//  Devin's v3 API expects two credentials on every call:
//   - `Authorization: Bearer <cog_…>` — the service-user API key
//   - `<org_id>` (looks like `org-…`) as a path parameter
//  Both are stored separately in KeyStore (`.devin` + `.devinOrgID`). Calls
//  fail fast with a human-readable error when either is missing.
//
//  Patterns reused from CursorAgentService:
//   - Persistence: `[DevinAgentJob]` JSON in UserDefaults.
//   - Long-running poll: in-process DispatchSourceTimer + iOS background-task
//     grace + resume-on-launch.
//   - Post-back: locate the parent conversation via SimpleConversationManager
//     and append an assistant message.
//
//  Wire details (base URL, paths, status mapping, message shape) are pinned in
//  the `DevinAPI` enum + the `normalizeStatus` / `extractMessages` helpers.
//

import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Posted after a Devin completion message is written into a conversation so
/// an open chat view can refresh in place. Mirrors `.cursorAgentDidPostMessage`;
/// MessagingVC routes both at the same `handleSubAgentMessage` handler.
extension Notification.Name {
    static let devinAgentDidPostMessage = Notification.Name("loop.devin.didPostMessage")
    /// Posted whenever a tracked Devin job's persisted state changes (status,
    /// new messages, PR url). Subagent list + detail screens listen to this
    /// to refresh in place between polls.
    static let devinAgentsDidChange = Notification.Name("loop.devin.didChange")
}

/// One message in a Devin session transcript. Decoded from v3's
/// `SessionMessage` payload — kept on the local job so the detail view can
/// render the entire history without re-fetching.
///
/// `type` mirrors v3's `source` field ("devin" | "user"); we keep the older
/// name to avoid churning every UI call-site.
struct DevinTranscriptMessage: Codable, Identifiable {
    var id: String { eventId }
    var eventId: String
    var type: String
    var message: String
    var timestamp: String
    var username: String?
}

/// One dispatched Devin session we're tracking through to its PR.
struct DevinAgentJob: Codable {
    var sessionId: String
    var task: String
    var repository: String?
    /// Conversation to post the outcome back into. May be "" — the post-back
    /// resolves a sensible fallback the same way SubAgentManager does.
    var conversationId: String
    var createdAt: Date
    /// Normalized lifecycle: "running" until a terminal value
    /// ("finished" | "blocked" | "expired" | "cancelled" | "error" | "stale").
    var status: String
    /// Raw v3 top-level `status` (new / claimed / running / exit / error /
    /// suspended / resuming). Kept alongside the normalized field so the UI
    /// can surface a more precise label without re-parsing.
    var statusEnum: String?
    /// Raw v3 `status_detail` (working / waiting_for_user / waiting_for_approval
    /// / finished / inactivity / user_request / …).
    var statusDetail: String?
    var prURL: String?
    /// Latest v3 `pull_requests[].pr_state` — `"open"`, `"merged"`, `"closed"`,
    /// or `"draft"` per GitHub's vocabulary. We poll for this even after the
    /// session itself has gone terminal, so the row flips to "Merged" the
    /// moment Devin observes the merge.
    var prState: String?
    var dashboardURL: String?
    var title: String?
    var messages: [DevinTranscriptMessage]
    /// v3 messages endpoint is cursor-paginated — store the last `end_cursor`
    /// we saw so incremental polls only ask for new messages instead of
    /// re-fetching the whole history each tick.
    var messagesCursor: String?
    var lastPolledAt: Date?
    /// Set once the completion message has been written, so a relaunch can't
    /// double-post.
    var postedBack: Bool
    /// Set once we've posted a follow-up message announcing the PR merged,
    /// so subsequent polls (or a relaunch) don't double-post. Optional so
    /// jobs persisted before this field existed still decode cleanly.
    var mergedPosted: Bool?

    static let terminal: Set<String> = ["finished", "blocked", "expired", "cancelled", "error", "stale"]
    var isTerminal: Bool { DevinAgentJob.terminal.contains(status) }

    /// Short label for list rows — the user's task, single-line, truncated.
    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if trimmed.count <= 80 { return trimmed }
        return String(trimmed.prefix(77)) + "…"
    }
}

final class DevinAgentService {

    static let shared = DevinAgentService()

    // MARK: - Devin v3 API surface (the single place to pin on drift)

    private enum DevinAPI {
        static let base = "https://api.devin.ai"

        static func authHeader(_ key: String) -> (String, String) {
            return ("Authorization", "Bearer \(key)")
        }

        static func sessionsURL(orgID: String) -> URL? {
            URL(string: "\(base)/v3/organizations/\(orgID)/sessions")
        }

        static func sessionURL(orgID: String, sessionId: String) -> URL? {
            URL(string: "\(base)/v3/organizations/\(orgID)/sessions/\(sessionId)")
        }

        static func messagesURL(orgID: String, sessionId: String, after: String?) -> URL? {
            var components = URLComponents(string: "\(base)/v3/organizations/\(orgID)/sessions/\(sessionId)/messages")
            // Max page size per the spec; lets us drain a chatty session in a
            // single request before paginating.
            var items: [URLQueryItem] = [URLQueryItem(name: "first", value: "200")]
            if let after = after, !after.isEmpty {
                items.append(URLQueryItem(name: "after", value: after))
            }
            components?.queryItems = items
            return components?.url
        }

        static func sendMessageURL(orgID: String, sessionId: String) -> URL? {
            URL(string: "\(base)/v3/organizations/\(orgID)/sessions/\(sessionId)/messages")
        }

        /// Body for POST /sessions. v3 takes `repos` as an array of repository
        /// identifiers (e.g. "owner/name"); we forward whatever the caller
        /// gave us so the model can hint at a repo without having to know the
        /// exact format Devin's UI uses.
        static func createBody(task: String, title: String?, tags: [String]?, repos: [String]?) -> [String: Any] {
            var body: [String: Any] = ["prompt": task]
            if let title = title, !title.isEmpty { body["title"] = title }
            if let tags = tags, !tags.isEmpty { body["tags"] = tags }
            if let repos = repos, !repos.isEmpty { body["repos"] = repos }
            return body
        }
    }

    /// Resolved credentials. `key` is the cog_ token, `orgID` is the org-
    /// path parameter. Returns `.missing(reason)` with a human-readable
    /// explanation when either is unset, so callers can surface the same
    /// message verbatim. Not modelled as `Result` because `Result.Failure`
    /// requires `Error` conformance and we don't want to introduce a
    /// dedicated error type for an internal helper.
    private struct Credentials {
        let key: String
        let orgID: String
    }
    private enum CredentialsResult {
        case ok(Credentials)
        case missing(String)
    }

    private func credentials() -> CredentialsResult {
        let key = (KeyStore.shared.value(for: .devin) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let orgID = (KeyStore.shared.value(for: .devinOrgID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty && orgID.isEmpty {
            return .missing("Devin isn't connected. Open Settings ▸ Integrations ▸ Devin.AI and paste your cog_… API key + org-… Organization ID.")
        }
        if key.isEmpty {
            return .missing("Devin API key is missing. Open Settings ▸ Keys ▸ Devin API Key and paste a cog_… service-user key from app.devin.ai.")
        }
        if orgID.isEmpty {
            return .missing("Devin Organization ID is missing. Open Settings ▸ Keys ▸ Devin Organization ID and paste your org-… id (the v3 API requires it).")
        }
        return .ok(Credentials(key: key, orgID: orgID))
    }

    // MARK: - Cadence

    /// Stop polling a job that never finishes so the timer can't run forever.
    private static let maxLifetime: TimeInterval = 8 * 60 * 60
    /// Background cadence — keeps the persisted state warm so a relaunch can
    /// post completion back even if no UI was ever opened.
    private static let backgroundPollInterval: TimeInterval = 20
    /// Foreground cadence (spec story (J)): the detail view "boosts" while
    /// on-screen so the transcript refreshes every 5s while the user watches.
    static let foregroundPollInterval: TimeInterval = 5

    private let jobsKey = "loop.devin.jobs"
    /// Serializes job-array mutations + timer lifecycle.
    private let queue = DispatchQueue(label: "loop.devin.service")
    private var pollTimer: DispatchSourceTimer?
    /// Session ids that an on-screen detail view has asked us to poll fast.
    /// Empty → use the background cadence.
    private var boostedSessions: Set<String> = []

    private init() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        #endif
    }

    // MARK: - Persistence (mirrors CursorAgentService)

    func loadJobs() -> [DevinAgentJob] {
        guard let data = UserDefaults.standard.data(forKey: jobsKey) else { return [] }
        return (try? JSONDecoder().decode([DevinAgentJob].self, from: data)) ?? []
    }

    private func saveJobs(_ jobs: [DevinAgentJob]) {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        UserDefaults.standard.set(data, forKey: jobsKey)
    }

    private func upsert(_ job: DevinAgentJob, broadcast: Bool = true) {
        queue.sync {
            var jobs = loadJobs()
            if let idx = jobs.firstIndex(where: { $0.sessionId == job.sessionId }) {
                jobs[idx] = job
            } else {
                jobs.append(job)
            }
            saveJobs(jobs)
        }
        if broadcast {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .devinAgentsDidChange,
                    object: nil,
                    userInfo: ["sessionId": job.sessionId])
            }
        }
    }

    func job(forSessionId id: String) -> DevinAgentJob? {
        return loadJobs().first { $0.sessionId == id }
    }

    /// Most-recent-first listing for Settings ▸ Subagents.
    func allJobs() -> [DevinAgentJob] {
        return loadJobs().sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Foreground boost

    /// The detail view calls this on appear to bump polling to 5s for its
    /// session, then `removeBoost` on disappear. The shared timer reschedules
    /// itself to the boosted cadence whenever any session is boosted.
    func addBoost(sessionId: String) {
        queue.sync { _ = boostedSessions.insert(sessionId) }
        rescheduleTimerIfNeeded()
        // Trigger an immediate poll so the view feels alive on appear instead
        // of waiting a full interval.
        if let job = job(forSessionId: sessionId), !job.isTerminal {
            pollJob(job, completion: { _ in })
        }
    }

    func removeBoost(sessionId: String) {
        queue.sync { boostedSessions.remove(sessionId) }
        rescheduleTimerIfNeeded()
    }

    // MARK: - Dispatch

    enum DispatchResult {
        case success(DevinAgentJob)
        case failure(String)
    }

    /// POST a new session to Devin v3. Surfaces missing-credential and
    /// HTTP/network errors verbatim — never silently degrades.
    func dispatch(task: String,
                  repository: String?,
                  title: String?,
                  tags: [String]?,
                  conversationId: String,
                  completion: @escaping (DispatchResult) -> Void) {

        let creds: Credentials
        switch credentials() {
        case .missing(let reason): completion(.failure(reason)); return
        case .ok(let c): creds = c
        }
        guard let url = DevinAPI.sessionsURL(orgID: creds.orgID) else {
            completion(.failure("Bad Devin API URL (check that the Organization ID is in `org-…` format).")); return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (h, v) = DevinAPI.authHeader(creds.key)
        req.setValue(v, forHTTPHeaderField: h)
        // Normalize a full GitHub URL down to "owner/name" — Devin v3 accepts
        // either, but a normalized identifier is the safer wire format and
        // also matches what shows up in the Devin UI.
        let repos: [String]? = repository.flatMap { repo -> [String]? in
            let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            let path = URL(string: trimmed)?.path ?? trimmed
            let parts = path.split(separator: "/").suffix(2)
            let normalized = parts.joined(separator: "/")
                .replacingOccurrences(of: ".git", with: "")
            return [normalized.isEmpty ? trimmed : normalized]
        }
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: DevinAPI.createBody(task: task, title: title, tags: tags, repos: repos))
        req.timeoutInterval = 60

        print("DevinAgentService: POST \(url)")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                completion(.failure("Network error talking to Devin: \(error.localizedDescription)"))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure("Devin returned an unreadable response (HTTP \(code))."))
                return
            }
            if code >= 400 {
                completion(.failure("Devin API error (HTTP \(code)): \(Self.errorDetail(json) ?? "no detail")"))
                return
            }
            guard let sessionId = json["session_id"] as? String, !sessionId.isEmpty else {
                completion(.failure("Devin response had no session_id."))
                return
            }
            let initialPR = Self.extractPR(json)
            let job = DevinAgentJob(
                sessionId: sessionId,
                task: task,
                repository: repository,
                conversationId: conversationId,
                createdAt: Date(),
                status: "running",
                statusEnum: json["status"] as? String,
                statusDetail: json["status_detail"] as? String,
                prURL: initialPR?.url,
                prState: initialPR?.state,
                dashboardURL: json["url"] as? String,
                title: (json["title"] as? String) ?? title,
                messages: [],
                messagesCursor: nil,
                lastPolledAt: nil,
                postedBack: false,
                mergedPosted: nil)
            self.upsert(job)
            self.ensurePolling()
            completion(.success(job))
        }.resume()
    }

    // MARK: - Polling

    /// One-shot status refresh. Also updates persistence + triggers post-back
    /// if the session just went terminal.
    func refresh(sessionId: String, completion: @escaping (DevinAgentJob?) -> Void) {
        guard let job = job(forSessionId: sessionId) else { completion(nil); return }
        pollJob(job) { updated in
            completion(updated ?? job)
        }
    }

    /// Start the shared poll timer if there's anything non-terminal to watch.
    func ensurePolling() {
        rescheduleTimerIfNeeded()
    }

    private func rescheduleTimerIfNeeded() {
        queue.sync {
            // Keep polling as long as something needs watching. Two reasons
            // a job needs polling: (a) it's still running, or (b) the user
            // is watching it (boosted) — even after the session has finished,
            // boosted polls catch state that only changes post-completion,
            // notably `pr_state` going from "open" to "merged".
            let jobs = loadJobs()
            let hasWork = jobs.contains(where: { !$0.isTerminal })
                || jobs.contains(where: { boostedSessions.contains($0.sessionId) })
            guard hasWork else {
                pollTimer?.cancel()
                pollTimer = nil
                return
            }
            let interval = boostedSessions.isEmpty
                ? Self.backgroundPollInterval
                : Self.foregroundPollInterval
            // Cancel + recreate so a cadence change takes effect immediately
            // (DispatchSourceTimer.schedule applies on the next fire, which
            // would otherwise leave a boosted session waiting up to 20s).
            pollTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "loop.devin.poll", qos: .utility))
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in self?.pollCycle() }
            pollTimer = timer
            timer.resume()
        }
    }

    private func pollCycle() {
        // Snapshot the boost set up front so we make a single, consistent
        // decision per cycle instead of racing with addBoost/removeBoost.
        let boosted: Set<String> = queue.sync { boostedSessions }
        let pending = loadJobs().filter { job in
            // Still running → poll. Already finished but the user is watching
            // → also poll, so post-completion changes (notably a merge) reach
            // the UI while it's open.
            !job.isTerminal || boosted.contains(job.sessionId)
        }
        if pending.isEmpty {
            queue.sync {
                pollTimer?.cancel()
                pollTimer = nil
            }
            return
        }
        for job in pending {
            // Lifetime cap applies only to still-running sessions — a finished
            // PR we're just watching for a merge doesn't have a "stuck" failure
            // mode to escape from.
            if !job.isTerminal, Date().timeIntervalSince(job.createdAt) > Self.maxLifetime {
                var stale = job
                stale.status = "stale"
                finish(stale)
                continue
            }
            pollJob(job, completion: { _ in })
        }
    }

    /// Poll a single session: refresh status/PR via GET /sessions/{id}, then
    /// pull any new messages via GET /sessions/{id}/messages?after=<cursor>.
    /// The two requests fire sequentially so the persisted job reflects both
    /// in a single notification update.
    private func pollJob(_ job: DevinAgentJob,
                         completion: @escaping (DevinAgentJob?) -> Void) {
        let creds: Credentials
        switch credentials() {
        case .missing: completion(nil); return
        case .ok(let c): creds = c
        }
        guard let url = DevinAPI.sessionURL(orgID: creds.orgID, sessionId: job.sessionId) else {
            completion(nil); return
        }

        var req = URLRequest(url: url)
        let (h, v) = DevinAPI.authHeader(creds.key)
        req.setValue(v, forHTTPHeaderField: h)
        req.timeoutInterval = 30

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { completion(nil); return }
            guard error == nil,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil); return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Re-read the latest persisted copy so we don't clobber a
            // concurrent update.
            guard var current = self.job(forSessionId: job.sessionId) else {
                completion(nil); return
            }
            if code >= 400 {
                current.status = "error"
                current.lastPolledAt = Date()
                self.finish(current)
                completion(current)
                return
            }
            current.lastPolledAt = Date()
            let priorState = current.prState?.lowercased()
            if let pr = Self.extractPR(json) {
                current.prURL = pr.url
                // Only update state when the response actually carries one,
                // and never demote a `merged` we've already observed — Devin
                // shouldn't ever do that, but it'd be a confusing regression
                // if the row flipped from "Merged" back to "Open".
                if let newState = pr.state, !newState.isEmpty,
                   priorState != "merged" {
                    current.prState = newState
                }
            }
            // Catch the moment the PR transitions to merged so we can post a
            // one-shot follow-up message back into the conversation. Guarded
            // by `mergedPosted` (defaulting to false for jobs persisted before
            // this field existed) so a relaunch + re-poll can't duplicate.
            let nowMerged = current.prState?.lowercased() == "merged"
            let needsMergePost = nowMerged
                && priorState != "merged"
                && !(current.mergedPosted ?? false)
            if needsMergePost {
                self.postMerged(for: current)
                current.mergedPosted = true
            }
            current.dashboardURL = (json["url"] as? String) ?? current.dashboardURL
            if let title = json["title"] as? String, !title.isEmpty { current.title = title }
            current.statusEnum = (json["status"] as? String) ?? current.statusEnum
            current.statusDetail = (json["status_detail"] as? String) ?? current.statusDetail
            current.status = Self.normalizeStatus(current.statusEnum,
                                                  detail: current.statusDetail,
                                                  fallback: current.status)

            // Drain the messages page(s) so the transcript stays current.
            // We do this even after the session is terminal to capture the
            // final assistant message that announces completion.
            self.appendNewMessages(for: current, creds: creds) { withMessages in
                let updated = withMessages ?? current
                if updated.isTerminal {
                    if updated.postedBack {
                        // Already finished + already posted the completion
                        // message — this is a boosted re-poll that just
                        // captured a post-terminal change (e.g. pr_state
                        // flipping to "merged"). Persist and broadcast so the
                        // detail view re-renders; skip finish() to avoid the
                        // double-post guard short-circuiting the broadcast.
                        self.upsert(updated)
                    } else {
                        self.finish(updated)
                    }
                } else {
                    self.upsert(updated)
                }
                completion(updated)
            }
        }.resume()
    }

    /// Fetch new messages since the stored cursor, append them to the job,
    /// and update the cursor. Follows `has_next_page` until exhausted (capped
    /// to a generous N pages so a runaway session can't pin a worker).
    private func appendNewMessages(for job: DevinAgentJob,
                                   creds: Credentials,
                                   completion: @escaping (DevinAgentJob?) -> Void) {
        var working = job
        let maxPages = 5
        func step(page: Int) {
            if page >= maxPages { completion(working); return }
            guard let url = DevinAPI.messagesURL(orgID: creds.orgID,
                                                 sessionId: working.sessionId,
                                                 after: working.messagesCursor) else {
                completion(working); return
            }
            var req = URLRequest(url: url)
            let (h, v) = DevinAPI.authHeader(creds.key)
            req.setValue(v, forHTTPHeaderField: h)
            req.timeoutInterval = 30
            URLSession.shared.dataTask(with: req) { data, response, _ in
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code < 400,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(working); return
                }
                let items = (json["items"] as? [[String: Any]]) ?? []
                let parsed = Self.extractMessages(items)
                if !parsed.isEmpty {
                    // Dedup against the existing transcript by event_id so a
                    // retry doesn't double up.
                    let known = Set(working.messages.map { $0.eventId })
                    let fresh = parsed.filter { !known.contains($0.eventId) }
                    working.messages.append(contentsOf: fresh)
                }
                if let cursor = json["end_cursor"] as? String, !cursor.isEmpty {
                    working.messagesCursor = cursor
                }
                let hasMore = (json["has_next_page"] as? Bool) ?? false
                if hasMore {
                    step(page: page + 1)
                } else {
                    completion(working)
                }
            }.resume()
        }
        step(page: 0)
    }

    /// Mark a job terminal, persist, and post the outcome back exactly once.
    private func finish(_ job: DevinAgentJob) {
        var done = job
        if !DevinAgentJob.terminal.contains(done.status) { done.status = "finished" }
        upsert(done, broadcast: false)
        guard !done.postedBack else { return }
        postCompletion(for: done)
        var marked = done
        marked.postedBack = true
        upsert(marked)
        rescheduleTimerIfNeeded()
    }

    // MARK: - Resume on launch

    /// Called once at launch (AgentHarness bootstrap). Re-arms polling for
    /// anything unfinished, and flushes any job that went terminal while the
    /// app was dead but never got its message posted.
    func resumePending() {
        for job in loadJobs() where job.isTerminal && !job.postedBack {
            finish(job)
        }
        ensurePolling()
        // Sweep terminal jobs with still-open PRs once on launch so a merge
        // that happened while the app was dead lands in the list immediately,
        // not the next time the user taps into a detail view.
        pollOpenPRs()
    }

    /// One-shot poll for every terminal job whose PR hasn't merged/closed
    /// yet — used by surfaces that show many sessions at once (the Subagents
    /// list, app foregrounding). Doesn't touch live sessions; those are
    /// already covered by the recurring poll timer.
    func pollOpenPRs() {
        let candidates = loadJobs().filter { job in
            guard job.isTerminal else { return false }
            guard let pr = job.prURL, !pr.isEmpty else { return false }
            let state = job.prState?.lowercased() ?? "open"
            return state != "merged" && state != "closed"
        }
        for job in candidates {
            pollJob(job, completion: { _ in })
        }
    }

    // MARK: - Send a follow-up

    /// Send a message into an existing Devin session (e.g. extra context or a
    /// nudge). Completion receives a nil error on success, or a
    /// human-readable failure string otherwise.
    func sendMessage(sessionId: String,
                     text: String,
                     completion: @escaping (String?) -> Void) {
        let creds: Credentials
        switch credentials() {
        case .missing(let reason): completion(reason); return
        case .ok(let c): creds = c
        }
        guard let url = DevinAPI.sendMessageURL(orgID: creds.orgID, sessionId: sessionId) else {
            completion("Bad Devin API URL."); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (h, v) = DevinAPI.authHeader(creds.key)
        req.setValue(v, forHTTPHeaderField: h)
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["message": text])
        req.timeoutInterval = 30
        URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            if let error = error {
                completion(error.localizedDescription); return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code >= 400 {
                completion("HTTP \(code)"); return
            }
            // Refresh so the new message shows up before the next poll tick.
            self?.refresh(sessionId: sessionId) { _ in
                completion(nil)
            }
        }.resume()
    }

    // MARK: - Post-back (mirrors CursorAgentService.postCompletion)

    private func postCompletion(for job: DevinAgentJob) {
        let manager = SimpleConversationManager.shared
        let conversations = manager.getAllConversations()
        let parent: SimpleConversation? = {
            if let exact = conversations.first(where: { $0.id == job.conversationId }) {
                return exact
            }
            if let current = manager.currentConversation { return current }
            return manager.loadLastConversation()
        }()
        guard let parent = parent else {
            print("⚠️ Devin session \(job.sessionId) finished but no conversation to post to — dropped.")
            return
        }

        var msg = MessageStruct(role: "assistant",
                                content: Self.completionBody(for: job),
                                model: "Devin · \(job.displayTitle)")
        msg.name = "devin_agent_\(job.sessionId.prefix(8))"
        manager.addMessage(msg, to: parent)

        let postedId = parent.id
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .devinAgentDidPostMessage,
                object: nil,
                userInfo: ["conversationId": postedId, "messageId": msg.id])
            NotificationCenter.default.post(
                name: .devinAgentsDidChange,
                object: nil,
                userInfo: ["sessionId": job.sessionId])
        }
        deliverNotificationIfNeeded(for: job)
    }

    /// Post a one-shot "🎉 PR merged" assistant message into the originating
    /// conversation the moment we observe `pr_state` flip to "merged". Same
    /// routing as `postCompletion` (current conversation → last persisted →
    /// drop), but with a distinct body so the chat reads as a follow-up to
    /// the original "Devin finished — PR …" message rather than a duplicate.
    /// `mergedPosted` is flipped by the caller so a relaunch + re-poll can't
    /// duplicate this.
    private func postMerged(for job: DevinAgentJob) {
        let manager = SimpleConversationManager.shared
        let conversations = manager.getAllConversations()
        let parent: SimpleConversation? = {
            if let exact = conversations.first(where: { $0.id == job.conversationId }) {
                return exact
            }
            if let current = manager.currentConversation { return current }
            return manager.loadLastConversation()
        }()
        guard let parent = parent else {
            print("⚠️ Devin session \(job.sessionId) merged but no conversation to post to — dropped.")
            return
        }

        let body: String
        if let pr = job.prURL {
            body = "🎉 Merged — \(pr)"
        } else {
            body = "🎉 Devin's PR was merged."
        }
        var msg = MessageStruct(role: "assistant",
                                content: body,
                                model: "Devin · \(job.displayTitle)")
        msg.name = "devin_agent_\(job.sessionId.prefix(8))_merged"
        manager.addMessage(msg, to: parent)

        let postedId = parent.id
        DispatchQueue.main.async {
            // Reuse the same notifications the completion post uses — the
            // chat view already listens to `.devinAgentDidPostMessage` to
            // reload, and the Subagents list listens to `.devinAgentsDidChange`
            // for the row refresh.
            NotificationCenter.default.post(
                name: .devinAgentDidPostMessage,
                object: nil,
                userInfo: ["conversationId": postedId, "messageId": msg.id])
            NotificationCenter.default.post(
                name: .devinAgentsDidChange,
                object: nil,
                userInfo: ["sessionId": job.sessionId])
        }
        // Optional system notification when the app isn't foregrounded —
        // same gate as `postCompletion`, so a merge that lands while you're
        // away surfaces a local push.
        deliverMergedNotificationIfNeeded(for: job)
    }

    private func deliverMergedNotificationIfNeeded(for job: DevinAgentJob) {
        #if os(iOS)
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState != .active else { return }
            DevinAgentService.deliverMergedLocalNotification(for: job)
        }
        #elseif os(macOS)
        DispatchQueue.main.async {
            guard !NSApplication.shared.isActive else { return }
            DevinAgentService.deliverMergedLocalNotification(for: job)
        }
        #endif
    }

    private static func deliverMergedLocalNotification(for job: DevinAgentJob) {
        let content = UNMutableNotificationContent()
        content.title = "Devin · \(job.displayTitle)"
        content.body = job.prURL.map { "🎉 Merged — \($0)" } ?? "🎉 Devin's PR was merged."
        content.sound = .default
        let req = UNNotificationRequest(
            // Distinct id from the completion notification so they don't
            // collide if both land while the app is backgrounded.
            identifier: "loop.devin.\(job.sessionId).merged",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private static func completionBody(for job: DevinAgentJob) -> String {
        // Build a short informal summary of what the agent worked on.
        let summary = buildSummary(for: job)
        let prLine = job.prURL.map { "\n🔗 PR: \($0)" } ?? ""
        let dashLine = job.dashboardURL.map { "\n📂 [Open session](\($0))" } ?? ""

        switch job.status {
        case "finished":
            return "\(summary) — all done!\(prLine)\(dashLine)"
        case "blocked":
            return "\(summary) — paused and needs your input.\(prLine)\(dashLine)"
        case "expired":
            return "\(summary) — session timed out before finishing.\(dashLine)"
        case "cancelled":
            return "\(summary) — session was cancelled.\(dashLine)"
        case "stale":
            return "\(summary) — been a while with no progress, stopped tracking.\(prLine)\(dashLine)"
        default:
            return "\(summary) — hit an error and couldn't continue.\(prLine)\(dashLine)"
        }
    }

    /// Synthesize a brief natural-language summary from the best available
    /// data: title, last assistant message, or original task prompt.
    private static func buildSummary(for job: DevinAgentJob) -> String {
        // Prefer the session title if available (most descriptive).
        let headline: String
        if let title = job.title, !title.isEmpty {
            headline = title
        } else {
            // Fall back to the first line of the task prompt, truncated.
            let first = job.task.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first ?? job.task
            headline = first.count <= 60 ? first : String(first.prefix(57)) + "…"
        }

        // Try to pull the last Devin message as extra context (what it said
        // right before finishing). Keep it short — one sentence max.
        let lastDevinMsg = job.messages.last(where: { $0.type == "devin" })?.message
        let snippet: String? = lastDevinMsg.flatMap { msg in
            let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Take the first sentence (up to ~120 chars) for a brief excerpt.
            let firstSentence = trimmed.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).first ?? trimmed
            let capped = firstSentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if capped.isEmpty { return nil }
            return capped.count <= 120 ? capped : String(capped.prefix(117)) + "…"
        }

        if let snippet = snippet, snippet.lowercased() != headline.lowercased() {
            return "Devin worked on **\(headline)** — \(snippet)"
        }
        return "Devin worked on **\(headline)**"
    }

    private func deliverNotificationIfNeeded(for job: DevinAgentJob) {
        #if os(iOS)
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState != .active else { return }
            DevinAgentService.deliverLocalNotification(for: job)
        }
        #elseif os(macOS)
        DispatchQueue.main.async {
            guard !NSApplication.shared.isActive else { return }
            DevinAgentService.deliverLocalNotification(for: job)
        }
        #endif
    }

    private static func deliverLocalNotification(for job: DevinAgentJob) {
        let content = UNMutableNotificationContent()
        content.title = "Devin · \(job.displayTitle)"
        content.body = completionBody(for: job)
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "loop.devin.\(job.sessionId)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    #if os(iOS)
    @objc private func appWillResignActive() {
        guard loadJobs().contains(where: { !$0.isTerminal }) else { return }
        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask(withName: "loop.devin.poll") {
            UIApplication.shared.endBackgroundTask(taskId)
            taskId = .invalid
        }
        DispatchQueue.global(qos: .background).async { [weak self] in
            while let self = self,
                  self.loadJobs().contains(where: { !$0.isTerminal }) {
                Thread.sleep(forTimeInterval: 2.0)
            }
            DispatchQueue.main.async {
                if taskId != .invalid { UIApplication.shared.endBackgroundTask(taskId) }
            }
        }
    }
    #endif

    // MARK: - Response parsing helpers (Devin v3 SessionResponse / SessionMessage)

    /// Map v3's (`status`, `status_detail`) pair onto the simpler bucket the
    /// UI drives off of. Per docs:
    ///  - status=exit → task ran to completion (terminal)
    ///  - status=error → failure (terminal)
    ///  - status=running, status_detail=finished → task complete (terminal)
    ///  - status=running, status_detail=working → still going
    ///  - status=running, status_detail=waiting_for_* → paused waiting on user
    ///  - status=suspended → paused; the next send-message resumes it
    ///  - status=new/claimed/resuming → bootstrapping
    private static func normalizeStatus(_ status: String?,
                                        detail: String?,
                                        fallback: String) -> String {
        let s = (status ?? "").lowercased()
        let d = (detail ?? "").lowercased()

        if s == "exit" { return "finished" }
        if s == "error" { return "error" }
        if s == "running" && d == "finished" { return "finished" }
        if s == "running" && (d == "waiting_for_user" || d == "waiting_for_approval") {
            return "blocked"
        }
        if s == "running" { return "running" }
        if s == "suspended" {
            // Some suspend reasons are terminal-ish (out_of_credits, etc.) —
            // surface them as errors so the user sees a clear failure.
            switch d {
            case "out_of_credits", "out_of_quota", "no_quota_allocation",
                 "payment_declined", "usage_limit_exceeded",
                 "org_usage_limit_exceeded", "total_session_limit_exceeded",
                 "error":
                return "error"
            case "user_request":
                return "cancelled"
            case "inactivity":
                return "blocked"
            default:
                return "blocked"
            }
        }
        if s == "new" || s == "claimed" || s == "resuming" { return "running" }
        return fallback
    }

    /// Pull the PR url + state out of v3's `pull_requests: [{pr_url, pr_state}]`.
    /// Prefer a `merged` entry over `open`/`closed`/`draft` so the row never
    /// "demotes" from merged → open if Devin reports both (it shouldn't, but
    /// defense in depth). Returns nil when no PR has been opened yet.
    private static func extractPR(_ json: [String: Any]) -> (url: String, state: String?)? {
        if let prs = json["pull_requests"] as? [[String: Any]], !prs.isEmpty {
            // First pass: find a merged PR.
            for pr in prs {
                guard let url = pr["pr_url"] as? String, !url.isEmpty else { continue }
                if let state = pr["pr_state"] as? String, state.lowercased() == "merged" {
                    return (url, state)
                }
            }
            // Fallback: first PR with a non-empty url, whatever its state.
            for pr in prs {
                if let url = pr["pr_url"] as? String, !url.isEmpty {
                    return (url, pr["pr_state"] as? String)
                }
            }
        }
        // Legacy single-object shape — defensive only; v3 always returns an
        // array. Keep both candidate field names since older builds varied.
        if let pr = json["pull_request"] as? [String: Any] {
            if let url = pr["pr_url"] as? String, !url.isEmpty {
                return (url, pr["pr_state"] as? String)
            }
            if let url = pr["url"] as? String, !url.isEmpty {
                return (url, pr["pr_state"] as? String)
            }
        }
        return nil
    }

    /// Decode v3 SessionMessage list items into our local transcript shape.
    /// v3 fields: `event_id`, `source` ("devin" | "user"), `message`,
    /// `created_at` (epoch integer). No `type` / `username` — the source
    /// enum is the only role signal.
    private static func extractMessages(_ items: [[String: Any]]) -> [DevinTranscriptMessage] {
        return items.compactMap { dict -> DevinTranscriptMessage? in
            guard let eventId = dict["event_id"] as? String,
                  let message = dict["message"] as? String,
                  let source = dict["source"] as? String else { return nil }
            let createdAt = dict["created_at"]
            let timestamp: String
            if let n = createdAt as? NSNumber {
                timestamp = String(n.int64Value)
            } else if let n = createdAt as? Int {
                timestamp = String(n)
            } else if let s = createdAt as? String {
                timestamp = s
            } else {
                timestamp = ""
            }
            return DevinTranscriptMessage(
                eventId: eventId,
                type: source,
                message: message,
                timestamp: timestamp,
                username: nil)
        }
    }

    private static func errorDetail(_ json: [String: Any]) -> String? {
        if let err = json["error"] as? [String: Any] {
            return (err["message"] as? String) ?? (err["code"] as? String)
        }
        if let detail = json["detail"] {
            if let s = detail as? String { return s }
            if let arr = detail as? [[String: Any]] {
                return arr.compactMap { $0["msg"] as? String }.joined(separator: "; ")
            }
        }
        return (json["error"] as? String) ?? (json["message"] as? String)
    }
}
