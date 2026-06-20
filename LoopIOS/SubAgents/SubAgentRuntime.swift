//
//  SubAgentRuntime.swift
//  Loop
//
//  Drives a single sub-agent through its execution lifecycle: builds a
//  scoped system prompt, calls the same model + tool dispatch the primary
//  conversation uses, captures logs along the way, and produces a summary
//  for the parent thread. Cross-platform (iOS + macOS).
//

import Foundation

/// Default cap on how many agent turns we'll run before declaring the
/// sub-agent runaway and forcing a summary. Sub-agents (research / general)
/// exist to complete a delegated task and report back — anything taking
/// more than this many turns probably needs to be a primary conversation.
private let kMaxSubAgentTurns = 25

/// Default time budget per sub-agent. Coverage for the v1
/// "long research / coding workflow" target without letting a stuck agent
/// hold runtime forever.
private let kMaxSubAgentRuntimeSeconds: TimeInterval = 300

/// Per-kind budget. Coding sub-agents drive a real shell (often handing
/// off to `claude` in the terminal for long edit/test loops) where the
/// natural cadence is "model fires a command, then polls read_terminal_
/// _output every few seconds for tens of minutes." A 25-turn / 5-minute
/// cap is the wrong shape for that — the agent should run until it
/// finishes the task or the user manually stops it from the inspector.
/// Other kinds keep the existing defaults.
private func maxTurns(for kind: SubAgentKind) -> Int {
    switch kind {
    case .coding: return .max
    default:      return kMaxSubAgentTurns
    }
}

private func maxRuntimeSeconds(for kind: SubAgentKind) -> TimeInterval {
    switch kind {
    case .coding: return .greatestFiniteMagnitude
    default:      return kMaxSubAgentRuntimeSeconds
    }
}

enum SubAgentRuntime {

    /// Run the agent loop until completion, failure, or budget exhaustion.
    /// The runtime mutates the agent through the manager so all UI
    /// broadcasts go through one place. Returns when the agent is no
    /// longer alive.
    ///
    /// - Parameters:
    ///   - agent: The sub-agent to drive. Its `state` and `messages` get
    ///     mutated through `SubAgentManager.shared`.
    ///   - onUpdate: Fired after every state/log mutation so the inspector
    ///     can re-render. The manager wires this to a NotificationCenter
    ///     post; the runtime doesn't care about the implementation.
    ///   - onComplete: Fired once after the agent transitions to a terminal
    ///     state. The manager uses this to post the completion summary into
    ///     the parent conversation.
    static func run(agent: SubAgent,
                    onUpdate: @escaping () -> Void,
                    onComplete: @escaping () -> Void) async {
        seedMessages(for: agent)
        SubAgentManager.shared.appendLog(id: agent.id, entry: SubAgentLogEntry(
            kind: .system,
            summary: "Spawned sub-agent for: \(agent.displayTitle)"
        ))

        let turnCap = maxTurns(for: agent.kind)
        let timeCap = maxRuntimeSeconds(for: agent.kind)
        var turnCount = 0
        while turnCount < turnCap {
            // Budget check — gives the inspector a clean "timed out" reason
            // instead of letting a stuck agent run forever. Coding agents
            // have `.greatestFiniteMagnitude` here, so this branch is dead
            // for them; they stop only when the model itself wraps up or
            // the user kills via the inspector.
            if agent.runtime > timeCap {
                let summary = composeTimeoutSummary(for: agent)
                SubAgentManager.shared.setResult(id: agent.id, summary: summary)
                SubAgentManager.shared.updateState(id: agent.id,
                                                   to: .failed,
                                                   step: "Hit \(Int(timeCap))s time budget")
                onComplete()
                return
            }

            // External kill: manager flipped state to .failed. Stop turning.
            // This is also how coding agents get stopped — they run until
            // either they finish the task themselves, or the user clicks
            // Stop in the inspector.
            if !agent.isAlive {
                onComplete()
                return
            }

            turnCount += 1
            SubAgentManager.shared.updateState(id: agent.id,
                                               to: .active,
                                               step: "Thinking (turn \(turnCount))")

            let response: MessageStruct?
            do {
                response = try await runOneModelCall(messages: agent.messages)
            } catch {
                let message = (error as NSError).localizedDescription
                SubAgentManager.shared.appendLog(id: agent.id, entry: SubAgentLogEntry(
                    kind: .system,
                    summary: "Model call failed: \(message)"
                ))
                SubAgentManager.shared.setError(id: agent.id, message: message)
                SubAgentManager.shared.setResult(id: agent.id, summary: "Couldn't reach the model: \(message)")
                SubAgentManager.shared.updateState(id: agent.id, to: .failed, step: "Model error")
                onComplete()
                return
            }

            guard let reply = response else {
                SubAgentManager.shared.appendLog(id: agent.id, entry: SubAgentLogEntry(
                    kind: .system,
                    summary: "Empty response from model"
                ))
                SubAgentManager.shared.setError(id: agent.id, message: "Empty model response")
                SubAgentManager.shared.setResult(id: agent.id, summary: "The model returned an empty response.")
                SubAgentManager.shared.updateState(id: agent.id, to: .failed, step: "Empty response")
                onComplete()
                return
            }

            // Append the assistant turn to the agent's local context so the
            // next call sees it.
            agent.messages.append(reply)

            // One or more tool calls → run them all, append every result,
            // loop. Sub-agents inherit the same parallel-tool-call shape as
            // the primary path: a single assistant turn can carry multiple
            // `tool_use` blocks, and we have to dispatch every one before
            // re-entering the model (Anthropic rejects mismatched tool
            // result counts; OpenAI loses the pairing). Dispatching
            // sequentially here is deliberate — sub-agents are turn-budget-
            // limited and parallel dispatch would complicate the log
            // ordering for the inspector.
            if !reply.functions.isEmpty {
                if let first = reply.functions.first {
                    SubAgentManager.shared.updateState(id: agent.id,
                                                       to: .active,
                                                       step: stepLabel(for: first))
                }
                for function in reply.functions {
                    logToolCall(agent: agent, function: function)
                    var result = await dispatchTool(function: function)
                    // Pair the result back to the originating call so the
                    // wire payload can emit a structured `tool_result` /
                    // `role:"tool"` instead of falling back to prose.
                    if result.callId == nil { result.callId = function.callId }
                    if result.name   == nil { result.name   = function.name }
                    agent.messages.append(result)
                    logToolResult(agent: agent, function: function, result: result)
                }
                onUpdate()
                continue
            }

            // Plain text reply. Treat as the agent's final summary and
            // finish up.
            let summary = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty {
                SubAgentManager.shared.appendLog(id: agent.id, entry: SubAgentLogEntry(
                    kind: .thought, summary: summary.prefix(160).description
                ))
                SubAgentManager.shared.setResult(id: agent.id, summary: summary)
            } else {
                SubAgentManager.shared.setResult(id: agent.id, summary: "(no output)")
            }
            SubAgentManager.shared.updateState(id: agent.id,
                                               to: .completed,
                                               step: "Done")
            onComplete()
            return
        }

        // Fell out of the loop without finishing. Ask the model for a
        // forced wrap-up so the parent gets *something* useful back.
        // Unreachable for coding agents (turnCap is Int.max) — they
        // stop only when finished or killed by the user.
        let summary = composeForcedWrapupSummary(for: agent)
        SubAgentManager.shared.setResult(id: agent.id, summary: summary)
        SubAgentManager.shared.updateState(id: agent.id,
                                           to: .failed,
                                           step: "Hit \(turnCap)-turn cap")
        onComplete()
    }

    // MARK: - Message seeding

    /// Build the initial message list for the sub-agent: a scoped system
    /// prompt that explains the agent contract, then the user task as the
    /// first user turn.
    private static func seedMessages(for agent: SubAgent) {
        let system = MessageStruct(role: "system", content: systemPrompt(for: agent))
        let user = MessageStruct(role: "user", content: agent.task)
        agent.messages = [system, user]
    }

    private static func systemPrompt(for agent: SubAgent) -> String {
        let kindBlock: String
        switch agent.kind {
        case .research:
            kindBlock = """
            You are a research sub-agent. Use the search and read tools available
            to you to investigate the user's question thoroughly, then summarize
            findings concisely with citations or sources where you can.
            """
        case .coding:
            kindBlock = """
            You are a coding sub-agent. **You ARE a sub-agent — call the
            terminal tools (start_terminal_session, run_terminal_command,
            read_terminal_output) directly to do your work; do not try
            to spawn another sub-agent.**

            **Preferred workflow: delegate the code to Claude Code.**
            The user almost certainly has `claude` (Claude Code) on PATH.
            Burning your own turn budget on read-edit-verify loops is
            slow and runs into limits — Claude Code is a much better
            coder, runs inside the terminal, and just needs a clear
            prompt. Default workflow:

              1. start_terminal_session  (defaults to the iCloud
                 workspace; relative working_dir lands in a subfolder).
              2. run_terminal_command `which claude` to verify it's
                 installed.
                 - If present: run_terminal_command with a single
                   `claude '<your full task description>'`. Phrase the
                   task as a complete spec — what to build, where to
                   put it, success criteria, any constraints. Claude
                   Code will plan, edit files, run tests, and report
                   back.
                 - Then read_terminal_output with wait_seconds=4,
                   keep polling (with the latest marker) every few
                   seconds until you see the `claude` prompt return /
                   the session settles. Watch for it asking yes/no
                   confirmations — answer concisely via
                   run_terminal_command if needed.
              3. Once Claude finishes, do a final read_terminal_output
                 to capture the wrap-up, then summarize what was done
                 (files changed, tests run, follow-ups) back to the
                 user. Don't paraphrase Claude's output verbatim — the
                 user wants a tight summary, not a transcript.

            When `claude` is NOT available (the `which` returned
            nothing, or the user explicitly asked you to do it
            yourself), fall back to:
            - Terminal commands directly (git, npm, pytest, etc.) plus
            - file_list / file_search / file_read / file_write
              (mode "write" or "append") / file_edit for code
              changes. Workspace-relative paths only; 1 MB per-file
              cap on file_read.
            - git_clone / git_status / git_pull for repos under
              `repos/<name>`.

            **Where code lives:** All project files live inside the
            user's iCloud workspace (the same root `file_write` uses).
            Your terminal sessions default to that root. Put each
            project in its own subfolder (e.g. `my-api/`,
            `scratch-ml/`) — never write code outside the workspace
            unless the user explicitly asks. That way the user sees
            everything in the Files app and the work survives across
            conversations and devices.

            **Python: use a venv by default.** For any Python work,
            create and activate a project-local virtualenv before
            installing packages or running scripts:
              cd <project>
              python3 -m venv .venv
              source .venv/bin/activate
              pip install <packages>
            Run subsequent commands with the venv activated (the shell
            session keeps the activation across commands). Don't
            `pip install` against the user's system Python — it
            pollutes their machine and the next session won't see those
            packages anyway. Tell Claude Code about the venv in your
            prompt so it doesn't fight you. Same idea for other
            languages with isolated envs (Node: stay inside the
            project's `node_modules`; Ruby: `bundle install --path
            vendor/`).

            When you're done, report exactly what was built or changed,
            the relevant output / paths, how you verified it, and any
            follow-ups. Keep the summary tight.
            """
        case .general:
            kindBlock = """
            You are a sub-agent spawned to complete a single delegated task.
            Use whatever tools are available to you to make progress, then
            wrap up with a clear summary.
            """
        }

        // Budget language varies by kind. Coding agents run unbounded
        // (user stops them manually from the inspector); research /
        // general have hard caps and need to plan for them.
        let budgetLine: String
        switch agent.kind {
        case .coding:
            budgetLine = "- No turn or time budget. Run until the task is done; the user can stop you from the sub-agent inspector if they want to bail early."
        default:
            budgetLine = "- You have a turn budget of \(maxTurns(for: agent.kind)) and a time budget of \(Int(maxRuntimeSeconds(for: agent.kind)))s. Plan accordingly."
        }

        let contract = """
        You are running detached from the primary Loop conversation. The user
        cannot see this thread — they will only see the final summary you post
        back. So:

        - Drive the task to completion or a clear stopping point.
        - Don't ask the user clarifying questions; make reasonable defaults.
        - When you're done, reply with plain text — that text becomes the
          summary that goes back to the user.
        - The summary should cover: what you did, what you produced, any
          errors you hit, and (if useful) what to do next.
        - Keep the summary tight — a short paragraph or a few bullets.
        \(budgetLine)
        """

        return """
        \(kindBlock)

        \(contract)
        """
    }

    // MARK: - Model call

    /// Bridge `Cloud.connection.chat` (completion-based) into async/await.
    private static func runOneModelCall(messages: [MessageStruct]) async throws -> MessageStruct? {
        return try await withCheckedThrowingContinuation { continuation in
            Cloud.connection.chat(messages: messages) { response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: response)
            }
        }
    }

    // MARK: - Tool dispatch

    /// Run a tool call on the appropriate skill and return the function
    /// result message. Reuses the shared `SkillDispatcher` so every skill
    /// the primary chat thread can reach is also reachable from a sub-agent,
    /// without us having to mirror the if-chain here.
    ///
    /// We deliberately do NOT call `spawn_sub_agent` recursively — a sub-
    /// agent spawning another sub-agent could fan out unboundedly. If the
    /// model tries, we return a function result explaining that.
    private static func dispatchTool(function: FunctionCallStruct) async -> MessageStruct {
        if function.name == "spawn_sub_agent" || function.name == "cancel_sub_agent" {
            return MessageStruct(
                role: "function",
                content: "Sub-agents cannot manage other sub-agents in v1. Continue this task yourself.",
                name: function.name
            )
        }

        return await withCheckedContinuation { continuation in
            SkillDispatcher.shared.dispatch(function) { result in
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Logging helpers

    private static func stepLabel(for function: FunctionCallStruct) -> String {
        if let s = statusText(for: function) { return s }
        return "Running \(function.name.replacingOccurrences(of: "_", with: " "))"
    }

    /// Best-effort progress label. Falls back to a generic "running …" string
    /// in the runtime if no skill claims the call — sub-agents may need to
    /// describe what they're doing even when a skill doesn't volunteer a
    /// status of its own.
    private static func statusText(for call: FunctionCallStruct) -> String? {
        if let s = ExaSkill.shared.statusText(for: call) { return s }
        if let s = NotionSkill.shared.statusText(for: call) { return s }
        if let s = SchedulerSkill.shared.statusText(for: call) { return s }
        if let s = SelfImprovementSkill.shared.statusText(for: call) { return s }
        if let s = FileSystemSkill.shared.statusText(for: call) { return s }
        if let s = SpecBuilderSkill.shared.statusText(for: call) { return s }
        if let s = ObsidianSkill.shared.statusText(for: call) { return s }
        if let s = CalendarSkill.shared.statusText(for: call) { return s }
        if let s = SSHSkill.shared.statusText(for: call) { return s }
        if let s = GoogleDriveSkill.shared.statusText(for: call) { return s }
        if let s = GoogleGmailSkill.shared.statusText(for: call) { return s }
        if let s = GoogleCalendarSkill.shared.statusText(for: call) { return s }
        return nil
    }

    private static func logToolCall(agent: SubAgent, function: FunctionCallStruct) {
        let label = stepLabel(for: function)
        SubAgentManager.shared.appendLog(id: agent.id, entry: SubAgentLogEntry(
            kind: .toolCall,
            summary: label,
            detail: serializedArguments(function.arguments)
        ))
    }

    private static func logToolResult(agent: SubAgent,
                                      function: FunctionCallStruct,
                                      result: MessageStruct) {
        let preview: String
        let raw = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.count > 120 {
            preview = String(raw.prefix(117)) + "…"
        } else {
            preview = raw.isEmpty ? "(empty result)" : raw
        }
        SubAgentManager.shared.appendLog(id: agent.id, entry: SubAgentLogEntry(
            kind: .toolResult,
            summary: "\(function.name) → \(preview)",
            detail: raw
        ))
    }

    private static func serializedArguments(_ args: [String: Any]) -> String? {
        guard !args.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted]),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    // MARK: - Forced wrap-ups

    private static func composeTimeoutSummary(for agent: SubAgent) -> String {
        let lastThought = agent.messages.last(where: { $0.role == "assistant" && $0.function == nil })?.content
        let tail = lastThought?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = Int(maxRuntimeSeconds(for: agent.kind))
        var body = "Sub-agent stopped after hitting its \(cap)s time budget."
        if let tail = tail, !tail.isEmpty {
            body += "\n\nLast thought: \(tail)"
        }
        return body
    }

    private static func composeForcedWrapupSummary(for agent: SubAgent) -> String {
        let lastThought = agent.messages.last(where: { $0.role == "assistant" && $0.function == nil })?.content
        let tail = lastThought?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = maxTurns(for: agent.kind)
        var body = "Sub-agent stopped after \(cap) turns without producing a final summary."
        if let tail = tail, !tail.isEmpty {
            body += "\n\nLast thought: \(tail)"
        }
        return body
    }
}
