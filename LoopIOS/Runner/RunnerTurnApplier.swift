//
//  RunnerTurnApplier.swift
//  Loop
//
//  Single, exactly-once write point for a completed Loop Runner turn that was
//  handed off from a local conversation. Two delivery channels race to deliver
//  the same turn:
//
//    1. the completion APNs push (tapped → AppDelegate fetches the turn), and
//    2. the foreground poller (`LoopRunnerPoller`) seeing the completed turn.
//
//  Both funnel through `applyRunnerTurn`, which dedupes by `turn_id` against a
//  persisted set so the conversation gets exactly one assistant message no
//  matter which channel wins (or whether the app was killed in between).
//
//  Persistence is in UserDefaults and MUST survive app termination: the app may
//  be force-quit before the push arrives, then cold-started by the tap. The
//  turn→conversation map is the fallback for the poller path, where the runner's
//  `/turns` response is the only source of `conversation_id`.
//

import Foundation
import os

extension Notification.Name {
    /// Posted (main queue) after a handed-off runner turn is written into a
    /// conversation, so an open MessagingVC can reload if it's that chat.
    static let runnerTurnApplied = Notification.Name("loop.runner.turnApplied")
}

enum RunnerTurnApplier {

    private static let log = Logger(subsystem: "com.bhat.intel", category: "RunnerTurnApplier")

    private static let appliedKey = "loop.runner.handoff.applied"      // [turnId] (ordered)
    private static let mapKey = "loop.runner.handoff.map"              // ["turnId\tconvId"] (ordered)
    private static let cap = 50

    /// Serializes the read-modify-write of the persisted dedup set + map so two
    /// concurrent deliveries can't both pass the `contains` check.
    private static let lock = NSLock()

    // MARK: - Handoff mapping

    /// What we remember about a handed-off turn until its reply lands.
    struct HandoffRecord {
        let conversationId: String
        /// Display name of the model that ran on the VM (for the message byline).
        let model: String?
    }

    /// Remember which conversation + model a handed-off turn used. Called when the
    /// background handoff submit succeeds, so the reply can be reconciled into the
    /// right chat and stamped with the model that actually ran on the VM.
    static func recordHandoff(turnId: String, conversationId: String, model: String?) {
        lock.lock(); defer { lock.unlock() }
        var map = loadMap()
        map[turnId] = HandoffRecord(conversationId: conversationId, model: model)
        saveMap(map)
    }

    /// Already-applied check (used to suppress a duplicate push banner).
    static func isApplied(turnId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loadApplied().contains(turnId)
    }

    /// The conversation a handed-off turn belongs to, from the persisted map.
    static func conversationId(forTurn turnId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loadMap()[turnId]?.conversationId
    }

    // MARK: - Apply

    /// Write a completed runner turn's reply into its conversation, exactly once.
    /// Returns true if this call performed the write, false if it was a duplicate
    /// or the conversation couldn't be resolved. `conversationId` from the push /
    /// poll payload takes precedence; the persisted map is the fallback.
    @discardableResult
    static func applyRunnerTurn(turnId: String, conversationId: String?, text: String) -> Bool {
        guard !text.isEmpty else { return false }

        lock.lock()
        var applied = loadApplied()
        if applied.contains(turnId) {
            lock.unlock()
            return false
        }
        let record = loadMap()[turnId]
        let resolved = (conversationId?.isEmpty == false ? conversationId : nil) ?? record?.conversationId
        guard let convId = resolved else {
            lock.unlock()
            log.error("applyRunnerTurn: no conversation for turn \(turnId, privacy: .public)")
            return false
        }
        guard let conversation = SimpleConversationManager.shared.getConversation(by: convId) else {
            lock.unlock()
            log.error("applyRunnerTurn: conversation \(convId, privacy: .public) not found")
            return false
        }
        // Claim the turn before writing so a racing channel sees it as applied.
        applied.append(turnId)
        if applied.count > cap { applied.removeFirst(applied.count - cap) }
        saveApplied(applied)
        lock.unlock()

        var message = MessageStruct(role: "assistant", content: text)
        // Stamp the byline with the model that ran + a "VM" indicator so it's
        // clear this reply was produced in the background on the VM.
        message.model = record?.model.map { "\($0) · VM" } ?? "VM"
        // Persistence + any UI snapshot refresh stays on main (the conversation
        // manager mutates its `currentConversation` snapshot here).
        DispatchQueue.main.async {
            SimpleConversationManager.shared.addMessage(message, to: conversation)
            NotificationCenter.default.post(
                name: .runnerTurnApplied, object: nil,
                userInfo: ["conversation_id": convId])
        }
        log.info("applied runner turn \(turnId, privacy: .public) → conversation \(convId, privacy: .public)")
        return true
    }

    // MARK: - UserDefaults helpers

    private static func loadApplied() -> [String] {
        UserDefaults.standard.stringArray(forKey: appliedKey) ?? []
    }

    private static func saveApplied(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: appliedKey)
    }

    private static func loadMap() -> [String: HandoffRecord] {
        let rows = UserDefaults.standard.stringArray(forKey: mapKey) ?? []
        var map: [String: HandoffRecord] = [:]
        for row in rows {
            let p = row.components(separatedBy: "\t")
            guard p.count >= 2 else { continue }
            let model = (p.count >= 3 && !p[2].isEmpty) ? p[2] : nil
            map[p[0]] = HandoffRecord(conversationId: p[1], model: model)
        }
        return map
    }

    private static func saveMap(_ map: [String: HandoffRecord]) {
        // Preserve recency by capping the row count; dictionaries are unordered,
        // so this caps total size rather than strictly evicting oldest — fine for
        // a fallback lookup that the push payload usually satisfies anyway.
        var rows = map.map { "\($0.key)\t\($0.value.conversationId)\t\($0.value.model ?? "")" }
        if rows.count > cap { rows = Array(rows.suffix(cap)) }
        UserDefaults.standard.set(rows, forKey: mapKey)
    }
}
