//
//  AgentMailClient.swift
//  Loop
//
//  Shared networking client for AgentMail (https://agentmail.to) — an email
//  API built for agents. Reads the API key from KeyStore (Settings → Keys →
//  AgentMail) and injects `Authorization: Bearer <key>` into every request.
//  Mirrors GoogleWorkspaceClient's shape: one private request helper, typed
//  errors, and a hint string per error code that skills relay to the model.
//
//  REST surface used (base https://api.agentmail.to):
//    GET  /v0/inboxes
//    POST /v0/inboxes
//    GET  /v0/inboxes/{inbox_id}/messages
//    GET  /v0/inboxes/{inbox_id}/messages/{message_id}
//    POST /v0/inboxes/{inbox_id}/messages/send
//

import Foundation

/// Thin wrapper around the AgentMail REST API. Methods return raw
/// `[String: Any]` payloads so callers (AgentMailSkill) can shape them
/// however the model wants. Foundation-only so it builds on iOS/macOS alike.
final class AgentMailClient {

    static let shared = AgentMailClient()

    static let baseURL = "https://api.agentmail.to"

    /// Dedicated session so attachment uploads don't stall on the shared
    /// session's defaults. Attachments are base64-inlined in the JSON body,
    /// so give the resource timeout some headroom for a few-MB PDF.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Errors

    enum AgentMailError: Error {
        case notConnected
        case transport
        case malformedResponse
        /// Non-2xx response. `status` is the HTTP code; `message` is the
        /// server's human-readable detail (best-effort parsed).
        case api(status: Int, message: String)

        /// One-liner the skill passes back through the `function` role so the
        /// model has something concrete to relay to the user.
        var hint: String {
            switch self {
            case .notConnected:
                return "AgentMail isn't connected. Ask the user to paste their AgentMail API key in Settings \u{2192} Keys \u{2192} AgentMail."
            case .transport:
                return "Network error talking to api.agentmail.to. Suggest retrying."
            case .malformedResponse:
                return "AgentMail returned an unexpected response shape."
            case .api(let status, _):
                return AgentMailClient.recoveryHint(forStatus: status)
            }
        }

        /// Short stable error code for the JSON payload back to the model.
        var code: String {
            switch self {
            case .notConnected:      return "agentmail_not_connected"
            case .transport:         return "agentmail_transport_failed"
            case .malformedResponse: return "agentmail_malformed_response"
            case .api(let status, _): return "agentmail_http_\(status)"
            }
        }
    }

    private static func recoveryHint(forStatus status: Int) -> String {
        switch status {
        case 401, 403:
            return "The AgentMail API key is invalid or lacks permission. Ask the user to check it in Settings \u{2192} Keys \u{2192} AgentMail."
        case 404:
            return "AgentMail resource not found. Double-check the inbox or message id."
        case 422:
            return "AgentMail rejected the request as invalid — check the recipient address and required fields."
        case 429:
            return "AgentMail rate-limited the call. Wait a moment and retry."
        default:
            return "AgentMail returned HTTP \(status). See https://docs.agentmail.to for details."
        }
    }

    // MARK: - Inboxes

    /// GET /v0/inboxes — returns the raw payload (expects an `inboxes` array).
    func listInboxes(completion: @escaping (Result<[String: Any], AgentMailError>) -> Void) {
        request(method: "GET", path: "/v0/inboxes", queryItems: nil, body: nil, completion: completion)
    }

    /// POST /v0/inboxes — create an inbox. `username`/`displayName` optional;
    /// AgentMail auto-assigns an address when `username` is nil.
    func createInbox(username: String?,
                     displayName: String?,
                     completion: @escaping (Result<[String: Any], AgentMailError>) -> Void) {
        var body: [String: Any] = [:]
        if let username, !username.isEmpty { body["username"] = username }
        if let displayName, !displayName.isEmpty { body["display_name"] = displayName }
        request(method: "POST", path: "/v0/inboxes", queryItems: nil, body: body, completion: completion)
    }

    // MARK: - Messages

    /// GET /v0/inboxes/{inbox_id}/messages
    func listMessages(inboxId: String,
                      limit: Int?,
                      completion: @escaping (Result<[String: Any], AgentMailError>) -> Void) {
        var items: [URLQueryItem] = []
        if let limit { items.append(URLQueryItem(name: "limit", value: "\(limit)")) }
        request(method: "GET",
                path: "/v0/inboxes/\(pathEscape(inboxId))/messages",
                queryItems: items.isEmpty ? nil : items,
                body: nil,
                completion: completion)
    }

    /// GET /v0/inboxes/{inbox_id}/messages/{message_id}
    func getMessage(inboxId: String,
                    messageId: String,
                    completion: @escaping (Result<[String: Any], AgentMailError>) -> Void) {
        request(method: "GET",
                path: "/v0/inboxes/\(pathEscape(inboxId))/messages/\(pathEscape(messageId))",
                queryItems: nil,
                body: nil,
                completion: completion)
    }

    /// POST /v0/inboxes/{inbox_id}/messages/send. `attachments` are already
    /// shaped per the AgentMail schema (filename / content_type / base64
    /// `content`). Pass an empty array to send a plain message.
    func sendMessage(inboxId: String,
                     to: [String],
                     subject: String?,
                     text: String?,
                     html: String?,
                     cc: [String]?,
                     attachments: [[String: Any]],
                     completion: @escaping (Result<[String: Any], AgentMailError>) -> Void) {
        var body: [String: Any] = ["to": to]
        if let subject { body["subject"] = subject }
        if let text, !text.isEmpty { body["text"] = text }
        if let html, !html.isEmpty { body["html"] = html }
        if let cc, !cc.isEmpty { body["cc"] = cc }
        if !attachments.isEmpty { body["attachments"] = attachments }
        request(method: "POST",
                path: "/v0/inboxes/\(pathEscape(inboxId))/messages/send",
                queryItems: nil,
                body: body,
                completion: completion)
    }

    // MARK: - Request plumbing

    private func request(method: String,
                         path: String,
                         queryItems: [URLQueryItem]?,
                         body: [String: Any]?,
                         completion: @escaping (Result<[String: Any], AgentMailError>) -> Void) {
        guard let key = KeyStore.shared.value(for: .agentMail),
              !key.isEmpty else {
            DispatchQueue.main.async { completion(.failure(.notConnected)) }
            return
        }
        guard var components = URLComponents(string: AgentMailClient.baseURL + path) else {
            DispatchQueue.main.async { completion(.failure(.transport)) }
            return
        }
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + queryItems
        }
        guard let url = components.url else {
            DispatchQueue.main.async { completion(.failure(.transport)) }
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let task = session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                if error != nil { completion(.failure(.transport)); return }
                guard let http = response as? HTTPURLResponse, let data else {
                    completion(.failure(.transport)); return
                }
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if (200..<300).contains(http.statusCode) {
                    completion(.success(json ?? [:]))
                } else {
                    let message = AgentMailClient.parseError(json: json, data: data, status: http.statusCode)
                    completion(.failure(.api(status: http.statusCode, message: message)))
                }
            }
        }
        task.resume()
    }

    /// Best-effort extraction of a human-readable error message from an
    /// AgentMail error body. Falls back to the raw string / status code.
    private static func parseError(json: [String: Any]?, data: Data, status: Int) -> String {
        if let message = json?["message"] as? String { return message }
        if let detail = json?["detail"] as? String { return detail }
        if let error = json?["error"] as? String { return error }
        if let error = json?["error"] as? [String: Any],
           let message = error["message"] as? String { return message }
        if let raw = String(data: data, encoding: .utf8), !raw.isEmpty, raw.count < 500 {
            return raw
        }
        return "HTTP \(status)"
    }

    /// Percent-escape a single path segment (inbox ids are email addresses,
    /// so `@` and `.` must survive but be URL-safe).
    private func pathEscape(_ segment: String) -> String {
        return segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment
    }
}
