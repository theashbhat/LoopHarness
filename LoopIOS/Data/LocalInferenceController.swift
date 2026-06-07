//
//  LocalInferenceController.swift
//  Loop
//
//  A tiny process-wide handle on the in-flight local inference request so the
//  background-handoff path can hard-cancel it. The provider clients
//  (AnthropicChat / OpenAIChat / FireworksChat) all create a single streaming
//  `URLSessionDataTask` per turn but never retained it, so there was no way to
//  stop a local turn when handing it off to a runner — it would keep running in
//  iOS's background grace window and "win" the race. Each client now `track`s
//  its task here; the handoff calls `cancelActive()`.
//
//  We hold the task weakly: URLSession retains it until completion, so the weak
//  ref stays valid while running and auto-clears once finished (cancel then
//  no-ops). One active local turn at a time on device, so a single slot is
//  enough.
//

import Foundation

final class LocalInferenceController {
    static let shared = LocalInferenceController()
    private init() {}

    private let lock = NSLock()
    private weak var activeTask: URLSessionTask?

    /// Record the streaming task for the current local turn.
    func track(_ task: URLSessionTask) {
        lock.lock(); activeTask = task; lock.unlock()
    }

    /// Cancel the in-flight local inference request, if any is still running.
    /// Returns true if a running task was cancelled. The cancelled task's
    /// completion fires with a cancellation error, which the handoff guard
    /// (`abandonedLocalTurns`) swallows so no stray error message is written.
    @discardableResult
    func cancelActive() -> Bool {
        lock.lock()
        let task = activeTask
        activeTask = nil
        lock.unlock()
        guard let task = task, task.state == .running || task.state == .suspended else {
            return false
        }
        task.cancel()
        return true
    }
}
