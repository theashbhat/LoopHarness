//
//  VMCronPoller.swift
//  Loop
//
//  Backstop delivery for VM cron agents. The primary path is the `runner_turn`
//  push each cron firing POSTs; this poller catches runs whose push was dropped
//  (device offline / killed at fire time) by SSH-reading each job's
//  `results.ndjson` past a stored cursor and feeding new lines through
//  `RunnerTurnApplier` — which dedups by `turn_id`, so push + poll can never
//  double-write the same run into the thread.
//
//  Foreground-only and deliberately gentle (60s): cron runs are infrequent and
//  each tick does one short SSH `cat` per job.
//

import Foundation
import os

final class VMCronPoller {

    static let shared = VMCronPoller()
    private init() {}

    private static let log = Logger(subsystem: "com.bhat.intel", category: "VMCronPoller")

    private let foregroundInterval: TimeInterval = 60
    private let lock = NSLock()
    private var foregroundTimer: DispatchSourceTimer?
    private var pollInFlight = false

    /// Start a one-shot catch-up at launch so a result that landed while the app
    /// was away surfaces on next open without waiting a full interval.
    func bootstrap() {
        pollNow()
    }

    func startForegroundPolling() {
        lock.lock()
        guard foregroundTimer == nil else { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3, repeating: foregroundInterval)
        timer.setEventHandler { [weak self] in self?.pollNow() }
        foregroundTimer = timer
        lock.unlock()
        timer.resume()
        Self.log.info("VM cron polling started")
    }

    func stopForegroundPolling() {
        lock.lock()
        foregroundTimer?.cancel()
        foregroundTimer = nil
        lock.unlock()
        Self.log.info("VM cron polling stopped")
    }

    func pollNow() {
        lock.lock()
        if pollInFlight { lock.unlock(); return }
        let jobs = VMCronStore.shared.all()
        guard !jobs.isEmpty else { lock.unlock(); return }
        pollInFlight = true
        lock.unlock()

        Task { [weak self] in
            guard let self else { return }
            for job in jobs {
                await self.drain(job)
            }
            self.lock.lock(); self.pollInFlight = false; self.lock.unlock()
        }
    }

    /// Apply any unseen result lines for one job and advance its cursor.
    private func drain(_ job: VMCronJob) async {
        guard let result = await VMCronManager.shared.fetchNewResults(for: job) else { return }
        var applied = false
        for line in result.lines {
            let body = !line.text.isEmpty ? line.text
                     : (line.error.isEmpty ? "" : "⚠️ \(line.error)")
            guard !body.isEmpty else { continue }
            let convId = line.conversationId.isEmpty ? job.conversationId : line.conversationId
            if RunnerTurnApplier.applyRunnerTurn(turnId: line.turnId, conversationId: convId, text: body) {
                applied = true
            }
        }
        // Persist the cursor even when every line was a push-applied duplicate, so
        // we don't re-read them forever. Re-fetch the record in case it changed.
        if var fresh = VMCronStore.shared.all().first(where: { $0.id == job.id }) {
            fresh.resultsCursor = result.newCursor
            if applied { fresh.lastRunAt = Date() }
            VMCronStore.shared.upsert(fresh)
        }
    }
}
