//
//  OpenClawMessagePoller.swift
//  Loop
//
//  Background polling for new OpenClaw messages. Where `LoopRunnerPoller` watches
//  Portable Loop Runner VMs, this watches the OpenClaw execution backend(s): it
//  lists each configured + validated backend's agent sessions and notices when a
//  session's `updatedAt` advances — i.e. a new message landed (an agent reply
//  that finished after the app backgrounded, a Telegram/other-surface turn, etc).
//
//  When a session advances and the change isn't already visible in the foreground
//  (the conversation isn't open and no in-app turn is driving it), the poller
//  pulls the fresh transcript into the store's cache and fires a local
//  notification. Tapping it routes to that conversation (AppDelegate), which now
//  renders instantly from the pre-loaded cache.
//
//  Two cadences, mirroring `LoopRunnerPoller`:
//    Foreground — a DispatchSourceTimer (25 s) so activity in a *different*
//      conversation than the one on-screen still surfaces.
//    Background — the brief grace window iOS grants after backgrounding (catches a
//      turn that finishes seconds after the user leaves) plus a BGAppRefreshTask
//      (`com.loop.openclaw.poll`, ~15 min, iOS-throttled, supplemental). Longer
//      latencies need true push, which isn't built yet.
//
//  Change detection is per (backend, session) via an `updatedAt` cursor in
//  UserDefaults. The first poll of a backend seeds cursors silently so the
//  existing backlog doesn't fire a notification storm.
//

import Foundation
import UserNotifications
#if os(iOS)
import BackgroundTasks
import UIKit
#endif
import os

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the poller detects a new OpenClaw message so open views can
    /// react (e.g. flag the conversation unread). userInfo: `conversation_id`.
    static let openClawMessageDidArrive = Notification.Name("loop.openclaw.messageDidArrive")
}

// MARK: - OpenClawMessagePoller

final class OpenClawMessagePoller {

    static let shared = OpenClawMessagePoller()

    /// BGAppRefreshTask identifier. Must appear in Info.plist under
    /// BGTaskSchedulerPermittedIdentifiers.
    static let bgTaskIdentifier = "com.loop.openclaw.poll"

    /// userInfo `type` marker on the local notifications this poller posts.
    static let notificationType = "openclaw_message"

    private static let log = Logger(subsystem: "com.bhat.intel", category: "OpenClawMessagePoller")

    /// Foreground polling interval (seconds). Gentler than the runner poller's 3 s
    /// — OpenClaw turns are slower and each tick is an SSH round trip per backend.
    private let foregroundInterval: TimeInterval = 25

    /// Guards mutable state across the timer callback and public API.
    private let lock = NSLock()

    private var foregroundTimer: DispatchSourceTimer?

    /// True while a `pollAllBackends()` pass is still awaiting its per-backend
    /// session-list callbacks. Guards against overlapping ticks: each `openclaw`
    /// SSH command is serialized daemon-side (and can take up to 30 s to time
    /// out), while the foreground timer fires every 25 s and the background
    /// grace timer every 8 s. Without this, ticks would queue up faster than
    /// they drain — the runaway background-task pile-up. A still-running pass
    /// means a new tick has nothing to add, so we drop it.
    private var pollInFlight = false

    /// Notification ids already posted this process, so the same advance polled
    /// twice before the cursor persists can't double-fire.
    private var notifiedKeys: Set<String> = []

    /// Foreground/active flag and the on-screen conversation id, snapshotted from
    /// the main thread so the poll loop can suppress notifications for what the
    /// user is already looking at without touching UIKit off-main.
    private var appIsForeground = false
    private var visibleConversationId: String?

    #if os(iOS)
    private var graceTimer: DispatchSourceTimer?
    private var graceTaskId: UIBackgroundTaskIdentifier = .invalid
    /// Latches `setTaskCompleted` so the BGAppRefresh task is finished exactly once.
    private var bgTaskFinished = false
    #endif

    private init() {
        // Track which conversation is on-screen so we never notify about the one
        // the user is actively reading. Posted on the main thread by the manager.
        NotificationCenter.default.addObserver(
            forName: .activeConversationDidChange, object: nil, queue: .main) { [weak self] note in
                let id = note.userInfo?["conversationId"] as? String
                self?.lock.lock(); self?.visibleConversationId = id; self?.lock.unlock()
            }
    }

    // MARK: - Bootstrap

    /// Call from `application(_:didFinishLaunchingWithOptions:)`. Registers the
    /// BGAppRefreshTask handler (must happen before the launch method returns).
    func bootstrap() {
        #if os(iOS)
        registerBGTask()
        #endif
    }

    // MARK: - Foreground lifecycle

    /// Call from `sceneDidBecomeActive`. Starts the foreground timer.
    func startForegroundPolling() {
        #if os(iOS)
        endBackgroundGracePolling()   // back in foreground — the grace window is moot
        #endif
        lock.lock()
        appIsForeground = true
        visibleConversationId = SimpleConversationManager.shared.currentConversation?.id
        guard foregroundTimer == nil else { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: foregroundInterval)
        timer.setEventHandler { [weak self] in self?.pollAllBackends() }
        foregroundTimer = timer
        lock.unlock()
        timer.resume()
        Self.log.info("Foreground polling started")
    }

    /// Call from `sceneWillResignActive`. Stops the foreground timer, keeps polling
    /// through the brief background window iOS grants, and schedules the next
    /// background refresh.
    func stopForegroundPolling() {
        lock.lock()
        appIsForeground = false
        foregroundTimer?.cancel()
        foregroundTimer = nil
        lock.unlock()
        Self.log.info("Foreground polling stopped")

        #if os(iOS)
        startBackgroundGracePolling()
        submitNextBGTask()
        #endif
    }

    #if os(iOS)
    /// After the app backgrounds, iOS grants a short execution window. Keep polling
    /// for that window so a turn that finishes right after the user leaves still
    /// fires its notification — without waiting for the (throttled) BGAppRefresh.
    private func startBackgroundGracePolling() {
        let app = UIApplication.shared
        lock.lock()
        guard graceTimer == nil else { lock.unlock(); return }
        let taskId = app.beginBackgroundTask(withName: "loop.openclaw.grace") { [weak self] in
            self?.endBackgroundGracePolling()
        }
        guard taskId != .invalid else { lock.unlock(); return }
        graceTaskId = taskId

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3, repeating: 8)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Stop before iOS suspends us, otherwise the task is force-ended.
            if app.backgroundTimeRemaining < 10 {
                self.endBackgroundGracePolling()
                return
            }
            self.pollAllBackends()
        }
        graceTimer = timer
        lock.unlock()
        timer.resume()
        Self.log.info("Background grace polling started")
    }

    private func endBackgroundGracePolling() {
        lock.lock()
        graceTimer?.cancel()
        graceTimer = nil
        let taskId = graceTaskId
        graceTaskId = .invalid
        lock.unlock()
        if taskId != .invalid {
            UIApplication.shared.endBackgroundTask(taskId)
        }
    }
    #endif

    // MARK: - Per-(backend, session) cursor (UserDefaults)

    private func cursorKey(backend: String, session: String) -> String {
        "loop.openclaw.\(backend).\(session).updatedAt"
    }

    private func seededKey(backend: String) -> String {
        "loop.openclaw.\(backend).seeded"
    }

    private func cursor(backend: String, session: String) -> Date {
        let ti = UserDefaults.standard.double(forKey: cursorKey(backend: backend, session: session))
        return ti > 0 ? Date(timeIntervalSince1970: ti) : .distantPast
    }

    private func setCursor(_ date: Date, backend: String, session: String) {
        UserDefaults.standard.set(date.timeIntervalSince1970,
                                  forKey: cursorKey(backend: backend, session: session))
    }

    /// Remove persisted cursors for a deleted backend.
    func clearState(forBackend backendID: String) {
        let defaults = UserDefaults.standard
        let prefix = "loop.openclaw.\(backendID)."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Core poll loop

    /// Poll every configured + validated OpenClaw backend. Safe to call from any
    /// queue; wraps the work in a background-task assertion on iOS.
    func pollAllBackends() {
        let backends = ExecutionBackendStore.shared.remoteBackends.filter {
            $0.config.isConfigured && ExecutionBackendStore.shared.isValidated(id: $0.id)
        }
        guard !backends.isEmpty else { return }

        // Drop this tick if the previous pass is still draining its per-backend
        // session-list callbacks — overlapping passes only pile up SSH commands
        // (each serialized + up-to-30s) against a timer that fires far sooner.
        lock.lock()
        guard !pollInFlight else { lock.unlock(); return }
        pollInFlight = true
        lock.unlock()

        #if os(iOS)
        let app = UIApplication.shared
        let taskId = app.beginBackgroundTask(withName: "loop.openclaw.poll") {}
        #endif
        let group = DispatchGroup()

        for backend in backends {
            guard let store = SimpleConversationManager.shared.remoteStore(for: backend.id) else { continue }
            group.enter()
            store.listSessionsForPoll { [weak self] sessions in
                self?.handleSessionList(sessions, backend: backend, store: store)
                group.leave()
            }
        }

        group.notify(queue: .global()) { [weak self] in
            self?.lock.lock(); self?.pollInFlight = false; self?.lock.unlock()
            #if os(iOS)
            if taskId != .invalid { app.endBackgroundTask(taskId) }
            #endif
        }
    }

    /// Compare a backend's freshly-listed sessions against the stored cursors and
    /// notify for any that advanced. Runs on the store's `ioQueue` (the
    /// `listSessionsForPoll` callback queue).
    private func handleSessionList(_ sessions: [SimpleConversation],
                                   backend: ExecutionBackend,
                                   store: OpenClawConversationStore) {
        guard !sessions.isEmpty else { return }

        let defaults = UserDefaults.standard
        let seeded = defaults.bool(forKey: seededKey(backend: backend.id))

        // First sight of this backend: record every session's current high-water
        // mark without notifying, so we don't alert for the pre-existing backlog.
        guard seeded else {
            for s in sessions { setCursor(s.updatedAt, backend: backend.id, session: s.id) }
            defaults.set(true, forKey: seededKey(backend: backend.id))
            Self.log.info("Seeded \(sessions.count) session cursor(s) for backend \(backend.id, privacy: .public)")
            return
        }

        lock.lock()
        let foreground = appIsForeground
        let visible = visibleConversationId
        lock.unlock()

        for session in sessions {
            let previous = cursor(backend: backend.id, session: session.id)
            guard session.updatedAt > previous else { continue }
            // Advance the cursor up front so a later poll doesn't re-detect this
            // same change (best effort, matching the runner poller's `since`).
            setCursor(session.updatedAt, backend: backend.id, session: session.id)

            // Suppress what the user can already see: the on-screen conversation
            // while foregrounded, or a turn being driven in-app right now.
            if foreground && visible == session.id { continue }
            if store.isInFlight(id: session.id) { continue }

            // Pull the fresh transcript so the tap lands on loaded content and we
            // can preview the new message. Then decide whether it warrants a
            // notification (only when the freshest line is an assistant reply).
            store.refreshConversation(id: session.id) { [weak self] reachable in
                guard let self, reachable else { return }
                let last = store.conversation(id: session.id)?.messages.last
                guard let last, last.role == "assistant", !last.content.isEmpty else { return }
                self.notify(backend: backend, session: session, body: last.content,
                            stamp: session.updatedAt)
            }
        }
    }

    // MARK: - Notification

    private func notify(backend: ExecutionBackend, session: SimpleConversation,
                        body: String, stamp: Date) {
        let key = "\(backend.id).\(session.id).\(Int(stamp.timeIntervalSince1970 * 1000))"
        lock.lock()
        let isNew = notifiedKeys.insert(key).inserted
        lock.unlock()
        guard isNew else { return }

        let content = UNMutableNotificationContent()
        let convTitle = session.title.isEmpty ? "OpenClaw" : session.title
        content.title = "Loop · \(convTitle)"
        content.body = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
        content.sound = .default
        content.userInfo = [
            "type": Self.notificationType,
            "backend_id": backend.id,
            "conversation_id": session.id,
        ]

        let request = UNNotificationRequest(
            identifier: "openclaw.msg.\(key)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Self.log.error("Notification add failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        NotificationCenter.default.post(
            name: .openClawMessageDidArrive, object: nil,
            userInfo: ["conversation_id": session.id]
        )
    }

    // MARK: - Background task (iOS)

    #if os(iOS)
    private func registerBGTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.bgTaskIdentifier, using: nil) { [weak self] task in
                guard let task = task as? BGAppRefreshTask else { return }
                self?.handleBGTask(task)
            }
        Self.log.info("Registered BGAppRefreshTask: \(Self.bgTaskIdentifier)")
    }

    func submitNextBGTask() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            Self.log.info("Scheduled next BGAppRefreshTask")
        } catch {
            Self.log.error("BGAppRefreshTask submit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleBGTask(_ task: BGAppRefreshTask) {
        submitNextBGTask()
        // The poll is async (SSH + transcript reads). Give it a bounded window and
        // mark the task complete once the grace deadline lapses or iOS expires us.
        // The expiration handler and the deadline can fire on different threads, so
        // latch completion under the lock — `setTaskCompleted` must run exactly once.
        let finish: (Bool) -> Void = { [weak self] success in
            guard let self else { return }
            self.lock.lock()
            let alreadyDone = self.bgTaskFinished
            self.bgTaskFinished = true
            self.lock.unlock()
            guard !alreadyDone else { return }
            task.setTaskCompleted(success: success)
        }
        lock.lock(); bgTaskFinished = false; lock.unlock()
        task.expirationHandler = { finish(false) }
        pollAllBackends()
        // BGAppRefresh gets ~30 s; let the async polls run, then close out.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 25) { finish(true) }
    }
    #endif

    // MARK: - Notification tap routing

    /// True if the notification belongs to this poller.
    static func isMessageNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["type"] as? String) == notificationType
    }

    /// The conversation id a message notification routes to.
    static func conversationId(from userInfo: [AnyHashable: Any]) -> String? {
        userInfo["conversation_id"] as? String
    }
}
