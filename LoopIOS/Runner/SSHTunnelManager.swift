//
//  SSHTunnelManager.swift
//  Loop
//
//  Central owner of persistent SSH connections and their loopback tunnels.
//  Multiple Loop Runners on the same VM share ONE `PersistentSSHConnection`
//  (keyed by user@host:port), with one `SSHTunnelForwarder` per remote port.
//
//  `tunneledBaseURL(remotePort:)` is the entry point the poller uses: it ensures
//  the connection + forwarder are up, verifies the path with a one-time loopback
//  health probe, and returns `http://127.0.0.1:<localPort>` for the existing
//  `LoopRunnerClient` to hit. On any failure it returns nil so the caller can
//  fall back to the `curl`-over-SSH-exec transport (`LoopRunnerSSHClient`).
//
//  SSH-backed runners connect to the default Settings → SSH connection (the same
//  host `LoopRunnerSSHClient` → `SSHSkill.runCommand` already uses), so the
//  manager reads `SSHConfigStore.shared.config`.
//

import Foundation
import os

// MARK: - Connection state

/// Coarse tunnel state for the SSH host, surfaced to the UI so it can show a
/// connecting / connected / failed indicator.
enum TunnelConnectionState: Equatable {
    case connecting
    case connected
    /// Tunnel unavailable; running on the SSH-exec fallback. Carries a short reason.
    case failed(String)
}

extension Notification.Name {
    /// Posted when the tunnel connection state changes. `userInfo["state"]` holds
    /// a `TunnelConnectionState`.
    static let tunnelConnectionStateChanged = Notification.Name("loop.tunnel.connectionStateChanged")
}

final class SSHTunnelManager {

    static let shared = SSHTunnelManager()

    private static let log = Logger(subsystem: "com.bhat.intel", category: "SSHTunnelManager")

    /// Backoff schedule for repeated setup failures, so a VM that rejects
    /// forwarding (e.g. `AllowTcpForwarding no`) isn't probed every poll — we
    /// fall straight to the SSH-exec transport until the cooldown elapses.
    private static let backoffSchedule: [TimeInterval] = [2, 5, 15, 30, 60]

    private let lock = NSLock()
    private var connections: [String: PersistentSSHConnection] = [:]   // host key
    private var forwarders: [String: SSHTunnelForwarder] = [:]         // host key + "#" + remote port
    /// Serializes setup per forwarder key so concurrent polls don't open
    /// duplicate listeners for the same runner.
    private var setupTasks: [String: Task<Int, Error>] = [:]
    /// Per-forwarder consecutive-failure count and the time before which we
    /// won't retry setup.
    private var failureCount: [String: Int] = [:]
    private var retryAfter: [String: Date] = [:]
    /// Last state broadcast, to avoid posting duplicate notifications.
    private var lastState: TunnelConnectionState?

    private init() {}

    private func postState(_ state: TunnelConnectionState) {
        lock.lock()
        let changed = lastState != state
        lastState = state
        lock.unlock()
        guard changed else { return }
        NotificationCenter.default.post(
            name: .tunnelConnectionStateChanged, object: nil, userInfo: ["state": state])
    }

    // MARK: - Public API

    /// Returns the loopback base URL for a runner reachable on
    /// `127.0.0.1:<remotePort>` on the SSH host, or nil if the tunnel can't be
    /// established (caller falls back to the SSH-exec transport).
    func tunneledBaseURL(remotePort: Int) async -> URL? {
        let config = SSHConfigStore.shared.config
        guard config.isConfigured else { return nil }
        do {
            let port = try await localPort(config: config, remotePort: remotePort)
            return URL(string: "http://127.0.0.1:\(port)")
        } catch {
            Self.log.error("tunnel setup failed (remote \(remotePort, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Tears down all connections and forwarders. Called when the app backgrounds
    /// (the connection won't survive suspension) and rebuilt lazily on the next
    /// foreground poll.
    func closeAll() {
        lock.lock()
        let conns = connections.values
        let fwds = forwarders.values
        connections.removeAll()
        forwarders.removeAll()
        setupTasks.values.forEach { $0.cancel() }
        setupTasks.removeAll()
        failureCount.removeAll()
        retryAfter.removeAll()
        lastState = nil
        lock.unlock()

        fwds.forEach { $0.stop() }
        conns.forEach { $0.close() }
        Self.log.info("closed all tunnels")
    }

    // MARK: - Setup

    private func hostKey(_ c: SSHConfig) -> String {
        "\(c.username)@\(c.host):\(c.port == 0 ? 22 : c.port)"
    }

    private func localPort(config: SSHConfig, remotePort: Int) async throws -> Int {
        let hk = hostKey(config)
        let fk = "\(hk)#\(remotePort)"

        lock.lock()
        let existingFwd = forwarders[fk]
        let existingConn = connections[hk]
        if let fwd = existingFwd, let lp = fwd.localPort,
           let conn = existingConn, conn.isAlive {
            lock.unlock()
            return lp
        }
        if let task = setupTasks[fk] {
            lock.unlock()
            return try await task.value
        }
        // Respect the failure cooldown — skip the expensive connect+probe and let
        // the caller fall back to SSH-exec until it elapses.
        if let until = retryAfter[fk], until > Date() {
            lock.unlock()
            throw TunnelError.healthCheckFailed
        }
        let task = Task { try await self.establish(config: config, hostKey: hk, forwarderKey: fk, remotePort: remotePort) }
        setupTasks[fk] = task
        lock.unlock()

        postState(.connecting)

        defer {
            lock.lock()
            setupTasks[fk] = nil
            lock.unlock()
        }
        do {
            let port = try await task.value
            lock.lock()
            failureCount[fk] = nil
            retryAfter[fk] = nil
            lock.unlock()
            postState(.connected)
            return port
        } catch {
            lock.lock()
            let count = (failureCount[fk] ?? 0)
            failureCount[fk] = count + 1
            let delay = Self.backoffSchedule[min(count, Self.backoffSchedule.count - 1)]
            retryAfter[fk] = Date().addingTimeInterval(delay)
            lock.unlock()
            postState(.failed(error.localizedDescription))
            throw error
        }
    }

    private func establish(config: SSHConfig, hostKey hk: String, forwarderKey fk: String, remotePort: Int) async throws -> Int {
        // Reuse a live connection for this host, or stand up a fresh one.
        lock.lock()
        var connection = connections[hk]
        if let conn = connection, !conn.isAlive {
            // Stale — drop it and any forwarders that depended on it.
            conn.close()
            connections[hk] = nil
            forwarders = forwarders.filter { !$0.key.hasPrefix("\(hk)#") }
            connection = nil
        }
        if connection == nil {
            connection = PersistentSSHConnection(config: config)
            connections[hk] = connection
        }
        let conn = connection!
        lock.unlock()

        let forwarder = SSHTunnelForwarder(connection: conn, remotePort: remotePort)
        let port = try await forwarder.start()

        do {
            try await probeHealth(localPort: port)
        } catch {
            forwarder.stop()
            throw error
        }

        lock.lock()
        forwarders[fk] = forwarder
        lock.unlock()
        return port
    }

    /// Confirms the full byte path works by hitting the runner's unauthenticated
    /// `/health` over the loopback port. Any HTTP response means the tunnel
    /// reached the runner; a transport error means it didn't.
    private func probeHealth(localPort: Int) async throws {
        guard let url = URL(string: "http://127.0.0.1:\(localPort)/health") else {
            throw TunnelError.healthCheckFailed
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (_, response) = try await URLSession.shared.data(for: request)
        guard response is HTTPURLResponse else {
            throw TunnelError.healthCheckFailed
        }
    }
}
