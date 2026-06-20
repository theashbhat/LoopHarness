//
//  VMCronManager.swift
//  Loop
//
//  Recurring "VM agents": a prompt that runs on the user's SSH VM on a cron
//  schedule and pings the phone with the result. Each job is the
//  `BackgroundTurnRunner` one-shot made repeatable:
//
//   - We pin one local conversation (the evolving thread) to the job.
//   - We write `run.py` (the shared `VMAgentRuntime` agent loop) + a long-lived
//     `req.json` (cron mode) under `~/.loop/cron/<jobId>/` over SSH.
//   - We install a marker-tagged crontab line so we can list/remove only ours.
//   - On each firing, `run.py` mints a fresh `turn_id`, runs the prompt, appends
//     `results.ndjson`, and POSTs a `runner_turn` push. The device's
//     `RunnerTurnApplier` appends the reply into the pinned thread exactly-once
//     (push primary; `VMCronPoller` SSH-reads `results.ndjson` as a backstop).
//
//  Removal strips the crontab line and `rm -rf`s the job dir on the VM. The
//  conversation thread is kept as history.
//

import Foundation
import os

// MARK: - Model

/// A scheduled VM agent. Persisted locally (UserDefaults); the crontab on the VM
/// is the source of truth for *firing*, this mirror powers the UI + the poller.
struct VMCronJob: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var prompt: String
    /// Standard 5-field cron expression (VM-local time), e.g. "0 */2 * * *".
    var cronExpr: String
    /// Human-readable schedule for display, e.g. "every 2 hours".
    var humanSchedule: String
    /// The pinned local conversation this job's runs append to.
    var conversationId: String
    /// Which SSH connection the job was created on (so removal targets the right VM).
    var sshConfigID: String
    var createdAt: Date
    var lastRunAt: Date?
    /// Number of `results.ndjson` lines already applied to the thread (poller cursor).
    var resultsCursor: Int
}

// MARK: - Store

/// Tiny UserDefaults-backed registry of VM cron jobs (JSON list).
final class VMCronStore {
    static let shared = VMCronStore()
    private init() {}

    private let key = "loop.vmcron.jobs.v1"
    private let defaults = UserDefaults.standard
    private let lock = NSLock()

    func all() -> [VMCronJob] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    func upsert(_ job: VMCronJob) {
        lock.lock(); defer { lock.unlock() }
        var jobs = load()
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job }
        else { jobs.append(job) }
        save(jobs)
    }

    @discardableResult
    func remove(id: String) -> VMCronJob? {
        lock.lock(); defer { lock.unlock() }
        var jobs = load()
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = jobs.remove(at: i)
        save(jobs)
        return removed
    }

    private func load() -> [VMCronJob] {
        guard let data = defaults.data(forKey: key),
              let jobs = try? JSONDecoder().decode([VMCronJob].self, from: data) else { return [] }
        return jobs
    }

    private func save(_ jobs: [VMCronJob]) {
        if let data = try? JSONEncoder().encode(jobs) { defaults.set(data, forKey: key) }
    }
}

// MARK: - Manager

final class VMCronManager {

    static let shared = VMCronManager()
    private init() {}

    private static let log = Logger(subsystem: "com.bhat.intel", category: "vmcron")

    enum CreateResult {
        case success(VMCronJob)
        case failure(String)
    }

    // MARK: Create

    /// Write the script + request to the VM, install the crontab line, pin a
    /// conversation, and persist the job. `cronExpr` is a standard 5-field cron
    /// expression (VM-local time). `humanSchedule` is for display only.
    func create(title: String,
                prompt: String,
                cronExpr: String,
                humanSchedule: String) async -> CreateResult {
        let config = SSHConfigStore.shared.config
        guard config.isConfigured else {
            return .failure("No SSH connection selected. Add one in Settings → SSH first.")
        }
        guard let pc = VMAgentRuntime.providerConfig() else {
            return .failure("No cloud model API key set (add one in Settings → Keys).")
        }
        let userId = LoopRunnerClient.deviceUserId
        guard !userId.isEmpty else {
            return .failure("No device push id yet — open the app once with notifications enabled.")
        }
        guard let cleanCron = Self.sanitizeCron(cronExpr) else {
            return .failure("Invalid cron expression: '\(cronExpr)'. Expected 5 fields, e.g. '0 */2 * * *'.")
        }

        let jobId = UUID().uuidString

        // Pin the evolving thread up front so the first run has somewhere to land.
        let conversation = await MainActor.run {
            SimpleConversationManager.shared.createConversation(title: title)
        }

        // Request consumed by run.py each firing. Paths are RELATIVE — the crontab
        // line `cd`s into the job dir, so Python opens them against that cwd
        // (Python's open() doesn't expand `$HOME`).
        let cfg: [String: Any] = [
            "cron": true,
            "job_id": jobId,
            "provider": pc.provider,
            "model": pc.modelID,
            "api_key": pc.key,
            "messages": [["role": "user", "content": prompt]],
            "user_id": userId,
            "conversation_id": conversation.id,
            "title": title,
            "push_url": VMAgentRuntime.pushURL,
            "results_path": "results.ndjson",
            "env": VMAgentRuntime.exportableKeys(),
        ]
        guard let cfgData = try? JSONSerialization.data(withJSONObject: cfg) else {
            return .failure("Could not encode the request.")
        }

        let dir = "$HOME/.loop/cron/\(jobId)"
        let cfgB64 = cfgData.base64EncodedString()
        let scriptB64 = Data(VMAgentRuntime.pythonScript.utf8).base64EncodedString()
        // `$HOME` stays single-quoted so the OUTER shell leaves it literal; cron's
        // /bin/sh expands it at fire time. The `# loop-cron <id>` marker lets us
        // find and remove exactly this line later.
        let cronLine = "\(cleanCron) cd $HOME/.loop/cron/\(jobId) && /usr/bin/env python3 run.py req.json >> run.log 2>&1  # loop-cron \(jobId)"

        let cmd = """
        command -v python3 >/dev/null 2>&1 || { echo LOOP_NOPYTHON; exit 0; }
        command -v crontab >/dev/null 2>&1 || { echo LOOP_NOCRON; exit 0; }
        mkdir -p \(dir) && printf %s '\(scriptB64)' | base64 -d > \(dir)/run.py && printf %s '\(cfgB64)' | base64 -d > \(dir)/req.json && chmod 600 \(dir)/req.json || { echo LOOP_WRITEFAIL; exit 0; }
        ( crontab -l 2>/dev/null | grep -v 'loop-cron \(jobId)'; echo '\(cronLine)' ) | crontab - || { echo LOOP_CRONFAIL; exit 0; }
        echo LOOP_OK
        """

        do {
            let r = try await SSHSkill.shared.runCommand(cmd, on: config, timeout: 30)
            if r.stdout.contains("LOOP_NOPYTHON") { return .failure("python3 isn't installed on the VM.") }
            if r.stdout.contains("LOOP_NOCRON") { return .failure("cron (crontab) isn't available on the VM.") }
            if r.stdout.contains("LOOP_WRITEFAIL") { return .failure("Couldn't write the job on the VM: \(r.stderr)") }
            if r.stdout.contains("LOOP_CRONFAIL") { return .failure("Couldn't install the cron schedule: \(r.stderr)") }
            guard r.stdout.contains("LOOP_OK") else {
                return .failure(r.stderr.isEmpty ? "Setup not confirmed (\(r.stdout.prefix(120)))" : r.stderr)
            }

            let job = VMCronJob(
                id: jobId,
                title: title,
                prompt: prompt,
                cronExpr: cleanCron,
                humanSchedule: humanSchedule.isEmpty ? cleanCron : humanSchedule,
                conversationId: conversation.id,
                sshConfigID: config.id.uuidString,
                createdAt: Date(),
                lastRunAt: nil,
                resultsCursor: 0
            )
            VMCronStore.shared.upsert(job)
            Self.log.info("created VM cron \(jobId, privacy: .public) (\(cleanCron, privacy: .public))")
            return .success(job)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: Delete

    /// Remove the crontab line + job dir on the VM and drop the local record.
    /// The conversation thread is kept. Returns nil if the job is unknown.
    @discardableResult
    func delete(id: String) async -> String? {
        guard let job = VMCronStore.shared.all().first(where: { $0.id == id }) else { return nil }
        // Prefer the connection the job was created on; fall back to the active one.
        let config = SSHConfigStore.shared.connection(id: UUID(uuidString: job.sshConfigID) ?? UUID())
            ?? SSHConfigStore.shared.config
        let cmd = """
        if command -v crontab >/dev/null 2>&1; then crontab -l 2>/dev/null | grep -v 'loop-cron \(job.id)' | crontab - 2>/dev/null; fi
        rm -rf $HOME/.loop/cron/\(job.id)
        echo LOOP_OK
        """
        if config.isConfigured {
            _ = try? await SSHSkill.shared.runCommand(cmd, on: config, timeout: 20)
        }
        VMCronStore.shared.remove(id: id)
        Self.log.info("deleted VM cron \(job.id, privacy: .public)")
        return job.title
    }

    // MARK: List

    func list() -> [VMCronJob] { VMCronStore.shared.all() }

    // MARK: Poller backstop

    /// One result line read back from a job's `results.ndjson`.
    struct ResultLine {
        let turnId: String
        let conversationId: String
        let text: String
        let error: String
    }

    /// SSH-read `results.ndjson` lines past the job's stored cursor. Returns the
    /// new lines plus the updated total line count (the new cursor). Used by
    /// `VMCronPoller` so runs that fired while a push was missed still land.
    func fetchNewResults(for job: VMCronJob) async -> (lines: [ResultLine], newCursor: Int)? {
        let config = SSHConfigStore.shared.connection(id: UUID(uuidString: job.sshConfigID) ?? UUID())
            ?? SSHConfigStore.shared.config
        guard config.isConfigured else { return nil }
        let cmd = "cat $HOME/.loop/cron/\(job.id)/results.ndjson 2>/dev/null | base64"
        guard let r = try? await SSHSkill.shared.runCommand(cmd, on: config, timeout: 20),
              r.exitCode == 0 else { return nil }
        let b64 = r.stdout.replacingOccurrences(of: "\n", with: "")
        guard !b64.isEmpty,
              let data = Data(base64Encoded: b64),
              let body = String(data: data, encoding: .utf8) else {
            return ([], job.resultsCursor)
        }
        let rows = body.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let total = rows.count
        guard total > job.resultsCursor else { return ([], total) }
        let fresh = rows[job.resultsCursor..<total].compactMap { Self.parseLine($0) }
        return (fresh, total)
    }

    private static func parseLine(_ line: String) -> ResultLine? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ResultLine(
            turnId: obj["turn_id"] as? String ?? "",
            conversationId: obj["conversation_id"] as? String ?? "",
            text: obj["text"] as? String ?? "",
            error: obj["error"] as? String ?? ""
        )
    }

    // MARK: Helpers

    /// Translate a manual-form schedule into (cronExpr, humanText). Accepts a
    /// shorthand interval ("30m", "2h", "1d") or a raw 5-field cron expression.
    static func parseSchedule(_ raw: String) -> (cron: String, human: String)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        // Raw cron expression (whitespace-separated fields).
        if s.contains(" ") {
            if let c = sanitizeCron(s) { return (c, c) }
            return nil
        }
        // Shorthand: <N><unit> where unit is m(inutes) / h(ours) / d(ays).
        guard let unit = s.last, "mhd".contains(unit), let n = Int(s.dropLast()), n > 0 else {
            return nil
        }
        switch unit {
        case "m": return n <= 59 ? ("*/\(n) * * * *", "every \(n) min") : nil
        case "h": return n <= 23 ? ("0 */\(n) * * *", "every \(n)h") : nil
        case "d": return n <= 31 ? ("0 9 */\(n) * *", n == 1 ? "daily 9am" : "every \(n) days 9am") : nil
        default:  return nil
        }
    }

    /// Validate + normalize a 5-field cron expression and reject anything with
    /// shell-dangerous characters (it's interpolated into an SSH command).
    static func sanitizeCron(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("'"),
              !trimmed.contains("\n"),
              !trimmed.contains("#"),
              !trimmed.contains("&") else { return nil }
        let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 5 else { return nil }
        // Each field may contain digits, * , - / only.
        let allowed = CharacterSet(charactersIn: "0123456789*,-/")
        for f in fields where f.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return nil
        }
        return fields.joined(separator: " ")
    }
}
