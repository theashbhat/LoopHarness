//
//  ToolCallGuard.swift
//  Loop
//
//  Anti-loop / duplicate tool-call guard. Sits between the model's tool
//  requests and the actual skill dispatch, catching models (Kimi K2 and
//  others) that emit the same call in a tight loop and burning tokens +
//  API quota for no reason.
//
//  Four layers of protection (all configurable):
//
//  1. **Dedup guard** — tracks the last N calls (name + normalized args).
//     If a duplicate is detected, returns a synthetic error immediately
//     without executing the tool.
//
//  2. **Repeat counter** — hard-caps identical calls at `maxRepeats`. On
//     the Nth repeat the turn is aborted with a warning surfaced to the
//     user.
//
//  3. **Result diff check** — if a tool returned the exact same payload
//     twice in a row for the same (name, args) signature, short-circuits
//     the next identical call with a system-level reminder.
//
//  4. **Prompt injection** — when any layer trips, sets a flag that the
//     harness reads on the next `buildSystemPrompt` call to inject a
//     strong "stop repeating" system reminder into the conversation
//     context.
//
//  Thread-safe: all mutable state is protected by `NSLock`. The guard is
//  singleton per process — all execution paths (MessagingVC, SubAgentRuntime,
//  BackgroundScheduler) share the same history so a loop that spans paths
//  is still caught.
//

import Foundation

final class ToolCallGuard {

    static let shared = ToolCallGuard()

    // MARK: - Configuration

    struct Config {
        /// How many recent calls to remember for dedup detection.
        var historyWindow: Int = 5
        /// Maximum times the same (name, args) can repeat before hard-abort.
        var maxRepeats: Int = 3
        /// Enable/disable each layer independently.
        var deduplicationEnabled: Bool = true
        var repeatCounterEnabled: Bool = true
        var resultDiffEnabled: Bool = true
        var promptInjectionEnabled: Bool = true
    }

    var config = Config()

    // MARK: - Outcome

    /// What the guard decided about a given call.
    enum Verdict {
        /// Call is allowed — proceed to the real skill dispatch.
        case allow
        /// Call is blocked — return the associated synthetic `MessageStruct`
        /// to the model instead of executing the tool. The `loopDetected`
        /// flag indicates whether prompt injection should fire.
        case block(result: MessageStruct, loopDetected: Bool)
    }

    // MARK: - Internal state

    /// Fingerprint of a single tool call: name + deterministic JSON of args.
    private struct CallSignature: Hashable {
        let name: String
        let normalizedArgs: String
    }

    private struct HistoryEntry {
        let signature: CallSignature
        let resultContent: String?
    }

    /// Ring buffer of recent calls, newest at the end.
    private var history: [HistoryEntry] = []

    /// Running repeat count per signature within the current conversation
    /// turn sequence. Reset when `resetHistory()` is called (e.g. on a new
    /// user message).
    private var repeatCounts: [CallSignature: Int] = [:]

    /// Last result content per signature, for the result-diff check.
    private var lastResults: [CallSignature: String] = [:]

    /// When true, the next `buildSystemPrompt` should inject the anti-loop
    /// reminder. Cleared after injection.
    private(set) var shouldInjectLoopReminder: Bool = false

    /// The anti-loop system message injected when a loop is detected.
    static let loopReminderPrompt: String = """
    ⚠️ LOOP DETECTED — STOP REPEATING TOOL CALLS.

    You have called the same tool with the same arguments multiple times \
    and received the same result. This is wasteful and unproductive.

    INSTRUCTIONS:
    1. Do NOT call that tool again with the same arguments.
    2. Use the data you already have to answer the user's question.
    3. If the data is insufficient, try a DIFFERENT tool or DIFFERENT arguments.
    4. If no alternative exists, tell the user what you found and ask for guidance.

    Continuing to loop will cause your turn to be terminated.
    """

    private let lock = NSLock()

    private init() {}

    // MARK: - Public API

    /// Evaluate a tool call before dispatch. Returns `.allow` if the call
    /// should proceed, or `.block(result:loopDetected:)` with a synthetic
    /// error message if the guard intervenes.
    func evaluate(call: FunctionCallStruct) -> Verdict {
        lock.lock()
        defer { lock.unlock() }

        let sig = signature(for: call)

        // Bump the repeat counter for this signature.
        let count = (repeatCounts[sig] ?? 0) + 1
        repeatCounts[sig] = count

        // --- Layer 2: Repeat counter (hard cap) ---
        if config.repeatCounterEnabled && count > config.maxRepeats {
            shouldInjectLoopReminder = config.promptInjectionEnabled
            let msg = MessageStruct(
                role: "function",
                content: """
                {"status":"error","error":"LOOP ABORTED: You have called \
                \\(call.name) with these exact arguments \(count) times. \
                Your turn is being terminated. Stop repeating and use the \
                data you already have."}
                """,
                name: call.name
            )
            return .block(result: msg, loopDetected: true)
        }

        // --- Layer 1: Dedup guard (recent window) ---
        if config.deduplicationEnabled && count > 1 {
            // The call appeared before in the current sequence. Check
            // whether it's within the sliding window.
            let windowStart = max(0, history.count - config.historyWindow)
            let recentSigs = history[windowStart...].map(\.signature)
            if recentSigs.contains(sig) {
                shouldInjectLoopReminder = config.promptInjectionEnabled
                let msg = MessageStruct(
                    role: "function",
                    content: """
                    {"status":"error","error":"You already called \
                    \\(call.name) with these arguments. Stop looping. \
                    Use the result you already received."}
                    """,
                    name: call.name
                )
                return .block(result: msg, loopDetected: true)
            }
        }

        // --- Layer 3: Result diff check ---
        if config.resultDiffEnabled, let lastResult = lastResults[sig] {
            // We'll check after dispatch — but if this is the 2nd+ call
            // AND the last result is known, we can preemptively block when
            // the model hasn't yet seen a different result.
            if count > 1 {
                shouldInjectLoopReminder = config.promptInjectionEnabled
                let msg = MessageStruct(
                    role: "function",
                    content: """
                    {"status":"error","error":"You are repeating tool \
                    calls and getting the same result. Stop. Use what \
                    you already have. Previous result was: \
                    \(String(lastResult.prefix(200)))"}
                    """,
                    name: call.name
                )
                return .block(result: msg, loopDetected: true)
            }
        }

        // Allowed — record in history.
        history.append(HistoryEntry(signature: sig, resultContent: nil))
        trimHistory()

        return .allow
    }

    /// Record the result of a tool call that was allowed through. Used by
    /// the result-diff layer on subsequent calls.
    func recordResult(call: FunctionCallStruct, resultContent: String) {
        lock.lock()
        defer { lock.unlock() }
        let sig = signature(for: call)
        lastResults[sig] = resultContent
    }

    /// Clear the loop-reminder flag after it has been consumed by the
    /// system prompt builder.
    func consumeLoopReminder() {
        lock.lock()
        defer { lock.unlock() }
        shouldInjectLoopReminder = false
    }

    /// Reset all tracking state. Call this when a new user message arrives
    /// so prior tool-call patterns from a different turn don't bleed into
    /// the new one. The per-conversation reset is important because the
    /// model might legitimately re-use a tool in a different conversational
    /// context.
    func resetForNewTurn() {
        lock.lock()
        defer { lock.unlock() }
        history.removeAll()
        repeatCounts.removeAll()
        lastResults.removeAll()
        shouldInjectLoopReminder = false
    }

    // MARK: - Helpers

    private func signature(for call: FunctionCallStruct) -> CallSignature {
        CallSignature(
            name: call.name,
            normalizedArgs: normalizeArgs(call.arguments)
        )
    }

    /// Deterministic JSON serialization of the arguments dictionary so that
    /// `{a:1, b:2}` and `{b:2, a:1}` produce the same string.
    private func normalizeArgs(_ args: [String: Any]) -> String {
        guard !args.isEmpty else { return "{}" }
        // JSONSerialization with .sortedKeys gives us a canonical form.
        if let data = try? JSONSerialization.data(
            withJSONObject: args,
            options: [.sortedKeys]
        ), let str = String(data: data, encoding: .utf8) {
            return str
        }
        // Fallback: sort keys manually and concatenate.
        return args.keys.sorted().map { "\($0)=\(args[$0] ?? "nil")" }.joined(separator: "&")
    }

    private func trimHistory() {
        let maxEntries = config.historyWindow * 2
        if history.count > maxEntries {
            history.removeFirst(history.count - maxEntries)
        }
    }
}
