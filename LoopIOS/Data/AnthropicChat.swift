//
//  AnthropicChat.swift
//  Loop
//
//  Direct client-side Anthropic (Claude) path. Used by AgentHarness when the
//  selected model's provider is `.anthropic` and the user has set an
//  ANTHROPIC_API_KEY in the Keys panel. Talks straight to
//  api.anthropic.com/v1/messages with the user's own key — no backend.
//
//  Drop-in sibling of `OpenAIChat`: same
//  `(messages, tools, completion) -> (MessageStruct?, Error?)` contract and
//  the same model-agnostic history flattening, so the agent loop (function
//  call → tool result → next turn) is unchanged. The differences from the
//  OpenAI path are all Anthropic-API shape:
//    • `system` is a top-level string, not a message,
//    • messages must start with `user` and alternate roles (we coalesce
//      consecutive same-role turns to guarantee that),
//    • tool schemas are `{name, description, input_schema}` (remapped from
//      the skills' OpenAI `{type:function, function:{…}}` shape),
//    • `max_tokens` is required,
//    • images use `{type:image, source:{base64,…}}` blocks.
//

import Foundation

final class AnthropicChat {

    static let shared = AnthropicChat()
    private init() {}

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    private lazy var streamingSessionDelegate: StreamingSessionDelegateRouter = {
        StreamingSessionDelegateRouter()
    }()
    private lazy var streamingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: streamingSessionDelegate, delegateQueue: nil)
    }()

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicVersion = "2023-06-01"
    /// Opt-in to prompt caching. Sent as a space-separated list in the
    /// `anthropic-beta` header; the API ignores unknown feature flags so
    /// this is forward-compatible.
    private let betaFeatures = "prompt-caching-2024-07-31"
    /// Cap on a single completion. Generous enough for long agent turns
    /// without inviting runaway generations; required by the API.
    private let maxTokens = 4096

    func chat(messages: [MessageStruct],
              tools: [[String: Any]]? = nil,
              completion: @escaping (MessageStruct?, Error?) -> Void) {

        guard let apiKey = KeyStore.shared.value(for: .anthropic),
              !apiKey.isEmpty else {
            completion(nil, Self.error(
                "A Claude model is selected but no Anthropic key is set. Add ANTHROPIC_API_KEY in Settings ▸ Keys, or pick a different model."))
            return
        }

        let modelID = ModelSelectionStore.current.apiModelID ?? "claude-sonnet-4-6"
        let (system, wire) = Self.wirePayload(from: messages)

        var body: [String: Any] = [
            "model": modelID,
            "max_tokens": maxTokens,
            "messages": wire,
        ]
        // --- Prompt caching: system prompt ---
        // Anthropic's prompt caching requires `system` to be an array of
        // content blocks (not a plain string) when cache_control is used.
        // We mark the entire system prompt as a single cacheable block so
        // the stable SOUL/USER/MEMORY/AGENTS/TOOLS prefix gets a server-
        // side cache hit on subsequent turns (5-minute TTL, typically
        // saving 90%+ of input tokens on multi-turn conversations).
        if let system = system, !system.isEmpty {
            body["system"] = [
                [
                    "type": "text",
                    "text": system,
                    "cache_control": ["type": "ephemeral"],
                ] as [String: Any]
            ]
        }

        // --- Prompt caching: tool schemas ---
        // Tool definitions are stable across turns (they only change when
        // a dynamic skill is added/removed). Mark the last tool with a
        // cache breakpoint so the entire tool list is cached together with
        // the system prompt.
        if let tools = tools, !tools.isEmpty {
            var anthropicTools = Self.anthropicTools(from: tools)
            if !anthropicTools.isEmpty {
                var lastTool = anthropicTools[anthropicTools.count - 1]
                lastTool["cache_control"] = ["type": "ephemeral"]
                anthropicTools[anthropicTools.count - 1] = lastTool
            }
            body["tools"] = anthropicTools
            body["tool_choice"] = ["type": "auto"]
        }

        body["stream"] = true

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            completion(nil, Self.error("Failed to encode the Anthropic request body."))
            return
        }

        var metrics = InferenceMetrics(provider: "Anthropic", model: modelID, toolCount: (tools ?? []).count)
        metrics.didBuildPayload(bytes: payload.count)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue(betaFeatures, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        req.timeoutInterval = 120

        metrics.willSendRequest()

        let reader = AnthropicStreamReader(metrics: metrics) { result in
            switch result {
            case .success(let r):
                let msg = MessageStruct(
                    role: "assistant",
                    content: r.content,
                    model: ModelSelectionStore.current.stampedMessageModel,
                    functions: r.toolCalls,
                    tokenUsage: r.usage)
                completion(msg, nil)
            case .failure(let error):
                completion(nil, Self.error("Anthropic streaming error: \(error.localizedDescription)"))
            }
        }

        let task = streamingSession.dataTask(with: req)
        streamingSessionDelegate.register(task: task, reader: reader)
        task.resume()
    }

    // MARK: - Tool schema remap

    /// Skills declare tools in OpenAI's `{"type":"function","function":{name,
    /// description, parameters}}` shape. Anthropic wants flat
    /// `{name, description, input_schema}`.
    private static func anthropicTools(from tools: [[String: Any]]) -> [[String: Any]] {
        var seen = Set<String>()
        var out: [[String: Any]] = []
        for tool in tools {
            guard let fn = tool["function"] as? [String: Any],
                  let name = fn["name"] as? String,
                  // Anthropic hard-rejects duplicate names. The harness already
                  // dedupes, but guard here too so a direct caller can't trip
                  // the API.
                  seen.insert(name).inserted else { continue }
            var entry: [String: Any] = ["name": name]
            if let desc = fn["description"] as? String { entry["description"] = desc }
            // Anthropic requires an object schema; default to an empty one so
            // parameter-less tools still validate.
            entry["input_schema"] = (fn["parameters"] as? [String: Any])
                ?? ["type": "object", "properties": [:]]
            out.append(entry)
        }
        return out
    }

    // MARK: - Message mapping

    /// Flatten the harness conversation into Anthropic's shape: a top-level
    /// `system` string plus a strictly alternating user/assistant array.
    /// Assistant turns that carry function calls emit `tool_use` blocks and
    /// tool-result turns emit `tool_result` blocks — paired via the persisted
    /// `callId` so multi-call sequences round-trip correctly. Legacy messages
    /// without a `callId` fall back to plain prose so older persisted chats
    /// keep working.
    private static func wirePayload(from messages: [MessageStruct]) -> (String?, [[String: Any]]) {
        var systemParts: [String] = []
        // Intermediate: (role, content blocks). Always block arrays so a text
        // turn and an image turn can be merged uniformly when coalescing.
        var seq: [(role: String, blocks: [[String: Any]])] = []

        func textBlock(_ s: String) -> [String: Any] { ["type": "text", "text": s] }

        // Drop synthetic UI-marker messages (image-/pdf- placeholders the
        // chat surface inserts so it can render a thumbnail bubble). They
        // carry no model-readable content and otherwise coalesce into the
        // assistant turn between `tool_use` and its `tool_result`, which
        // can trip the orphan-tool_use sanitizer below.
        let filteredMessages = messages.filter { m in
            guard m.role == "assistant" else { return true }
            if m.id.hasPrefix("image-") || m.id.hasPrefix("pdf-") { return false }
            return true
        }

        for m in filteredMessages {
            if m.role == "system" {
                if !m.content.isEmpty { systemParts.append(m.content) }
                continue
            }
            if m.role == "function" {
                // Structured `tool_result` when we have the originating call's
                // id; otherwise fall back to prose for legacy messages.
                if let toolUseId = m.callId, !toolUseId.isEmpty {
                    seq.append(("user", [[
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": m.content,
                    ] as [String: Any]]))
                } else {
                    let toolName = m.name ?? "tool"
                    seq.append(("user", [textBlock("[\(toolName) result]\n\(m.content)")]))
                }
                continue
            }
            if !m.functions.isEmpty {
                // Assistant turn with one or more `tool_use` blocks. Include any
                // accompanying text the model emitted before the calls.
                var blocks: [[String: Any]] = []
                if !m.content.isEmpty {
                    blocks.append(textBlock(m.content))
                }
                var sawStructured = false
                for call in m.functions {
                    if let id = call.callId, !id.isEmpty {
                        blocks.append([
                            "type": "tool_use",
                            "id": id,
                            "name": call.name,
                            "input": call.arguments,
                        ])
                        sawStructured = true
                    } else {
                        // Legacy call without an id — replay as prose so we
                        // don't lie to the model about a `tool_use` it never
                        // emitted, and so Anthropic doesn't reject the turn.
                        let argsString: String
                        if let d = try? JSONSerialization.data(withJSONObject: call.arguments),
                           let s = String(data: d, encoding: .utf8) {
                            argsString = s
                        } else {
                            argsString = "{}"
                        }
                        blocks.append(textBlock("Calling \(call.name) with arguments: \(argsString)"))
                    }
                }
                // Anthropic rejects an assistant turn that's a structured
                // tool_use mixed with nothing else if the turn has no content
                // at all — we always have at least the tool_use here, so the
                // block list is non-empty. `sawStructured` is referenced only
                // to suppress an unused-warning for the legacy-only path.
                _ = sawStructured
                seq.append(("assistant", blocks))
                continue
            }

            // Plain turn. Real vision when there's a usable image; otherwise
            // inline the text hint (PDF text / path tag).
            let role = (m.role == "assistant") ? "assistant" : "user"
            if let f = m.fileAttachment, f.status == .ready, f.kind == .image,
               let imageBlock = imageBlock(for: f) {
                let text = m.content.isEmpty ? f.assistantHint
                                             : "\(m.content)\n\n\(f.assistantHint)"
                seq.append((role, [textBlock(text), imageBlock]))
            } else {
                var content = m.content
                if let f = m.fileAttachment, f.status == .ready {
                    content += (content.isEmpty ? "" : "\n\n") + f.assistantHint
                }
                // Anthropic rejects empty text blocks — skip a contentless
                // turn entirely rather than emit one.
                guard !content.isEmpty else { continue }
                seq.append((role, [textBlock(content)]))
            }
        }

        // Anthropic requires the first message to be `user` and rejects
        // consecutive same-role messages. Coalesce adjacent same-role turns
        // (which also guarantees alternation), then ensure a user lead.
        var coalesced: [(role: String, blocks: [[String: Any]])] = []
        for turn in seq {
            if var last = coalesced.last, last.role == turn.role {
                last.blocks.append(contentsOf: turn.blocks)
                coalesced[coalesced.count - 1] = last
            } else {
                coalesced.append(turn)
            }
        }
        if coalesced.first?.role != "user" {
            coalesced.insert(("user", [textBlock("Continue.")]), at: 0)
        }

        // Sanitize tool_use ↔ tool_result pairing. Anthropic rejects any
        // assistant turn that emits a `tool_use` block whose id has no
        // matching `tool_result` in the immediately-following user turn —
        // and vice versa. Orphans creep in when a turn is canceled mid-
        // dispatch, when history is restored from a store that doesn't
        // persist `callId`, or when an in-flight error stamps an assistant
        // bubble between the tool_use and the result it was waiting on. We
        // rebuild any orphan block as plain prose so the model still has
        // the gist and the API call goes through.
        for i in 0..<coalesced.count {
            let turn = coalesced[i]
            if turn.role == "assistant" {
                let nextResultIds: Set<String> = {
                    guard i + 1 < coalesced.count, coalesced[i + 1].role == "user" else { return [] }
                    var s = Set<String>()
                    for b in coalesced[i + 1].blocks where (b["type"] as? String) == "tool_result" {
                        if let id = b["tool_use_id"] as? String, !id.isEmpty { s.insert(id) }
                    }
                    return s
                }()
                var rebuilt: [[String: Any]] = []
                for b in turn.blocks {
                    guard (b["type"] as? String) == "tool_use" else {
                        rebuilt.append(b); continue
                    }
                    let id = (b["id"] as? String) ?? ""
                    if !id.isEmpty, nextResultIds.contains(id) {
                        rebuilt.append(b)
                    } else {
                        let name = (b["name"] as? String) ?? "tool"
                        let input = (b["input"] as? [String: Any]) ?? [:]
                        let argsString: String
                        if let d = try? JSONSerialization.data(withJSONObject: input),
                           let s = String(data: d, encoding: .utf8) {
                            argsString = s
                        } else {
                            argsString = "{}"
                        }
                        rebuilt.append(textBlock("Calling \(name) with arguments: \(argsString)"))
                    }
                }
                coalesced[i] = (turn.role, rebuilt)
            } else if turn.role == "user" {
                // Use the (possibly already-rewritten) previous assistant
                // turn so a tool_result whose tool_use was just downgraded
                // also gets downgraded — keeping the two sides consistent.
                let prevToolUseIds: Set<String> = {
                    guard i > 0, coalesced[i - 1].role == "assistant" else { return [] }
                    var s = Set<String>()
                    for b in coalesced[i - 1].blocks where (b["type"] as? String) == "tool_use" {
                        if let id = b["id"] as? String, !id.isEmpty { s.insert(id) }
                    }
                    return s
                }()
                var rebuilt: [[String: Any]] = []
                for b in turn.blocks {
                    guard (b["type"] as? String) == "tool_result" else {
                        rebuilt.append(b); continue
                    }
                    let id = (b["tool_use_id"] as? String) ?? ""
                    if !id.isEmpty, prevToolUseIds.contains(id) {
                        rebuilt.append(b)
                    } else {
                        let content = (b["content"] as? String) ?? ""
                        rebuilt.append(textBlock("[tool result]\n\(content)"))
                    }
                }
                coalesced[i] = (turn.role, rebuilt)
            }
        }

        // Empty turns can show up if every block in a coalesced turn got
        // dropped (extreme edge case, but cheap to guard). Anthropic
        // rejects an empty content array.
        coalesced = coalesced.filter { !$0.blocks.isEmpty }
        if coalesced.first?.role != "user" {
            coalesced.insert(("user", [textBlock("Continue.")]), at: 0)
        }

        let wire = coalesced.map { ["role": $0.role, "content": $0.blocks] as [String: Any] }
        let system = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n")
        return (system, wire)
    }

    /// Anthropic base64 image block, or nil if the bytes can't be read or the
    /// format isn't one Anthropic accepts (jpeg/png/gif/webp) — caller then
    /// degrades to the text hint. HEIC is intentionally excluded.
    private static func imageBlock(for f: FileAttachment) -> [String: Any]? {
        guard let data = try? Data(contentsOf: f.fileURL) else { return nil }
        let media: String
        if ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(f.mimeType) {
            media = f.mimeType
        } else {
            switch f.fileURL.pathExtension.lowercased() {
            case "png":          media = "image/png"
            case "gif":          media = "image/gif"
            case "webp":         media = "image/webp"
            case "jpg", "jpeg":  media = "image/jpeg"
            default:             return nil
            }
        }
        return [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": media,
                "data": data.base64EncodedString(),
            ],
        ]
    }

    // MARK: - Test support

    /// Expose `anthropicTools(from:)` for unit tests. Production code should
    /// call through `chat(messages:tools:completion:)` which applies caching
    /// annotations on top.
    static func testableAnthropicTools(from tools: [[String: Any]]) -> [[String: Any]] {
        anthropicTools(from: tools)
    }

    // MARK: - Errors

    private static func error(_ message: String) -> NSError {
        NSError(domain: "AnthropicChat", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func errorDetail(from bodyStr: String) -> String? {
        guard let data = bodyStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let err = json["error"] as? [String: Any] {
            if let msg = err["message"] as? String { return msg }
            if let type = err["type"] as? String { return type }
        }
        return json["message"] as? String
    }
}
