//
//  AgentMailSkill.swift
//  Loop
//
//  AgentMail (agentmail.to) integration. Reads the API key from KeyStore
//  (Settings → Keys → AgentMail) and talks to the AgentMail REST API through
//  AgentMailClient. Mirrors GoogleGmailSkill's shape: one `agent_mail` tool
//  with an `action` selector, structured JSON responses.
//
//  The headline capability is `send_message` with attachments: the model can
//  attach the file Loop just generated (a PDF, image, or story) by setting
//  `attach_latest: true` — the skill resolves the newest matching file in the
//  workspace and base64-inlines it for AgentMail. Explicit workspace paths are
//  also supported via `attachment_paths`.
//

import Foundation

final class AgentMailSkill {
    static let shared = AgentMailSkill()

    /// Per-attachment byte cap. base64 inflates by ~33%, so a 20MB file lands
    /// around 27MB of JSON — generous for a PDF/image without risking OOM.
    private static let maxAttachmentBytes = 20 * 1024 * 1024

    /// Resolved sender inbox id, cached for the session so we don't re-list /
    /// re-create on every send. Guarded by `lock`.
    private var cachedInboxId: String?
    private let lock = NSLock()

    private init() {}

    // MARK: - System prompt

    static let systemPromptFragment: String = """
You can send and read email on the user's behalf through AgentMail (agentmail.to) via the `agent_mail` tool. Mail is sent from the user's own AgentMail inbox (e.g. loop_email@agentmail.to).
- agent_mail (action: "send_message"): send an email. Params: to (required — address or array of addresses), subject, text (the body), cc (optional), html (optional). To attach a file: set attach_latest=true to attach the most recently generated file, optionally with attach_kind ("pdf", "image", "story", or "file") to disambiguate; or pass attachment_paths (array of workspace-relative paths like "pdfs/report.pdf").
- agent_mail (action: "list_messages"): list recent messages in the inbox. Params: limit (default 20, max 100).
- agent_mail (action: "get_message"): read one message. Params: message_id (required).
- agent_mail (action: "list_inboxes"): list the AgentMail inboxes available to this key.

Workflow tips:
- To email a PDF/image/story you just created for the user, call send_message with attach_latest=true and attach_kind set to the matching type. The file must have finished generating first — if a generation is still in progress, wait for it to appear before sending.
- When the user says "email me X", default the recipient to their own address if they've given it; otherwise ask once.
- If a tool returns {"error":"agentmail_not_connected"}, tell the user to paste their AgentMail API key in Settings → Keys → AgentMail. Don't retry until they have.
"""

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "agent_mail",
                "description": "Send and read email via the user's AgentMail (agentmail.to) inbox. Supports sending with attachments — including the file Loop just generated.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["send_message", "list_messages", "get_message", "list_inboxes"],
                            "description": "The AgentMail action to perform."
                        ],
                        "to": [
                            "type": ["string", "array"],
                            "items": ["type": "string"],
                            "description": "Recipient address or addresses (for send_message)."
                        ],
                        "cc": [
                            "type": ["string", "array"],
                            "items": ["type": "string"],
                            "description": "CC address or addresses (for send_message, optional)."
                        ],
                        "subject": [
                            "type": "string",
                            "description": "Email subject (for send_message)."
                        ],
                        "text": [
                            "type": "string",
                            "description": "Plain-text body of the email (for send_message)."
                        ],
                        "html": [
                            "type": "string",
                            "description": "Optional HTML body (for send_message)."
                        ],
                        "attach_latest": [
                            "type": "boolean",
                            "description": "If true, attach the most recently generated file in the workspace (for send_message)."
                        ],
                        "attach_kind": [
                            "type": "string",
                            "enum": ["pdf", "image", "story", "file"],
                            "description": "Which kind of recently generated file to attach when attach_latest is true. Omit to attach the newest of any kind."
                        ],
                        "attachment_paths": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Explicit workspace-relative file paths to attach (e.g. \"pdfs/report.pdf\")."
                        ],
                        "message_id": [
                            "type": "string",
                            "description": "Message id (for get_message)."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Max messages to return for list_messages. Default 20, max 100."
                        ],
                        "inbox": [
                            "type": "string",
                            "description": "Optional inbox id/address to operate on. Defaults to the configured or first inbox."
                        ]
                    ],
                    "required": ["action"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = ["agent_mail"]

    func handles(functionName: String) -> Bool {
        return AgentMailSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        guard call.name == "agent_mail" else { return nil }
        switch call.arguments["action"] as? String ?? "" {
        case "send_message":  return "sending email"
        case "list_messages": return "reading inbox"
        case "get_message":   return "reading email"
        case "list_inboxes":  return "listing inboxes"
        default:              return "accessing AgentMail"
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        let args = functionCall.arguments
        guard let action = args["action"] as? String, !action.isEmpty else {
            completion(missingArgs(expected: "action")); return
        }
        let explicitInbox = (args["inbox"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch action {
        case "list_inboxes":
            AgentMailClient.shared.listInboxes { [self] result in
                completion(map(result))
            }

        case "list_messages":
            resolveInbox(explicit: explicitInbox) { [self] inboxResult in
                switch inboxResult {
                case .failure(let err): completion(errorMessage(err))
                case .success(let inboxId):
                    let limit = min(max(intArg(args["limit"]) ?? 20, 1), 100)
                    AgentMailClient.shared.listMessages(inboxId: inboxId, limit: limit) { result in
                        completion(self.map(result))
                    }
                }
            }

        case "get_message":
            guard let messageId = (args["message_id"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !messageId.isEmpty else {
                completion(missingArgs(expected: "message_id")); return
            }
            resolveInbox(explicit: explicitInbox) { [self] inboxResult in
                switch inboxResult {
                case .failure(let err): completion(errorMessage(err))
                case .success(let inboxId):
                    AgentMailClient.shared.getMessage(inboxId: inboxId, messageId: messageId) { result in
                        completion(self.map(result))
                    }
                }
            }

        case "send_message":
            handleSend(args: args, explicitInbox: explicitInbox, completion: completion)

        default:
            completion(functionMessage(payload: [
                "error": "unknown_action",
                "hint": "Valid actions: send_message, list_messages, get_message, list_inboxes"
            ]))
        }
    }

    // MARK: - Send

    private func handleSend(args: [String: Any],
                            explicitInbox: String?,
                            completion: @escaping (MessageStruct) -> Void) {
        let to = stringList(args["to"])
        guard !to.isEmpty else {
            completion(missingArgs(expected: "to")); return
        }
        let cc = stringList(args["cc"])
        let subject = args["subject"] as? String
        let text = args["text"] as? String ?? args["body"] as? String
        let html = args["html"] as? String

        // Gather attachments off-main — reading + base64-encoding a multi-MB
        // PDF shouldn't block the UI.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let attachmentResult = gatherAttachments(args: args)
            switch attachmentResult {
            case .failure(let err):
                DispatchQueue.main.async {
                    completion(functionMessage(payload: [
                        "error": "attachment_failed",
                        "hint": err.message
                    ]))
                }
            case .success(let attachments):
                resolveInbox(explicit: explicitInbox) { inboxResult in
                    switch inboxResult {
                    case .failure(let err):
                        completion(self.errorMessage(err))
                    case .success(let inboxId):
                        AgentMailClient.shared.sendMessage(
                            inboxId: inboxId,
                            to: to,
                            subject: subject,
                            text: text,
                            html: html,
                            cc: cc.isEmpty ? nil : cc,
                            attachments: attachments
                        ) { result in
                            switch result {
                            case .failure(let err):
                                completion(self.errorMessage(err))
                            case .success(let dict):
                                completion(self.functionMessage(payload: [
                                    "status": "sent",
                                    "from_inbox": inboxId,
                                    "to": to,
                                    "attachments_count": attachments.count,
                                    "message_id": dict["message_id"] as? String ?? "",
                                    "thread_id": dict["thread_id"] as? String ?? ""
                                ]))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Inbox resolution

    /// Resolve the inbox id to send/read from. Priority: explicit arg →
    /// configured AGENT_MAIL_INBOX → cached → first existing inbox → create one.
    private func resolveInbox(explicit: String?,
                              completion: @escaping (Result<String, AgentMailClient.AgentMailError>) -> Void) {
        if let explicit, !explicit.isEmpty {
            completion(.success(explicit)); return
        }
        if let configured = KeyStore.shared.value(for: .agentMailInbox)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            completion(.success(configured)); return
        }
        lock.lock(); let cached = cachedInboxId; lock.unlock()
        if let cached { completion(.success(cached)); return }

        AgentMailClient.shared.listInboxes { [self] result in
            switch result {
            case .failure(let err):
                completion(.failure(err))
            case .success(let dict):
                if let id = firstInboxId(from: dict) {
                    cache(inboxId: id); completion(.success(id)); return
                }
                // No inbox yet — create a default one.
                AgentMailClient.shared.createInbox(username: nil, displayName: "Loop") { createResult in
                    switch createResult {
                    case .failure(let err):
                        completion(.failure(err))
                    case .success(let created):
                        if let id = (created["inbox_id"] as? String) ?? (created["email"] as? String) {
                            self.cache(inboxId: id); completion(.success(id))
                        } else {
                            completion(.failure(.malformedResponse))
                        }
                    }
                }
            }
        }
    }

    private func firstInboxId(from dict: [String: Any]) -> String? {
        guard let inboxes = dict["inboxes"] as? [[String: Any]], let first = inboxes.first else {
            return nil
        }
        return (first["inbox_id"] as? String) ?? (first["email"] as? String)
    }

    private func cache(inboxId: String) {
        lock.lock(); cachedInboxId = inboxId; lock.unlock()
    }

    // MARK: - Attachment resolution

    /// Model-relayable reason an attachment couldn't be assembled (missing
    /// file, too large, bad path). Carried as a `Result` failure.
    struct AttachmentError: Error { let message: String }

    /// Build the AgentMail `attachments` array from the call args. Returns a
    /// failure message (model-relayable) if a requested file can't be found or
    /// is too large.
    private func gatherAttachments(args: [String: Any]) -> Result<[[String: Any]], AttachmentError> {
        var urls: [URL] = []

        // Explicit workspace-relative paths.
        if let paths = args["attachment_paths"] as? [String] {
            for raw in paths {
                let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { continue }
                let cleaned = path.replacingOccurrences(of: "workspace://", with: "")
                guard let url = try? Workspace.shared.resolve(cleaned) else {
                    return .failure(AttachmentError(message: "Couldn't resolve attachment path '\(raw)' inside the workspace."))
                }
                urls.append(url)
            }
        }

        // Newest generated file of a given kind (or any kind).
        if (args["attach_latest"] as? Bool) == true {
            let kind = (args["attach_kind"] as? String)?.lowercased()
            if let url = latestGeneratedFile(kind: kind) {
                urls.append(url)
            } else {
                let what = kind.map { "\($0) " } ?? ""
                return .failure(AttachmentError(message: "No recently generated \(what)file was found to attach. If a file is still generating, wait for it to finish, then try again."))
            }
        }

        guard !urls.isEmpty else { return .success([]) }

        var out: [[String: Any]] = []
        for url in urls {
            try? Workspace.shared.ensureDownloaded(url)
            guard let data = try? Data(contentsOf: url) else {
                return .failure(AttachmentError(message: "Couldn't read the attachment at '\(url.lastPathComponent)'."))
            }
            guard data.count <= AgentMailSkill.maxAttachmentBytes else {
                let mb = data.count / (1024 * 1024)
                return .failure(AttachmentError(message: "'\(url.lastPathComponent)' is \(mb)MB — over the \(AgentMailSkill.maxAttachmentBytes / (1024 * 1024))MB attachment limit."))
            }
            out.append([
                "filename": url.lastPathComponent,
                "content_type": contentType(for: url),
                "content": data.base64EncodedString()
            ])
        }
        return .success(out)
    }

    /// Find the most recently modified file produced by a generation skill.
    /// Maps each kind to its on-disk home; `nil` kind searches them all and
    /// returns the globally newest.
    private func latestGeneratedFile(kind: String?) -> URL? {
        let root = Workspace.shared.rootURL
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first

        // (directory, predicate the filename must satisfy)
        var sources: [(dir: URL, accept: (String) -> Bool)] = []
        func addPDF()   { sources.append((root.appendingPathComponent("pdfs", isDirectory: true),
                                          { $0.hasSuffix(".pdf") })) }
        func addImage() { sources.append((root.appendingPathComponent("images", isDirectory: true),
                                          { $0.hasSuffix(".png") || $0.hasSuffix(".jpg") || $0.hasSuffix(".jpeg") })) }
        func addStory() { if let docs { sources.append((docs.appendingPathComponent("Stories", isDirectory: true),
                                          { $0.hasSuffix(".html") })) } }
        func addFile()  { sources.append((root.appendingPathComponent("attachments", isDirectory: true),
                                          { _ in true })) }

        switch kind {
        case "pdf":   addPDF()
        case "image": addImage()
        case "story": addStory()
        case "file":  addFile()
        default:      addPDF(); addImage(); addStory(); addFile()
        }

        var newest: (url: URL, date: Date)?
        let fm = FileManager.default
        for source in sources {
            guard let entries = try? fm.contentsOfDirectory(
                at: source.dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                let name = entry.lastPathComponent
                // Skip generated thumbnails (e.g. PDF "<name>.thumb.png").
                if name.contains(".thumb.") { continue }
                guard source.accept(name) else { continue }
                let mod = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if newest == nil || mod > newest!.date {
                    newest = (entry, mod)
                }
            }
        }
        return newest?.url
    }

    private func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf":            return "application/pdf"
        case "png":            return "image/png"
        case "jpg", "jpeg":    return "image/jpeg"
        case "gif":            return "image/gif"
        case "html", "htm":    return "text/html"
        case "md", "markdown": return "text/markdown"
        case "txt", "log":     return "text/plain"
        case "csv":            return "text/csv"
        case "json":           return "application/json"
        case "zip":            return "application/zip"
        default:               return "application/octet-stream"
        }
    }

    // MARK: - Helpers

    /// Map a client Result into a function-role MessageStruct.
    private func map(_ result: Result<[String: Any], AgentMailClient.AgentMailError>) -> MessageStruct {
        switch result {
        case .failure(let err): return errorMessage(err)
        case .success(let dict): return functionMessage(payload: dict)
        }
    }

    private func errorMessage(_ error: AgentMailClient.AgentMailError) -> MessageStruct {
        return functionMessage(payload: ["error": error.code, "hint": error.hint])
    }

    private func functionMessage(payload: Any) -> MessageStruct {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            json = "{}"
        }
        return MessageStruct(role: "function", content: json, name: "agent_mail")
    }

    private func missingArgs(expected: String) -> MessageStruct {
        return MessageStruct(role: "assistant",
                             content: "I need \(expected) to call agent_mail. Please provide it.")
    }

    /// Accept a single string or an array of strings for to/cc fields.
    private func stringList(_ value: Any?) -> [String] {
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let arr = value as? [String] {
            return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let arr = value as? [Any] {
            return arr.compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        return []
    }

    private func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }
}
