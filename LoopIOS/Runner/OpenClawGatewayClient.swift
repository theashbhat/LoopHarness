//
//  OpenClawGatewayClient.swift
//  Loop
//
//  A persistent operator client for the OpenClaw Gateway — what the `openclaw tui`
//  is, ported to Swift. The 20s "simple response" the app used to see came from
//  driving the agent with one-shot `openclaw agent` CLI calls, which run COLD
//  every time (~16s) because nothing holds the session resident. The Gateway keeps
//  a session warm (<5s) only while a client holds the connection OPEN — so this
//  connects once, subscribes, and keeps talking to the warm session.
//
//  Validated live against the daemon (OpenClaw 2026.4.1, 2026-06-03): warm sends
//  hit ~4s time-to-first-token vs ~16s cold. Protocol (see the gateway-protocol
//  notes) is v3:
//    • Transport: ws://127.0.0.1:<localPort> over an SSH `direct-tcpip` tunnel to
//      the daemon's loopback `:18789` (reusing PersistentSSHConnection +
//      SSHTunnelForwarder — the same building blocks as the Loop Runner tunnel).
//    • Handshake: the gateway sends `event connect.challenge {nonce}` first; we
//      reply with a `connect` req carrying an ed25519 device signature over the
//      v3 payload, plus the shared gateway token. Success → `hello-ok` (carries a
//      `deviceToken` we persist for rotation-proof reconnects).
//    • Send:   `sessions.send {key, message}` → `{runId, status:"started"}`.
//    • Stream: `event agent {runId, stream, data}` — `stream:"assistant"` carries
//      CUMULATIVE `data.text` (replace, don't append); `stream:"lifecycle"` with
//      `data.phase:"end"` marks the turn complete.
//
//  Threading: URLSession WebSocket callbacks land off-main. All client state is
//  funneled onto a single serial queue; streaming callbacks (`onAssistantText` /
//  `onTurnComplete`) fire on that queue, so the UI layer must hop to main before
//  touching the message list / streaming bubble (the MessagingVC main-thread
//  invariant).
//

import Foundation
import CryptoKit
import os

// MARK: - Device identity

/// A persistent ed25519 device identity used for the Gateway connect handshake.
/// `deviceId` = SHA-256 hex of the raw 32-byte public key; signatures and the
/// public key are base64url-encoded, matching the daemon's `device-identity`
/// verifier.
struct OpenClawDeviceIdentity {
    let privateKey: Curve25519.Signing.PrivateKey
    let deviceId: String
    let publicKeyB64Url: String

    init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
        let raw = privateKey.publicKey.rawRepresentation
        self.deviceId = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        self.publicKeyB64Url = OpenClawDeviceIdentity.b64url(raw)
    }

    /// Loads the persisted identity for a backend, or creates + persists a new one.
    /// TODO: migrate the private key from UserDefaults to the Keychain (it only
    /// authorizes connecting to the user's own gateway over a loopback tunnel they
    /// control, so the exposure is limited, but Keychain is the right home).
    static func loadOrCreate(backendID: String) -> OpenClawDeviceIdentity {
        let key = "loop.openclaw.deviceKey.\(backendID)"
        if let b64 = UserDefaults.standard.string(forKey: key),
           let data = Data(base64Encoded: b64),
           let restored = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return OpenClawDeviceIdentity(privateKey: restored)
        }
        let priv = Curve25519.Signing.PrivateKey()
        UserDefaults.standard.set(priv.rawRepresentation.base64EncodedString(), forKey: key)
        return OpenClawDeviceIdentity(privateKey: priv)
    }

    /// ed25519 signature over `payload`, base64url-encoded.
    func sign(_ payload: String) -> String {
        guard let sig = try? privateKey.signature(for: Data(payload.utf8)) else { return "" }
        return OpenClawDeviceIdentity.b64url(sig)
    }

    static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Errors

enum OpenClawGatewayError: LocalizedError {
    case notConnected
    case handshakeFailed(String)
    case requestFailed(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Gateway is not connected."
        case .handshakeFailed(let d): return "Gateway handshake failed: \(d)"
        case .requestFailed(let d): return "Gateway request failed: \(d)"
        case .transport(let d): return "Gateway transport error: \(d)"
        }
    }
}

// MARK: - Single-shot continuation

/// Wraps a `CheckedContinuation` so it can be resumed at most once — any later
/// resume is a no-op instead of a fatal "resumed more than once" trap. The
/// gateway has the same hazard SSHSkill's `SingleResume` guards against: a
/// `task.send` error callback, a `receive` failure, and `close()` can all
/// converge on the same in-flight request during a disconnect. Confined to the
/// client's serial `q`, so the plain optional needs no locking.
private final class OneShotContinuation {
    private var cont: CheckedContinuation<[String: Any], Error>?
    init(_ cont: CheckedContinuation<[String: Any], Error>) { self.cont = cont }
    func resume(returning value: [String: Any]) { cont?.resume(returning: value); cont = nil }
    func resume(throwing error: Error) { cont?.resume(throwing: error); cont = nil }
}

// MARK: - Client

/// `@unchecked Sendable`: all mutable state is confined to the serial `q`; the
/// transport handles (set once in `setupTransport` before any `q` work reads
/// them) and the streaming callbacks are the only cross-actor surface.
final class OpenClawGatewayClient: NSObject, @unchecked Sendable {

    private static let log = Logger(subsystem: "com.bhat.intel", category: "OpenClawGateway")

    // Connection inputs
    private let backendID: String
    private let sshConfig: SSHConfig
    /// Optional override. Normally the gateway token is fetched from the VM's
    /// `~/.openclaw/openclaw.json` at connect time — the app already has SSH to the
    /// backend, so the user never enters a token.
    private let gatewayTokenOverride: String?
    private var resolvedToken = ""
    private let remotePort = 18789

    // Handshake constants (must be enum values the daemon's schema accepts)
    private let clientId = "openclaw-ios"
    private let clientMode = "ui"
    private let role = "operator"
    private let scopes = ["operator.read", "operator.write"]
    private let platform = "ios"
    private let deviceFamily = "iphone"

    private let identity: OpenClawDeviceIdentity

    // Transport (retained for the connection's lifetime)
    private var connection: PersistentSSHConnection?
    private var forwarder: SSHTunnelForwarder?
    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?

    // State (all access on `q`)
    private let q = DispatchQueue(label: "loop.openclaw.gateway")
    private var reqCounter = 0
    private var pending: [String: OneShotContinuation] = [:]
    private var connectContinuation: OneShotContinuation?
    private var deviceToken: String?
    private var currentRunId: String?
    /// Session keys this connection has already subscribed to. One warm
    /// connection fans out across every Loop chat's session (each chat is its
    /// own OpenClaw session); we subscribe lazily on first send to a key.
    private var subscribedKeys: Set<String> = []
    private var isClosed = false
    private var connected = false
    /// Whether the in-flight `connect` used a persisted device token (vs the
    /// shared gateway token) — drives the stale-device-token retry.
    private var usedDeviceToken = false

    /// True once the handshake + subscribe have succeeded and the link is up.
    /// Reads off the serial queue are a benign race (flags flip true→false on a
    /// drop); the store uses this to decide whether to reuse or rebuild.
    var isLive: Bool { connected && !isClosed }

    /// The session's model id (from `sessions.list` defaults), surfaced so the UI
    /// can label replies accurately instead of the local placeholder model.
    private(set) var sessionModel: String?

    private static let connectReqId = "0"

    // Streaming output. Fire on `q` (off-main) — hop to main before touching UI.
    var onAssistantText: ((String) -> Void)?
    /// Fires when the agent invokes a tool mid-turn (name + optional call id +
    /// decoded input). May fire repeatedly for the same `callId` if the daemon
    /// streams the input cumulatively — the consumer should dedupe by `callId`.
    var onToolCall: ((_ name: String, _ callId: String?, _ input: [String: Any]) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onError: ((Error) -> Void)?

    init(backendID: String, sshConfig: SSHConfig, gatewayTokenOverride: String? = nil) {
        self.backendID = backendID
        self.sshConfig = sshConfig
        self.gatewayTokenOverride = gatewayTokenOverride
        self.identity = OpenClawDeviceIdentity.loadOrCreate(backendID: backendID)
        self.deviceToken = UserDefaults.standard.string(forKey: "loop.openclaw.deviceToken.\(backendID)")
        super.init()
    }

    // MARK: - Lifecycle

    /// Stands up the tunnel, opens the WebSocket, and performs the v3 handshake.
    /// Resolves once the link is live; throws on any transport/handshake/auth
    /// failure. Sessions are subscribed lazily on first `send`.
    func connectAndSubscribe() async throws {
        do {
            try await attemptConnect()
        } catch {
            // A rejected DEVICE token (rotated/revoked) is recoverable: clear it
            // and retry once with the freshly re-read shared gateway token. A
            // shared-token failure (or any non-auth error) is surfaced as-is.
            guard usedDeviceToken, isAuthError(error) else { throw error }
            Self.log.info("gateway: device token rejected — retrying with shared token")
            clearDeviceToken()
            teardownTransport()
            try await attemptConnect()
        }
    }

    /// One full connect attempt: re-read token (handles shared-token rotation) →
    /// tunnel → handshake → capture model. Per-session subscription is deferred to
    /// the first `send` for that session (see `ensureSubscribed`).
    private func attemptConnect() async throws {
        resolvedToken = try await resolveToken()
        try await setupTransport()
        let hello = try await performConnect()
        persistDeviceToken(from: hello)
        // Best-effort: capture the agent's default model for the reply label.
        if let list = try? await req("sessions.list", [:]),
           let defaults = list["defaults"] as? [String: Any],
           let model = defaults["model"] as? String {
            sessionModel = model
        }
        connected = true
        Self.log.info("gateway ready")
    }

    private func isAuthError(_ error: Error) -> Bool {
        guard let e = error as? OpenClawGatewayError, case .handshakeFailed(let m) = e else { return false }
        let lower = m.lowercased()
        return lower.contains("mismatch") || lower.contains("unauthor") || lower.contains("token")
    }

    /// Creates a fresh session for `agentId` and returns the daemon-assigned key
    /// (and sessionId). A session MUST exist before it can be subscribed/sent to —
    /// the daemon rejects an unknown key with "session not found" — so a new Loop
    /// chat mints one here on its first turn. Tolerates the response carrying the
    /// session object at the top level or nested under `session`.
    func createSession(agentId: String) async throws -> (key: String, sessionId: String?) {
        let payload = try await req("sessions.create", ["agentId": agentId])
        let obj = (payload["session"] as? [String: Any]) ?? payload
        let key = (obj["key"] as? String) ?? (obj["sessionKey"] as? String)
        let sessionId = obj["sessionId"] as? String
        guard let key = key, !key.isEmpty else {
            throw OpenClawGatewayError.requestFailed("sessions.create returned no session key")
        }
        Self.log.info("gateway session created: key=\(key, privacy: .public)")
        return (key, sessionId)
    }

    /// Lists the agent's sessions over the warm WS — cheap (one RPC on the open
    /// socket) vs an SSH `openclaw sessions --json` poll, which spawns a fresh CLI
    /// gateway-client each time and contends with in-flight turns on the daemon.
    /// Returns the raw session rows (same shape as the CLI's `.sessions[]`).
    func listSessions() async throws -> [[String: Any]] {
        let payload = try await req("sessions.list", [:])
        return (payload["sessions"] as? [[String: Any]]) ?? []
    }

    // MARK: - Artifacts (agent-produced media)

    /// Lists the transcript-derived artifacts a run produced (`{name, mimeType,
    /// size, url, kind}` per the protocol docs). Used to surface images the agent
    /// "sent" back, which the text-only `agent` stream doesn't carry. The live
    /// payload shape is UNCONFIRMED (the docs point at the unpublished
    /// `frames.ts`), so parse tolerantly and log the keys to discover it — mirrors
    /// how tool-call frames were reverse-engineered. Best effort: callers treat a
    /// throw / empty list as "no artifacts".
    func listArtifacts(runId: String) async throws -> [[String: Any]] {
        let payload = try await req("artifacts.list", ["runId": runId])
        let items = (payload["artifacts"] as? [[String: Any]])
            ?? (payload["items"] as? [[String: Any]])
            ?? (payload["results"] as? [[String: Any]]) ?? []
        Self.log.debug("artifacts.list runId=\(runId, privacy: .public) count=\(items.count) payloadKeys=\(payload.keys.joined(separator: ","), privacy: .public)")
        return items
    }

    /// Downloads one artifact's bytes. `entry` is a row from `listArtifacts`; we
    /// pass through whatever identifiers it carries (name/url/id) alongside the run
    /// scope, and decode base64 from `bytes`/`base64`/`data`. Returns nil when the
    /// response carries no decodable body (shape-tolerant, logs the keys).
    func downloadArtifact(runId: String, entry: [String: Any]) async throws -> Data? {
        var params: [String: Any] = ["runId": runId]
        if let name = entry["name"] as? String { params["name"] = name }
        if let url = entry["url"] as? String { params["url"] = url }
        if let id = (entry["id"] as? String) ?? (entry["artifactId"] as? String) { params["artifactId"] = id }
        let payload = try await req("artifacts.download", params)
        let raw = (payload["bytes"] as? String) ?? (payload["base64"] as? String) ?? (payload["data"] as? String)
        guard let raw = raw, let data = Data(base64Encoded: Self.stripBase64(raw)) else {
            Self.log.debug("artifacts.download no decodable bytes; payloadKeys=\(payload.keys.joined(separator: ","), privacy: .public)")
            return nil
        }
        return data
    }

    /// Strip a `data:<mime>;base64,` prefix and any whitespace/newlines so a
    /// base64 string from JSON (or a data URL) decodes cleanly.
    private static func stripBase64(_ s: String) -> String {
        var body = s
        if let comma = body.range(of: ";base64,") { body = String(body[comma.upperBound...]) }
        return body.filter { !$0.isWhitespace }
    }

    /// Subscribes this connection to a session's event stream if it hasn't
    /// already. The session must already exist (see `createSession`); subscribing
    /// before the first send ensures the turn's assistant deltas are delivered.
    func ensureSubscribed(to key: String) async throws {
        let alreadySubscribed: Bool = q.sync { self.subscribedKeys.contains(key) }
        guard !alreadySubscribed else { return }
        _ = try await req("sessions.messages.subscribe", ["key": key])
        q.sync { _ = self.subscribedKeys.insert(key) }
    }

    /// Sends a user turn to the given session (subscribing to it first if needed).
    /// The reply streams back via `onAssistantText` (cumulative) and
    /// `onTurnComplete`. Returns the runId.
    @discardableResult
    func send(_ text: String, sessionKey key: String) async throws -> String {
        try await ensureSubscribed(to: key)
        let payload = try await req("sessions.send", ["key": key, "message": text])
        let runId = payload["runId"] as? String ?? ""
        q.async { self.currentRunId = runId }
        Self.log.info("gateway send: key=\(key, privacy: .public) runId=\(runId, privacy: .public)")
        return runId
    }

    func close() {
        q.async {
            guard !self.isClosed else { return }
            self.isClosed = true
            self.connected = false
            self.task?.cancel(with: .goingAway, reason: nil)
            self.failAllPending(OpenClawGatewayError.notConnected)
        }
        forwarder?.stop()
        connection?.close()
        urlSession?.invalidateAndCancel()
    }

    deinit { close() }

    // MARK: - Token resolution

    /// Resolves the gateway auth token. Prefers an explicit override (tests),
    /// otherwise reads it from the VM's `~/.openclaw/openclaw.json` over SSH — the
    /// app already authenticates to the backend, so there's no separate token for
    /// the user to enter. NOTE: this is the daemon's real token (48-char), which
    /// differs from what `openclaw config get gateway.auth.token` returns (a
    /// rotated override layer); read the raw file, not the CLI.
    private func resolveToken() async throws -> String {
        if let override = gatewayTokenOverride, !override.isEmpty { return override }
        // base64-frame the file so arbitrary content can't break the channel.
        let cmd = "[ -e \"$HOME/.openclaw/openclaw.json\" ] && base64 \"$HOME/.openclaw/openclaw.json\" || true"
        let result = try await SSHSkill.shared.runCommand(cmd, on: sshConfig, timeout: 25)
        let cleaned = result.stdout
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let data = Data(base64Encoded: cleaned),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = root["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String, !token.isEmpty else {
            throw OpenClawGatewayError.handshakeFailed("couldn't read gateway.auth.token from the VM's ~/.openclaw/openclaw.json")
        }
        return token
    }

    // MARK: - Transport setup

    private func setupTransport() async throws {
        let conn = PersistentSSHConnection(config: sshConfig)
        let fwd = SSHTunnelForwarder(connection: conn, remotePort: remotePort)
        let localPort = try await fwd.start()
        self.connection = conn
        self.forwarder = fwd

        guard let url = URL(string: "ws://127.0.0.1:\(localPort)") else {
            throw OpenClawGatewayError.transport("bad local URL")
        }
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.urlSession = session
        self.task = task
        task.resume()
        receiveLoop()
        Self.log.info("gateway ws opening 127.0.0.1:\(localPort, privacy: .public) -> remote :\(self.remotePort, privacy: .public)")
    }

    // MARK: - Handshake

    /// Awaits the `connect.challenge`, replies with the signed `connect`, and
    /// resolves with the `hello-ok` payload.
    private func performConnect() async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            q.async { self.connectContinuation = OneShotContinuation(cont) }
        }
    }

    /// Builds + signs the `connect` request for the given challenge nonce and
    /// sends it. The signing token prefers a persisted device token (survives
    /// gateway-token rotation), falling back to the shared gateway token.
    private func sendConnect(nonce: String) {
        let useDevice = deviceToken != nil
        usedDeviceToken = useDevice
        let token = deviceToken ?? resolvedToken
        let signedAt = Int(Date().timeIntervalSince1970 * 1000)
        let payloadV3 = [
            "v3", identity.deviceId, clientId, clientMode, role,
            scopes.joined(separator: ","), String(signedAt), token, nonce,
            platform.lowercased(), deviceFamily.lowercased(),
        ].joined(separator: "|")
        let signature = identity.sign(payloadV3)

        let auth: [String: Any] = useDevice
            ? ["deviceToken": token]
            : ["token": token]

        let params: [String: Any] = [
            "minProtocol": 3, "maxProtocol": 3,
            "client": ["id": clientId, "version": "0.0.1", "platform": platform,
                       "mode": clientMode, "deviceFamily": deviceFamily],
            "role": role, "scopes": scopes,
            "caps": [String](), "commands": [String](), "permissions": [String: Any](),
            "auth": auth, "locale": "en-US", "userAgent": "openclaw-ios/0.0.1",
            "device": ["id": identity.deviceId, "publicKey": identity.publicKeyB64Url,
                       "signature": signature, "signedAt": signedAt, "nonce": nonce],
        ]
        sendString(["type": "req", "id": Self.connectReqId, "method": "connect", "params": params])
    }

    private func persistDeviceToken(from hello: [String: Any]) {
        guard let auth = hello["auth"] as? [String: Any],
              let token = auth["deviceToken"] as? String, !token.isEmpty else { return }
        q.async { self.deviceToken = token }
        UserDefaults.standard.set(token, forKey: "loop.openclaw.deviceToken.\(backendID)")
    }

    /// Forget the persisted device token (it was rejected — rotated/revoked) so the
    /// next connect falls back to the freshly re-read shared gateway token.
    private func clearDeviceToken() {
        deviceToken = nil
        UserDefaults.standard.removeObject(forKey: "loop.openclaw.deviceToken.\(backendID)")
    }

    /// Tear down the tunnel + WebSocket so a fresh `attemptConnect` can rebuild
    /// them (used between a failed and retried handshake).
    private func teardownTransport() {
        task?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        forwarder?.stop()
        connection?.close()
        task = nil; urlSession = nil; forwarder = nil; connection = nil
        q.sync {
            // Resume-then-clear so a continuation in flight when we tear down to
            // retry doesn't leak (the OneShot makes a later real resume a no-op).
            self.connectContinuation?.resume(throwing: OpenClawGatewayError.notConnected)
            self.connectContinuation = nil
            for (_, cont) in self.pending { cont.resume(throwing: OpenClawGatewayError.notConnected) }
            self.pending.removeAll()
            self.connected = false
        }
    }

    // MARK: - Request/response

    private func req(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            q.async {
                guard !self.isClosed else { cont.resume(throwing: OpenClawGatewayError.notConnected); return }
                self.reqCounter += 1
                let id = String(self.reqCounter)
                self.pending[id] = OneShotContinuation(cont)
                self.sendString(["type": "req", "id": id, "method": method, "params": params])
            }
        }
    }

    // MARK: - Wire I/O

    /// Encodes + sends a JSON frame. Must be safe to call from `q`.
    private func sendString(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(str)) { [weak self] err in
            if let err = err { self?.handleTransport(err) }
        }
    }

    private func receiveLoop() {
        let myTask = task
        myTask?.receive { [weak self] result in
            // Ignore callbacks from a torn-down socket (a reconnect/retry replaced
            // `task`), so a stale drop can't pollute the new connection's state.
            guard let self = self, self.task === myTask else { return }
            switch result {
            case .failure(let err):
                self.handleTransport(err)
            case .success(let message):
                switch message {
                case .string(let s): self.q.async { self.handleFrame(s) }
                case .data(let d): if let s = String(data: d, encoding: .utf8) { self.q.async { self.handleFrame(s) } }
                @unknown default: break
                }
                self.receiveLoop()
            }
        }
    }

    /// Handles one inbound JSON frame. Runs on `q`.
    private func handleFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String else { return }

        switch type {
        case "event":
            handleEvent(event: msg["event"] as? String ?? "", payload: msg["payload"] as? [String: Any] ?? [:])
        case "res":
            handleRes(msg)
        default:
            break
        }
    }

    private func handleRes(_ msg: [String: Any]) {
        let id = msg["id"] as? String ?? ""
        let ok = (msg["ok"] as? Bool) ?? false
        let payload = msg["payload"] as? [String: Any] ?? [:]
        let errText = describeError(msg["error"])

        if id == Self.connectReqId {
            let cont = connectContinuation
            connectContinuation = nil
            if ok { cont?.resume(returning: payload) }
            else { cont?.resume(throwing: OpenClawGatewayError.handshakeFailed(errText)) }
            return
        }
        guard let cont = pending.removeValue(forKey: id) else { return }
        if ok { cont.resume(returning: payload) }
        else { cont.resume(throwing: OpenClawGatewayError.requestFailed(errText)) }
    }

    private func handleEvent(event: String, payload: [String: Any]) {
        switch event {
        case "connect.challenge":
            guard let nonce = payload["nonce"] as? String else { return }
            sendConnect(nonce: nonce)
        case "agent":
            // Only surface events for the turn we initiated — the subscription also
            // carries turns from other sources (TUI, Telegram) on this session.
            guard let cur = currentRunId, (payload["runId"] as? String) == cur else { break }
            let stream = payload["stream"] as? String
            let dataObj = payload["data"] as? [String: Any] ?? [:]
            switch stream {
            case "assistant":
                // Cumulative reply text — replace semantics.
                if let text = dataObj["text"] as? String { onAssistantText?(text) }
            case "lifecycle":
                // TEMP(tooldiag): log lifecycle phases so we see the full frame set.
                Self.log.info("TOOLDIAG gw agent stream=lifecycle data=\(Self.dump(dataObj), privacy: .public)")
                if (dataObj["phase"] as? String) == "end" {
                    currentRunId = nil
                    onTurnComplete?()
                }
            default:
                // Tool-use frames arrive on a non-assistant stream. The exact
                // stream label varies by daemon build, so recognize them
                // structurally (a tool name + its input) rather than by a hard
                // -coded label; tool *results* are ignored — we surface only the
                // calls. The transcript backstop (parseSessionTranscript) is the
                // source of truth, so a missed frame here is corrected at finalize.
                // TEMP(tooldiag): log the full payload so we can learn the real
                // tool-event shape (stream label + data schema) from a live turn.
                Self.log.info("TOOLDIAG gw agent stream=\(stream ?? "nil", privacy: .public) data=\(Self.dump(dataObj), privacy: .public)")
                emitToolCallIfPresent(data: dataObj)
            }
        default:
            break
        }
    }

    /// Best-effort extraction of a `tool_use` call from an `agent` event's `data`,
    /// tolerant of where the block sits (top level / `block` / `content[]`) and of
    /// key spelling (`input`/`arguments`/`args`, `id`/`toolUseId`/`callId`). Emits
    /// `onToolCall` for each tool call found; ignores frames with no tool name and
    /// explicit tool-result blocks.
    private func emitToolCallIfPresent(data: [String: Any]) {
        let candidates: [[String: Any]]
        if let block = data["block"] as? [String: Any] {
            candidates = [block]
        } else if let blocks = data["content"] as? [[String: Any]] {
            candidates = blocks
        } else {
            candidates = [data]
        }
        for obj in candidates {
            if let type = obj["type"] as? String {
                // Skip non-tool blocks (text/thinking) and tool *results*.
                guard type == "tool_use" || (type.contains("tool") && !type.contains("result")) else { continue }
            }
            guard let name = (obj["name"] as? String) ?? (obj["toolName"] as? String) ?? (obj["tool"] as? String),
                  !name.isEmpty else { continue }
            let input = (obj["input"] as? [String: Any])
                ?? (obj["arguments"] as? [String: Any])
                ?? (obj["args"] as? [String: Any]) ?? [:]
            let callId = (obj["id"] as? String) ?? (obj["toolUseId"] as? String) ?? (obj["callId"] as? String)
            Self.log.info("TOOLDIAG emit tool name=\(name, privacy: .public) callId=\(callId ?? "nil", privacy: .public)")
            onToolCall?(name, callId, input)
        }
    }

    /// TEMP(tooldiag): compact JSON dump of a payload for logging.
    private static func dump(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "\(obj)" }
        return s
    }

    // MARK: - Errors

    private func handleTransport(_ error: Error) {
        q.async {
            guard !self.isClosed else { return }
            self.connected = false
            Self.log.error("gateway transport error: \(error.localizedDescription, privacy: .public)")
            self.failAllPending(OpenClawGatewayError.transport(error.localizedDescription))
            self.onError?(OpenClawGatewayError.transport(error.localizedDescription))
        }
    }

    private func failAllPending(_ error: Error) {
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
    }

    private func describeError(_ raw: Any?) -> String {
        guard let err = raw as? [String: Any] else { return "unknown" }
        if let msg = err["message"] as? String { return msg }
        if let code = err["code"] as? String { return code }
        return "unknown"
    }
}
