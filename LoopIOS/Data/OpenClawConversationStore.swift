//
//  OpenClawConversationStore.swift
//  Loop
//
//  Remote conversation backend for the OpenClaw VM. Mirrors the same
//  NDJSON-per-conversation format `ConversationFileStore` uses, but the files
//  live on an SSH-accessible workspace:
//
//      <workspacePath>/conversations/<conversation-uuid>.ndjson
//
//  Reads are answered from an in-memory cache that's seeded from a local
//  on-disk mirror (so the conversation list and already-opened chats render
//  even when the VM is unreachable) and reconciled from the VM on demand.
//  Writes update the cache + local mirror synchronously, then flush to the VM
//  asynchronously over `SSHSkill`. If the VM is down a write still lands in the
//  local mirror — no data loss — and re-syncs next time the connection is up.
//
//  Transport: we shell out over SSH. Each NDJSON line is base64-encoded before
//  it crosses the wire and decoded on the host (`base64 -d`), so arbitrary
//  message content can't break shell quoting. We never put the private key or
//  passphrase on a command line — `SSHSkill` reads them from the Keychain-
//  backed config and handles auth itself.
//
//  Pure Foundation so it compiles for the iOS, macOS, and visionOS targets.
//

import Foundation
import os

private let openClawLog = Logger(subsystem: "com.bhat.intel", category: "OpenClaw")

final class OpenClawConversationStore: ConversationStore {

    static let shared = OpenClawConversationStore()

    /// This store owns the OpenClaw backend. Conversations it creates are
    /// stamped `"openclaw"`.
    let backendMarker = ConversationBackend.openclaw.rawValue

    // MARK: - State

    private let cacheLock = NSLock()
    private var cache: [String: SimpleConversation] = [:]
    private var orderedIds: [String] = []

    /// Background queue for all SSH + local-mirror disk I/O. Reads never enter
    /// here.
    private let ioQueue = DispatchQueue(label: "loop.openClawConversationStore.io",
                                        qos: .utility)

    private var _isSyncing = false

    /// Root of the local mirror used for offline list/render fallback.
    private let mirrorURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("Loop", isDirectory: true)
            .appendingPathComponent("openclaw-cache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.mirrorURL = dir

        bootstrapFromMirror()

        // Reconcile with the VM if it's already configured. Async + best-effort:
        // a down VM just leaves the mirror in place.
        if OpenClawConfigStore.shared.config.isConfigured {
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

    func createConversation(title: String) -> SimpleConversation {
        let conv = SimpleConversation(title: title, backend: backendMarker)
        cacheLock.lock()
        cache[conv.id] = conv
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        writeMirror(conv)
        postChange()
        let lines = [metaLine(for: conv)]
        enqueueRemoteAppend(lines, conversationId: conv.id)
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
        // A bare save only changes metadata (e.g. a rename); append a fresh
        // meta line rather than rewriting the whole remote file.
        enqueueRemoteAppend([metaLine(for: updated)], conversationId: updated.id)
    }

    func deleteConversation(id: String) {
        cacheLock.lock()
        cache.removeValue(forKey: id)
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        try? FileManager.default.removeItem(at: mirrorFileURL(for: id))
        postChange()
        enqueueRemoteDelete(conversationId: id)
    }

    func addMessage(_ message: SimpleMessage, toConversation id: String) {
        cacheLock.lock()
        var conv = cache[id] ?? SimpleConversation(id: id, title: "Untitled", backend: backendMarker)
        conv.messages.append(message)
        conv.updatedAt = Date()
        cache[id] = conv
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        let snapshot = conv
        writeMirror(snapshot)
        postChange()
        // Append the message then a bumped meta so a partial read still sees
        // the latest updatedAt — same convention as the local file store.
        enqueueRemoteAppend([messageLine(message), metaLine(for: snapshot)],
                            conversationId: id)
    }

    func removeMessage(id messageId: String, fromConversation conversationId: String) {
        cacheLock.lock()
        guard var conv = cache[conversationId] else { cacheLock.unlock(); return }
        conv.messages.removeAll { $0.id == messageId }
        conv.updatedAt = Date()
        cache[conversationId] = conv
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        let snapshot = conv
        writeMirror(snapshot)
        postChange()
        // Removal can't be expressed as an append — rewrite the whole file.
        enqueueRemoteRewrite(snapshot)
    }

    // MARK: - Validation

    /// Verifies the VM is reachable, authenticates, and that the configured
    /// workspace path can be created/inspected. Returns a short human-readable
    /// summary on success; throws `SSHSkillError`/`OpenClawError` on failure.
    /// Safe to call from the settings screen — performs no secret logging.
    func validate(_ config: OpenClawConfig) async throws -> String {
        guard config.isConfigured else {
            throw OpenClawError.notConfigured
        }
        let dir = Self.conversationsDirExpression(for: config)
        // One round trip: prove auth, ensure the conversations dir exists under
        // the workspace, then count what's already there. The `OPENCLAW_OK`
        // sentinel is printed only if `mkdir` succeeded, so we can tell a real
        // success from a swallowed `mkdir` failure (the trailing `|| true` only
        // guards `grep -c` returning 1 on an empty directory — shell binds `|`
        // tighter than `&&`/`||`).
        let cmd = "mkdir -p \(dir) && echo OPENCLAW_OK && (ls -1 \(dir) 2>/dev/null | grep -c '\\.ndjson$' || true)"
        let result = try await SSHSkill.shared.runCommand(cmd, on: config.sshConfig, timeout: 15)
        guard result.stdout.contains("OPENCLAW_OK") else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw OpenClawError.workspaceUnreachable(detail.isEmpty ? "Could not create or read the workspace path." : detail)
        }
        // The count is the numeric line emitted after the sentinel.
        let count = result.stdout
            .split(separator: "\n")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .last ?? 0
        return count == 0
            ? "Workspace ready (no conversations yet)."
            : "Workspace ready (\(count) conversation\(count == 1 ? "" : "s"))."
    }

    // MARK: - Remote sync

    /// Pull every conversation file from the VM into the cache + mirror. Best
    /// effort: failures are logged and leave existing cached data intact.
    func refreshFromRemote() {
        let config = OpenClawConfigStore.shared.config
        guard config.isConfigured else { return }
        setSyncing(true)
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.setSyncing(false) }
            do {
                let convs = try self.fetchAllRemote(config)
                self.cacheLock.lock()
                for conv in convs {
                    self.cache[conv.id] = conv
                }
                self.recomputeOrderedIdsLocked()
                self.cacheLock.unlock()
                for conv in convs { self.writeMirror(conv) }
                self.postChange()
            } catch {
                openClawLog.error("remote refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Blocking remote read. MUST run on `ioQueue`. Reads every `*.ndjson`
    /// under the conversations dir in a single round trip (base64 framed) and
    /// parses each into a `SimpleConversation`.
    private func fetchAllRemote(_ config: OpenClawConfig) throws -> [SimpleConversation] {
        let dir = Self.conversationsDirExpression(for: config)
        // Frame each file with a sentinel so we can split client-side. base64
        // keeps binary-safe content from corrupting the stream.
        let cmd = """
        cd \(dir) 2>/dev/null && for f in *.ndjson; do [ -e "$f" ] || continue; echo "===OPENCLAW:$f==="; base64 "$f"; done
        """
        let result = runBlocking { try await SSHSkill.shared.runCommand(cmd, on: config.sshConfig, timeout: 30) }
        switch result {
        case .failure(let error):
            throw error
        case .success(let cmdResult):
            return Self.parseFramedListing(cmdResult.stdout)
        }
    }

    /// Parse the `===OPENCLAW:<file>===` + base64 framing produced by
    /// `fetchAllRemote`. Exposed `static` for unit testing the wire format.
    static func parseFramedListing(_ output: String) -> [SimpleConversation] {
        var conversations: [SimpleConversation] = []
        var currentId: String?
        var b64 = ""

        func flush() {
            guard let id = currentId else { return }
            let cleaned = b64.replacingOccurrences(of: "\n", with: "")
                             .replacingOccurrences(of: "\r", with: "")
                             .replacingOccurrences(of: " ", with: "")
            if let data = Data(base64Encoded: cleaned),
               let text = String(data: data, encoding: .utf8),
               let conv = parseNDJSON(text, fallbackId: id) {
                conversations.append(conv)
            }
            currentId = nil
            b64 = ""
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("===OPENCLAW:") && line.hasSuffix("===") {
                flush()
                let name = line.dropFirst("===OPENCLAW:".count).dropLast(3)
                currentId = String(name).replacingOccurrences(of: ".ndjson", with: "")
            } else {
                b64 += line
            }
        }
        flush()
        return conversations
    }

    // MARK: - NDJSON encode/decode (shared format with ConversationFileStore)

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

    /// Parse an NDJSON blob (meta + msg lines) into a conversation. `static` so
    /// both the remote fetch and the local-mirror bootstrap share one parser,
    /// and so it's unit-testable.
    static func parseNDJSON(_ text: String, fallbackId: String) -> SimpleConversation? {
        var title = "Untitled"
        var createdAt = Date()
        var updatedAt = Date()
        var backend: String? = ConversationBackend.openclaw.rawValue
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

    // MARK: - Local mirror

    private func bootstrapFromMirror() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: mirrorURL,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) else { return }
        var seeds: [SimpleConversation] = []
        for url in entries where url.pathExtension == "ndjson" {
            let id = url.deletingPathExtension().lastPathComponent
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let conv = Self.parseNDJSON(text, fallbackId: id) {
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

    // MARK: - Remote writes (best-effort, on ioQueue)

    private func enqueueRemoteAppend(_ lines: [String], conversationId: String) {
        let config = OpenClawConfigStore.shared.config
        guard config.isConfigured else { return }
        let payload = lines.joined(separator: "\n") + "\n"
        let b64 = Data(payload.utf8).base64EncodedString()
        let dir = Self.conversationsDirExpression(for: config)
        let file = "\(dir)/\(conversationId).ndjson"
        let cmd = "mkdir -p \(dir) && printf %s \(Self.shQuote(b64)) | base64 -d >> \(file)"
        runRemote(cmd, config: config, label: "append")
    }

    private func enqueueRemoteRewrite(_ conv: SimpleConversation) {
        let config = OpenClawConfigStore.shared.config
        guard config.isConfigured else { return }
        var body = metaLine(for: conv) + "\n"
        for msg in conv.messages { body += messageLine(msg) + "\n" }
        let b64 = Data(body.utf8).base64EncodedString()
        let dir = Self.conversationsDirExpression(for: config)
        let file = "\(dir)/\(conv.id).ndjson"
        let cmd = "mkdir -p \(dir) && printf %s \(Self.shQuote(b64)) | base64 -d > \(file)"
        runRemote(cmd, config: config, label: "rewrite")
    }

    private func enqueueRemoteDelete(conversationId: String) {
        let config = OpenClawConfigStore.shared.config
        guard config.isConfigured else { return }
        let dir = Self.conversationsDirExpression(for: config)
        let cmd = "rm -f \(dir)/\(conversationId).ndjson"
        runRemote(cmd, config: config, label: "delete")
    }

    private func runRemote(_ command: String, config: OpenClawConfig, label: String) {
        ioQueue.async {
            let result = self.runBlocking {
                try await SSHSkill.shared.runCommand(command, on: config.sshConfig, timeout: 20)
            }
            if case .failure(let error) = result {
                // Degrade gracefully: the local mirror already holds the write,
                // so no data is lost — it re-syncs when the VM is reachable.
                openClawLog.error("remote \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
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

    /// Shell-quotes a base64 payload (single-quote wrap; base64 never contains
    /// a quote so the escape is belt-and-suspenders).
    static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Shell expression for `<workspace>/conversations`, expanding a leading
    /// `~` to `$HOME` (tilde isn't expanded inside quotes) while quoting the
    /// rest so spaces are safe.
    static func conversationsDirExpression(for config: OpenClawConfig) -> String {
        let ws = config.trimmedWorkspacePath
        let base: String
        if ws == "~" {
            base = "\"$HOME\""
        } else if ws.hasPrefix("~/") {
            base = "\"$HOME\"/" + shQuote(String(ws.dropFirst(2)))
        } else {
            base = shQuote(ws)
        }
        return base + "/conversations"
    }
}

// MARK: - Errors

enum OpenClawError: LocalizedError {
    case notConfigured
    case workspaceUnreachable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "OpenClaw is not configured. Enter host, username, private key, and workspace path."
        case .workspaceUnreachable(let detail):
            return "Couldn't access the workspace: \(detail)"
        }
    }
}

// MARK: - Line schemas (mirror ConversationFileStore's NDJSON shape)

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

/// Encodes a `SimpleMessage` to the same `{"_type":"msg",…}` line shape the
/// local file store writes, so the two backends produce interchangeable files.
private struct NDMessageEnvelope: Encodable {
    let message: SimpleMessage

    private enum CodingKeys: String, CodingKey {
        case _type, id, role, content, name, functionName, functionArguments
        case actions, fileAttachment, mapAttachment, model, isCompactionSummary, createdAt
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
        try c.encodeIfPresent(message.model, forKey: .model)
        try c.encodeIfPresent(message.isCompactionSummary, forKey: .isCompactionSummary)
        try c.encode(message.createdAt, forKey: .createdAt)
    }
}
