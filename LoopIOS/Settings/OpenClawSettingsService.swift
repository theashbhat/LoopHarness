//
//  OpenClawSettingsService.swift
//  Loop
//
//  Reads (and, where it maps, mutates) an OpenClaw VM's runtime configuration for
//  the Settings screens shown while a remote OpenClaw backend is active. The app
//  is a *client of the OpenClaw runtime*, so these screens mirror what the VM
//  actually has configured rather than the on-device stores used in Local mode.
//
//  Transport mirrors `OpenClawConversationStore`: shell `openclaw …` over
//  `SSHSkill` with the npm-global `PATH` prefix (the exec channel has no login
//  shell), parse the CLI's `--json` output. Confirmed against OpenClaw 2026.4.1:
//    • Models:    `openclaw models status --json` (default + aliases) and
//                 `openclaw models list --json` (configured catalog) — combined in
//                 one round trip via a sentinel split.
//    • Set model: `openclaw models set <model-or-alias>`.
//    • Crons:     `openclaw cron list --all --json` → `{ jobs: [...] }`.
//    • Subagents: `openclaw tasks list --runtime subagent --json` → `{ tasks: [...] }`.
//    • Keys:      derived from the configured model catalog — one row per model
//                 provider that has credentials (provider keys live in several
//                 places on the VM: `.env`, IAM, auth-profiles.json — the catalog
//                 is the single source that reflects what actually works).
//
//  Pure Foundation so it compiles for the iOS, macOS, and visionOS targets.
//

import Foundation
import os

private let openClawSettingsLog = Logger(subsystem: "com.bhat.intel", category: "OpenClawSettings")

/// Queries one OpenClaw backend's runtime config over SSH. Stateless beyond the
/// connection settings; each call is an independent `openclaw` invocation.
struct OpenClawSettingsService {

    let config: OpenClawConfig

    init(config: OpenClawConfig) { self.config = config }

    /// The service for the active remote backend, or nil when Local is active or
    /// the selected remote isn't configured/validated. Settings screens use this
    /// to decide whether to render OpenClaw data or fall back to local stores.
    static var active: OpenClawSettingsService? {
        guard let backend = ExecutionBackendStore.shared.activeRemoteBackend else { return nil }
        return OpenClawSettingsService(config: backend.config)
    }

    // MARK: - Models

    /// One model from the VM's configured catalog.
    struct Model: Equatable {
        let key: String        // canonical id, e.g. "openai/gpt-5.2"
        let name: String       // display name, e.g. "GPT-5.2"
        let provider: String   // derived: segment before the first "/"
        let available: Bool    // credentials present + usable
        let isDefault: Bool     // the agent's current default model
        let contextWindow: Int?
        let aliases: [String]  // short aliases (from `alias:` tags)

        /// Friendliest short alias for the action label, else the canonical key.
        var preferredAlias: String { aliases.first ?? key }
    }

    struct ModelCatalog {
        let models: [Model]
        let defaultKey: String?
        /// Models grouped by provider, providers in first-seen order.
        var byProvider: [(provider: String, models: [Model])] {
            var order: [String] = []
            var buckets: [String: [Model]] = [:]
            for m in models {
                if buckets[m.provider] == nil { order.append(m.provider) }
                buckets[m.provider, default: []].append(m)
            }
            return order.map { ($0, buckets[$0] ?? []) }
        }
    }

    /// Fetch the configured model catalog + current default in one SSH round trip.
    func fetchModels() async throws -> ModelCatalog {
        let cmd = "\(Self.pathPrefix) openclaw models status --json 2>/dev/null; "
            + "echo '\(Self.splitSentinel)'; "
            + "openclaw models list --json 2>/dev/null"
        let out = try await run(cmd)
        let parts = out.components(separatedBy: Self.splitSentinel)
        let statusJSON = parts.first ?? ""
        let listJSON = parts.count > 1 ? parts[1] : ""

        let status = Self.jsonObject(in: statusJSON)
        let defaultKey = (status?["resolvedDefault"] as? String)
            ?? (status?["defaultModel"] as? String)

        guard let listRoot = Self.jsonObject(in: listJSON),
              let rawModels = listRoot["models"] as? [[String: Any]] else {
            // A reachable VM with no catalog still yields a valid (empty) result.
            return ModelCatalog(models: [], defaultKey: defaultKey)
        }
        let models: [Model] = rawModels.compactMap { m in
            guard let key = m["key"] as? String else { return nil }
            let tags = (m["tags"] as? [String]) ?? []
            let aliases = tags.compactMap { tag -> String? in
                tag.hasPrefix("alias:") ? String(tag.dropFirst("alias:".count)) : nil
            }
            return Model(
                key: key,
                name: (m["name"] as? String) ?? key,
                provider: key.split(separator: "/").first.map(String.init) ?? key,
                available: (m["available"] as? Bool) ?? false,
                isDefault: key == defaultKey || tags.contains("default"),
                contextWindow: m["contextWindow"] as? Int,
                aliases: aliases)
        }
        return ModelCatalog(models: models, defaultKey: defaultKey)
    }

    /// Set the agent's default model on the VM. `modelOrAlias` is a catalog key or
    /// a short alias (both accepted by `openclaw models set`).
    func setDefaultModel(_ modelOrAlias: String) async throws {
        let cmd = "\(Self.pathPrefix) openclaw models set \(Self.shQuote(modelOrAlias))"
        let result = try await SSHSkill.shared.runOpenClawCommand(cmd, on: config.sshConfig, timeout: 30)
        guard result.exitCode == 0 else {
            throw OpenClawSettingsError.commandFailed(
                trimmedDetail(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
    }

    // MARK: - Keys (model-provider credentials)

    /// A model provider the VM has credentials for, with how many of its models
    /// are usable. "Keys I have set," reflected through what actually works.
    struct ProviderKey: Equatable {
        let provider: String
        let displayName: String
        let availableModels: Int
        var configured: Bool { availableModels > 0 }
    }

    /// Derive provider credential coverage from the configured model catalog.
    func fetchProviderKeys() async throws -> [ProviderKey] {
        let catalog = try await fetchModels()
        var counts: [String: Int] = [:]
        var order: [String] = []
        for m in catalog.models {
            if counts[m.provider] == nil { order.append(m.provider) }
            counts[m.provider, default: 0] += m.available ? 1 : 0
        }
        return order.map {
            ProviderKey(provider: $0,
                        displayName: Self.providerDisplayName($0),
                        availableModels: counts[$0] ?? 0)
        }
    }

    // MARK: - Crons

    struct Cron: Equatable {
        let id: String
        let name: String
        let enabled: Bool
        let scheduleText: String
        let lastRunAtMs: Double?
        let lastStatus: String?
        let nextRunAtMs: Double?
        let message: String?

        var lastRunDate: Date? { OpenClawSettingsService.date(fromMs: lastRunAtMs) }
        var nextRunDate: Date? { OpenClawSettingsService.date(fromMs: nextRunAtMs) }
    }

    /// List every cron job on the VM (including disabled), newest activity first.
    func fetchCrons() async throws -> [Cron] {
        let cmd = "\(Self.pathPrefix) openclaw cron list --all --json 2>/dev/null"
        let out = try await run(cmd)
        guard let root = Self.jsonObject(in: out),
              let jobs = root["jobs"] as? [[String: Any]] else { return [] }
        let crons: [Cron] = jobs.compactMap { j in
            guard let id = j["id"] as? String else { return nil }
            let state = j["state"] as? [String: Any]
            let payload = j["payload"] as? [String: Any]
            return Cron(
                id: id,
                name: (j["name"] as? String) ?? "Cron job",
                enabled: (j["enabled"] as? Bool) ?? true,
                scheduleText: Self.describeSchedule(j["schedule"] as? [String: Any]),
                lastRunAtMs: state?["lastRunAtMs"] as? Double,
                lastStatus: (state?["lastStatus"] as? String) ?? (state?["lastRunStatus"] as? String),
                nextRunAtMs: state?["nextRunAtMs"] as? Double,
                message: payload?["message"] as? String)
        }
        // Most recently active first; jobs that have never run sort by next run.
        return crons.sorted {
            ($0.lastRunAtMs ?? $0.nextRunAtMs ?? 0) > ($1.lastRunAtMs ?? $1.nextRunAtMs ?? 0)
        }
    }

    // MARK: - Subagents

    struct Subagent: Equatable {
        let taskId: String
        let label: String?
        let task: String
        let status: String
        let createdAtMs: Double?
        let endedAtMs: Double?
        let progressSummary: String?

        /// A turn that hasn't reached a terminal state yet.
        var isRunning: Bool { status == "running" || status == "queued" }
        var createdDate: Date? { OpenClawSettingsService.date(fromMs: createdAtMs) }

        /// A human title: the explicit label, else the first line of the task.
        var displayTitle: String {
            if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                return label
            }
            let firstLine = task.split(whereSeparator: \.isNewline).first.map(String.init) ?? task
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            return trimmed.count <= 80 ? trimmed : String(trimmed.prefix(77)) + "…"
        }
    }

    /// Subagent task runs (running + history), newest first. Capped so a busy VM's
    /// long ledger doesn't blow up the list.
    func fetchSubagents(limit: Int = 60) async throws -> [Subagent] {
        // NOTE: `openclaw tasks list --json` prints its payload on STDERR (unlike
        // models/cron, which use stdout), so we don't suppress stderr here — `run`
        // falls back to whichever stream carries the JSON.
        let cmd = "\(Self.pathPrefix) openclaw tasks list --runtime subagent --json"
        let out = try await run(cmd)
        guard let root = Self.jsonObject(in: out),
              let tasks = root["tasks"] as? [[String: Any]] else { return [] }
        let subagents: [Subagent] = tasks.compactMap { t in
            guard let taskId = t["taskId"] as? String else { return nil }
            return Subagent(
                taskId: taskId,
                label: t["label"] as? String,
                task: (t["task"] as? String) ?? "",
                status: (t["status"] as? String) ?? "unknown",
                createdAtMs: t["createdAt"] as? Double,
                endedAtMs: t["endedAt"] as? Double,
                progressSummary: t["progressSummary"] as? String)
        }
        let sorted = subagents.sorted { ($0.createdAtMs ?? 0) > ($1.createdAtMs ?? 0) }
        return Array(sorted.prefix(limit))
    }

    // MARK: - Transport

    /// Runs a command and returns whichever output stream carries the JSON. Most
    /// `openclaw … --json` subcommands print to stdout, but some (e.g. `tasks`)
    /// print to stderr — so prefer the stream that actually contains an object.
    private func run(_ command: String) async throws -> String {
        let result = try await SSHSkill.shared.runOpenClawCommand(command, on: config.sshConfig, timeout: 30)
        if result.stdout.contains("{") { return result.stdout }
        if result.stderr.contains("{") { return result.stderr }
        return result.stdout
    }

    private func trimmedDetail(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "unknown error" : String(t.suffix(300))
    }

    // MARK: - Parsing helpers (static, unit-testable)

    /// Reused from the conversation store so both transports prepend the same
    /// PATH + share the same shell-quoting rules.
    static let pathPrefix = OpenClawConversationStore.pathPrefix
    static func shQuote(_ s: String) -> String { OpenClawConversationStore.shQuote(s) }

    /// Splits the combined models status/list response.
    static let splitSentinel = "<<<LOOP_OPENCLAW_SPLIT>>>"

    /// Parse the first top-level JSON object in `s`, tolerating leading sentinel
    /// lines by scanning to the first `{`.
    static func jsonObject(in s: String) -> [String: Any]? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        let slice = String(s[start...])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Render a cron `schedule` object into a short human string. Handles the
    /// `every` (interval) and `cron` (expression) kinds, falling back to the raw
    /// kind for anything else.
    static func describeSchedule(_ schedule: [String: Any]?) -> String {
        guard let schedule = schedule else { return "—" }
        let kind = (schedule["kind"] as? String) ?? ""
        switch kind {
        case "every":
            if let ms = schedule["everyMs"] as? Double { return "Every \(humanInterval(ms))" }
            return "Repeating"
        case "cron":
            // The scheduler stores the expression under `expr`; accept the longer
            // spellings too in case the field is renamed.
            if let expr = schedule["expr"] as? String { return expr }
            if let expr = schedule["expression"] as? String { return expr }
            if let expr = schedule["cron"] as? String { return expr }
            return "Cron"
        case "at":
            if let date = date(fromMs: schedule["atMs"] as? Double) {
                return "Once at " + shortDateTime(date)
            }
            return "Once"
        default:
            return kind.isEmpty ? "—" : kind.capitalized
        }
    }

    /// Humanize a millisecond interval ("6h", "90m", "45s", "2d").
    static func humanInterval(_ ms: Double) -> String {
        let totalSeconds = Int((ms / 1000).rounded())
        if totalSeconds <= 0 { return "0s" }
        let day = 86_400, hour = 3_600, minute = 60
        if totalSeconds % day == 0 { return "\(totalSeconds / day)d" }
        if totalSeconds % hour == 0 { return "\(totalSeconds / hour)h" }
        if totalSeconds % minute == 0 { return "\(totalSeconds / minute)m" }
        return "\(totalSeconds)s"
    }

    static func date(fromMs ms: Double?) -> Date? {
        guard let ms = ms, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    static func shortDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Friendly label for a model provider id.
    static func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "amazon-bedrock": return "Amazon Bedrock"
        case "fireworks": return "Fireworks"
        case "xai": return "xAI"
        case "google", "google-vertex", "gemini": return "Google"
        case "openrouter": return "OpenRouter"
        case "groq": return "Groq"
        case "mistral": return "Mistral"
        case "deepseek": return "DeepSeek"
        default:
            // Title-case a hyphenated id as a last resort.
            return provider.split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}

enum OpenClawSettingsError: LocalizedError {
    case commandFailed(String)
    var errorDescription: String? {
        switch self {
        case .commandFailed(let detail): return detail
        }
    }
}
