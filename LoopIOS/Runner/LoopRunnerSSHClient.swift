//
//  LoopRunnerSSHClient.swift
//  Loop
//
//  SSH "exec-poll" transport for a Loop Runner. Instead of hitting the runner's
//  HTTP endpoints directly with URLSession (which iOS App Transport Security
//  blocks for plain http:// to a remote host), this runs `curl` against
//  127.0.0.1:<port> *on the SSH host itself* — over the same SSH connection the
//  `ssh_client` skill already uses — and decodes the stdout into the shared
//  Runner models.
//
//  This is the first of the two SSH transports: it reuses the proven
//  SSHExecHandler and works on a physical device with no ATS exception. The
//  follow-up persistent `direct-tcpip` tunnel keeps URLSession but is heavier
//  to build; this path opens an SSH session per request, which is fine for the
//  3 s poll cadence during testing.
//
//  The runner must be listening on 127.0.0.1:<remotePort> on the SSH host and
//  `curl` must be available there (standard on Ubuntu).
//

import Foundation
import os

final class LoopRunnerSSHClient {

    private let sharedSecret: String
    private let remotePort: Int

    private static let log = Logger(subsystem: "com.bhat.intel", category: "LoopRunnerSSHClient")

    /// ISO-8601 with fractional seconds — matches what the runner emits and the
    /// URLSession client sends, so the `since` cursor round-trips identically.
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(sharedSecret: String, remotePort: Int) {
        self.sharedSecret = sharedSecret
        self.remotePort = remotePort
    }

    // MARK: - Public API

    func pollTurns(since: Date) async throws -> (turns: [RunnerTurn], serverTime: Date) {
        let data = try await get(path: "/turns?since=\(Self.iso.string(from: since))&limit=50",
                                 authed: true, timeout: 15)
        let result = try LoopRunnerClient.jsonDecoder.decode(RunnerTurnsResponse.self, from: data)
        return (result.turns, result.serverTime)
    }

    func pollJobs(since: Date) async throws -> (jobs: [RunnerJob], serverTime: Date) {
        let data = try await get(path: "/jobs?since=\(Self.iso.string(from: since))&limit=50",
                                 authed: true, timeout: 15)
        let result = try LoopRunnerClient.jsonDecoder.decode(RunnerJobsResponse.self, from: data)
        return (result.jobs, result.serverTime)
    }

    func checkHealth() async throws -> RunnerHealthResponse {
        let data = try await get(path: "/health", authed: false, timeout: 10)
        return try LoopRunnerClient.jsonDecoder.decode(RunnerHealthResponse.self, from: data)
    }

    func getTurn(id: String) async throws -> RunnerTurn {
        let data = try await get(path: "/turn/\(id)", authed: true, timeout: 15)
        return try LoopRunnerClient.jsonDecoder.decode(RunnerTurn.self, from: data)
    }

    /// Submit a turn over SSH (handoff path). POSTs the same JSON the URLSession
    /// client sends; with `async: true` the runner replies `202 {"id":...}`.
    func startTurn(messages: [[String: String]], conversationId: String, userId: String, async: Bool = true) async throws -> String {
        let payload: [String: Any] = [
            "messages": messages,
            "conversation_id": conversationId,
            "user_id": userId,
            "async": async,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        let bodyStr = String(data: bodyData, encoding: .utf8) ?? "{}"
        let data = try await post(path: "/turn", jsonBody: bodyStr, timeout: 20)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let turnId = obj?["id"] as? String else {
            throw RunnerError.invalidResponse
        }
        return turnId
    }

    // MARK: - Internals

    /// Runs a single GET over SSH via curl and returns the response body. Uses
    /// curl's `-w '\n%{http_code}'` so the HTTP status rides the last line,
    /// letting us validate it without `-f` (which would swallow the body).
    private func get(path: String, authed: Bool, timeout: Int) async throws -> Data {
        let url = "http://127.0.0.1:\(remotePort)\(path)"
        var cmd = "curl -s -m \(timeout) -w '\\n%{http_code}'"
        if authed {
            cmd += " -H " + Self.shellQuote("Authorization: Bearer \(sharedSecret)")
        }
        cmd += " " + Self.shellQuote(url)

        let res = try await SSHSkill.shared.runCommand(cmd, timeout: Double(timeout + 5))

        // Non-zero curl exit = network/transport failure (couldn't connect,
        // curl missing, etc.). HTTP errors keep exit 0 because we don't use -f.
        if res.exitCode != 0 {
            let detail = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RunnerError.transport(
                "curl over SSH failed (exit \(res.exitCode))" + (detail.isEmpty ? "" : ": \(detail)"))
        }

        let out = res.stdout
        guard let nl = out.lastIndex(of: "\n") else {
            throw RunnerError.transport("empty response from runner over SSH")
        }
        let codeStr = out[out.index(after: nl)...].trimmingCharacters(in: .whitespacesAndNewlines)
        let body = String(out[..<nl])

        guard let code = Int(codeStr) else {
            throw RunnerError.transport("could not parse HTTP status from runner response")
        }
        if codeStr == "000" {
            throw RunnerError.transport(
                "could not reach runner on 127.0.0.1:\(remotePort) over SSH — is it running?")
        }
        guard (200..<300).contains(code) else {
            throw RunnerError.httpError(statusCode: code)
        }
        return Data(body.utf8)
    }

    /// Runs a single POST over SSH via curl with a JSON body and returns the
    /// response body. Same status-on-last-line trick as `get`.
    private func post(path: String, jsonBody: String, timeout: Int) async throws -> Data {
        let url = "http://127.0.0.1:\(remotePort)\(path)"
        var cmd = "curl -s -m \(timeout) -w '\\n%{http_code}' -X POST"
        cmd += " -H " + Self.shellQuote("Authorization: Bearer \(sharedSecret)")
        cmd += " -H " + Self.shellQuote("Content-Type: application/json")
        cmd += " -d " + Self.shellQuote(jsonBody)
        cmd += " " + Self.shellQuote(url)

        let res = try await SSHSkill.shared.runCommand(cmd, timeout: Double(timeout + 5))
        if res.exitCode != 0 {
            let detail = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RunnerError.transport(
                "curl POST over SSH failed (exit \(res.exitCode))" + (detail.isEmpty ? "" : ": \(detail)"))
        }

        let out = res.stdout
        guard let nl = out.lastIndex(of: "\n") else {
            throw RunnerError.transport("empty response from runner over SSH")
        }
        let codeStr = out[out.index(after: nl)...].trimmingCharacters(in: .whitespacesAndNewlines)
        let body = String(out[..<nl])
        guard let code = Int(codeStr) else {
            throw RunnerError.transport("could not parse HTTP status from runner response")
        }
        if codeStr == "000" {
            throw RunnerError.transport(
                "could not reach runner on 127.0.0.1:\(remotePort) over SSH — is it running?")
        }
        guard (200..<300).contains(code) else {
            throw RunnerError.httpError(statusCode: code)
        }
        return Data(body.utf8)
    }

    /// POSIX single-quote escaping so secrets/URLs can't break out of the
    /// remote shell command.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension LoopRunnerSSHClient: RunnerPolling {}
extension LoopRunnerSSHClient: RunnerSubmitting {}
extension LoopRunnerSSHClient: RunnerFetching {}
extension LoopRunnerSSHClient: RunnerTransport {}
