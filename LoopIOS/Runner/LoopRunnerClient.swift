//
//  LoopRunnerClient.swift
//  Loop
//
//  Networking layer for a single Portable Loop Runner VM. Talks to the Go
//  runner's REST endpoints (`GET /turn/:id`, `GET /job/:job_id`,
//  `GET /turns?since=...`, `GET /jobs?since=...`, `GET /health`) with
//  Bearer-token auth.
//
//  Designed for dependency injection: callers provide a `URLSession` so
//  unit tests can swap in a mock transport without touching the network.
//

import Foundation
import os

final class LoopRunnerClient {

    let baseURL: URL
    private let sharedSecret: String
    private let session: URLSession

    private static let log = Logger(subsystem: "com.bhat.intel", category: "LoopRunnerClient")

    /// ISO-8601 decoder with fractional seconds for the runner's timestamps.
    static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = ISO8601DateFormatter.withFractional.date(from: str) {
                return date
            }
            if let date = ISO8601DateFormatter.plain.date(from: str) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date: \(str)"
            )
        }
        return d
    }()

    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.withFractional.string(from: date))
        }
        return e
    }()

    init(baseURL: URL, sharedSecret: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.sharedSecret = sharedSecret
        self.session = session
    }

    convenience init?(runner: RunnerConfig) {
        guard let url = URL(string: runner.baseURL),
              let secret = RunnerStore.shared.secret(for: runner.secretRef) else {
            return nil
        }
        self.init(baseURL: url, sharedSecret: secret)
    }

    // MARK: - Public API

    /// Start a new turn on the runner. With `async: true` the runner persists the
    /// turn, returns `202 {"id":...}` immediately, and finishes in the background
    /// (the handoff path). With `async: false` the runner streams SSE — not what
    /// this JSON-parsing method expects, so callers should keep `async: true`.
    func startTurn(messages: [[String: String]], conversationId: String, userId: String, async: Bool = true) async throws -> String {
        var request = makeRequest(path: "/turn", method: "POST")
        let payload: [String: Any] = [
            "messages": messages,
            "conversation_id": conversationId,
            "user_id": userId,
            "async": async,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let turnId = body?["id"] as? String else {
            throw RunnerError.invalidResponse
        }
        return turnId
    }

    /// The stable device user id the central push backend targets (see
    /// `PushTokenBridge` / PUSH_NOTIFICATIONS.md). Empty when analytics/push has
    /// never run on this device — the runner then skips the completion push and
    /// delivery falls back to the foreground poller.
    static var deviceUserId: String {
        UserDefaults.standard.string(forKey: "loop.analytics.user_id") ?? ""
    }

    /// Fetch a single turn by id.
    func getTurn(id: String) async throws -> RunnerTurn {
        let request = makeRequest(path: "/turn/\(id)")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try Self.jsonDecoder.decode(RunnerTurn.self, from: data)
    }

    /// Batch-poll turns since a server timestamp.
    func pollTurns(since: Date) async throws -> (turns: [RunnerTurn], serverTime: Date) {
        let sinceStr = ISO8601DateFormatter.withFractional.string(from: since)
        let request = makeRequest(path: "/turns?since=\(sinceStr)")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        let result = try Self.jsonDecoder.decode(RunnerTurnsResponse.self, from: data)
        return (result.turns, result.serverTime)
    }

    /// Batch-poll jobs since a server timestamp.
    func pollJobs(since: Date) async throws -> (jobs: [RunnerJob], serverTime: Date) {
        let sinceStr = ISO8601DateFormatter.withFractional.string(from: since)
        let request = makeRequest(path: "/jobs?since=\(sinceStr)")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        let result = try Self.jsonDecoder.decode(RunnerJobsResponse.self, from: data)
        return (result.jobs, result.serverTime)
    }

    /// Health check. Throws on network / non-200.
    func checkHealth() async throws -> RunnerHealthResponse {
        let request = makeRequest(path: "/health")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try Self.jsonDecoder.decode(RunnerHealthResponse.self, from: data)
    }

    // MARK: - Internals

    private func makeRequest(path: String, method: String = "GET") -> URLRequest {
        let url: URL
        if path.contains("?") {
            // Path includes query string — build from components.
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            let parts = path.split(separator: "?", maxSplits: 1)
            components.path = String(parts[0])
            components.query = parts.count > 1 ? String(parts[1]) : nil
            url = components.url!
        } else {
            url = baseURL.appendingPathComponent(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(sharedSecret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RunnerError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RunnerError.httpError(statusCode: http.statusCode)
        }
    }
}

// MARK: - Error

enum RunnerError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case missingSecret
    /// SSH/transport-level failure (e.g. curl couldn't reach the runner, or
    /// the SSH command itself failed). Carries a human-readable detail.
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from runner"
        case .httpError(let code): return "Runner returned HTTP \(code)"
        case .missingSecret: return "Shared secret not configured"
        case .transport(let detail): return detail
        }
    }
}

// MARK: - Transport abstraction

/// The polling surface the Runner poller depends on. Implemented by the direct
/// HTTP client (`LoopRunnerClient`) and the SSH exec client
/// (`LoopRunnerSSHClient`) so the poller is transport-agnostic.
protocol RunnerPolling {
    func pollTurns(since: Date) async throws -> (turns: [RunnerTurn], serverTime: Date)
    func pollJobs(since: Date) async throws -> (jobs: [RunnerJob], serverTime: Date)
}

/// The submit surface used by the background-handoff path. Both transports
/// implement it so a handoff works whether the runner is reached directly,
/// over a tunnel, or via SSH-exec.
protocol RunnerSubmitting {
    func startTurn(messages: [[String: String]], conversationId: String, userId: String, async: Bool) async throws -> String
}

/// Fetch a single turn by id — used by the completion-push tap and foreground
/// reconciliation to read a handed-off turn's final response.
protocol RunnerFetching {
    func getTurn(id: String) async throws -> RunnerTurn
}

/// Combined transport capability — poll + submit + fetch. `makeClient` vends this
/// so the poller can poll, hand off, and fetch without rebuilding the transport.
protocol RunnerTransport: RunnerPolling, RunnerSubmitting, RunnerFetching {}

extension LoopRunnerClient: RunnerPolling {}
extension LoopRunnerClient: RunnerSubmitting {}
extension LoopRunnerClient: RunnerFetching {}
extension LoopRunnerClient: RunnerTransport {}

// MARK: - ISO8601 helpers

private extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
