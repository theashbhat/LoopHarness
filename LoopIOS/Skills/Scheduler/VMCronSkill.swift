//
//  VMCronSkill.swift
//  Loop
//
//  Agent-facing surface for VMCronManager — recurring "agents" that run a prompt
//  on the user's SSH VM via cron and push the result back as a chat. Exposes:
//   - schedule_vm_agent — create a recurring VM job (NL → cron expr by the model)
//   - list_vm_agents
//   - delete_vm_agent
//
//  Distinct from SchedulerSkill's `schedule_task` (on-device daily reminders):
//  this runs on the VM with shell + web access, on a real cron schedule, and is
//  for recurring agent *work* (digests, monitors) rather than local reminders.
//

import Foundation

final class VMCronSkill {

    static let shared = VMCronSkill()
    private init() {}

    // MARK: - System prompt fragment

    static let systemPromptFragment: String = """
You can set up recurring "VM agents" that run on the user's connected SSH VM on a schedule and push the result back as a new message in a dedicated chat thread:

- schedule_vm_agent: create a recurring job that runs a prompt on the VM (with shell + web access) on a cron schedule. Use this for ongoing work like "every 2 hours read Hacker News and send me the top stories" or "each weekday at 9am summarize my GitHub notifications". The result of each run is delivered as a push and appended to one evolving thread for that job.
  - title: a short label (e.g. "HN top stories").
  - prompt: the full instruction the VM agent runs every firing, written so it stands alone (it has no prior chat context) — e.g. "Fetch the Hacker News front page and list the top 5 stories with a one-line summary and link each."
  - cron: a standard 5-field cron expression in the VM's local time. Translate the user's words:
    - "every 2 hours" → "0 */2 * * *"
    - "every 30 minutes" → "*/30 * * * *"
    - "every day at 9am" → "0 9 * * *"
    - "every weekday at 8:30am" → "30 8 * * 1-5"
    - "every Monday at 7am" → "0 7 * * 1"
  - schedule_text: a short human-readable version of the schedule (e.g. "every 2 hours") for display.
- list_vm_agents: list the user's VM agents.
- delete_vm_agent: remove a VM agent by id (also removes it on the VM). Use list_vm_agents to find ids.

Notes:
- Requires an SSH connection (Settings → SSH) and a cloud model API key (Settings → Keys); if missing, the tool returns a clear error to relay.
- Cron times are the VM's local timezone — mention this if the user picks a wall-clock time.
- Prefer schedule_task (not this) for simple on-device reminders that don't need a VM. Use schedule_vm_agent when the work needs the internet/shell or should run server-side even when the phone is asleep.
After creating one, briefly confirm what was set and that results will arrive in a new chat (don't echo the id).
"""

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "schedule_vm_agent",
                "description": "Create a recurring agent that runs a prompt on the user's SSH VM on a cron schedule. Each run's result is pushed to the device and appended to one evolving chat thread for the job. Use for ongoing internet/shell work (digests, monitors), e.g. 'every 2 hours read Hacker News and send the top stories'.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Short, user-facing label for the job (e.g. 'HN top stories')."
                        ],
                        "prompt": [
                            "type": "string",
                            "description": "The full instruction the VM agent runs on every firing. Write it to stand alone (no prior chat context). E.g. 'Fetch the Hacker News front page and list the top 5 stories with a one-line summary and a link.'"
                        ],
                        "cron": [
                            "type": "string",
                            "description": "Standard 5-field cron expression in the VM's local time. Examples: '0 */2 * * *' (every 2 hours), '*/30 * * * *' (every 30 min), '0 9 * * *' (daily 9am), '30 8 * * 1-5' (weekdays 8:30am)."
                        ],
                        "schedule_text": [
                            "type": "string",
                            "description": "Short human-readable schedule for display (e.g. 'every 2 hours'). Optional."
                        ]
                    ],
                    "required": ["title", "prompt", "cron"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "list_vm_agents",
                "description": "List the user's recurring VM agents with their schedule and last run time.",
                "parameters": ["type": "object", "properties": [:], "required": []]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "delete_vm_agent",
                "description": "Delete a recurring VM agent by id. Also removes its cron entry and files on the VM. Use list_vm_agents to find ids.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "The id of the VM agent to delete."
                        ]
                    ],
                    "required": ["id"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "schedule_vm_agent", "list_vm_agents", "delete_vm_agent"
    ]

    func handles(functionName: String) -> Bool {
        return VMCronSkill.toolNames.contains(functionName)
    }

    // MARK: - Status text

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "schedule_vm_agent":
            if let title = call.arguments["title"] as? String, !title.isEmpty {
                return "scheduling \(title) on your VM"
            }
            return "scheduling a VM agent"
        case "list_vm_agents":
            return "looking up your VM agents"
        case "delete_vm_agent":
            return "removing VM agent"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "schedule_vm_agent":
            scheduleVMAgent(args: functionCall.arguments, completion: completion)
        case "list_vm_agents":
            listVMAgents(completion: completion)
        case "delete_vm_agent":
            deleteVMAgent(args: functionCall.arguments, completion: completion)
        default:
            completion(Self.functionMessage(
                name: functionCall.name,
                payload: ["status": "error", "error": "Unknown VM-agent tool '\(functionCall.name)'."]
            ))
        }
    }

    // MARK: - schedule_vm_agent

    private func scheduleVMAgent(args: [String: Any],
                                 completion: @escaping (MessageStruct) -> Void) {
        guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let prompt = (args["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty,
              let cron = (args["cron"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !cron.isEmpty else {
            completion(Self.functionMessage(
                name: "schedule_vm_agent",
                payload: ["status": "error", "error": "Missing arguments: title, prompt, cron are required."]
            ))
            return
        }
        let scheduleText = (args["schedule_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        Task {
            let result = await VMCronManager.shared.create(
                title: title, prompt: prompt, cronExpr: cron, humanSchedule: scheduleText)
            switch result {
            case .success(let job):
                completion(Self.functionMessage(
                    name: "schedule_vm_agent",
                    payload: [
                        "status": "success",
                        "id": job.id,
                        "title": job.title,
                        "schedule": job.humanSchedule,
                        "cron": job.cronExpr,
                        "message": "Scheduled '\(job.title)' on your VM — \(job.humanSchedule). Results will arrive in a new chat."
                    ]
                ))
            case .failure(let reason):
                completion(Self.functionMessage(
                    name: "schedule_vm_agent",
                    payload: ["status": "error", "error": reason]
                ))
            }
        }
    }

    // MARK: - list_vm_agents

    private func listVMAgents(completion: @escaping (MessageStruct) -> Void) {
        let jobs = VMCronManager.shared.list()
        let iso = ISO8601DateFormatter()
        let entries: [[String: Any]] = jobs.map { job in
            var e: [String: Any] = [
                "id": job.id,
                "title": job.title,
                "schedule": job.humanSchedule,
                "cron": job.cronExpr,
                "prompt_preview": String(job.prompt.prefix(80)),
            ]
            if let last = job.lastRunAt { e["last_run_at"] = iso.string(from: last) }
            return e
        }
        completion(Self.functionMessage(
            name: "list_vm_agents",
            payload: ["count": entries.count, "agents": entries]
        ))
    }

    // MARK: - delete_vm_agent

    private func deleteVMAgent(args: [String: Any],
                               completion: @escaping (MessageStruct) -> Void) {
        guard let id = (args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            completion(Self.functionMessage(
                name: "delete_vm_agent",
                payload: ["status": "error", "error": "Missing argument: id."]
            ))
            return
        }
        Task {
            if let title = await VMCronManager.shared.delete(id: id) {
                completion(Self.functionMessage(
                    name: "delete_vm_agent",
                    payload: ["status": "success", "id": id, "title": title, "message": "Deleted '\(title)'."]
                ))
            } else {
                completion(Self.functionMessage(
                    name: "delete_vm_agent",
                    payload: ["status": "not_found", "id": id]
                ))
            }
        }
    }

    // MARK: - Helpers

    private static func functionMessage(name: String, payload: Any) -> MessageStruct {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            json = "{}"
        }
        return MessageStruct(role: "function", content: json, name: name)
    }
}
