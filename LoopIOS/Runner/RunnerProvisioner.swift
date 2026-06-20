//
//  RunnerProvisioner.swift
//  Loop
//
//  Deploys + starts the Go `loop-runner` on the active SSH VM so background
//  handoffs have somewhere to land. The runner is a separate binary from
//  OpenClaw; nothing else puts it on the VM.
//
//  Strategy (hybrid): the linux binaries ship gzipped inside the app (asset
//  catalog Data Sets). On first use we detect the VM's arch (`uname -m`), and if
//  the right version isn't already installed we stream the gzipped binary over
//  the existing SSH connection in base64 chunks (no scp/SFTP available), then
//  decompress it to `~/.loop/loop-runner`. `config.json` (model key, no auth) is
//  (re)written each time. `ensureRunning` then health-checks and `nohup`-starts
//  it on demand — cheap enough to call on every handoff.
//
//  Transfer uses only `SSHSkill.runCommand` (command string, no stdin), so each
//  chunk is appended via a quoted heredoc. ~25 round-trips for a ~4MB gz —
//  fine for a one-time, foreground provision.
//

import Foundation
import CryptoKit
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum RunnerProvisionError: Error, LocalizedError {
    case archUnsupported(String)
    case noBundledBinary(String)
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .archUnsupported(let u): return "Unsupported VM architecture: \(u)"
        case .noBundledBinary(let a): return "No bundled runner binary for \(a)"
        case .remote(let d): return d
        }
    }
}

final class RunnerProvisioner {

    static let shared = RunnerProvisioner()
    private init() {}

    private static let log = Logger(subsystem: "com.bhat.intel", category: "runner-provision")
    private static let remoteDir = "$HOME/.loop"
    /// Loopback port the runner listens on (matches the handoff transport).
    static var port: Int { RunnerConfig.defaultRunnerPort }

    /// base64 chunk size (characters). Kept well under SSH channel-request limits.
    private static let chunkSize = 180_000

    private let lock = NSLock()
    private var inFlight = false
    /// Hosts verified up-to-date this session, so foreground re-checks are cheap.
    private var verifiedHosts: Set<String> = []

    // MARK: - Provision

    /// Ensure the runner binary + config are installed on the host (idempotent,
    /// version-checked). Foreground use — the first install can take ~10s.
    func provisionIfNeeded(on config: SSHConfig) async {
        guard config.isConfigured else { return }

        lock.lock()
        if inFlight || verifiedHosts.contains(config.host) { lock.unlock(); return }
        inFlight = true
        lock.unlock()
        defer { lock.lock(); inFlight = false; lock.unlock() }

        do {
            try await provision(on: config)
            lock.lock(); verifiedHosts.insert(config.host); lock.unlock()
        } catch {
            Self.log.error("provision failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func provision(on config: SSHConfig) async throws {
        // 1. Detect arch.
        let uname = try await run("uname -m", on: config, timeout: 15)
        guard let arch = Self.archToken(uname.stdout) else {
            throw RunnerProvisionError.archUnsupported(uname.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 2. Load the matching gzipped binary from the app bundle.
        guard let gz = NSDataAsset(name: "loop-runner-linux-\(arch)")?.data else {
            throw RunnerProvisionError.noBundledBinary(arch)
        }
        let version = Self.shortHash(gz)

        // 3. (Re)write config + ensure dir. config.json is cheap and may change
        //    (model key), so always refresh it.
        _ = try await run("mkdir -p \(Self.remoteDir)", on: config, timeout: 15)
        try await writeRemoteFile(makeConfigJSON(), to: "\(Self.remoteDir)/config.json", on: config)

        // 4. Skip the binary transfer if the installed version matches.
        let installed = (try? await run("cat \(Self.remoteDir)/version 2>/dev/null", on: config, timeout: 15))?
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if installed == version {
            Self.log.info("runner already up to date (v\(version, privacy: .public)) on \(config.host, privacy: .public)")
            return
        }

        // 5. Stream the gz over in base64 chunks, then decompress.
        Self.log.info("installing runner (\(arch, privacy: .public), v\(version, privacy: .public)) on \(config.host, privacy: .public)")
        _ = try await run("rm -f \(Self.remoteDir)/runner.gz.b64", on: config, timeout: 15)

        let b64 = gz.base64EncodedString()
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: Self.chunkSize, limitedBy: b64.endIndex) ?? b64.endIndex
            let chunk = String(b64[idx..<end])
            idx = end
            // Quoted heredoc: base64 alphabet has nothing the shell expands, and
            // base64EncodedString() emits no newlines, so the chunk is one line.
            let cmd = "cat >> \(Self.remoteDir)/runner.gz.b64 <<'LOOPB64'\n\(chunk)\nLOOPB64"
            let r = try await run(cmd, on: config, timeout: 30)
            guard r.exitCode == 0 else { throw RunnerProvisionError.remote("chunk write failed: \(r.stderr)") }
        }

        let assemble = "base64 -d \(Self.remoteDir)/runner.gz.b64 | gzip -d > \(Self.remoteDir)/loop-runner "
            + "&& chmod +x \(Self.remoteDir)/loop-runner "
            + "&& rm -f \(Self.remoteDir)/runner.gz.b64 "
            + "&& printf '%s' '\(version)' > \(Self.remoteDir)/version"
        let ar = try await run(assemble, on: config, timeout: 60)
        guard ar.exitCode == 0 else { throw RunnerProvisionError.remote("assemble failed: \(ar.stderr)") }
        Self.log.info("runner installed on \(config.host, privacy: .public)")
    }

    // MARK: - Ensure running

    /// Start the runner if it isn't answering /health. Cheap; safe to call on
    /// every handoff. Returns true once health is confirmed.
    @discardableResult
    func ensureRunning(on config: SSHConfig) async -> Bool {
        guard config.isConfigured else { return false }
        if await isHealthy(config) { return true }

        // Detached start: nohup + redirected stdio so it survives the SSH channel
        // closing.
        let start = "cd \(Self.remoteDir) && nohup ./loop-runner -config config.json "
            + ">runner.log 2>&1 </dev/null & echo started"
        _ = try? await run(start, on: config, timeout: 15)

        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if await isHealthy(config) { return true }
        }
        Self.log.error("runner did not become healthy on \(config.host, privacy: .public)")
        return false
    }

    private func isHealthy(_ config: SSHConfig) async -> Bool {
        let cmd = "curl -s -m 3 -o /dev/null -w '%{http_code}' 127.0.0.1:\(Self.port)/health 2>/dev/null"
        guard let r = try? await run(cmd, on: config, timeout: 10) else { return false }
        return r.stdout.contains("200")
    }

    // MARK: - Helpers

    private func run(_ command: String, on config: SSHConfig, timeout: Double) async throws -> SSHSkill.CommandResult {
        try await SSHSkill.shared.runCommand(command, on: config, timeout: timeout)
    }

    /// The runner's config.json. Uses the OpenAI key (the runner calls gpt-4o)
    /// and an empty shared_secret (auth disabled behind the private tunnel).
    /// `push_send_url` is intentionally omitted so the Go runner uses its own
    /// compiled-in default — keeping the backend URL out of this committed file.
    private func makeConfigJSON() -> String {
        let key = KeyStore.shared.value(for: .openAI) ?? ""
        let dict: [String: Any] = [
            "model_api_key": key,
            "shared_secret": "",
            "listen_port": Self.port,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func writeRemoteFile(_ contents: String, to path: String, on config: SSHConfig) async throws {
        // Small file — a single base64 echo is fine and avoids quoting issues.
        let b64 = Data(contents.utf8).base64EncodedString()
        let r = try await run("printf '%s' '\(b64)' | base64 -d > \(path)", on: config, timeout: 15)
        guard r.exitCode == 0 else { throw RunnerProvisionError.remote("write \(path) failed: \(r.stderr)") }
    }

    private static func archToken(_ uname: String) -> String? {
        switch uname.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "x86_64", "amd64": return "amd64"
        case "aarch64", "arm64": return "arm64"
        default: return nil
        }
    }

    private static func shortHash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
