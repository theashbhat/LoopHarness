//
//  GoogleWorkspaceClient.swift
//  Loop
//
//  Shared networking client for all Google Workspace APIs (Drive, Gmail,
//  Calendar). Reads the user's access token from KeyStore and injects
//  `Authorization: Bearer <token>` into every request. Mirrors
//  NotionClient's shape: one private request helper, typed errors, a hint
//  string per error code that skills can relay to the model.
//

import Foundation

/// Thin wrapper around Google Workspace REST APIs. Methods return raw
/// `[String: Any]` payloads so callers can shape them however the model wants.
final class GoogleWorkspaceClient {

    static let shared = GoogleWorkspaceClient()

    /// Dedicated URLSession so request/resource timeouts don't depend on the
    /// shared session config. Matches NotionClient's pattern.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Errors

    enum GoogleError: Error {
        case notConnected
        case transport
        case malformedResponse
        /// Non-2xx response. `status` is the HTTP code; `code` is Google's
        /// machine-readable error reason; `message` is their human detail.
        case api(status: Int, code: String, message: String)

        /// One-liner the skill can pass back through `function` role so the
        /// model has something concrete to relay to the user.
        var hint: String {
            switch self {
            case .notConnected:
                return "Google Workspace isn't connected. Ask the user to paste their access token in Settings \u{2192} Keys \u{2192} Google Workspace Access Token."
            case .transport:
                return "Network error talking to googleapis.com. Suggest retrying."
            case .malformedResponse:
                return "Google returned an unexpected response shape."
            case .api(let status, _, _):
                return GoogleWorkspaceClient.recoveryHint(forStatus: status)
            }
        }

        /// Short stable error code for the JSON payload back to the model.
        var code: String {
            switch self {
            case .notConnected:        return "google_not_connected"
            case .transport:           return "google_transport_failed"
            case .malformedResponse:   return "google_malformed_response"
            case .api(_, let c, _):    return c
            }
        }
    }

    private static func recoveryHint(forStatus status: Int) -> String {
        switch status {
        case 401:
            return "The Google access token is invalid or expired. Ask the user to refresh it and paste the new token in Settings \u{2192} Keys \u{2192} Google Workspace Access Token."
        case 403:
            return "The token doesn't have permission for this resource. The user may need to grant additional scopes."
        case 404:
            return "Resource not found. Double-check the id."
        case 429:
            return "Google rate-limited the call. Wait a moment and retry."
        default:
            return "Google API returned HTTP \(status). See https://developers.google.com/workspace for details."
        }
    }

    // MARK: - Public request interface

    /// Perform a GET request against a Google API endpoint.
    func get(url urlString: String,
             queryItems: [URLQueryItem]? = nil,
             completion: @escaping (Result<[String: Any], GoogleError>) -> Void) {
        request(method: "GET", urlString: urlString, queryItems: queryItems, body: nil, completion: completion)
    }

    /// Perform a POST request against a Google API endpoint.
    func post(url urlString: String,
              body: [String: Any]?,
              completion: @escaping (Result<[String: Any], GoogleError>) -> Void) {
        request(method: "POST", urlString: urlString, queryItems: nil, body: body, completion: completion)
    }

    /// Perform a POST request with raw Data body (used for MIME messages).
    func postRaw(url urlString: String,
                 data: Data,
                 contentType: String,
                 completion: @escaping (Result<[String: Any], GoogleError>) -> Void) {
        guard let token = KeyStore.shared.value(for: .googleWorkspaceAccessToken),
              !token.isEmpty else {
            DispatchQueue.main.async { completion(.failure(.notConnected)) }
            return
        }
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(.failure(.transport)) }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        let task = session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                if error != nil { completion(.failure(.transport)); return }
                guard let http = response as? HTTPURLResponse,
                      let data else { completion(.failure(.transport)); return }
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if (200..<300).contains(http.statusCode) {
                    completion(.success(json ?? [:]))
                } else {
                    let (code, message) = GoogleWorkspaceClient.parseError(json: json, status: http.statusCode)
                    completion(.failure(.api(status: http.statusCode, code: code, message: message)))
                }
            }
        }
        task.resume()
    }

    // MARK: - Private request plumbing

    private func request(method: String,
                         urlString: String,
                         queryItems: [URLQueryItem]?,
                         body: [String: Any]?,
                         completion: @escaping (Result<[String: Any], GoogleError>) -> Void) {
        guard let token = KeyStore.shared.value(for: .googleWorkspaceAccessToken),
              !token.isEmpty else {
            DispatchQueue.main.async { completion(.failure(.notConnected)) }
            return
        }

        guard var components = URLComponents(string: urlString) else {
            DispatchQueue.main.async { completion(.failure(.transport)) }
            return
        }
        if let queryItems, !queryItems.isEmpty {
            var existing = components.queryItems ?? []
            existing.append(contentsOf: queryItems)
            components.queryItems = existing
        }
        guard let url = components.url else {
            DispatchQueue.main.async { completion(.failure(.transport)) }
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let task = session.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                if error != nil { completion(.failure(.transport)); return }
                guard let http = response as? HTTPURLResponse,
                      let data else { completion(.failure(.transport)); return }
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if (200..<300).contains(http.statusCode) {
                    completion(.success(json ?? [:]))
                } else {
                    let (code, message) = GoogleWorkspaceClient.parseError(json: json, status: http.statusCode)
                    completion(.failure(.api(status: http.statusCode, code: code, message: message)))
                }
            }
        }
        task.resume()
    }

    /// Parse a Google API error response into a code + message pair.
    private static func parseError(json: [String: Any]?, status: Int) -> (code: String, message: String) {
        if let errorDict = json?["error"] as? [String: Any] {
            let message = (errorDict["message"] as? String) ?? "HTTP \(status)"
            if let errors = errorDict["errors"] as? [[String: Any]],
               let first = errors.first,
               let reason = first["reason"] as? String {
                if status == 401 { return (code: "token_expired", message: message) }
                return (code: reason, message: message)
            }
            let code = (errorDict["status"] as? String) ?? "http_\(status)"
            if status == 401 { return (code: "token_expired", message: message) }
            return (code: code, message: message)
        }
        if status == 401 { return (code: "token_expired", message: "Token expired or invalid") }
        return (code: "http_\(status)", message: "HTTP \(status)")
    }
}
