//
//  SSHTunnelForwarder.swift
//  Loop
//
//  Bridges a loopback TCP port on the device to a `direct-tcpip` channel on a
//  `PersistentSSHConnection`, so URLSession can hit `http://127.0.0.1:<localPort>`
//  and have the bytes forwarded to `127.0.0.1:<remotePort>` on the SSH host —
//  where the Go Loop Runner listens. This replaces the `curl`-over-SSH-exec hack
//  in `LoopRunnerSSHClient`: loopback HTTP is ATS-exempt, so the existing
//  `LoopRunnerClient` (URLSession, SSE-capable) works unchanged once pointed at
//  the local port, and the per-poll SSH handshake disappears.
//
//  The bridge is the canonical SwiftNIO port-forwarding pattern: a
//  `ServerBootstrap` whose accepted connections each open a `direct-tcpip` SSH
//  child channel, paired by two `GlueHandler`s. `GlueHandler` and the SSH
//  data wrapper are copied (and namespaced) from the upstream `NIOSSHClient`
//  example. Everything runs on the connection's single event loop, so the glue
//  pair never crosses threads.
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import os

final class SSHTunnelForwarder {

    private static let log = Logger(subsystem: "com.bhat.intel", category: "SSHTunnel")

    private let connection: PersistentSSHConnection
    private let remotePort: Int

    private let lock = NSLock()
    private var serverChannel: Channel?
    private(set) var localPort: Int?

    init(connection: PersistentSSHConnection, remotePort: Int) {
        self.connection = connection
        self.remotePort = remotePort
    }

    /// Binds a loopback listener on an ephemeral port and returns it. Each
    /// accepted connection is bridged to a fresh `direct-tcpip` channel to
    /// `127.0.0.1:<remotePort>` on the SSH host.
    func start() async throws -> Int {
        // Capture the live root channel; we resolve the SSH handler inside the
        // child initializer (on the same single event loop) to avoid capturing a
        // non-Sendable handler across the bootstrap closure.
        let rootChannel = try await connection.rootChannel()
        let remotePort = self.remotePort

        let server = try await ServerBootstrap(group: connection.eventLoopGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { inbound in
                Self.bridge(inbound: inbound, rootChannel: rootChannel, remotePort: remotePort)
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        guard let port = server.localAddress?.port else {
            try? await server.close()
            throw TunnelError.noLocalPort
        }

        lock.lock()
        serverChannel = server
        localPort = port
        lock.unlock()

        Self.log.info("forwarder up 127.0.0.1:\(port, privacy: .public) -> remote 127.0.0.1:\(remotePort, privacy: .public)")
        return port
    }

    func stop() {
        lock.lock()
        let server = serverChannel
        serverChannel = nil
        localPort = nil
        lock.unlock()
        server?.close(promise: nil)
    }

    /// Wires an accepted loopback channel to a new `direct-tcpip` SSH channel.
    /// Returning the combined future from the child initializer keeps the inbound
    /// channel from reading until both glue handlers are installed.
    private static func bridge(inbound: Channel,
                               rootChannel: Channel,
                               remotePort: Int) -> EventLoopFuture<Void> {
        rootChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler -> EventLoopFuture<Void> in
            let origin: SocketAddress
            if let remote = inbound.remoteAddress {
                origin = remote
            } else if let fallback = try? SocketAddress(ipAddress: "127.0.0.1", port: 0) {
                origin = fallback
            } else {
                return inbound.eventLoop.makeFailedFuture(TunnelError.noOriginatorAddress)
            }

            let directTCPIP = SSHChannelType.DirectTCPIP(
                targetHost: "127.0.0.1",
                targetPort: remotePort,
                originatorAddress: origin)

            let promise = inbound.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise, channelType: .directTCPIP(directTCPIP)) { childChannel, channelType in
                guard case .directTCPIP = channelType else {
                    return childChannel.eventLoop.makeFailedFuture(TunnelError.invalidChannelType)
                }
                return childChannel.eventLoop.makeCompletedFuture {
                    let (ours, theirs) = TunnelGlueHandler.matchedPair()
                    let childSync = childChannel.pipeline.syncOperations
                    try childSync.addHandler(TunnelSSHWrapperHandler())
                    try childSync.addHandler(ours)
                    let inboundSync = inbound.pipeline.syncOperations
                    try inboundSync.addHandler(theirs)
                }
            }
            return promise.futureResult.map { _ in }
        }
    }
}

// MARK: - Errors

enum TunnelError: LocalizedError {
    case invalidChannelType
    case invalidData
    case noLocalPort
    case noOriginatorAddress
    case healthCheckFailed

    var errorDescription: String? {
        switch self {
        case .invalidChannelType: return "Unexpected SSH channel type for tunnel."
        case .invalidData: return "Invalid data on tunnel channel."
        case .noLocalPort: return "Tunnel listener did not report a local port."
        case .noOriginatorAddress: return "Could not derive an originator address for the tunnel."
        case .healthCheckFailed: return "Tunnel health check failed."
        }
    }
}

// MARK: - Glue (copied from swift-nio-ssh NIOSSHClient example, namespaced)

/// Pumps bytes between two channels with proper backpressure. One instance sits
/// in each channel's pipeline; the pair is created via `matchedPair()`.
private final class TunnelGlueHandler {
    private var partner: TunnelGlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (TunnelGlueHandler, TunnelGlueHandler) {
        let first = TunnelGlueHandler()
        let second = TunnelGlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
    private func partnerCloseFull() { context?.close(promise: nil) }
    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }
}

extension TunnelGlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerCloseFull()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

/// Wraps/unwraps raw `ByteBuffer`s into `SSHChannelData` for the SSH side of the
/// bridge so the glue handler can treat both channels as plain byte streams.
private final class TunnelSSHWrapperHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .channel = data.type, case .byteBuffer(let buffer) = data.data else {
            context.fireErrorCaught(TunnelError.invalidData)
            return
        }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.write(wrapOutboundOut(wrapped), promise: promise)
    }
}
