//
//  BackgroundTurnRunner.swift
//  Loop
//
//  Self-contained background handoff: when the user backgrounds the app mid-turn,
//  we run the turn on their SSH VM as a single detached one-shot — NO server,
//  tunnel, port, or deployed binary. One SSH command writes a tiny Python script
//  + the request JSON to `~/.loop/` and launches `python3` detached (`nohup`).
//  The script calls the model directly and POSTs the reply to the push backend,
//  which alerts the device.
//
//  This replaces the earlier "deploy + run a Go HTTP runner" path, whose
//  multi-handshake install was too slow to finish before the app suspended. The
//  one-shot needs only `python3` (stdlib only) on the VM and a single SSH
//  round-trip, so it reliably fits the background-handoff window.
//
//  It also uses the user's *selected* model/provider (not a hardcoded one), so
//  the reply is closer to what local inference would have produced.
//

import Foundation
import os

final class BackgroundTurnRunner {

    static let shared = BackgroundTurnRunner()
    private init() {}

    private static let log = Logger(subsystem: "com.bhat.intel", category: "handoff")
    // File layout + model/key selection + the Python agent loop are shared with
    // the recurring VM-cron path; see `VMAgentRuntime`.
    private static let remoteDir = VMAgentRuntime.remoteDir
    private static let pushURL = VMAgentRuntime.pushURL

    enum RunResult {
        /// Launched successfully; `model` is the display name that will run on the VM.
        case success(model: String)
        case failure(String)
    }

    /// Launch the turn on the VM. Returns `.success` once the one-shot is
    /// confirmed launched (it pushes on its own when the model replies), or
    /// `.failure(reason)` with a user-surfaceable message.
    func run(messages: [[String: String]],
             conversationId: String,
             userId: String,
             turnId: String,
             on config: SSHConfig) async -> RunResult {
        guard config.isConfigured else { return .failure("No SSH connection selected.") }
        guard !userId.isEmpty else { return .failure("No device push id yet — open the app once with notifications enabled.") }
        guard let pc = VMAgentRuntime.providerConfig() else {
            return .failure("No cloud model API key set (add one in Settings → Keys).")
        }

        let cfg: [String: Any] = [
            "provider": pc.provider,
            "model": pc.modelID,
            "api_key": pc.key,
            "messages": messages,
            "user_id": userId,
            "conversation_id": conversationId,
            "turn_id": turnId,
            "push_url": Self.pushURL,
            "result_path": "\(Self.remoteDir)/turns/\(turnId).json",
            // All the user's cloud keys (by env-var name), so the runner's tools
            // can use any connected service dynamically — no per-tool porting.
            "env": VMAgentRuntime.exportableKeys(),
        ]
        guard let cfgData = try? JSONSerialization.data(withJSONObject: cfg) else {
            return .failure("Could not encode the request.")
        }

        let cfgB64 = cfgData.base64EncodedString()
        let scriptB64 = Data(VMAgentRuntime.pythonScript.utf8).base64EncodedString()

        // One round-trip: ensure python3, write script + request synchronously,
        // then launch python detached so it outlives the SSH channel.
        let cmd = """
        command -v python3 >/dev/null 2>&1 || { echo LOOP_NOPYTHON; exit 0; }
        mkdir -p \(Self.remoteDir)/turns && printf %s '\(scriptB64)' | base64 -d > \(Self.remoteDir)/oneshot.py && printf %s '\(cfgB64)' | base64 -d > \(Self.remoteDir)/req-\(turnId).json || { echo LOOP_WRITEFAIL; exit 0; }
        cd \(Self.remoteDir) && nohup python3 oneshot.py req-\(turnId).json >>oneshot.log 2>&1 </dev/null & echo LOOP_OK
        """

        do {
            let r = try await SSHSkill.shared.runCommand(cmd, on: config, timeout: 30)
            if r.stdout.contains("LOOP_NOPYTHON") { return .failure("python3 isn't installed on the VM.") }
            if r.stdout.contains("LOOP_WRITEFAIL") { return .failure("Couldn't write the request on the VM: \(r.stderr)") }
            guard r.exitCode == 0 else {
                return .failure(r.stderr.isEmpty ? "SSH command failed (exit \(r.exitCode))" : r.stderr)
            }
            guard r.stdout.contains("LOOP_OK") else {
                return .failure("Launch not confirmed (\(r.stdout.prefix(120)))")
            }
            Self.log.info("background turn launched on VM (\(pc.provider, privacy: .public)/\(pc.modelID, privacy: .public)): \(turnId, privacy: .public)")
            return .success(model: pc.label)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

}
