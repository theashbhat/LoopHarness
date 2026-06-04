//
//  PersistentSSHConnection.swift
//  Loop
//
//  A single, long-lived NIOSSH connection that vends multiple child channels
//  over one TCP + handshake + auth. Where `SSHSkill.runSSHCommand` opens a fresh
//  connection per command (the per-poll cost we're removing) and
//  `SSHTerminalSession` holds one connection for an interactive PTY, this holds
//  one connection that callers multiplex `direct-tcpip` forwarding channels over
//  — the basis for tunnelling the Loop Runner's loopback HTTP port to the device
//  (see `SSHTunnelForwarder` / `SSHTunnelManager`).
//
//  It deliberately imports only NIO/Foundation so it compiles in every target
//  that links NIOSSH, and reuses the same auth/host-key/key-parsing primitives
//  as `SSHSkill` and `SSHTerminalSession` (`parsePrivateKey`,
//  `SSHPrivateKeyAuthDelegate`, `SSHAcceptAllHostKeysDelegate`).
//
//  The owning `MultiThreadedEventLoopGroup` lives for the connection's lifetime
//  and is shut down only by `close()` — never per channel. Every child channel
//  (the forwarder's server channel, its accepted loopback sockets, and the SSH
//  direct-tcpip channels) runs on this one event loop, which keeps the
//  byte-pumping `GlueHandler` pair race-free.
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import os

final class PersistentSSHConnection {

    private static let log = Logger(subsystem: "com.bhat.intel", category: "PersistentSSH")

    let config: SSHConfig

    /// One event loop for the whole connection lifetime. Do NOT shut this down
    /// per channel — only `close()` tears it down.
    private let group: MultiThreadedEventLoopGroup

    private let lock = NSLock()
    private var channel: Channel?
    private var isConnected = false
    /// De-dupes concurrent `rootChannel()` callers so several runners on the same
    /// host share one handshake instead of racing to open parallel connections.
    private var connectTask: Task<Channel, Error>?

    init(config: SSHConfig) {
        self.config = config
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// The shared event-loop group. The tunnel forwarder binds its loopback
    /// listener on this so every channel stays on one loop.
    var eventLoopGroup: EventLoopGroup { group }

    /// True while the underlying TCP/SSH channel is live. Cheap, lock-guarded —
    /// reads a flag maintained by the connect/close paths rather than touching
    /// NIO state off the event loop.
    var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return isConnected
    }

    // MARK: - Connect

    /// Returns the live root channel, connecting (and authenticating) on first
    /// use or after a drop. Idempotent and safe to call concurrently.
    func rootChannel() async throws -> Channel {
        lock.lock()
        if let channel, isConnected {
            lock.unlock()
            return channel
        }
        if let task = connectTask {
            lock.unlock()
            return try await task.value
        }
        let task = Task { try await self.doConnect() }
        connectTask = task
        lock.unlock()

        do {
            let ch = try await task.value
            lock.lock()
            channel = ch
            isConnected = true
            connectTask = nil
            lock.unlock()
            return ch
        } catch {
            lock.lock()
            connectTask = nil
            isConnected = false
            lock.unlock()
            throw error
        }
    }

    /// Resolves the connection's `NIOSSHHandler` once the root channel is up.
    /// Callers open child channels through it.
    func sshHandler() async throws -> NIOSSHHandler {
        let ch = try await rootChannel()
        return try await ch.pipeline.handler(type: NIOSSHHandler.self).get()
    }

    private func doConnect() async throws -> Channel {
        let host = config.host
        let port = config.port == 0 ? 22 : config.port
        Self.log.info("connecting \(host, privacy: .public):\(port, privacy: .public) user=\(self.config.username, privacy: .public)")

        let nioKey = try SSHSkill.shared.parsePrivateKey(
            pem: config.privateKey, passphrase: config.passphrase)
        let username = config.username

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sshHandler = NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: SSHPrivateKeyAuthDelegate(
                                username: username, privateKey: nioKey),
                            serverAuthDelegate: SSHAcceptAllHostKeysDelegate())),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .connectTimeout(.seconds(15))

        let channel = try await bootstrap.connect(host: host, port: port).get()
        // Wait until the SSH handler is in the pipeline so child-channel creation
        // can proceed. Auth completes asynchronously after this; the first real
        // request through the tunnel (the health probe) is the readiness gate.
        _ = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()

        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.isConnected = false
            if self.channel === channel { self.channel = nil }
            self.lock.unlock()
            Self.log.info("connection closed \(host, privacy: .public):\(port, privacy: .public)")
        }
        Self.log.info("connected \(host, privacy: .public):\(port, privacy: .public)")
        return channel
    }

    // MARK: - Teardown

    /// Closes the connection and shuts down its event-loop group. The instance
    /// must not be reused after this.
    func close() {
        lock.lock()
        let ch = channel
        channel = nil
        isConnected = false
        connectTask?.cancel()
        connectTask = nil
        lock.unlock()

        ch?.close(promise: nil)
        group.shutdownGracefully { _ in }
    }
}
