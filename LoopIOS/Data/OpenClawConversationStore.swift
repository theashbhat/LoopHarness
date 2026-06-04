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

    /// Maps a Loop conversation id → the real OpenClaw Gateway session *key* for
    /// VM-surfaced sessions (the daemon's `key`, which isn't always derivable from
    /// the session id — channel sessions carry a structured path). App-created
    /// chats aren't in here; their key is derived from the conversation id.
    /// Guarded by `cacheLock`, persisted in the sidecar.
    private var remoteSessionKeys: [String: String] = [:]

    /// Conversations whose agent turn is currently running on the VM. While a run
    /// is in-flight, polling reads its run log for the `--json` result rather than
    /// a transcript. Guarded by `cacheLock`.
    private var inFlightRuns: Set<String> = []

    /// Live foreground `execStream` turns, keyed by conversation id, so the exec
    /// channel stays retained for the turn's duration — an unreferenced
    /// `ExecStream` cancels itself in `deinit`. Guarded by `cacheLock`.
    private var liveTurns: [String: PersistentSSHConnection.ExecStream] = [:]

    /// One long-lived SSH connection for this backend, reused across turns so a
    /// send no longer pays a fresh TCP + handshake + auth (the bulk of the old
    /// per-message latency). `rootChannel()` reconnects transparently after a
    /// drop; we only drop+recreate when the host changes. Guarded by `connLock`.
    private let connLock = NSLock()
    private var persistentConn: PersistentSSHConnection?
    private var persistentConnHostKey: String?

    /// When true (default), a user turn streams `openclaw agent --json` in the
    /// foreground over the persistent connection — the result lands the instant
    /// the turn completes, with no per-poll handshake. When false, falls back to
    /// the legacy detached-`nohup` + run-log-poll path. Lets us A/B the transports.
    static var useStreamingExec = true

    /// When true (default), remote user turns are driven over the persistent
    /// Gateway WebSocket (`OpenClawGatewayClient`) — a warm, held session that
    /// streams replies in ~4s, vs the cold one-shot CLI paths (~16s). The UI
    /// drives this via `sendStreaming` (so deltas reach the streaming bubble), so
    /// `addMessage` does NOT auto-enqueue a CLI turn when this is on.
    static var useGatewayWS = true

    /// The persistent Gateway client for this backend, created + connected on the
    /// first send and held open. Guarded by `cacheLock`.
    private var gateway: OpenClawGatewayClient?
    private var gatewayConnectTask: Task<OpenClawGatewayClient, Error>?
    private var backgroundObserver: NSObjectProtocol?

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

        // Drop the held Gateway on app background — the SSH tunnel won't survive
        // suspension; the next send reconnects lazily. Raw notification name keeps
        // this file UIKit-free (no-op on platforms that never post it).
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidEnterBackgroundNotification"),
            object: nil, queue: nil) { [weak self] _ in self?.closeGateway() }
    }

    /// Drop the held Gateway connection (app background, or config change).
    /// Idempotent; the next send reconnects via `gatewayClient()`.
    private func closeGateway() {
        cacheLock.lock()
        let g = gateway
        gateway = nil
        gatewayConnectTask?.cancel()
        gatewayConnectTask = nil
        cacheLock.unlock()
        g?.close()
    }

    /// Replace this backend's connection settings (e.g. after the user edits
    /// them) and re-sync if the new settings are usable. Keeps the existing
    /// cache + mirror so the conversation list never blanks during an edit.
    func updateConfig(_ newConfig: OpenClawConfig) {
        guard newConfig != config else { return }
        config = newConfig
        // Drop the held Gateway connection so it reconnects with the new settings.
        closeGateway()
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

    /// Whether a turn for this conversation is currently being driven from the app
    /// (Gateway/exec stream in flight). The background poller checks this to avoid
    /// notifying about a reply the foreground UI is already streaming in.
    func isInFlight(id: String) -> Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return inFlightRuns.contains(id)
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
        let liveTurn = liveTurns.removeValue(forKey: id)
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        liveTurn?.cancel()
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
        // the VM and arrive via polling, so they must not re-trigger a run. The
        // Gateway-WS path is driven explicitly by the UI (`sendStreaming`) so it
        // can stream into the bubble — skip the CLI enqueue there.
        if message.role == "user" && !Self.useGatewayWS {
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
        fetchAndIngestSessionList(completion: nil)
    }

    /// Background-poll entry point: pull the agent's session list, fold it into
    /// the cache + mirror (exactly like `refreshFromRemote`), and hand the parsed
    /// metadata (id, title, `updatedAt`) to `completion` so the message poller can
    /// detect which sessions advanced since it last looked. `completion` runs on
    /// `ioQueue` with an empty array on any failure / unconfigured backend.
    func listSessionsForPoll(completion: @escaping ([SimpleConversation]) -> Void) {
        fetchAndIngestSessionList(completion: completion)
    }

    /// Shared session-list fetch used by both the on-demand refresh and the
    /// background poller. Runs the `openclaw sessions --json` command on `ioQueue`,
    /// folds the result into the cache/mirror, and invokes `completion` (if any)
    /// with the parsed list. Best effort: a failure leaves cached data intact and
    /// reports an empty list.
    private func fetchAndIngestSessionList(completion: (([SimpleConversation]) -> Void)?) {
        let config = self.config
        guard config.isConfigured else {
            if let completion = completion { ioQueue.async { completion([]) } }
            return
        }
        setSyncing(true)
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.setSyncing(false) }

            // Prefer the warm Gateway WS for listing. Shelling out `openclaw
            // sessions --json` spawns a fresh CLI gateway-client per poll and
            // contends with in-flight turns on the daemon's single connection —
            // under load it times out (30s) and starves sends. The WS is one cheap
            // RPC on the already-open socket. Fall back to SSH only when no live WS.
            var rows: [[String: Any]]?
            if let gateway = self.liveGatewayIfAvailable() {
                if case .success(let ws) = self.runBlockingValue({ try await gateway.listSessions() }) {
                    // `sessions.list` is unscoped; keep only this backend's agent
                    // (the SSH path filtered server-side via `--agent`).
                    let prefix = "agent:\(config.trimmedAgentId):"
                    rows = ws.filter { ($0["key"] as? String)?.hasPrefix(prefix) ?? false }
                } else {
                    openClawLog.error("gateway session list failed; falling back to SSH")
                }
            }
            if rows == nil {
                let agent = Self.shQuote(config.trimmedAgentId)
                let cmd = "\(Self.pathPrefix) openclaw sessions --json --agent \(agent) 2>/dev/null"
                let result = self.runBlocking {
                    try await SSHSkill.shared.runCommand(cmd, on: config.sshConfig, timeout: 30)
                }
                guard case .success(let cmdResult) = result else {
                    if case .failure(let error) = result {
                        openClawLog.error("session list failed: \(error.localizedDescription, privacy: .public)")
                    }
                    completion?([])
                    return
                }
                rows = Self.sessionRows(in: cmdResult.stdout)
            }
            let mapped = Self.mapSessionRows(rows ?? [], defaultBackend: self.backendID)
            // Hide VM sessions that are already an app-created chat (each such chat
            // owns a daemon session minted via `sessions.create`); otherwise it
            // would surface a second time as its own list entry.
            self.cacheLock.lock()
            let appSessionIds = Set(self.appCreated.compactMap { self.remoteSessionIds[$0] })
            self.cacheLock.unlock()
            let listed = mapped.convs.filter { !appSessionIds.contains($0.id) }
            self.ingestSessionList(listed, keys: mapped.keys)
            completion?(listed)
        }
    }

    /// Fold a freshly-parsed session list into the cache + mirror, preserving any
    /// already-loaded transcripts/titles. No-op for an empty list.
    private func ingestSessionList(_ listed: [SimpleConversation], keys: [String: String] = [:]) {
        guard !listed.isEmpty else { return }
        cacheLock.lock()
        for session in listed {
            // A listed conversation's id *is* its OpenClaw session id, so it's
            // directly resumable and reads its real transcript (not app-created).
            remoteSessionIds[session.id] = session.id
            // Keep the daemon's real gateway key so a turn resumes the exact VM
            // session (the key isn't always `agent:<id>:<sessionId>`).
            if let key = keys[session.id] { remoteSessionKeys[session.id] = key }
            if var existing = cache[session.id] {
                // Preserve any already-loaded transcript + title; the list
                // only carries metadata.
                existing.updatedAt = session.updatedAt
                if existing.messages.isEmpty { existing.title = session.title }
                cache[session.id] = existing
            } else {
                cache[session.id] = session
            }
        }
        recomputeOrderedIdsLocked()
        let snapshot = listed.compactMap { cache[$0.id] }
        cacheLock.unlock()
        for conv in snapshot { writeMirror(conv) }
        persistSidecar()
        postChange()
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
            // Streaming path: the foreground exec stream appends the reply to the
            // cache on completion, so the poller just needs the (already-current)
            // cache — no SSH round trip per tick. Legacy path still reads the
            // detached run's log.
            if Self.useStreamingExec {
                DispatchQueue.main.async { completion?(true) }
            } else {
                ioQueue.async { [weak self] in self?.pollRunLog(conversationId: id, config: config, completion: completion) }
            }
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

    /// Run a user turn through the OpenClaw agent on the VM and mark the
    /// conversation in-flight. Resumes the conversation's known OpenClaw session
    /// when we have one; a turn with no `--session-id` routes to the agent's main
    /// session (whose real id we then capture from the result). Best effort: a
    /// failed dispatch leaves the local user message in place and the poll times
    /// out with a notice.
    ///
    /// Default transport (`useStreamingExec`): the turn runs *foreground* over the
    /// persistent connection (`streamAgentTurn`), so the reply lands the instant
    /// the turn completes — no per-poll SSH handshake, no detach+log dance.
    private func enqueueAgentTurn(message: String, conversationId: String) {
        let config = self.config
        guard config.isConfigured else { return }
        cacheLock.lock()
        let sessionId = openClawSessionIdLocked(for: conversationId)
        inFlightRuns.insert(conversationId)
        cacheLock.unlock()

        let b64 = Data(message.utf8).base64EncodedString()
        let agentQ = Self.shQuote(config.trimmedAgentId)
        // Each conversation always runs against its own `--session-id` (app-created
        // chats get a unique `loop-<id>` session) so a new chat is an isolated
        // thread, never the shared agent `main` session.
        let sidQ = Self.shQuote(sessionId)

        guard Self.useStreamingExec else {
            legacyEnqueueDetachedTurn(b64: b64, agentQ: agentQ, sidQ: sidQ,
                                      conversationId: conversationId, config: config)
            return
        }

        // Foreground turn. `MSG` is reconstituted on the host from base64 so
        // arbitrary content can't break quoting, then passed as `-m "$MSG"` (a
        // shell var's expanded value isn't re-parsed, so quotes/backticks inside
        // it stay literal). No nohup/log: stdout carries the `--json` result and
        // the exec channel's exit status marks completion.
        let cmd = """
        \(Self.pathPrefix) MSG=$(printf %s \(Self.shQuote(b64)) | base64 -d); AGENT=\(agentQ); SID=\(sidQ); if [ -n "$SID" ]; then openclaw agent --agent "$AGENT" --session-id "$SID" -m "$MSG" --json; else openclaw agent --agent "$AGENT" -m "$MSG" --json; fi
        """
        streamAgentTurn(cmd, conversationId: conversationId, config: config)
    }

    /// Stream a foreground `openclaw agent --json` turn over the persistent
    /// connection. OpenClaw emits the `--json` result as one blob at the end of
    /// the turn (this CLI has no token-stream mode), so we accumulate stdout and
    /// parse on the channel's exit. Retains the `ExecStream` in `liveTurns` for
    /// the turn's lifetime and arms a watchdog so a hung turn can't pin it open.
    private func streamAgentTurn(_ command: String, conversationId id: String, config: OpenClawConfig) {
        let conn = persistentConnection(for: config)
        let stdoutBuffer = ByteAccumulator()
        let stderrBuffer = ByteAccumulator()

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let stream = try await conn.execStream(
                    command,
                    onStdout: { stdoutBuffer.append($0) },
                    onStderr: { stderrBuffer.append($0) },
                    onExit: { [weak self] exitCode in
                        self?.finishStreamedTurn(conversationId: id,
                                                 stdout: stdoutBuffer.string(),
                                                 stderr: stderrBuffer.string(),
                                                 exitCode: exitCode)
                    })
                self.cacheLock.lock()
                self.liveTurns[id] = stream
                self.cacheLock.unlock()
            } catch {
                openClawLog.error("agent-turn stream failed (\(id, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                self.finishStreamedTurn(conversationId: id, stdout: "",
                                        stderr: error.localizedDescription, exitCode: -1)
            }
        }

        // Backstop: the CLI enforces its own `--timeout` (default 600s), but if the
        // channel never closes, cancel so `liveTurns`/`inFlightRuns` don't leak.
        ioQueue.asyncAfter(deadline: .now() + 650) { [weak self] in
            guard let self = self else { return }
            self.cacheLock.lock()
            let stream = self.liveTurns[id]
            self.cacheLock.unlock()
            stream?.cancel()   // → channelInactive → onExit → finishStreamedTurn
        }
    }

    /// Parse a completed foreground turn's `--json` output and append the reply
    /// (or an error notice), capturing the real OpenClaw session id for resume.
    /// May run on the connection's event loop; all mutation is lock-guarded and
    /// notifications hop to main inside `postChange`.
    private func finishStreamedTurn(conversationId id: String, stdout: String,
                                    stderr: String, exitCode: Int32?) {
        cacheLock.lock()
        liveTurns[id] = nil
        let stillInFlight = inFlightRuns.contains(id)
        cacheLock.unlock()
        // Cancelled out from under us (e.g. the conversation was deleted).
        guard stillInFlight else { return }

        // Reuse the tested `--json` parser by appending the completion sentinel it
        // keys on; the channel's exit status stands in for the legacy `LOOPDONE`.
        let outcome = Self.parseAgentResult(stdout + "\nLOOPDONE:\(exitCode ?? -1)\n")
            ?? AgentTurnOutcome(ok: false, reply: "", sessionId: nil, model: nil,
                                messageId: UUID().uuidString, durationSeconds: nil,
                                error: stderr.isEmpty ? "no result" : String(stderr.suffix(300)))
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
    }

    /// Legacy transport: launch the turn detached (`nohup … &`) and let the poller
    /// read its run log. Kept behind `useStreamingExec == false` as a fallback.
    private func legacyEnqueueDetachedTurn(b64: String, agentQ: String, sidQ: String,
                                           conversationId: String, config: OpenClawConfig) {
        let log = Self.runLogPath(for: conversationId)
        let cmd = """
        \(Self.pathPrefix) MSG=$(printf %s \(Self.shQuote(b64)) | base64 -d); AGENT=\(agentQ); SID=\(sidQ); export MSG AGENT SID; : > \(log); nohup sh -c 'if [ -n "$SID" ]; then openclaw agent --agent "$AGENT" --session-id "$SID" -m "$MSG" --json; else openclaw agent --agent "$AGENT" -m "$MSG" --json; fi; echo "LOOPDONE:$?"' >> \(log) 2>&1 &
        """
        runRemote(cmd, config: config, label: "agent-turn")
    }

    /// The reused connection for this backend, (re)connecting lazily on first
    /// `execStream`. Recreated only when the SSH host changes — a dropped link is
    /// re-established transparently by `PersistentSSHConnection.rootChannel()`.
    private func persistentConnection(for config: OpenClawConfig) -> PersistentSSHConnection {
        let ssh = config.sshConfig
        let hostKey = "\(ssh.username)@\(ssh.host):\(ssh.port == 0 ? 22 : ssh.port)"
        connLock.lock(); defer { connLock.unlock() }
        if let conn = persistentConn, persistentConnHostKey == hostKey {
            return conn
        }
        persistentConn?.close()   // host changed — the old group must be torn down
        let conn = PersistentSSHConnection(config: ssh)
        persistentConn = conn
        persistentConnHostKey = hostKey
        return conn
    }

    deinit {
        if let o = backgroundObserver { NotificationCenter.default.removeObserver(o) }
        persistentConn?.close()
        gateway?.close()
    }

    // MARK: - Send (Gateway WebSocket — warm streaming session)

    /// The OpenClaw session id a conversation's turns run against. Each chat
    /// created in the app gets its own stable, unique session (derived from the
    /// conversation id) so a new Loop chat is an isolated thread whose only
    /// context is its own messages — not the shared agent `main` session.
    /// Conversations surfaced from the VM keep their real session id; once a turn
    /// reports the authoritative id (CLI path) we use that. Caller holds `cacheLock`.
    private func openClawSessionIdLocked(for conversationId: String) -> String {
        if let real = remoteSessionIds[conversationId] { return real }
        if appCreated.contains(conversationId) { return "loop-\(conversationId)" }
        return conversationId
    }

    /// The Gateway session key a conversation routes to, creating a fresh daemon
    /// session the first time an app chat is sent to (the daemon rejects an unknown
    /// key with "session not found", so we can't just mint a key client-side). The
    /// created key + sessionId are cached and persisted so every later turn — over
    /// the gateway OR the CLI — resumes the same isolated session.
    private func resolveGatewaySessionKey(for conversationId: String,
                                          client: OpenClawGatewayClient) async throws -> String {
        cacheLock.lock()
        if let key = remoteSessionKeys[conversationId] { cacheLock.unlock(); return key }
        let isApp = appCreated.contains(conversationId)
        cacheLock.unlock()
        // A VM-surfaced session we somehow lack a stored key for (e.g. an old
        // sidecar): reconstruct best-effort rather than mint a new session.
        guard isApp else {
            cacheLock.lock(); defer { cacheLock.unlock() }
            return "agent:\(config.trimmedAgentId):\(openClawSessionIdLocked(for: conversationId))"
        }
        // App chat's first gateway turn — create its own session on the daemon.
        let created = try await client.createSession(agentId: config.trimmedAgentId)
        cacheLock.lock()
        remoteSessionKeys[conversationId] = created.key
        if let sid = created.sessionId { remoteSessionIds[conversationId] = sid }
        cacheLock.unlock()
        persistSidecar()
        return created.key
    }

    /// Returns the connected Gateway client, connecting (once) on first use and
    /// holding it open. Concurrent callers share one connect.
    private func gatewayClient() async throws -> OpenClawGatewayClient {
        cacheLock.lock()
        if let g = gateway {
            if g.isLive { cacheLock.unlock(); return g }
            // Dead (dropped or backgrounded) — discard and reconnect. The persisted
            // device token makes the reconnect fast and rotation-proof.
            gateway = nil
            cacheLock.unlock()
            g.close()
            cacheLock.lock()
        }
        if let t = gatewayConnectTask { cacheLock.unlock(); return try await t.value }
        let config = self.config
        let backendID = self.backendID
        let task = Task { () -> OpenClawGatewayClient in
            let client = OpenClawGatewayClient(backendID: backendID, sshConfig: config.sshConfig)
            try await client.connectAndSubscribe()
            return client
        }
        gatewayConnectTask = task
        cacheLock.unlock()
        do {
            let client = try await task.value
            cacheLock.lock(); gateway = client; gatewayConnectTask = nil; cacheLock.unlock()
            return client
        } catch {
            cacheLock.lock(); gatewayConnectTask = nil; cacheLock.unlock()
            throw error
        }
    }

    /// Drives a user turn over the warm Gateway session, streaming the reply.
    /// `onDelta` gets incremental text (derived from the gateway's cumulative
    /// frames) and `completion` the persisted assistant message — both on the main
    /// queue. The user message is assumed already persisted via `addMessage`.
    func sendStreaming(text: String, conversationId: String,
                       onDelta: @escaping (String) -> Void,
                       completion: @escaping (Result<SimpleMessage, Error>) -> Void) {
        cacheLock.lock(); inFlightRuns.insert(conversationId); cacheLock.unlock()
        let stream = StreamState()
        // Latches the turn so a late `onError` (e.g. a drop after the reply) can't
        // double-fire `completion`. All three sites run on the client's event
        // queue / this Task and are mutually exclusive in time.
        var finished = false
        // Time-to-first-token, measured from when the message is sent (excludes the
        // one-time connect on the first turn). Surfaced in the reply's label.
        var ttft: TimeInterval?
        var turnStart = Date()
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let client = try await self.gatewayClient()
                let model = client.sessionModel
                client.onAssistantText = { cumulative in
                    guard !finished else { return }
                    if ttft == nil { ttft = Date().timeIntervalSince(turnStart) }
                    let delta = stream.delta(for: cumulative)
                    if !delta.isEmpty { DispatchQueue.main.async { onDelta(delta) } }
                }
                client.onTurnComplete = { [weak self] in
                    guard let self = self, !finished else { return }
                    finished = true
                    let total = Date().timeIntervalSince(turnStart)
                    openClawLog.info("gateway turn complete: ttft=\(ttft ?? -1, privacy: .public)s total=\(total, privacy: .public)s")
                    let msg = self.finalizeGatewayReply(text: stream.latest, ttft: ttft, model: model, conversationId: conversationId)
                    DispatchQueue.main.async { completion(.success(msg)) }
                }
                client.onError = { [weak self] error in
                    guard let self = self, !finished else { return }
                    finished = true
                    self.cacheLock.lock(); self.inFlightRuns.remove(conversationId); self.cacheLock.unlock()
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
                let sessionKey = try await self.resolveGatewaySessionKey(for: conversationId, client: client)
                turnStart = Date()   // reset to the actual send moment (post-connect)
                _ = try await client.send(text, sessionKey: sessionKey)
            } catch {
                guard !finished else { return }
                finished = true
                self.cacheLock.lock(); self.inFlightRuns.remove(conversationId); self.cacheLock.unlock()
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Persist a completed assistant reply to the cache + mirror, clear in-flight,
    /// and return the message for the UI to render.
    private func finalizeGatewayReply(text: String, ttft: TimeInterval?, model: String?,
                                      conversationId id: String) -> SimpleMessage {
        // `responseSeconds` renders as the time-to-first-token next to the model
        // name in the reply label (see `MessageStruct.ttft` / `modelText`).
        // Fall back to "OpenClaw" so the label never shows the local placeholder
        // model when the session model wasn't captured.
        let assistant = SimpleMessage(id: UUID().uuidString, role: "assistant",
                                      content: text, model: model ?? "OpenClaw",
                                      responseSeconds: ttft, createdAt: Date())
        cacheLock.lock()
        var conv = cache[id] ?? SimpleConversation(id: id, title: "Conversation", backend: backendID)
        conv.messages.append(assistant)
        conv.updatedAt = Date()
        cache[id] = conv
        inFlightRuns.remove(id)
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        writeMirror(conv)
        postChange()
        return assistant
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
    /// Filters out machine sub-sessions (`:cron:`, `:run:`) and Loop's own
    /// app-created sessions (`loop-<id>`, already surfaced as their local chat),
    /// and dedups by `sessionId`, keeping the most recently updated.
    static func parseSessionsList(_ output: String, defaultBackend: String) -> [SimpleConversation] {
        mapSessionRows(sessionRows(in: output), defaultBackend: defaultBackend).convs
    }

    /// Extract a `sessionId → gateway key` map from `openclaw sessions --json`
    /// output (same `:cron:`/`:run:` filter as `parseSessionsList`). The daemon
    /// reports `key` and `sessionId` as distinct fields, so we keep the real key
    /// to resume the exact VM session rather than reconstructing it.
    static func sessionKeyMap(from output: String) -> [String: String] {
        mapSessionRows(sessionRows(in: output), defaultBackend: "").keys
    }

    /// Pull the `sessions[]` array out of `openclaw sessions --json` text,
    /// tolerating a leading sentinel line by scanning for the first `{`.
    static func sessionRows(in output: String) -> [[String: Any]] {
        guard let data = jsonObjectData(in: output),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = root["sessions"] as? [[String: Any]] else { return [] }
        return sessions
    }

    /// Map raw session rows (from the CLI's JSON or the WS `sessions.list`) into
    /// conversations + a `sessionId → key` map in one pass. Filters machine
    /// sub-sessions (`:cron:`/`:run:`) and Loop's own app sessions (`loop-<id>`),
    /// and dedups by `sessionId`, keeping the most recently updated.
    static func mapSessionRows(_ rows: [[String: Any]], defaultBackend: String)
        -> (convs: [SimpleConversation], keys: [String: String]) {
        var byId: [String: SimpleConversation] = [:]
        var keys: [String: String] = [:]
        for s in rows {
            guard let key = s["key"] as? String,
                  let sessionId = s["sessionId"] as? String else { continue }
            if key.contains(":cron:") || key.contains(":run:") { continue }
            if isAppCreatedSessionId(sessionId) { continue }
            keys[sessionId] = key
            let updated = epochMillisToDate(s["updatedAt"]) ?? .distantPast
            let agentId = (s["agentId"] as? String) ?? "main"
            let title = deriveTitle(fromKey: key, agentId: agentId)
            let conv = SimpleConversation(id: sessionId, title: title, messages: [],
                                          createdAt: updated, updatedAt: updated,
                                          backend: defaultBackend)
            if let existing = byId[sessionId], existing.updatedAt >= updated { continue }
            byId[sessionId] = conv
        }
        return (Array(byId.values), keys)
    }

    /// Whether a VM session id is one Loop created for an app chat. These are
    /// already represented locally by their app conversation, so they're filtered
    /// from the surfaced VM list to avoid a duplicate entry. Mirrors the
    /// `loop-<conversationId>` id minted in `openClawSessionIdLocked`.
    static func isAppCreatedSessionId(_ sessionId: String) -> Bool {
        sessionId.hasPrefix("loop-")
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
        /// Conversation id → real gateway key for VM-surfaced sessions. Optional
        /// so sidecars written before this field decode cleanly.
        var keys: [String: String]?
    }

    private var sidecarURL: URL { mirrorURL.appendingPathComponent("_loop-meta.json") }

    private func loadSidecar() {
        guard let data = try? Data(contentsOf: sidecarURL),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) else { return }
        cacheLock.lock()
        remoteSessionIds = sidecar.sessions
        appCreated = Set(sidecar.appCreated)
        remoteSessionKeys = sidecar.keys ?? [:]
        cacheLock.unlock()
    }

    /// Snapshot the conversation→session map + app-created set under the lock and
    /// write them asynchronously. Safe to call without holding `cacheLock`.
    private func persistSidecar() {
        cacheLock.lock()
        let sidecar = Sidecar(sessions: remoteSessionIds, appCreated: Array(appCreated),
                              keys: remoteSessionKeys)
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
        runBlockingValue(work)
    }

    /// Run an async closure to completion from a synchronous (`ioQueue`) context.
    /// Generic form used for both SSH commands and warm-WS RPCs.
    private func runBlockingValue<T>(_ work: @escaping () async throws -> T) -> Result<T, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<T, Error>!
        Task {
            do { outcome = .success(try await work()) }
            catch { outcome = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return outcome
    }

    /// The held Gateway client only if it's connected and live — never connects.
    /// Used to prefer the warm WS for cheap RPCs (e.g. session listing) without
    /// paying a connect on paths that can fall back to SSH.
    private func liveGatewayIfAvailable() -> OpenClawGatewayClient? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let g = gateway, g.isLive { return g }
        return nil
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

// MARK: - Cumulative→delta converter

/// The Gateway streams the assistant reply as CUMULATIVE text (each frame is the
/// full text so far). The UI's streaming bubble appends deltas, so this converts
/// cumulative frames into incremental suffixes. Assumes growth-by-suffix
/// (validated against the live daemon); on a non-prefix frame it emits the whole
/// text (rare — may briefly duplicate).
private final class StreamState {
    private(set) var latest = ""
    func delta(for cumulative: String) -> String {
        defer { latest = cumulative }
        if cumulative.hasPrefix(latest) { return String(cumulative.dropFirst(latest.count)) }
        return cumulative
    }
}

// MARK: - Streaming output accumulator

/// Thread-safe sink for incremental stdout/stderr chunks from a streaming exec.
/// A chunk may split a multi-byte UTF-8 sequence, so we buffer raw bytes and
/// decode only when the whole stream is read (`string()`).
private final class ByteAccumulator {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    func string() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
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
