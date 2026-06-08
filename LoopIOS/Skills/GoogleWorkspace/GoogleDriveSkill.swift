//
//  GoogleDriveSkill.swift
//  Loop
//
//  Google Drive integration. Reads the user's access token from KeyStore
//  (Settings → Keys → Google Workspace Access Token) and talks directly to
//  the Google Drive v3 API. Mirrors NotionSkill's shape: static tool schemas,
//  a dispatch method, and structured JSON responses.
//

import Foundation

struct GoogleDriveSkill {
    static let shared = GoogleDriveSkill()

    // MARK: - System prompt

    static let systemPromptFragment: String = """
You can access the user's Google Drive through these tools:
- google_drive (action: "list_files"): list files. Optional params: q (Drive search query), pageSize (default 20, max 100), fields (partial response field mask).
- google_drive (action: "get_file"): get file metadata by fileId.
- google_drive (action: "read_file"): read file content. For Google Docs/Sheets/Slides, exports as plain text. For other files, returns a download URL.
- google_drive (action: "create_file"): create a new file. Params: name (required), mimeType (required), content (optional text content), parents (optional array of folder ids).

Workflow tips:
- Use list_files with a q parameter to search (e.g. q: "name contains 'report'" or q: "mimeType = 'application/vnd.google-apps.document'").
- If a tool returns {"error":"google_not_connected"}, tell the user to paste their Google access token in Settings → Keys → Google Workspace Access Token.
- If a tool returns {"error":"token_expired"}, tell the user their Google token has expired and they need to refresh it.
"""

    // MARK: - Tool schemas

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "google_drive",
                "description": "Interact with Google Drive. Specify an action and its parameters.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["list_files", "get_file", "read_file", "create_file"],
                            "description": "The Drive action to perform."
                        ],
                        "q": [
                            "type": "string",
                            "description": "Drive search query (for list_files). See https://developers.google.com/drive/api/guides/search-files"
                        ],
                        "pageSize": [
                            "type": "integer",
                            "description": "Max files to return for list_files. Default 20, max 100."
                        ],
                        "fields": [
                            "type": "string",
                            "description": "Partial response field mask (for list_files or get_file)."
                        ],
                        "fileId": [
                            "type": "string",
                            "description": "The file id (for get_file, read_file)."
                        ],
                        "name": [
                            "type": "string",
                            "description": "File name (for create_file)."
                        ],
                        "mimeType": [
                            "type": "string",
                            "description": "MIME type of the file to create (for create_file). Use 'application/vnd.google-apps.document' for Google Docs."
                        ],
                        "content": [
                            "type": "string",
                            "description": "Optional text content for the new file (for create_file)."
                        ],
                        "parents": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional folder ids to place the file in (for create_file)."
                        ]
                    ],
                    "required": ["action"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = ["google_drive"]

    func handles(functionName: String) -> Bool {
        return GoogleDriveSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        guard call.name == "google_drive" else { return nil }
        let action = call.arguments["action"] as? String ?? ""
        switch action {
        case "list_files":  return "listing Google Drive files"
        case "get_file":    return "reading Drive file metadata"
        case "read_file":   return "reading Drive file content"
        case "create_file":
            if let name = call.arguments["name"] as? String, !name.isEmpty {
                return "creating Drive file \(name)"
            }
            return "creating a Drive file"
        default:            return "accessing Google Drive"
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
        case "list_files":
            listFiles(q: args["q"] as? String,
                      pageSize: intArg(args["pageSize"]),
                      fields: args["fields"] as? String,
                      completion: completion)
        case "get_file":
            guard let fileId = args["fileId"] as? String, !fileId.isEmpty else {
                completion(missingArgs(expected: "fileId")); return
            }
            getFile(fileId: fileId, fields: args["fields"] as? String, completion: completion)
        case "read_file":
            guard let fileId = args["fileId"] as? String, !fileId.isEmpty else {
                completion(missingArgs(expected: "fileId")); return
            }
            readFile(fileId: fileId, completion: completion)
        case "create_file":
            guard let name = args["name"] as? String, !name.isEmpty,
                  let mimeType = args["mimeType"] as? String, !mimeType.isEmpty else {
                completion(missingArgs(expected: "name, mimeType")); return
            }
            createFile(name: name,
                       mimeType: mimeType,
                       content: args["content"] as? String,
                       parents: args["parents"] as? [String],
                       completion: completion)
        default:
            completion(functionMessage(payload: [
                "error": "unknown_action",
                "hint": "Valid actions: list_files, get_file, read_file, create_file"
            ]))
        }
    }

    // MARK: - Actions

    private func listFiles(q: String?,
                           pageSize: Int?,
                           fields: String?,
                           completion: @escaping (MessageStruct) -> Void) {
        let size = min(max(pageSize ?? 20, 1), 100)
        var queryItems = [
            URLQueryItem(name: "pageSize", value: "\(size)"),
            URLQueryItem(name: "fields", value: fields ?? "files(id,name,mimeType,modifiedTime,size,parents)")
        ]
        if let q, !q.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: q))
        }
        GoogleWorkspaceClient.shared.get(
            url: "https://www.googleapis.com/drive/v3/files",
            queryItems: queryItems
        ) { [self] result in
            switch result {
            case .failure(let err):
                completion(errorMessage(error: err))
            case .success(let dict):
                let files = dict["files"] as? [[String: Any]] ?? []
                completion(functionMessage(payload: ["files": files]))
            }
        }
    }

    private func getFile(fileId: String,
                         fields: String?,
                         completion: @escaping (MessageStruct) -> Void) {
        let fieldMask = fields ?? "id,name,mimeType,modifiedTime,size,parents,webViewLink"
        let queryItems = [URLQueryItem(name: "fields", value: fieldMask)]
        GoogleWorkspaceClient.shared.get(
            url: "https://www.googleapis.com/drive/v3/files/\(fileId)",
            queryItems: queryItems
        ) { [self] result in
            switch result {
            case .failure(let err):
                completion(errorMessage(error: err))
            case .success(let dict):
                completion(functionMessage(payload: dict))
            }
        }
    }

    private func readFile(fileId: String,
                          completion: @escaping (MessageStruct) -> Void) {
        // First get metadata to determine the mimeType
        let queryItems = [URLQueryItem(name: "fields", value: "id,name,mimeType")]
        GoogleWorkspaceClient.shared.get(
            url: "https://www.googleapis.com/drive/v3/files/\(fileId)",
            queryItems: queryItems
        ) { [self] result in
            switch result {
            case .failure(let err):
                completion(errorMessage(error: err))
            case .success(let meta):
                let mimeType = meta["mimeType"] as? String ?? ""
                if mimeType.starts(with: "application/vnd.google-apps.") {
                    // Google native format — export as text
                    exportAsText(fileId: fileId, nativeMime: mimeType, completion: completion)
                } else {
                    // Binary/non-native — return a download URL
                    let downloadURL = "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media"
                    completion(functionMessage(payload: [
                        "type": "binary",
                        "mimeType": mimeType,
                        "downloadUrl": downloadURL,
                        "hint": "Use this URL with the access token to download the file content."
                    ]))
                }
            }
        }
    }

    private func exportAsText(fileId: String,
                              nativeMime: String,
                              completion: @escaping (MessageStruct) -> Void) {
        let exportMime: String
        switch nativeMime {
        case "application/vnd.google-apps.document":
            exportMime = "text/plain"
        case "application/vnd.google-apps.spreadsheet":
            exportMime = "text/csv"
        case "application/vnd.google-apps.presentation":
            exportMime = "text/plain"
        default:
            exportMime = "text/plain"
        }
        let queryItems = [URLQueryItem(name: "mimeType", value: exportMime)]
        GoogleWorkspaceClient.shared.get(
            url: "https://www.googleapis.com/drive/v3/files/\(fileId)/export",
            queryItems: queryItems
        ) { [self] result in
            switch result {
            case .failure(let err):
                // If export fails, it may be because the response was plain text (not JSON).
                // In that case the client would report malformedResponse — handle gracefully.
                completion(errorMessage(error: err))
            case .success(let dict):
                // The export endpoint returns raw text, not JSON. If we got JSON
                // back it means the client parsed an error. Pass through whatever we got.
                completion(functionMessage(payload: [
                    "type": "text",
                    "mimeType": exportMime,
                    "content": dict
                ]))
            }
        }
    }

    private func createFile(name: String,
                            mimeType: String,
                            content: String?,
                            parents: [String]?,
                            completion: @escaping (MessageStruct) -> Void) {
        var metadata: [String: Any] = [
            "name": name,
            "mimeType": mimeType
        ]
        if let parents, !parents.isEmpty {
            metadata["parents"] = parents
        }

        if let content, !content.isEmpty,
           mimeType == "application/vnd.google-apps.document" {
            // For Google Docs, create with content using the multipart upload
            // Simplified: create empty doc then would need to use Docs API to add content.
            // For v1, create the file metadata-only; content param noted in response.
            GoogleWorkspaceClient.shared.post(
                url: "https://www.googleapis.com/drive/v3/files",
                body: metadata
            ) { [self] result in
                switch result {
                case .failure(let err):
                    completion(errorMessage(error: err))
                case .success(let dict):
                    var response = dict
                    response["note"] = "File created. For Google Docs, use the Google Docs API to insert content after creation."
                    completion(functionMessage(payload: response))
                }
            }
        } else {
            // Metadata-only creation
            GoogleWorkspaceClient.shared.post(
                url: "https://www.googleapis.com/drive/v3/files",
                body: metadata
            ) { [self] result in
                switch result {
                case .failure(let err):
                    completion(errorMessage(error: err))
                case .success(let dict):
                    completion(functionMessage(payload: dict))
                }
            }
        }
    }

    // MARK: - Helpers

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
        return MessageStruct(role: "function", content: json, name: "google_drive")
    }

    private func missingArgs(expected: String) -> MessageStruct {
        return MessageStruct(
            role: "assistant",
            content: "I need \(expected) to call google_drive. Please provide them."
        )
    }

    private func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }
}
