//
//  GoogleGmailSkill.swift
//  Loop
//
//  Gmail integration. Reads the user's access token from KeyStore
//  (Settings → Keys → Google Workspace Access Token) and talks directly to
//  the Gmail v1 API. Mirrors SlackSkill's shape: static tool schemas,
//  a dispatch method, and structured JSON responses.
//

import Foundation

struct GoogleGmailSkill {
    static let shared = GoogleGmailSkill()

    // MARK: - System prompt

    static let systemPromptFragment: String = """
You can access the user's Gmail through these tools:
- google_gmail (action: "search_messages"): search for messages. Params: q (Gmail search query, required), maxResults (default 10, max 50).
- google_gmail (action: "get_message"): get a specific message by id. Params: id (required), format (optional: "full", "metadata", "minimal" — default "full").
- google_gmail (action: "send_message"): send an email. Params: to (required), subject (required), body (required), attachments (optional, not supported in v1).

Workflow tips:
- Use Gmail search syntax in q: "from:alice@example.com", "subject:meeting", "is:unread", "newer_than:2d", etc.
- Message ids come from search_messages results — chain calls when needed.
- If a tool returns {"error":"google_not_connected"}, tell the user to paste their Google access token in Settings → Keys → Google Workspace Access Token.
- If a tool returns {"error":"token_expired"}, tell the user their Google token has expired and they need to refresh it.
"""

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "google_gmail",
                "description": "Interact with Gmail. Specify an action and its parameters.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["search_messages", "get_message", "send_message"],
                            "description": "The Gmail action to perform."
                        ],
                        "q": [
                            "type": "string",
                            "description": "Gmail search query (for search_messages). Supports Gmail search syntax."
                        ],
                        "maxResults": [
                            "type": "integer",
                            "description": "Max messages to return for search_messages. Default 10, max 50."
                        ],
                        "id": [
                            "type": "string",
                            "description": "Message id (for get_message)."
                        ],
                        "format": [
                            "type": "string",
                            "enum": ["full", "metadata", "minimal"],
                            "description": "Response format for get_message. Default 'full'."
                        ],
                        "to": [
                            "type": "string",
                            "description": "Recipient email address (for send_message)."
                        ],
                        "subject": [
                            "type": "string",
                            "description": "Email subject (for send_message)."
                        ],
                        "body": [
                            "type": "string",
                            "description": "Email body text (for send_message)."
                        ]
                    ],
                    "required": ["action"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = ["google_gmail"]

    func handles(functionName: String) -> Bool {
        return GoogleGmailSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        guard call.name == "google_gmail" else { return nil }
        let action = call.arguments["action"] as? String ?? ""
        switch action {
        case "search_messages": return "searching Gmail"
        case "get_message":     return "reading Gmail message"
        case "send_message":    return "sending email"
        default:                return "accessing Gmail"
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        let args = functionCall.arguments
        guard let action = args["action"] as? String, !action.isEmpty else {
            completion(missingArgs(expected: "action")); return
        }
        switch action {
        case "search_messages":
            guard let q = args["q"] as? String, !q.isEmpty else {
                completion(missingArgs(expected: "q")); return
            }
            searchMessages(q: q, maxResults: intArg(args["maxResults"]), completion: completion)
        case "get_message":
            guard let id = args["id"] as? String, !id.isEmpty else {
                completion(missingArgs(expected: "id")); return
            }
            getMessage(id: id, format: args["format"] as? String, completion: completion)
        case "send_message":
            guard let to = args["to"] as? String, !to.isEmpty,
                  let subject = args["subject"] as? String,
                  let body = args["body"] as? String else {
                completion(missingArgs(expected: "to, subject, body")); return
            }
            sendMessage(to: to, subject: subject, body: body, completion: completion)
        default:
            completion(functionMessage(payload: [
                "error": "unknown_action",
                "hint": "Valid actions: search_messages, get_message, send_message"
            ]))
        }
    }

    // MARK: - Actions

    private func searchMessages(q: String,
                                maxResults: Int?,
                                completion: @escaping (MessageStruct) -> Void) {
        let count = min(max(maxResults ?? 10, 1), 50)
        let queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "maxResults", value: "\(count)")
        ]
        GoogleWorkspaceClient.shared.get(
            url: "https://www.googleapis.com/gmail/v1/users/me/messages",
            queryItems: queryItems
        ) { [self] result in
            switch result {
            case .failure(let err):
                completion(errorMessage(error: err))
            case .success(let dict):
                let messages = dict["messages"] as? [[String: Any]] ?? []
                let resultSizeEstimate = dict["resultSizeEstimate"] as? Int ?? 0
                completion(functionMessage(payload: [
                    "messages": messages,
                    "resultSizeEstimate": resultSizeEstimate
                ]))
            }
        }
    }

    private func getMessage(id: String,
                            format: String?,
                            completion: @escaping (MessageStruct) -> Void) {
        let fmt = format ?? "full"
        let queryItems = [URLQueryItem(name: "format", value: fmt)]
        GoogleWorkspaceClient.shared.get(
            url: "https://www.googleapis.com/gmail/v1/users/me/messages/\(id)",
            queryItems: queryItems
        ) { [self] result in
            switch result {
            case .failure(let err):
                completion(errorMessage(error: err))
            case .success(let dict):
                // Trim to useful fields for the model
                var trimmed: [String: Any] = [
                    "id": dict["id"] as? String ?? "",
                    "threadId": dict["threadId"] as? String ?? "",
                    "snippet": dict["snippet"] as? String ?? ""
                ]
                if let payload = dict["payload"] as? [String: Any] {
                    if let headers = payload["headers"] as? [[String: Any]] {
                        let relevant = headers.filter { h in
                            let name = (h["name"] as? String ?? "").lowercased()
                            return ["from", "to", "subject", "date", "cc"].contains(name)
                        }
                        trimmed["headers"] = relevant
                    }
                    // Extract plain text body if available
                    if let body = payload["body"] as? [String: Any],
                       let data = body["data"] as? String {
                        trimmed["body"] = decodeBase64URL(data)
                    } else if let parts = payload["parts"] as? [[String: Any]] {
                        for part in parts {
                            let mime = part["mimeType"] as? String ?? ""
                            if mime == "text/plain",
                               let body = part["body"] as? [String: Any],
                               let data = body["data"] as? String {
                                trimmed["body"] = decodeBase64URL(data)
                                break
                            }
                        }
                    }
                }
                if let labels = dict["labelIds"] as? [String] {
                    trimmed["labelIds"] = labels
                }
                completion(functionMessage(payload: trimmed))
            }
        }
    }

    private func sendMessage(to: String,
                             subject: String,
                             body: String,
                             completion: @escaping (MessageStruct) -> Void) {
        // Construct a simple RFC 2822 message
        let message = [
            "To: \(to)",
            "Subject: \(subject)",
            "Content-Type: text/plain; charset=utf-8",
            "",
            body
        ].joined(separator: "\r\n")

        guard let messageData = message.data(using: .utf8) else {
            completion(functionMessage(payload: [
                "error": "encoding_failed",
                "hint": "Failed to encode the email message."
            ]))
            return
        }

        // Gmail API expects base64url-encoded raw message
        let encoded = messageData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let requestBody: [String: Any] = ["raw": encoded]
        GoogleWorkspaceClient.shared.post(
            url: "https://www.googleapis.com/gmail/v1/users/me/messages/send",
            body: requestBody
        ) { [self] result in
            switch result {
            case .failure(let err):
                completion(errorMessage(error: err))
            case .success(let dict):
                completion(functionMessage(payload: [
                    "status": "sent",
                    "id": dict["id"] as? String ?? "",
                    "threadId": dict["threadId"] as? String ?? ""
                ]))
            }
        }
    }

    // MARK: - Helpers

    private func decodeBase64URL(_ input: String) -> String {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64) else { return input }
        return String(data: data, encoding: .utf8) ?? input
    }

    private func errorMessage(error: GoogleWorkspaceClient.GoogleError) -> MessageStruct {
        let payload: [String: Any] = [
            "error": error.code,
            "hint": error.hint
        ]
        return functionMessage(payload: payload)
    }

    private func functionMessage(payload: Any) -> MessageStruct {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            json = "{}"
        }
        return MessageStruct(role: "function", content: json, name: "google_gmail")
    }

    private func missingArgs(expected: String) -> MessageStruct {
        return MessageStruct(
            role: "assistant",
            content: "I need \(expected) to call google_gmail. Please provide them."
        )
    }

    private func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }
}
