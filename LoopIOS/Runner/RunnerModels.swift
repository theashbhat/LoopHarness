//
//  RunnerModels.swift
//  Loop
//
//  Domain models for the Portable Loop Runner integration. These mirror the
//  Go runner's JSON shapes (`GET /turn/:id`, `GET /job/:job_id`,
//  `GET /turns?since=...`, `GET /jobs?since=...`) and the persisted runner
//  configuration stored in the Keychain.
//

import Foundation

// MARK: - Runner configuration (persisted)

/// A single configured Loop Runner instance. Stored as a JSON array in the
/// Keychain under `RunnerStore.service`.
struct RunnerConfig: Codable, Identifiable, Equatable {
    var id: String
    var nickname: String
    var baseURL: String
    /// Keychain account name that holds the shared secret for this runner.
    /// The secret itself lives in a separate Keychain entry so it never
    /// rides serialized JSON.
    var secretRef: String
    var createdAt: Date
    var lastPollTime: Date?
    var lastSeenTurnCount: Int
    /// When set, the runner is reached by tunnelling over the SSH host
    /// configured in Settings → SSH (transport hits `127.0.0.1:<port>` on that
    /// host) rather than by hitting `baseURL` directly over HTTP. `nil` keeps
    /// the original direct-URL behaviour. Optional so existing persisted
    /// runners decode unchanged.
    var sshRemotePort: Int?

    /// True when this runner polls over the SSH host instead of a direct URL.
    var usesSSH: Bool { sshRemotePort != nil }

    /// Stable id for the zero-config fallback runner derived from the default
    /// Settings → SSH connection (see `LoopRunnerPoller.effectiveRunners`).
    static let autoSSHID = "auto-ssh"

    /// The loopback port the Go `loop-runner` listens on by default. Overridable
    /// via UserDefaults so the fallback can target a non-default deployment.
    static var defaultRunnerPort: Int {
        let p = UserDefaults.standard.integer(forKey: "loop.runner.defaultPort")
        return p > 0 ? p : 8080
    }

    /// A synthetic runner that reuses the default Settings → SSH connection as
    /// its transport — used when the user hasn't added an explicit Loop Runner
    /// but does have an SSH VM. `secretRef` resolves to no Keychain entry, so the
    /// client sends an empty bearer (the runner must run with `shared_secret`
    /// empty, i.e. auth disabled behind the tunnel).
    static var autoSSHRunner: RunnerConfig {
        RunnerConfig(id: autoSSHID,
                     nickname: "My VM",
                     baseURL: "",
                     secretRef: "com.loop.runner.secret.\(autoSSHID)",
                     sshRemotePort: defaultRunnerPort)
    }

    init(id: String = UUID().uuidString,
         nickname: String,
         baseURL: String,
         secretRef: String? = nil,
         createdAt: Date = Date(),
         lastPollTime: Date? = nil,
         lastSeenTurnCount: Int = 0,
         sshRemotePort: Int? = nil) {
        self.id = id
        self.nickname = nickname
        self.baseURL = baseURL
        self.secretRef = secretRef ?? "com.loop.runner.secret.\(id)"
        self.createdAt = createdAt
        self.lastPollTime = lastPollTime
        self.lastSeenTurnCount = lastSeenTurnCount
        self.sshRemotePort = sshRemotePort
    }
}

// MARK: - Wire models (runner API responses)

/// A single turn as returned by the runner.
struct RunnerTurn: Codable, Identifiable, Equatable {
    let id: String
    let status: String
    let finalResponse: String?
    let error: String?
    let createdAt: Date
    let updatedAt: Date
    /// The originating conversation for handoff turns (empty/nil for interactive
    /// turns). Lets the poller reconcile a completed turn into the right chat.
    let conversationId: String?

    var isCompleted: Bool { status == "completed" || status == "error" }

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case finalResponse = "final_response"
        case error
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case conversationId = "conversation_id"
    }
}

/// A single job as returned by the runner.
struct RunnerJob: Codable, Identifiable, Equatable {
    let id: String
    let turnId: String
    let status: String
    let result: String?
    let error: String?
    let createdAt: Date
    let updatedAt: Date

    var isCompleted: Bool { status == "completed" || status == "error" }

    enum CodingKeys: String, CodingKey {
        case id
        case turnId = "turn_id"
        case status
        case result
        case error
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Batch-poll response wrapper. The runner returns a `server_time` field
/// alongside the items so the client can advance its `since` cursor without
/// clock-skew issues.
struct RunnerTurnsResponse: Codable {
    let turns: [RunnerTurn]
    let serverTime: Date

    enum CodingKeys: String, CodingKey {
        case turns
        case serverTime = "server_time"
    }
}

struct RunnerJobsResponse: Codable {
    let jobs: [RunnerJob]
    let serverTime: Date

    enum CodingKeys: String, CodingKey {
        case jobs
        case serverTime = "server_time"
    }
}

/// Health-check response from `GET /health`. The runner returns
/// `{"ok":true,"version":"0.1.0","uptime_seconds":N}`.
struct RunnerHealthResponse: Codable {
    let ok: Bool
    let version: String?
    let uptimeSeconds: Double?

    /// Human-readable summary for the Test Connection UI.
    var summary: String {
        var parts = [ok ? "ok" : "not ok"]
        if let version { parts.append("v\(version)") }
        if let uptimeSeconds { parts.append("up \(Int(uptimeSeconds))s") }
        return parts.joined(separator: " · ")
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case version
        case uptimeSeconds = "uptime_seconds"
    }
}
