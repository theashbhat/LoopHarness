//
//  LoopRunnerPoller.swift
//  Loop
//
//  Background polling service for Portable Loop Runner VMs. Two cadences:
//
//    Foreground active — poll every 3 s while a turn is in flight. Driven by
//    a DispatchSourceTimer that starts/stops with scene activation.
//
//    Background — a BGAppRefreshTask (identifier `com.loop.runner.poll`) that
//    iOS schedules opportunistically (~15 min). Purely supplemental; iOS will
//    throttle it, which is fine.
//
//  On each tick the poller calls `pollTurns(since:)` + `pollJobs(since:)` on
//  every configured runner, advancing the per-runner `since` cursor stored in
//  UserDefaults. Newly-completed turns/jobs fire a local notification via
//  UNUserNotificationCenter.
//
//  Patterns mirror CursorAgentService / DevinAgentService:
//    - In-process DispatchSourceTimer + beginBackgroundTask grace
//    - Resume on launch via `bootstrap()`
//    - Notification through UNUserNotificationCenter
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
    /// Posted when a runner turn completes so open views can react.
    static let runnerTurnDidComplete = Notification.Name("loop.runner.turnDidComplete")
}

// MARK: - LoopRunnerPoller

final class LoopRunnerPoller {

    static let shared = LoopRunnerPoller()

    /// BGAppRefreshTask identifier. Must appear in Info.plist under
    /// BGTaskSchedulerPermittedIdentifiers.
    static let bgTaskIdentifier = "com.loop.runner.poll"

    private static let log = Logger(subsystem: "com.bhat.intel", category: "LoopRunnerPoller")

    /// Foreground polling interval (seconds).
    private let foregroundInterval: TimeInterval = 3

    /// Set of turn ids we've already notified about. Prevents duplicate
    /// notifications when the same completed turn appears in consecutive
    /// polls before the server cursor advances past it.
    private var notifiedTurnIds: Set<String> = []
    private var notifiedJobIds: Set<String> = []

    /// Guards mutable state across the timer callback and public API.
    private let lock = NSLock()

    private var foregroundTimer: DispatchSourceTimer?
    private var isPolling = false

    #if os(iOS)
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    /// Timer + task for the short polling window iOS grants right after the
    /// app backgrounds (see `startBackgroundGracePolling`).
    private var graceTimer: DispatchSourceTimer?
    private var graceTaskId: UIBackgroundTaskIdentifier = .invalid
    #endif

    private init() {}

    // MARK: - Bootstrap

    /// Call from `application(_:didFinishLaunchingWithOptions:)`. Registers the
    /// BGAppRefreshTask handler (must happen before the launch method returns).
    func bootstrap() {
        #if os(iOS)
        registerBGTask()
        #endif
    }

    // MARK: - Foreground lifecycle

    /// Call from `sceneDidBecomeActive`. Starts the 3-second foreground timer.
    func startForegroundPolling() {
        #if os(iOS)
        endBackgroundGracePolling()   // back in foreground — the grace window is moot
        #endif
        lock.lock(); defer { lock.unlock() }
        guard foregroundTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: foregroundInterval)
        timer.setEventHandler { [weak self] in
            self?.pollAllRunners()
        }
        timer.resume()
        foregroundTimer = timer
        Self.log.info("Foreground polling started")
    }

    /// Call from `sceneWillResignActive`. Stops the foreground timer, keeps
    /// polling through the brief background window iOS grants, and schedules the
    /// next background refresh.
    func stopForegroundPolling() {
        lock.lock()
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
    /// After the app backgrounds, iOS grants ~30 s of execution. Keep polling
    /// every few seconds for that window so a short turn that finishes right
    /// after the user leaves still fires its notification — without waiting for
    /// the (iOS-throttled, ~15 min) BGAppRefresh. Longer tasks need APNs.
    private func startBackgroundGracePolling() {
        let app = UIApplication.shared

        lock.lock()
        guard graceTimer == nil else { lock.unlock(); return }
        let taskId = app.beginBackgroundTask(withName: "loop.runner.grace") { [weak self] in
            SSHTunnelManager.shared.closeAll()
            self?.endBackgroundGracePolling()
        }
        guard taskId != .invalid else { lock.unlock(); return }
        graceTaskId = taskId

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3, repeating: 4)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Stop before iOS suspends us, otherwise the task is force-ended.
            if app.backgroundTimeRemaining < 8 {
                // The SSH connection won't survive suspension; tear tunnels down
                // so the next foreground poll rebuilds cleanly rather than reusing
                // a dead socket.
                SSHTunnelManager.shared.closeAll()
                self.endBackgroundGracePolling()
                return
            }
            self.pollAllRunners()
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

    // MARK: - Per-runner state (UserDefaults)

    private func sinceKey(for runnerId: String, kind: String) -> String {
        "loop.runner.\(runnerId).\(kind).since"
    }

    func lastSince(for runnerId: String, kind: String) -> Date {
        let key = sinceKey(for: runnerId, kind: kind)
        let ti = UserDefaults.standard.double(forKey: key)
        return ti > 0 ? Date(timeIntervalSince1970: ti) : Date.distantPast
    }

    func setLastSince(_ date: Date, for runnerId: String, kind: String) {
        let key = sinceKey(for: runnerId, kind: kind)
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key)
    }

    /// Remove persisted state for a deleted runner.
    func clearState(for runnerId: String) {
        for kind in ["turns", "jobs"] {
            UserDefaults.standard.removeObject(forKey: sinceKey(for: runnerId, kind: kind))
        }
    }

    // MARK: - Core poll loop

    func pollAllRunners() {
        let runners = RunnerStore.shared.loadRunners()
        guard !runners.isEmpty else { return }

        #if os(iOS)
        let app = UIApplication.shared
        let taskId = app.beginBackgroundTask {
            // Expiration handler — nothing to clean up, the async work
            // will be cancelled when the process suspends.
        }
        #endif

        let group = DispatchGroup()
        for runner in runners {
            group.enter()
            Task {
                await pollRunner(runner)
                group.leave()
            }
        }
        group.notify(queue: .global()) {
            #if os(iOS)
            app.endBackgroundTask(taskId)
            #endif
        }
    }

    /// Builds the right polling transport for a runner. For an SSH-backed runner
    /// it prefers a persistent `direct-tcpip` tunnel (native HTTP over a warm
    /// connection — no per-poll handshake) via `SSHTunnelManager`, falling back
    /// to the `curl`-over-SSH-exec client if the tunnel can't be established
    /// (e.g. `AllowTcpForwarding no`). Non-SSH runners use the direct URLSession
    /// client. Returns nil if the shared secret or URL is missing.
    private func makeClient(for runner: RunnerConfig) async -> RunnerPolling? {
        guard let secret = RunnerStore.shared.secret(for: runner.secretRef) else { return nil }
        if let remotePort = runner.sshRemotePort {
            if let url = await SSHTunnelManager.shared.tunneledBaseURL(remotePort: remotePort) {
                return LoopRunnerClient(baseURL: url, sharedSecret: secret)
            }
            return LoopRunnerSSHClient(sharedSecret: secret, remotePort: remotePort)
        }
        guard let url = URL(string: runner.baseURL) else { return nil }
        return LoopRunnerClient(baseURL: url, sharedSecret: secret)
    }

    private func pollRunner(_ runner: RunnerConfig) async {
        guard let client = await makeClient(for: runner) else { return }

        // Poll turns
        do {
            let turnsSince = lastSince(for: runner.id, kind: "turns")
            let (turns, serverTime) = try await client.pollTurns(since: turnsSince)
            setLastSince(serverTime, for: runner.id, kind: "turns")

            var updatedRunner = runner
            updatedRunner.lastPollTime = Date()
            updatedRunner.lastSeenTurnCount += turns.filter { $0.isCompleted }.count
            RunnerStore.shared.updateRunner(updatedRunner)

            for turn in turns where turn.isCompleted {
                notifyIfNew(turn: turn, runner: runner)
            }
        } catch {
            Self.log.error("Turn poll failed for \(runner.nickname): \(error.localizedDescription)")
        }

        // Poll jobs
        do {
            let jobsSince = lastSince(for: runner.id, kind: "jobs")
            let (jobs, serverTime) = try await client.pollJobs(since: jobsSince)
            setLastSince(serverTime, for: runner.id, kind: "jobs")

            for job in jobs where job.isCompleted {
                notifyJobIfNew(job: job, runner: runner)
            }
        } catch {
            Self.log.error("Job poll failed for \(runner.nickname): \(error.localizedDescription)")
        }
    }

    // MARK: - Notifications

    private func notifyIfNew(turn: RunnerTurn, runner: RunnerConfig) {
        lock.lock()
        let isNew = notifiedTurnIds.insert(turn.id).inserted
        lock.unlock()
        guard isNew else { return }

        let content = UNMutableNotificationContent()
        content.title = "Loop · \(runner.nickname)"
        if let error = turn.error, !error.isEmpty {
            content.body = "Error: \(String(error.prefix(120)))"
        } else if let response = turn.finalResponse, !response.isEmpty {
            content.body = String(response.prefix(120))
        } else {
            content.body = "Turn completed"
        }
        content.sound = .default
        content.userInfo = [
            "type": "runner_turn",
            "runner_id": runner.id,
            "turn_id": turn.id,
        ]

        let request = UNNotificationRequest(
            identifier: "runner.turn.\(turn.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Self.log.error("Notification add failed: \(error.localizedDescription)")
            }
        }

        NotificationCenter.default.post(
            name: .runnerTurnDidComplete,
            object: nil,
            userInfo: ["runner_id": runner.id, "turn_id": turn.id]
        )
    }

    private func notifyJobIfNew(job: RunnerJob, runner: RunnerConfig) {
        lock.lock()
        let isNew = notifiedJobIds.insert(job.id).inserted
        lock.unlock()
        guard isNew else { return }

        let content = UNMutableNotificationContent()
        content.title = "Loop · \(runner.nickname)"
        if let error = job.error, !error.isEmpty {
            content.body = "Job error: \(String(error.prefix(120)))"
        } else if let result = job.result, !result.isEmpty {
            content.body = "Job done: \(String(result.prefix(110)))"
        } else {
            content.body = "Job completed"
        }
        content.sound = .default
        content.userInfo = [
            "type": "runner_job",
            "runner_id": runner.id,
            "job_id": job.id,
            "turn_id": job.turnId,
        ]

        let request = UNNotificationRequest(
            identifier: "runner.job.\(job.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Background task (iOS)

    #if os(iOS)
    private func registerBGTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.bgTaskIdentifier,
            using: nil
        ) { [weak self] task in
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
            Self.log.error("BGAppRefreshTask submit failed: \(error.localizedDescription)")
        }
    }

    private func handleBGTask(_ task: BGAppRefreshTask) {
        submitNextBGTask()

        let workItem = DispatchWorkItem { [weak self] in
            self?.pollAllRunners()
        }

        task.expirationHandler = {
            workItem.cancel()
        }

        workItem.notify(queue: .global()) {
            task.setTaskCompleted(success: !workItem.isCancelled)
        }

        DispatchQueue.global(qos: .utility).async(execute: workItem)
    }
    #endif

    // MARK: - Notification tap routing

    /// Returns true if the notification userInfo belongs to the runner subsystem.
    static func isRunnerNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let type = userInfo["type"] as? String else { return false }
        return type == "runner_turn" || type == "runner_job"
    }

    /// Returns the conversation-relevant turn id from a runner notification
    /// so AppDelegate can route to it.
    static func turnId(from userInfo: [AnyHashable: Any]) -> String? {
        return userInfo["turn_id"] as? String
    }

    static func runnerId(from userInfo: [AnyHashable: Any]) -> String? {
        return userInfo["runner_id"] as? String
    }
}
