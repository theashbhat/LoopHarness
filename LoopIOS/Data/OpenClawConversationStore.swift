//
//  OpenClawConversationStore.swift
//  Loop
//
//  Remote conversation backend for an OpenClaw VM. Loop is a *client of the
//  OpenClaw runtime*: the conversation list and history come from OpenClaw's own
//  session store, and sending a message runs the real agent on the VM.
//
//  Contract (OpenClaw 2026.4.x), all driven over SSH (`SSHSkill`):
//    • List:    `openclaw sessions --json --agent <id>` → `{ sessions: [{key,
//               sessionId, updatedAt(ms), model, kind}, …] }`. Each `sessionId`
//               is both the conversation id and the transcript filename.
//    • History: read `~/.openclaw/agents/<id>/sessions/<sessionId>.jsonl` — the
//               full, unredacted transcript (Anthropic-style content blocks).
//    • Send:    `openclaw agent --agent <id> --session-id <sessionId> -m <text>`
//               runs a turn via the already-running Gateway (the VM's configured
//               model keys). We launch it detached so a long turn survives the
//               SSH connection closing, and poll the transcript for the reply.
//
//  Reads are answered from an in-memory cache seeded from a local on-disk mirror
//  (so the list and already-opened chats render even when the VM is unreachable)
//  and reconciled from the VM on demand. The mirror is Loop's own NDJSON cache
//  format — independent of OpenClaw's on-disk layout.
//
//  Transport: we shell out over SSH. File contents cross the wire base64-encoded
//  and the message body is base64-decoded on the host, so arbitrary content
//  can't break shell quoting. Because `runCommand` uses a raw exec channel (no
//  login shell), we prepend a `PATH` export so the npm-global `openclaw` binary
//  resolves.
//
//  Pure Foundation so it compiles for the iOS, macOS, and visionOS targets.
//

import Foundation
import os

private let openClawLog = Logger(subsystem: "com.bhat.intel", category: "OpenClaw")

final class OpenClawConversationStore: ConversationStore {

    /// The execution backend this store serves. Stamped onto conversations it
    /// creates (`SimpleConversation.backend`) so each backend's conversations
    /// stay isolated and resolve back to the right remote.
    let backendID: String
    var backendMarker: String { backendID }

    /// Connection + agent settings for this backend. Mutable so the manager can
    /// push edited settings without recreating the store (and losing cache).
    private(set) var config: OpenClawConfig

    // MARK: - State

    private let cacheLock = NSLock()
    private var cache: [String: SimpleConversation] = [:]
    private var orderedIds: [String] = []

    /// Background queue for all SSH + local-mirror disk I/O. Reads never enter
    /// here.
    private let ioQueue = DispatchQueue(label: "loop.openClawConversationStore.io",
                                        qos: .utility)

    private var _isSyncing = false

    /// Root of the local mirror used for offline list/render fallback. Namespaced
    /// per backend id so multiple remote backends never share a mirror.
    private let mirrorURL: URL

    /// Cap on how many bytes of a transcript we pull per read. OpenClaw sessions
    /// can be large (a busy `agent:main:main` firehose is multi-MB); we read the
    /// trailing slice so polling stays cheap. The JSONL parser tolerates a
    /// truncated leading line.
    private static let transcriptReadCap = 512 * 1024

    /// Maps a Loop conversation id → the OpenClaw `sessionId` the agent actually
    /// ran against (captured from the `--json` run result). For conversations
    /// surfaced from the VM's session list this is the same value; for app-created
    /// chats it's learned after the first turn (a session-less turn routes to the
    /// agent's main session). Guarded by `cacheLock`, persisted in the mirror.
    private var remoteSessionIds: [String: String] = [:]

    /// Conversation ids created in-app (vs surfaced from the VM's session list).
    /// App-created chats render from the local mirror + run results, never from a
    /// (possibly shared/huge) remote transcript — so a brand-new chat doesn't
    /// inherit another session's history. Guarded by `cacheLock`, persisted.
    private var appCreated: Set<String> = []

    /// Conversations whose agent turn is currently running on the VM. While a run
    /// is in-flight, polling reads its run log for the `--json` result rather than
    /// a transcript. Guarded by `cacheLock`.
    private var inFlightRuns: Set<String> = []

    init(backendID: String, config: OpenClawConfig) {
        self.backendID = backendID
        self.config = config

        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("Loop", isDirectory: true)
            .appendingPathComponent("openclaw-cache", isDirectory: true)
            .appendingPathComponent(backendID, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.mirrorURL = dir

        loadSidecar()
        bootstrapFromMirror()

        // Reconcile with the VM if it's already configured. Async + best-effort:
        // a down VM just leaves the mirror in place.
        if config.isConfigured {
            refreshFromRemote()
        }
    }

    /// Replace this backend's connection settings (e.g. after the user edits
    /// them) and re-sync if the new settings are usable. Keeps the existing
    /// cache + mirror so the conversation list never blanks during an edit.
    func updateConfig(_ newConfig: OpenClawConfig) {
        guard newConfig != config else { return }
        config = newConfig
        if newConfig.isConfigured {
            refreshFromRemote()
        }
    }

    // MARK: - ConversationStore (reads, cache-only)

    var isSyncing: Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return _isSyncing
    }

    func allConversations() -> [SimpleConversation] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return orderedIds.compactMap { cache[$0] }
    }

    func conversation(id: String) -> SimpleConversation? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[id]
    }

    func mostRecentlyUpdatedConversation() -> SimpleConversation? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let first = orderedIds.first else { return nil }
        return cache[first]
    }

    func messages(forConversation id: String) -> [SimpleMessage] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[id]?.messages ?? []
    }

    // MARK: - ConversationStore (writes)
    //
    // The OpenClaw session store is the source of truth for message *content*:
    // the transcript is written by the agent on the VM and pulled back by polling
    // (`refreshConversation`). So these local writes update the cache + mirror for
    // immediate UI and offline render, and only a *user* turn reaches out to the
    // VM — to run the agent. Renames, edits, deletes, and assistant/tool lines
    // never mutate the VM's sessions.

    func createConversation(title: String) -> SimpleConversation {
        // `id` becomes the OpenClaw `--session-id` for this chat. OpenClaw
        // creates the session on the VM when the first user turn runs.
        let conv = SimpleConversation(title: title, backend: backendMarker)
        cacheLock.lock()
        cache[conv.id] = conv
        appCreated.insert(conv.id)
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        writeMirror(conv)
        persistSidecar()
        postChange()
        return conv
    }

    func saveConversation(_ conversation: SimpleConversation) {
        var updated = conversation
        updated.updatedAt = Date()
        if updated.backend == nil { updated.backend = backendMarker }
        cacheLock.lock()
        cache[updated.id] = updated
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        writeMirror(updated)
        postChange()
        // Rename is a local concept; OpenClaw sessions have no title. No remote.
    }

    func deleteConversation(id: String) {
        // Remove from Loop's view only — we never delete the user's real agent
        // session on the VM.
        cacheLock.lock()
        cache.removeValue(forKey: id)
        remoteSessionIds.removeValue(forKey: id)
        appCreated.remove(id)
        inFlightRuns.remove(id)
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        try? FileManager.default.removeItem(at: mirrorFileURL(for: id))
        persistSidecar()
        postChange()
    }

    func addMessage(_ message: SimpleMessage, toConversation id: String) {
        cacheLock.lock()
        var conv = cache[id] ?? SimpleConversation(id: id, title: "New Conversation", backend: backendMarker)
        conv.messages.append(message)
        conv.updatedAt = Date()
        cache[id] = conv
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        writeMirror(conv)
        postChange()
        // Only a user turn drives the agent. Assistant/tool lines are produced by
        // the VM and arrive via polling, so they must not re-trigger a run.
        if message.role == "user" {
            enqueueAgentTurn(message: message.content, conversationId: id)
        }
    }

    func updateMessage(_ message: SimpleMessage, inConversation conversationId: String) {
        cacheLock.lock()
        guard var conv = cache[conversationId],
              let idx = conv.messages.firstIndex(where: { $0.id == message.id }) else {
            cacheLock.unlock(); return
        }
        conv.messages[idx] = message
        conv.updatedAt = Date()
        cache[conversationId] = conv
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        writeMirror(conv)
        postChange()
        // Local-only: OpenClaw transcripts are append-only history we don't edit.
    }

    func removeMessage(id messageId: String, fromConversation conversationId: String) {
        cacheLock.lock()
        guard var conv = cache[conversationId] else { cacheLock.unlock(); return }
        conv.messages.removeAll { $0.id == messageId }
        conv.updatedAt = Date()
        cache[conversationId] = conv
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        writeMirror(conv)
        postChange()
        // Local-only.
    }

    // MARK: - Validation

    /// Verifies the VM is reachable, authenticates, and that the `openclaw` CLI
    /// is installed and its agent's session store is readable. Returns a short
    /// human-readable summary on success; throws on failure. Safe to call from
    /// the settings screen — performs no secret logging.
    static func validate(_ config: OpenClawConfig) async throws -> String {
        guard config.isConfigured else {
            throw OpenClawError.notConfigured
        }
        let agent = shQuote(config.trimmedAgentId)
        // One round trip: prove auth, prove the CLI exists, then list the agent's
        // sessions so we can report a count. `OPENCLAW_MISSING` distinguishes
        // "VM reachable but no CLI" (an actionable setup error) from an auth/host
        // failure (surfaced as the thrown SSH error).
        let cmd = """
        \(pathPrefix) if command -v openclaw >/dev/null 2>&1; then echo OPENCLAW_OK; openclaw sessions --json --agent \(agent) 2>/dev/null; else echo OPENCLAW_MISSING; fi
        """
        let result = try await SSHSkill.shared.runCommand(cmd, on: config.sshConfig, timeout: 25)
        if result.stdout.contains("OPENCLAW_MISSING") {
            throw OpenClawError.cliNotFound
        }
        guard result.stdout.contains("OPENCLAW_OK") else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw OpenClawError.workspaceUnreachable(detail.isEmpty ? "Couldn't reach the VM." : detail)
        }
        let count = parseSessionsList(result.stdout, defaultBackend: "probe").count
        return count == 0
            ? "OpenClaw ready (no sessions yet)."
            : "OpenClaw ready (\(count) session\(count == 1 ? "" : "s"))."
    }

    // MARK: - Remote sync (list)

    /// Pull the agent's session list from the VM into the cache + mirror. Best
    /// effort: failures are logged and leave existing cached data intact.
    func refreshFromRemote() {
        let config = self.config
        guard config.isConfigured else { return }
        setSyncing(true)
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.setSyncing(false) }
            let agent = Self.shQuote(config.trimmedAgentId)
            let cmd = "\(Self.pathPrefix) openclaw sessions --json --agent \(agent) 2>/dev/null"
            let result = self.runBlocking {
                try await SSHSkill.shared.runCommand(cmd, on: config.sshConfig, timeout: 30)
            }
            guard case .success(let cmdResult) = result else {
                if case .failure(let error) = result {
                    openClawLog.error("session list failed: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
            let listed = Self.parseSessionsList(cmdResult.stdout, defaultBackend: self.backendID)
            guard !listed.isEmpty else { return }
            self.cacheLock.lock()
            for session in listed {
                // A listed conversation's id *is* its OpenClaw session id, so it's
                // directly resumable and reads its real transcript (not app-created).
                self.remoteSessionIds[session.id] = session.id
                if var existing = self.cache[session.id] {
                    // Preserve any already-loaded transcript + title; the list
                    // only carries metadata.
                    existing.updatedAt = session.updatedAt
                    if existing.messages.isEmpty { existing.title = session.title }
                    self.cache[session.id] = existing
                } else {
                    self.cache[session.id] = session
                }
            }
            self.recomputeOrderedIdsLocked()
            let snapshot = listed.compactMap { self.cache[$0.id] }
            self.cacheLock.unlock()
            for conv in snapshot { self.writeMirror(conv) }
            self.persistSidecar()
            self.postChange()
        }
    }

    /// Poll a single conversation for new content. Two modes:
    ///   • A turn is in-flight → read its run log; when the `--json` result lands,
    ///     append the assistant reply and capture the real OpenClaw session id.
    ///   • Otherwise (an existing VM session opened from the list) → read its
    ///     transcript and replace the cached messages. App-created chats skip the
    ///     remote read (their messages live in the mirror + run results).
    /// Best effort. `completion` runs on the main queue with `true` when the VM
    /// was reachable.
    func refreshConversation(id: String, completion: ((Bool) -> Void)? = nil) {
        let config = self.config
        guard config.isConfigured else {
            DispatchQueue.main.async { completion?(false) }
            return
        }
        cacheLock.lock()
        let inFlight = inFlightRuns.contains(id)
        let isAppCreated = appCreated.contains(id)
        let sessionId = remoteSessionIds[id] ?? id
        cacheLock.unlock()

        if inFlight {
            ioQueue.async { [weak self] in self?.pollRunLog(conversationId: id, config: config, completion: completion) }
            return
        }
        // No in-flight run: app-created chats render from the mirror only.
        guard !isAppCreated else {
            DispatchQueue.main.async { completion?(true) }
            return
        }
        ioQueue.async { [weak self] in
            self?.pollTranscript(conversationId: id, sessionId: sessionId, config: config, completion: completion)
        }
    }

    /// Read the detached run's log and, once the `--json` result has landed,
    /// append the assistant reply (or an error notice) and remember the session id
    /// OpenClaw used so follow-up turns resume it. MUST run on `ioQueue`.
    private func pollRunLog(conversationId id: String, config: OpenClawConfig, completion: ((Bool) -> Void)?) {
        let log = Self.runLogPath(for: id)
        let cmd = "[ -e \(log) ] && base64 \(log) || true"
        let result = runBlocking {
            try await SSHSkill.shared.runCommand(cmd, on: config.sshConfig, timeout: 25)
        }
        switch result {
        case .failure(let error):
            openClawLog.error("run-log fetch (\(id, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { completion?(false) }
        case .success(let cmdResult):
            let cleaned = cmdResult.stdout
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "")
            guard let data = Data(base64Encoded: cleaned),
                  let text = String(data: data, encoding: .utf8),
                  let outcome = Self.parseAgentResult(text) else {
                // Still running (or log not written yet) — keep polling.
                DispatchQueue.main.async { completion?(true) }
                return
            }
            let content = outcome.ok
                ? outcome.reply
                : "⚠️ The agent run didn't complete: \(outcome.error ?? "unknown error")."
            let assistant = SimpleMessage(id: outcome.messageId, role: "assistant",
                                          content: content, model: outcome.model,
                                          responseSeconds: outcome.durationSeconds, createdAt: Date())
            cacheLock.lock()
            var conv = cache[id] ?? SimpleConversation(id: id, title: "Conversation", backend: backendID)
            if !conv.messages.contains(where: { $0.id == assistant.id }) {
                conv.messages.append(assistant)
                conv.updatedAt = Date()
            }
            cache[id] = conv
            if let real = outcome.sessionId { remoteSessionIds[id] = real }
            inFlightRuns.remove(id)
            recomputeOrderedIdsLocked()
            cacheLock.unlock()
            writeMirror(conv)
            persistSidecar()
            postChange()
            DispatchQueue.main.async { completion?(true) }
        }
    }

    /// Read an existing VM session's transcript and replace the cached messages.
    /// MUST run on `ioQueue`.
    private func pollTranscript(conversationId id: String, sessionId: String,
                                config: OpenClawConfig, completion: ((Bool) -> Void)?) {
        let file = Self.sessionFileExpression(for: config, sessionId: sessionId)
        // Read the trailing slice of the transcript (bounded transfer), base64
        // framed. `|| true` keeps the exit status clean + stdout empty when the
        // session file doesn't exist.
        let cmd = "[ -e \(file) ] && tail -c \(Self.transcriptReadCap) \(file) | base64 || true"
        let result = runBlocking {
            try await SSHSkill.shared.runCommand(cmd, on: config.sshConfig, timeout: 25)
        }
        switch result {
        case .failure(let error):
            openClawLog.error("transcript fetch (\(id, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { completion?(false) }
        case .success(let cmdResult):
            let cleaned = cmdResult.stdout
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "")
            if let data = Data(base64Encoded: cleaned),
               let text = String(data: data, encoding: .utf8) {
                let messages = Self.parseSessionTranscript(text, sessionId: sessionId)
                if !messages.isEmpty {
                    cacheLock.lock()
                    var conv = cache[id]
                        ?? SimpleConversation(id: id, title: "Conversation", backend: backendID)
                    conv.messages = messages
                    if let last = messages.last { conv.updatedAt = last.createdAt }
                    if let firstUser = messages.first(where: { $0.role == "user" }) {
                        let snippet = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !snippet.isEmpty { conv.title = String(snippet.prefix(60)) }
                    }
                    cache[id] = conv
                    recomputeOrderedIdsLocked()
                    cacheLock.unlock()
                    writeMirror(conv)
                    postChange()
                }
            }
            DispatchQueue.main.async { completion?(true) }
        }
    }

    // MARK: - Send (run an agent turn on the VM)

    /// Run a user turn through the OpenClaw agent on the VM, detached, and mark the
    /// conversation in-flight so polling reads the run log for the `--json` result.
    /// Resumes the conversation's known OpenClaw session when we have one; a turn
    /// with no `--session-id` routes to the agent's main session (whose real id we
    /// then capture from the result). Best effort: a failed dispatch leaves the
    /// local user message in place and the poll times out with a notice.
    private func enqueueAgentTurn(message: String, conversationId: String) {
        let config = self.config
        guard config.isConfigured else { return }
        cacheLock.lock()
        let knownSession = remoteSessionIds[conversationId]
        inFlightRuns.insert(conversationId)
        cacheLock.unlock()

        let b64 = Data(message.utf8).base64EncodedString()
        let agentQ = Self.shQuote(config.trimmedAgentId)
        // Empty `SID` ⇒ the inner shell omits `--session-id` (new/main session).
        let sidQ = knownSession.map { Self.shQuote($0) } ?? "''"
        let log = Self.runLogPath(for: conversationId)
        // All dynamic values cross the wire as exported shell vars (base64 for the
        // message body) so the inner `sh -c` is a static string immune to quoting
        // breaks. We truncate the log first, then run detached via the Gateway (no
        // `--local`/`--deliver`). A trailing `LOOPDONE:<exit>` marks completion so
        // the poller can tell "still running" from "finished" (and catch errors).
        let cmd = """
        \(Self.pathPrefix) MSG=$(printf %s \(Self.shQuote(b64)) | base64 -d); AGENT=\(agentQ); SID=\(sidQ); export MSG AGENT SID; : > \(log); nohup sh -c 'if [ -n "$SID" ]; then openclaw agent --agent "$AGENT" --session-id "$SID" -m "$MSG" --json; else openclaw agent --agent "$AGENT" -m "$MSG" --json; fi; echo "LOOPDONE:$?"' >> \(log) 2>&1 &
        """
        runRemote(cmd, config: config, label: "agent-turn")
    }

    private static func runLogPath(for conversationId: String) -> String {
        // Conversation ids are UUIDs — safe in a /tmp path.
        "/tmp/loop-openclaw-\(conversationId).log"
    }

    private func runRemote(_ command: String, config: OpenClawConfig, label: String) {
        ioQueue.async {
            let result = self.runBlocking {
                try await SSHSkill.shared.runCommand(command, on: config.sshConfig, timeout: 25)
            }
            if case .failure(let error) = result {
                openClawLog.error("remote \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - OpenClaw session parsing (static, unit-testable)

    /// Parse `openclaw sessions --json` output into conversations. Tolerates a
    /// leading sentinel line (`OPENCLAW_OK`) by scanning for the first `{`. Maps
    /// `sessionId` → conversation id and derives a title from the session key.
    /// Filters out machine sub-sessions (`:cron:`, `:run:`) and dedups by
    /// `sessionId`, keeping the most recently updated.
    static func parseSessionsList(_ output: String, defaultBackend: String) -> [SimpleConversation] {
        guard let data = jsonObjectData(in: output),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = root["sessions"] as? [[String: Any]] else {
            return []
        }
        var byId: [String: SimpleConversation] = [:]
        for s in sessions {
            guard let key = s["key"] as? String,
                  let sessionId = s["sessionId"] as? String else { continue }
            if key.contains(":cron:") || key.contains(":run:") { continue }
            let updated = epochMillisToDate(s["updatedAt"]) ?? .distantPast
            let agentId = (s["agentId"] as? String) ?? "main"
            let title = deriveTitle(fromKey: key, agentId: agentId)
            let conv = SimpleConversation(id: sessionId, title: title, messages: [],
                                          createdAt: updated, updatedAt: updated,
                                          backend: defaultBackend)
            if let existing = byId[sessionId], existing.updatedAt >= updated { continue }
            byId[sessionId] = conv
        }
        return Array(byId.values)
    }

    /// Parse an OpenClaw transcript `.jsonl` into Loop messages. Each line is one
    /// JSON event; we keep `type:"message"` events with role user/assistant that
    /// carry text, mapping Anthropic-style content blocks to plain text. (Tool
    /// steps are elided in this pass.) Unparseable lines — including a truncated
    /// leading line from a capped read — are skipped.
    static func parseSessionTranscript(_ text: String, sessionId: String) -> [SimpleMessage] {
        var messages: [SimpleMessage] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for (index, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "message",
                  let message = obj["message"] as? [String: Any] else { continue }
            let role = (message["role"] as? String) ?? ""
            guard role == "user" || role == "assistant" else { continue }
            let content = extractText(from: message["content"])
            guard !content.isEmpty else { continue }
            let id = (obj["id"] as? String) ?? "\(sessionId)-\(index)"
            let timestamp = epochMillisToDate(message["timestamp"])
                ?? isoDate(obj["timestamp"])
                ?? Date()
            var model: String? = nil
            if role == "assistant" {
                let raw = message["model"] as? String
                // `delivery-mirror` is an internal echo, not a user-facing model.
                model = (raw == "delivery-mirror") ? nil : raw
            }
            messages.append(SimpleMessage(id: id, role: role, content: content,
                                          model: model, createdAt: timestamp))
        }
        return messages
    }

    /// Flatten a message `content` field — either a plain string or an array of
    /// Anthropic-style blocks — into the concatenated text of its `text` blocks.
    static func extractText(from content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for block in blocks {
            if (block["type"] as? String) == "text", let t = block["text"] as? String, !t.isEmpty {
                parts.append(t)
            }
        }
        return parts.joined(separator: "\n")
    }

    /// The outcome of an `openclaw agent --json` run, parsed from its run log.
    struct AgentTurnOutcome {
        let ok: Bool
        let reply: String
        /// The OpenClaw session id the agent actually ran against (so follow-up
        /// turns can resume it). Nil if the result didn't report one.
        let sessionId: String?
        let model: String?
        /// Stable id for the assistant message (the run id), so re-polling the
        /// same completed log doesn't duplicate the reply.
        let messageId: String
        /// Wall-clock duration of the agent run in seconds (`result.meta.durationMs`),
        /// surfaced next to the model name. Nil if the result didn't report it.
        let durationSeconds: TimeInterval?
        let error: String?
    }

    /// Parse a detached run's log into an outcome, or nil if the run hasn't
    /// finished. Completion is marked by a trailing `LOOPDONE:<exit>` line; the
    /// `--json` object precedes it on stdout. Tolerates interleaved stderr by
    /// extracting the outermost `{ … }` before the marker.
    static func parseAgentResult(_ log: String) -> AgentTurnOutcome? {
        guard let doneRange = log.range(of: "LOOPDONE:") else { return nil }
        let head = String(log[..<doneRange.lowerBound])
        let exitDigits = log[doneRange.upperBound...].prefix { $0.isNumber }
        let exitCode = Int(exitDigits) ?? -1

        if let start = head.firstIndex(of: "{"),
           let end = head.lastIndex(of: "}"), start < end,
           let data = String(head[start...end]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let status = obj["status"] as? String
            let runId = (obj["runId"] as? String) ?? UUID().uuidString
            let result = obj["result"] as? [String: Any]
            let payloads = result?["payloads"] as? [[String: Any]] ?? []
            let reply = payloads.compactMap { $0["text"] as? String }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let meta = result?["meta"] as? [String: Any]
            let agentMeta = meta?["agentMeta"] as? [String: Any]
            let sessionId = agentMeta?["sessionId"] as? String
            let model = agentMeta?["model"] as? String
            let duration = (meta?["durationMs"] as? Double).map { $0 / 1000 }
            let ok = status == "ok" && exitCode == 0 && !reply.isEmpty
            return AgentTurnOutcome(ok: ok, reply: reply, sessionId: sessionId, model: model,
                                    messageId: runId, durationSeconds: duration,
                                    error: ok ? nil : (status ?? "exit \(exitCode)"))
        }

        // Finished but no parseable JSON ⇒ a failure (e.g. the CLI errored before
        // producing `--json`). Surface the tail of the log.
        let raw = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentTurnOutcome(ok: false, reply: "", sessionId: nil, model: nil,
                                messageId: UUID().uuidString, durationSeconds: nil,
                                error: raw.isEmpty ? "exit \(exitCode)" : String(raw.suffix(300)))
    }

    /// Humanize a session key into a list title: strip the `agent:<id>:` prefix
    /// and join the rest with " · " (`agent:main:main` → "Main";
    /// `agent:main:telegram:direct:123` → "Telegram · direct · 123").
    static func deriveTitle(fromKey key: String, agentId: String) -> String {
        var rest = key
        let prefix = "agent:\(agentId):"
        if rest.hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
        } else if rest.hasPrefix("agent:") {
            // Unknown agent id in the key — drop `agent:` and the next segment.
            let parts = rest.split(separator: ":").dropFirst(2)
            rest = parts.joined(separator: ":")
        }
        let parts = rest.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return key }
        let joined = parts.joined(separator: " · ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// Returns the JSON object bytes starting at the first `{` in `s` (so a
    /// leading sentinel line is ignored). Nil if there's no object.
    private static func jsonObjectData(in s: String) -> Data? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        return String(s[start...]).data(using: .utf8)
    }

    /// Interpret an epoch-milliseconds value (Int/Double/String) as a Date.
    private static func epochMillisToDate(_ value: Any?) -> Date? {
        let millis: Double?
        switch value {
        case let d as Double: millis = d
        case let i as Int: millis = Double(i)
        case let s as String: millis = Double(s)
        default: millis = nil
        }
        guard let ms = millis, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    // MARK: - Local mirror (Loop's own NDJSON offline cache)

    private func bootstrapFromMirror() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: mirrorURL,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) else { return }
        var seeds: [SimpleConversation] = []
        for url in entries where url.pathExtension == "ndjson" {
            let id = url.deletingPathExtension().lastPathComponent
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let conv = Self.parseNDJSON(text, fallbackId: id, defaultBackend: backendID) {
                seeds.append(conv)
            }
        }
        cacheLock.lock()
        for conv in seeds { cache[conv.id] = conv }
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
    }

    private func mirrorFileURL(for id: String) -> URL {
        mirrorURL.appendingPathComponent("\(id).ndjson")
    }

    // MARK: Sidecar (conversation→session map + app-created set)

    private struct Sidecar: Codable {
        var sessions: [String: String]
        var appCreated: [String]
    }

    private var sidecarURL: URL { mirrorURL.appendingPathComponent("_loop-meta.json") }

    private func loadSidecar() {
        guard let data = try? Data(contentsOf: sidecarURL),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) else { return }
        cacheLock.lock()
        remoteSessionIds = sidecar.sessions
        appCreated = Set(sidecar.appCreated)
        cacheLock.unlock()
    }

    /// Snapshot the conversation→session map + app-created set under the lock and
    /// write them asynchronously. Safe to call without holding `cacheLock`.
    private func persistSidecar() {
        cacheLock.lock()
        let sidecar = Sidecar(sessions: remoteSessionIds, appCreated: Array(appCreated))
        cacheLock.unlock()
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            if let data = try? JSONEncoder().encode(sidecar) {
                try? data.write(to: self.sidecarURL, options: [.atomic])
            }
        }
    }

    /// Rewrite the whole local-mirror file for a conversation. Cheap (files are
    /// small) and keeps the mirror authoritative for offline render.
    private func writeMirror(_ conv: SimpleConversation) {
        var body = metaLine(for: conv) + "\n"
        for msg in conv.messages {
            body += messageLine(msg) + "\n"
        }
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            try? body.data(using: .utf8)?.write(to: self.mirrorFileURL(for: conv.id), options: [.atomic])
        }
    }

    private func metaLine(for conv: SimpleConversation) -> String {
        let meta = NDMeta(_type: "meta", id: conv.id, title: conv.title,
                          createdAt: conv.createdAt, updatedAt: conv.updatedAt,
                          backend: conv.backend ?? backendMarker)
        return encodeLine(meta)
    }

    private func messageLine(_ message: SimpleMessage) -> String {
        encodeLine(NDMessageEnvelope(message: message))
    }

    private func encodeLine<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    /// Parse a mirror NDJSON blob (meta + msg lines) into a conversation.
    /// `static` so both the offline bootstrap and tests share one parser.
    static func parseNDJSON(_ text: String, fallbackId: String, defaultBackend: String) -> SimpleConversation? {
        var title = "Untitled"
        var createdAt = Date()
        var updatedAt = Date()
        var backend: String? = defaultBackend
        var foundMeta = false
        var messages: [SimpleMessage] = []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let env = try? decoder.decode(NDEnvelope.self, from: data) else { continue }
            switch env._type {
            case "meta":
                if let meta = try? decoder.decode(NDMeta.self, from: data) {
                    title = meta.title
                    createdAt = meta.createdAt
                    updatedAt = meta.updatedAt
                    backend = meta.backend ?? backend
                    foundMeta = true
                }
            case "msg":
                if let msg = try? decoder.decode(SimpleMessage.self, from: data) {
                    messages.append(msg)
                }
            default:
                continue
            }
        }

        guard foundMeta else { return nil }
        messages.sort { $0.createdAt < $1.createdAt }
        return SimpleConversation(id: fallbackId, title: title, messages: messages,
                                  createdAt: createdAt, updatedAt: updatedAt, backend: backend)
    }

    // MARK: - Helpers

    /// Bridges the async `SSHSkill` API into the synchronous `ioQueue` flow.
    /// MUST be called off the main thread (we only call it from `ioQueue`).
    private func runBlocking(_ work: @escaping () async throws -> SSHSkill.CommandResult)
        -> Result<SSHSkill.CommandResult, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<SSHSkill.CommandResult, Error>!
        Task {
            do { outcome = .success(try await work()) }
            catch { outcome = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return outcome
    }

    private func recomputeOrderedIdsLocked() {
        orderedIds = cache.keys.sorted { lhs, rhs in
            (cache[lhs]?.updatedAt ?? .distantPast) > (cache[rhs]?.updatedAt ?? .distantPast)
        }
    }

    private func setSyncing(_ value: Bool) {
        cacheLock.lock(); _isSyncing = value; cacheLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .conversationStoreSyncStateChanged, object: nil)
        }
    }

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .conversationStoreDidChange, object: nil)
        }
    }

    /// Prepended to every `openclaw` command. `runCommand` uses a raw exec channel
    /// (no login shell), so the npm-global bin dir isn't on PATH by default.
    static let pathPrefix = #"export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH";"#

    /// Shell-quotes a payload (single-quote wrap, escaping embedded quotes).
    static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Shell expression for the workspace root, expanding a leading `~` to
    /// `$HOME` (tilde isn't expanded inside quotes) while quoting the rest so
    /// spaces are safe. Shared by the file + skill stores (Files/Skills tabs).
    static func workspaceDirExpression(for config: OpenClawConfig) -> String {
        let ws = config.trimmedWorkspacePath
        if ws == "~" {
            return "\"$HOME\""
        } else if ws.hasPrefix("~/") {
            return "\"$HOME\"/" + shQuote(String(ws.dropFirst(2)))
        } else {
            return shQuote(ws)
        }
    }

    /// Shell expression for the agent's session store dir on the VM:
    /// `"$HOME"/.openclaw/agents/<agentId>/sessions`.
    static func sessionsDirExpression(for config: OpenClawConfig) -> String {
        "\"$HOME\"/.openclaw/agents/" + shQuote(config.trimmedAgentId) + "/sessions"
    }

    /// Shell expression for one session's transcript file: `<sessionsDir>/<id>.jsonl`.
    static func sessionFileExpression(for config: OpenClawConfig, sessionId: String) -> String {
        sessionsDirExpression(for: config) + "/" + shQuote("\(sessionId).jsonl")
    }
}

// MARK: - Errors

enum OpenClawError: LocalizedError {
    case notConfigured
    case workspaceUnreachable(String)
    case cliNotFound

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "OpenClaw is not configured. Enter host, username, private key, and workspace path."
        case .workspaceUnreachable(let detail):
            return "Couldn't reach the VM: \(detail)"
        case .cliNotFound:
            return "The `openclaw` CLI wasn't found on the VM. Install OpenClaw and make sure the agent id is correct."
        }
    }
}

// MARK: - Mirror line schemas (Loop's offline NDJSON cache)

private struct NDEnvelope: Decodable {
    let _type: String
}

private struct NDMeta: Codable {
    let _type: String
    let id: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    var backend: String? = nil
}

/// Encodes a `SimpleMessage` to the `{"_type":"msg",…}` line shape the mirror
/// uses, matching `ConversationFileStore`'s on-disk format.
private struct NDMessageEnvelope: Encodable {
    let message: SimpleMessage

    private enum CodingKeys: String, CodingKey {
        case _type, id, role, content, name, functionName, functionArguments
        case actions, fileAttachment, mapAttachment, imageAttachment, model, isCompactionSummary, responseSeconds, createdAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("msg", forKey: ._type)
        try c.encode(message.id, forKey: .id)
        try c.encode(message.role, forKey: .role)
        try c.encode(message.content, forKey: .content)
        try c.encodeIfPresent(message.name, forKey: .name)
        try c.encodeIfPresent(message.functionName, forKey: .functionName)
        try c.encodeIfPresent(message.functionArguments, forKey: .functionArguments)
        try c.encodeIfPresent(message.actions, forKey: .actions)
        try c.encodeIfPresent(message.fileAttachment, forKey: .fileAttachment)
        try c.encodeIfPresent(message.mapAttachment, forKey: .mapAttachment)
        try c.encodeIfPresent(message.imageAttachment, forKey: .imageAttachment)
        try c.encodeIfPresent(message.model, forKey: .model)
        try c.encodeIfPresent(message.isCompactionSummary, forKey: .isCompactionSummary)
        try c.encodeIfPresent(message.responseSeconds, forKey: .responseSeconds)
        try c.encode(message.createdAt, forKey: .createdAt)
    }
}
