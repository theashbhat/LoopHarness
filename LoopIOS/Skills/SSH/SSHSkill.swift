//
//  SSHSkill.swift
//  Loop
//
//  Exposes an `ssh_client` tool that reads the persisted SSH configuration
//  from SSHConfigStore and executes a shell command over SSH, returning
//  stdout, stderr, and exit code. Uses NIOSSH (Apple's SwiftNIO SSH) for
//  the underlying connection.
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Crypto
import os

/// Diagnostic logger for the SSH connection path. View in Console.app or the
/// Xcode console by filtering on subsystem `com.bhat.intel`, category `SSH`.
let sshLog = Logger(subsystem: "com.bhat.intel", category: "SSH")

final class SSHSkill {

    static let shared = SSHSkill()
    private init() {}

    // MARK: - System prompt fragment

    static let systemPromptFragment: String = """
    You can execute shell commands on a remote server via SSH:
    - ssh_client: run a command over SSH on the host configured in Settings → SSH.
      Pass `command` (string, the shell command to execute). Optionally pass
      `timeout` (seconds, default 30). Returns stdout, stderr, and exit_code.
      If no SSH configuration is saved, the tool returns an error asking the
      user to configure it in Settings.
    """

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "ssh_client",
                "description": "Execute a shell command on the remote SSH host configured in Settings → SSH. Returns stdout, stderr, and exit_code.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "command": [
                            "type": "string",
                            "description": "The shell command to execute on the remote host."
                        ],
                        "timeout": [
                            "type": "number",
                            "description": "Optional timeout in seconds (default 30)."
                        ]
                    ],
                    "required": ["command"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = ["ssh_client"]

    func handles(functionName: String) -> Bool {
        SSHSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        guard call.name == "ssh_client" else { return nil }
        if let cmd = call.arguments["command"] as? String {
            let short = cmd.prefix(40)
            return "running via SSH: \(short)\(cmd.count > 40 ? "…" : "")"
        }
        return "running SSH command"
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        guard functionCall.name == "ssh_client" else {
            completion(Self.result(name: functionCall.name,
                                   payload: ["status": "error", "error": "Unknown SSH tool \(functionCall.name)"]))
            return
        }
        execute(args: functionCall.arguments, completion: completion)
    }

    // MARK: - Execution

    private func execute(args: [String: Any],
                         completion: @escaping (MessageStruct) -> Void) {

        let config = SSHConfigStore.shared.config
        guard config.isConfigured else {
            completion(Self.result(name: "ssh_client", payload: [
                "status": "error",
                "error": "SSH is not configured. Please set host, username, and private key in Settings → SSH."
            ]))
            return
        }

        guard let command = args["command"] as? String, !command.isEmpty else {
            completion(Self.result(name: "ssh_client", payload: [
                "status": "error",
                "error": "The `command` argument is required."
            ]))
            return
        }

        let timeout = (args["timeout"] as? NSNumber)?.doubleValue ?? 30.0

        Task {
            do {
                let result = try await self.runSSHCommand(
                    host: config.host,
                    port: config.port,
                    username: config.username,
                    privateKey: config.privateKey,
                    passphrase: config.passphrase,
                    command: command,
                    timeout: timeout
                )
                completion(Self.result(name: "ssh_client", payload: [
                    "status": "ok",
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                    "exit_code": result.exitCode
                ]))
            } catch {
                completion(Self.result(name: "ssh_client", payload: [
                    "status": "error",
                    "error": error.localizedDescription
                ]))
            }
        }
    }

    // MARK: - Connection test

    /// Verifies that the currently saved SSH configuration can connect and
    /// authenticate. Runs a trivial no-op command; throws if the connection,
    /// authentication, or key parsing fails. Returns normally on success.
    func testConnection(timeout: Double = 12) async throws {
        try await testConnection(SSHConfigStore.shared.config, timeout: timeout)
    }

    /// Verifies a specific configuration (used by the connection editor, which
    /// tests the connection being edited rather than the saved default).
    func testConnection(_ config: SSHConfig, timeout: Double = 12) async throws {
        guard config.isConfigured else {
            throw SSHSkillError.connectionFailed("Host, username, and private key are required.")
        }
        _ = try await runSSHCommand(
            host: config.host,
            port: config.port,
            username: config.username,
            privateKey: config.privateKey,
            passphrase: config.passphrase,
            command: "true",
            timeout: timeout
        )
    }

    // MARK: - Reusable command execution

    /// Runs a shell command on the host configured in Settings → SSH and
    /// returns its stdout/stderr/exit code. Shared entry point for callers
    /// outside the agent tool path (e.g. the Loop Runner SSH transport).
    /// Throws if SSH isn't configured or the connection fails.
    func runCommand(_ command: String, timeout: Double = 30) async throws -> CommandResult {
        let config = SSHConfigStore.shared.config
        guard config.isConfigured else {
            throw SSHSkillError.connectionFailed(
                "SSH is not configured. Set host, username, and private key in Settings → SSH.")
        }
        return try await runCommand(command, on: config, timeout: timeout)
    }

    /// Runs a shell command against an explicitly provided SSH configuration
    /// rather than the saved default. Used by backends that connect to their
    /// own host — e.g. the OpenClaw VM conversation store, which talks to the
    /// endpoint in `OpenClawConfigStore`, not Settings → SSH.
    func runCommand(_ command: String, on config: SSHConfig, timeout: Double = 30) async throws -> CommandResult {
        guard config.isConfigured else {
            throw SSHSkillError.connectionFailed(
                "SSH is not configured. Host, username, and private key are required.")
        }
        return try await runSSHCommand(
            host: config.host,
            port: config.port,
            username: config.username,
            privateKey: config.privateKey,
            passphrase: config.passphrase,
            command: command,
            timeout: timeout
        )
    }

    // MARK: - NIOSSH connection

    struct CommandResult {
        let stdout: String
        let stderr: String
        let exitCode: Int
    }

    private func runSSHCommand(host: String,
                               port: Int,
                               username: String,
                               privateKey: String,
                               passphrase: String,
                               command: String,
                               timeout: Double) async throws -> CommandResult {

        sshLog.info("connect start host=\(host, privacy: .public):\(port, privacy: .public) user=\(username, privacy: .public) cmd=\(command, privacy: .public) timeout=\(timeout, privacy: .public)")

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let nioKey: NIOSSHPrivateKey
        do {
            nioKey = try parsePrivateKey(pem: privateKey, passphrase: passphrase)
            sshLog.info("private key parsed OK")
        } catch {
            sshLog.error("private key parse FAILED: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: SSHPrivateKeyAuthDelegate(
                                    username: username,
                                    privateKey: nioKey
                                ),
                                serverAuthDelegate: SSHAcceptAllHostKeysDelegate()
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                ])
            }
            .connectTimeout(.seconds(Int64(min(timeout, 10))))

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
            sshLog.info("TCP connected; awaiting SSH handshake")
        } catch {
            sshLog.error("TCP connect FAILED: \(error.localizedDescription, privacy: .public)")
            throw SSHSkillError.connectionFailed(error.localizedDescription)
        }

        let result: CommandResult = try await withCheckedThrowingContinuation { continuation in
            // Four sites can resolve this continuation — output completion,
            // createChannel failure, handshake failure, and the watchdog — and
            // they are NOT mutually exclusive (e.g. the watchdog fires, then its
            // channel.close() triggers channelInactive → collector.complete()).
            // Route every resume through one single-shot gate so the second
            // attempt is a no-op instead of crashing with "resume continuation
            // more than once". All sites run on the single NIO event-loop
            // thread, so a plain flag in the gate is race-free.
            let gate = SingleResume(continuation)

            channel.pipeline.handler(type: NIOSSHHandler.self).whenSuccess { sshHandler in
                sshLog.info("SSH handler ready; creating session channel")
                let promise = channel.eventLoop.makePromise(of: Channel.self)

                sshHandler.createChannel(promise, channelType: .session) { childChannel, channelType in
                    guard case .session = channelType else {
                        return childChannel.eventLoop.makeFailedFuture(SSHSkillError.unexpectedChannelType)
                    }
                    sshLog.info("session channel created; attaching exec handler")
                    let collector = SSHOutputCollector(gate: gate)
                    return childChannel.pipeline.addHandlers([
                        SSHExecHandler(command: command, collector: collector)
                    ])
                }

                promise.futureResult.whenFailure { error in
                    sshLog.error("createChannel FAILED: \(error.localizedDescription, privacy: .public)")
                    gate.resume(throwing: error)
                }
            }

            channel.pipeline.handler(type: NIOSSHHandler.self).whenFailure { error in
                sshLog.error("SSH handshake FAILED: \(error.localizedDescription, privacy: .public)")
                gate.resume(throwing: error)
            }

            // Timeout watchdog
            channel.eventLoop.scheduleTask(in: .seconds(Int64(timeout))) {
                sshLog.error("watchdog fired after \(timeout, privacy: .public)s — no result; timing out")
                gate.resume(throwing: SSHSkillError.timeout)
                channel.close(promise: nil)
            }
        }

        sshLog.info("command complete exit=\(result.exitCode, privacy: .public) stdout=\(result.stdout.count, privacy: .public)B stderr=\(result.stderr.count, privacy: .public)B")
        try? await channel.close()
        return result
    }

    // MARK: - Key parsing

    /// Parses a private key in any of the formats users commonly paste in:
    ///   • OpenSSH format (`-----BEGIN OPENSSH PRIVATE KEY-----`), ed25519 + ECDSA
    ///   • SEC1 (`-----BEGIN EC PRIVATE KEY-----`), named or explicit curve params
    ///   • PKCS#8 (`-----BEGIN PRIVATE KEY-----`), ed25519 + ECDSA
    ///   • raw base64 ed25519 seed
    /// For EC keys the curve is inferred from the private-scalar length, so the
    /// curve-parameter encoding (named vs. explicit) doesn't matter.
    ///
    /// Internal (not private) so the interactive terminal transport
    /// (`SSHTerminalSession`) can build a `NIOSSHPrivateKey` from the same
    /// saved configuration without duplicating the parsing logic.
    func parsePrivateKey(pem: String, passphrase: String) throws -> NIOSSHPrivateKey {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)

        // OpenSSH format has a distinctive header and a non-DER body.
        if trimmed.contains("OPENSSH PRIVATE KEY") {
            return try parseOpenSSHKey(pem: trimmed)
        }

        if trimmed.contains("ENCRYPTED") {
            throw SSHSkillError.connectionFailed(
                "Encrypted PEM keys aren't supported. Re-export the key without a passphrase.")
        }

        // Fast path: swift-crypto's native PEM parser (named-curve PKCS#8/SEC1).
        if let p256 = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) {
            return NIOSSHPrivateKey(p256Key: p256)
        }
        if let p384 = try? P384.Signing.PrivateKey(pemRepresentation: trimmed) {
            return NIOSSHPrivateKey(p384Key: p384)
        }
        if let p521 = try? P521.Signing.PrivateKey(pemRepresentation: trimmed) {
            return NIOSSHPrivateKey(p521Key: p521)
        }

        // Generic DER parse: handles SEC1 (incl. explicit params) and PKCS#8.
        let body = Self.stripPEMHeaders(trimmed)
        if let der = Data(base64Encoded: body) {
            if let key = try? parseDERPrivateKey(Array(der)) {
                return key
            }
            // Raw ed25519 seed (32) or seed||pub (64) pasted as plain base64.
            if der.count == 32 {
                return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: der))
            }
            if der.count == 64 {
                return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: der.prefix(32)))
            }
        }

        throw SSHSkillError.unsupportedKeyFormat
    }

    // MARK: DER (SEC1 / PKCS#8)

    private static let oidECPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01] // 1.2.840.10045.2.1
    private static let oidEd25519: [UInt8] = [0x2B, 0x65, 0x70]                              // 1.3.101.112

    private func parseDERPrivateKey(_ der: [UInt8]) throws -> NIOSSHPrivateKey {
        var top = DERReader(der)
        let seq = try top.readTLV()
        guard seq.tag == 0x30 else { throw SSHSkillError.unsupportedKeyFormat }

        var body = DERReader(seq.value)
        let version = try body.readTLV()
        guard version.tag == 0x02, let v = version.value.last else { throw SSHSkillError.unsupportedKeyFormat }

        switch v {
        case 1:
            // SEC1 ECPrivateKey: version, privateKey OCTET STRING, [0] params, [1] pubkey
            let scalar = try body.readTLV()
            guard scalar.tag == 0x04 else { throw SSHSkillError.unsupportedKeyFormat }
            return try Self.ecKey(fromScalar: scalar.value)

        case 0:
            // PKCS#8 PrivateKeyInfo: version, AlgorithmIdentifier, privateKey OCTET STRING
            let alg = try body.readTLV()
            guard alg.tag == 0x30 else { throw SSHSkillError.unsupportedKeyFormat }
            var algReader = DERReader(alg.value)
            let oid = try algReader.readTLV()
            guard oid.tag == 0x06 else { throw SSHSkillError.unsupportedKeyFormat }

            let priv = try body.readTLV()
            guard priv.tag == 0x04 else { throw SSHSkillError.unsupportedKeyFormat }

            if oid.value == Self.oidEd25519 {
                // Inner OCTET STRING wraps the 32-byte seed.
                var inner = DERReader(priv.value)
                let seed = try inner.readTLV()
                guard seed.tag == 0x04 else { throw SSHSkillError.unsupportedKeyFormat }
                return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed.value)))
            }
            if oid.value == Self.oidECPublicKey {
                // Inner content is a SEC1 ECPrivateKey.
                return try parseDERPrivateKey(priv.value)
            }
            throw SSHSkillError.unsupportedKeyFormat

        default:
            throw SSHSkillError.unsupportedKeyFormat
        }
    }

    /// Builds an EC key, choosing the curve from the scalar length (32→P-256,
    /// 48→P-384, 66→P-521) after normalizing leading-zero padding.
    private static func ecKey(fromScalar raw: [UInt8]) throws -> NIOSSHPrivateKey {
        let scalar = normalizeScalar(raw)
        switch scalar.count {
        case 32: return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: Data(scalar)))
        case 48: return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: Data(scalar)))
        case 66: return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: Data(scalar)))
        default: throw SSHSkillError.unsupportedKeyFormat
        }
    }

    /// Strips leading zero bytes, then left-pads to the nearest valid EC scalar
    /// length. Handles SSH mpint padding and short scalars.
    private static func normalizeScalar(_ raw: [UInt8]) -> [UInt8] {
        var b = raw
        while b.count > 1 && b.first == 0 { b.removeFirst() }
        for size in [32, 48, 66] where b.count <= size {
            return b.count == size ? b : Array(repeating: 0, count: size - b.count) + b
        }
        return b
    }

    // MARK: OpenSSH format

    private func parseOpenSSHKey(pem: String) throws -> NIOSSHPrivateKey {
        guard let data = Data(base64Encoded: Self.stripPEMHeaders(pem)) else {
            throw SSHSkillError.unsupportedKeyFormat
        }
        var r = SSHBufReader(Array(data))

        let magic = Array("openssh-key-v1\0".utf8)
        guard let read = r.readBytes(magic.count), read == magic else {
            throw SSHSkillError.unsupportedKeyFormat
        }

        let cipher = try r.readString()      // ciphername
        _ = try r.readString()               // kdfname
        _ = try r.readString()               // kdfoptions
        guard String(decoding: cipher, as: UTF8.self) == "none" else {
            throw SSHSkillError.connectionFailed(
                "Encrypted OpenSSH keys aren't supported yet. Remove the passphrase with `ssh-keygen -p -f <key>` (empty passphrase) or paste a PEM key.")
        }

        guard try r.readUInt32() == 1 else { throw SSHSkillError.unsupportedKeyFormat }
        _ = try r.readString()               // public key blob

        var priv = SSHBufReader(try r.readString())
        _ = try priv.readUInt32()            // check int 1
        _ = try priv.readUInt32()            // check int 2
        let keyType = String(decoding: try priv.readString(), as: UTF8.self)

        switch keyType {
        case "ssh-ed25519":
            _ = try priv.readString()        // public key (32 bytes)
            let secret = try priv.readString() // 64 bytes: seed || public
            guard secret.count >= 32 else { throw SSHSkillError.unsupportedKeyFormat }
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: Data(secret.prefix(32))))

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try priv.readString()        // curve name
            _ = try priv.readString()        // public point Q
            let scalar = try priv.readString() // private scalar (mpint)
            return try Self.ecKey(fromScalar: scalar)

        default:
            throw SSHSkillError.connectionFailed("Unsupported OpenSSH key type: \(keyType)")
        }
    }

    private static func stripPEMHeaders(_ pem: String) -> String {
        pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
    }

    // MARK: - Result helper

    static func result(name: String, payload: [String: Any]) -> MessageStruct {
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return MessageStruct(role: "function", content: json, name: name)
    }
}

// MARK: - Binary readers

/// Minimal DER (ASN.1) tag-length-value reader.
private struct DERReader {
    private let bytes: [UInt8]
    private var idx = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func readTLV() throws -> (tag: UInt8, value: [UInt8]) {
        guard idx < bytes.count else { throw SSHSkillError.unsupportedKeyFormat }
        let tag = bytes[idx]; idx += 1
        let length = try readLength()
        guard idx + length <= bytes.count else { throw SSHSkillError.unsupportedKeyFormat }
        let value = Array(bytes[idx..<idx + length]); idx += length
        return (tag, value)
    }

    private mutating func readLength() throws -> Int {
        guard idx < bytes.count else { throw SSHSkillError.unsupportedKeyFormat }
        let first = bytes[idx]; idx += 1
        if first & 0x80 == 0 { return Int(first) }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 4, idx + count <= bytes.count else { throw SSHSkillError.unsupportedKeyFormat }
        var length = 0
        for _ in 0..<count { length = (length << 8) | Int(bytes[idx]); idx += 1 }
        return length
    }
}

/// Reader for the SSH wire format (uint32-length-prefixed strings), used by
/// the OpenSSH private-key container.
private struct SSHBufReader {
    private let bytes: [UInt8]
    private var idx = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func readUInt32() throws -> UInt32 {
        guard idx + 4 <= bytes.count else { throw SSHSkillError.unsupportedKeyFormat }
        let value = (UInt32(bytes[idx]) << 24) | (UInt32(bytes[idx + 1]) << 16)
            | (UInt32(bytes[idx + 2]) << 8) | UInt32(bytes[idx + 3])
        idx += 4
        return value
    }

    mutating func readBytes(_ count: Int) -> [UInt8]? {
        guard idx + count <= bytes.count else { return nil }
        let value = Array(bytes[idx..<idx + count]); idx += count
        return value
    }

    mutating func readString() throws -> [UInt8] {
        let length = Int(try readUInt32())
        guard let value = readBytes(length) else { throw SSHSkillError.unsupportedKeyFormat }
        return value
    }
}

// MARK: - Errors

enum SSHSkillError: LocalizedError {
    case timeout
    case unsupportedKeyFormat
    case unexpectedChannelType
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "SSH command timed out."
        case .unsupportedKeyFormat:
            return "Unsupported private key format. Please use an Ed25519 or ECDSA (P-256/P-384/P-521) key in PEM format."
        case .unexpectedChannelType:
            return "Unexpected SSH channel type."
        case .connectionFailed(let msg):
            return "SSH connection failed: \(msg)"
        }
    }
}

// MARK: - NIOSSH delegates

// Internal (not file-private): reused by the interactive terminal transport
// in SSHTerminalSession.swift, which performs the same public-key auth.
final class SSHPrivateKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if availableMethods.contains(.publicKey) {
            sshLog.info("auth: offering publickey for user=\(self.username, privacy: .public)")
            nextChallengePromise.succeed(.init(
                username: username,
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: privateKey))
            ))
        } else {
            sshLog.error("auth: server does not offer publickey method; giving up")
            nextChallengePromise.succeed(nil)
        }
    }
}

final class SSHAcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        sshLog.info("hostkey: accepting (no verification)")
        validationCompletePromise.succeed(())
    }
}

// MARK: - Channel handler

/// Combined exec + output collection handler. Sends the exec request on
/// channelActive, collects stdout/stderr, and resolves the continuation
/// on channel close or exit status.
private final class SSHExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    // Strong reference: the collector has no other owner once the channel
    // setup closure returns. Holding it `weak` would deallocate it immediately,
    // so `complete()` would never resume the continuation and every command
    // would hang until the watchdog timeout. There is no retain cycle — the
    // collector does not reference this handler.
    private let collector: SSHOutputCollector

    init(command: String, collector: SSHOutputCollector) {
        self.command = command
        self.collector = collector
    }

    func channelActive(context: ChannelHandlerContext) {
        sshLog.info("exec: channel active; sending exec request")
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(execRequest, promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = channelData.data else { return }

        switch channelData.type {
        case .channel:
            collector.appendStdout(bytes)
        case .stdErr:
            collector.appendStderr(bytes)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            sshLog.info("exec: received exit status \(status.exitStatus, privacy: .public)")
            collector.setExitCode(status.exitStatus)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        sshLog.info("exec: channel inactive")
        collector.complete()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        collector.complete()
    }
}

/// Single-shot gate around a `CheckedContinuation`. Several independent
/// callbacks (output completion, channel/handshake failure, watchdog timeout)
/// may try to resolve the same continuation; only the first wins, the rest are
/// silently dropped. All callers run on the one NIO event-loop thread, so the
/// `continuation = nil` guard needs no locking.
private final class SingleResume {
    private var continuation: CheckedContinuation<SSHSkill.CommandResult, Error>?

    init(_ continuation: CheckedContinuation<SSHSkill.CommandResult, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: SSHSkill.CommandResult) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Collects output from the SSH exec channel and resolves the async
/// continuation (via the shared single-shot gate) when complete.
private final class SSHOutputCollector {
    private var stdoutData = Data()
    private var stderrData = Data()
    private var exitCode: Int?
    private let gate: SingleResume
    private var completed = false

    init(gate: SingleResume) {
        self.gate = gate
    }

    func appendStdout(_ buffer: ByteBuffer) {
        var buf = buffer
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            stdoutData.append(contentsOf: bytes)
        }
    }

    func appendStderr(_ buffer: ByteBuffer) {
        var buf = buffer
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            stderrData.append(contentsOf: bytes)
        }
    }

    func setExitCode(_ code: Int) {
        exitCode = code
    }

    func complete() {
        guard !completed else { return }
        completed = true
        let result = SSHSkill.CommandResult(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: exitCode ?? -1
        )
        gate.resume(returning: result)
    }
}
