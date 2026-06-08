//
//  OpenAIChat.swift
//  Loop
//
//  Direct client-side OpenAI Chat Completions path. Used by AgentHarness when
//  the user has selected GPT-5.5 *and* set an OPENAI_API_KEY in the Keys
//  panel — it bypasses the `Cloud` backend entirely and talks straight to
//  api.openai.com with the user's own key.
//
//  Why this exists: the agent harness routes chat through a per-provider
//  client. An OpenAI key in the Keys panel makes the obvious thing happen —
//  runs the agent on OpenAI — instead of silently degrading to the on-device
//  Apple model.
//
//  Wire contract: `(messages, tools, completion) -> (MessageStruct?, Error?)`,
//  with history flattening so the agent loop (function call → tool result →
//  next turn) keeps working. No `tool_call_id` is persisted anywhere in the
//  app, so prior tool calls/results are replayed as plain assistant/user
//  prose rather than the strict tool-call pairing newer models expect.
//

import Foundation

final class OpenAIChat {

    static let shared = OpenAIChat()
    private init() {}

    /// 2 min/request is comfortably above a normal completion; resource cap
    /// guards a stuck socket. `waitsForConnectivity` rides out a brief blip
    /// instead of failing the whole agent turn.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    /// Dedicated session for streaming requests — uses a delegate-based flow
    /// so `URLSessionDataDelegate` receives incremental chunks.
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

    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    // MARK: - Prompt caching
    //
    // OpenAI applies automatic prefix caching for prompts ≥1024 tokens
    // when the prefix is identical across requests. No explicit API
    // parameter is required. To maximize cache hit rate:
    //   1. System message (stable) comes first.
    //   2. Tool schemas (stable) are sent in a consistent order.
    //   3. Dynamic/volatile content (user turns, timestamps) comes last.
    // The harness already composes messages in this order (system →
    // history → user), so we just need to keep that invariant and not
    // shuffle tools between requests. Cache hits are reported in
    // `usage.prompt_tokens_details.cached_tokens`.

    /// Maps `[MessageStruct]` → OpenAI chat messages, sends the
    /// (already OpenAI-shaped) tool schemas, and parses the reply back into a
    /// `MessageStruct` — emitting a `FunctionCallStruct` when the model wants
    /// a tool.
    func chat(messages: [MessageStruct],
              tools: [[String: Any]]? = nil,
              onPartial: ((String) -> Void)? = nil,
              completion: @escaping (MessageStruct?, Error?) -> Void) {

        guard let apiKey = KeyStore.shared.value(for: .openAI),
              !apiKey.isEmpty else {
            completion(nil, Self.error(
                "GPT-5.5 is selected but no OpenAI key is set. Add OPENAI_API_KEY in Settings ▸ Keys, or switch the model to Apple Foundation."))
            return
        }

        // The selected OpenAI model's wire id. Falls back to gpt-5.5 only if
        // somehow called for a non-OpenAI selection (routing shouldn't let
        // that happen).
        let modelID = ModelSelectionStore.current.apiModelID ?? "gpt-5.5"

        var body: [String: Any] = [
            "model": modelID,
            "messages": Self.wireMessages(from: messages),
        ]
        // Skill schemas already use the modern {"type":"function","function":…}
        // shape, so they pass straight through with no remapping. OpenAI rejects
        // requests with more than 128 tools ("Invalid 'tools': array too long"),
        // so cap here — on Mac the iOS-bundled set + MacApp/Terminal + any
        // dynamic/MCP tools can edge over the limit.
        if let tools = tools, !tools.isEmpty {
            let capped: [[String: Any]]
            if tools.count > 128 {
                let dropped = tools.count - 128
                let droppedNames = tools.suffix(dropped).compactMap { schema -> String? in
                    (schema["function"] as? [String: Any])?["name"] as? String
                }
                print("OpenAIChat: tools=\(tools.count) exceeds OpenAI cap of 128; dropping \(dropped): \(droppedNames)")
                capped = Array(tools.prefix(128))
            } else {
                capped = tools
            }
            body["tools"] = capped
            body["tool_choice"] = "auto"
        }

        // Enable streaming + usage reporting.
        body["stream"] = true
        body["stream_options"] = ["include_usage": true]

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            completion(nil, Self.error("Failed to encode the OpenAI request body."))
            return
        }

        var metrics = InferenceMetrics(provider: "OpenAI", model: modelID, toolCount: (tools ?? []).count)
        metrics.didBuildPayload(bytes: payload.count)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        req.timeoutInterval = 120

        metrics.willSendRequest()

        let reader = SSEStreamReader(metrics: metrics, onDelta: onPartial) { result in
            switch result {
            case .success(let r):
                let msg = MessageStruct(
                    role: "assistant",
                    content: r.content,
                    model: ModelSelectionStore.current.stampedMessageModel,
                    functions: r.toolCalls,
                    reasoningContent: r.reasoningContent,
                    tokenUsage: r.usage,
                    ttft: r.ttft)
                completion(msg, nil)
            case .failure(let error):
                completion(nil, Self.error("OpenAI streaming error: \(error.localizedDescription)"))
            }
        }

        let task = streamingSession.dataTask(with: req)
        streamingSessionDelegate.register(task: task, reader: reader)
        LocalInferenceController.shared.track(task)
        task.resume()
    }

    // MARK: - Message mapping

    /// Replays the conversation as OpenAI wire messages. Assistant turns that
    /// carry function calls emit a `tool_calls` array (with the persisted
    /// `id`s so the matching `role:"tool"` replies can pair back). Tool
    /// results emit `role:"tool"` + `tool_call_id`. Legacy persisted messages
    /// with no `callId` fall back to prose so older conversations keep
    /// working.
    ///
    /// Reused by sibling OpenAI-compatible clients (FireworksChat) — the
    /// wire shape is identical so there's no point duplicating the mapping.
    static func wireMessages(from messages: [MessageStruct]) -> [[String: Any]] {
        return sanitizeToolCallPairing(stripUIPlaceholders(messages)).map { m -> [String: Any] in
            if m.role == "function" {
                if let toolCallId = m.callId, !toolCallId.isEmpty {
                    return [
                        "role": "tool",
                        "tool_call_id": toolCallId,
                        "content": m.content,
                    ]
                }
                let toolName = m.name ?? "tool"
                return ["role": "user", "content": "[\(toolName) result]\n\(m.content)"]
            }
            if !m.functions.isEmpty {
                // OpenAI assistant turn with structured calls. Each call needs
                // its provider `id` to pair with the subsequent tool result —
                // calls missing one (older persisted messages) degrade to a
                // single prose turn so the model still sees the intent without
                // tripping the API's id-matching rules.
                let structured = m.functions.compactMap { call -> [String: Any]? in
                    guard let id = call.callId, !id.isEmpty else { return nil }
                    let argsString: String
                    if let d = try? JSONSerialization.data(withJSONObject: call.arguments),
                       let s = String(data: d, encoding: .utf8) {
                        argsString = s
                    } else {
                        argsString = "{}"
                    }
                    return [
                        "id": id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": argsString,
                        ],
                    ]
                }
                if structured.count == m.functions.count, !structured.isEmpty {
                    var out: [String: Any] = [
                        "role": "assistant",
                        "tool_calls": structured,
                    ]
                    // OpenAI tolerates a null content alongside tool_calls; we
                    // include any reasoning text when the model provided some.
                    if !m.content.isEmpty { out["content"] = m.content }
                    // Kimi K2.6 returns `reasoning_content` on assistant turns
                    // when thinking is enabled. The API requires the field to
                    // be present when the message is replayed in history;
                    // omitting it triggers "reasoning_content is missing".
                    if let rc = m.reasoningContent {
                        out["reasoning_content"] = rc
                    }
                    return out
                }
                // Legacy fallback — at least one call has no id. Replay all
                // as prose so the model has the gist.
                let lines = m.functions.map { call -> String in
                    let argsString: String
                    if let d = try? JSONSerialization.data(withJSONObject: call.arguments),
                       let s = String(data: d, encoding: .utf8) {
                        argsString = s
                    } else {
                        argsString = "{}"
                    }
                    return "Calling \(call.name) with arguments: \(argsString)"
                }
                return ["role": "assistant", "content": lines.joined(separator: "\n")]
            }
            // Plain turn. Never forward the backend-only base64
            // `attachment`/`attachment_type` keys from `MessageStruct.dict` —
            // OpenAI rejects them as unrecognized request arguments.
            var out: [String: Any] = ["role": m.role]
            if let name = m.name { out["name"] = name }
            // Replay reasoning_content on plain assistant turns too — Kimi
            // validates its presence whenever thinking was active.
            if m.role == "assistant", let rc = m.reasoningContent {
                out["reasoning_content"] = rc
            }

            if let f = m.fileAttachment, f.status == .ready,
               f.kind == .image,
               let dataURL = imageDataURL(for: f) {
                // Real OpenAI vision: a `content` array with the text context
                // plus an `image_url` part carrying the bytes inline, so the
                // model actually sees the image instead of just a path hint.
                let text = m.content.isEmpty
                    ? f.assistantHint
                    : "\(m.content)\n\n\(f.assistantHint)"
                out["content"] = [
                    ["type": "text", "text": text],
                    ["type": "image_url", "image_url": ["url": dataURL]],
                ]
            } else {
                // Text-only: PDFs inline their extracted text via
                // `assistantHint`; an unreadable image degrades to the path
                // hint so the turn still goes through.
                var content = m.content
                if let f = m.fileAttachment, f.status == .ready {
                    content += (content.isEmpty ? "" : "\n\n") + f.assistantHint
                }
                out["content"] = content
            }
            return out
        }
    }

    /// Drop synthetic UI-marker messages (the `image-<id>` / `pdf-<id>`
    /// placeholders that ImageSkill / PDFSkill insert into the store so the
    /// chat cell can render a thumbnail). They carry no model-readable
    /// content — the tool result already told the model what was generated —
    /// and they sit between the assistant `tool_calls` turn and the
    /// `role:"function"` result, which would otherwise break OpenAI's
    /// strict pairing rule and trigger a "tool message without preceding
    /// tool_calls" 400.
    private static func stripUIPlaceholders(_ messages: [MessageStruct]) -> [MessageStruct] {
        return messages.filter { m in
            guard m.role == "assistant" else { return true }
            // Identifier prefix is the authoritative signal — set by the
            // skill that inserted the placeholder, not derivable from any
            // user-controlled content.
            if m.id.hasPrefix("image-") || m.id.hasPrefix("pdf-") || m.id.hasPrefix("story-") { return false }
            return true
        }
    }

    /// Fills any unmatched `tool_calls` ids with a synthetic `role:"function"`
    /// cancellation stub so the wire payload always satisfies OpenAI's strict
    /// pairing rule: "an assistant message with `tool_calls` must be followed
    /// by tool messages responding to each `tool_call_id`". Orphans appear when
    /// the agent loop was interrupted between the assistant emitting the calls
    /// and all tool results landing — e.g. the user sent a new message while a
    /// tool batch was still running, a sub-agent post triggered a
    /// rebuild-from-store mid-flight, or a skill never invoked its completion.
    /// Without this, OpenAI 400s the whole turn; AnthropicChat handles the
    /// same case by downgrading orphan `tool_use` blocks to prose.
    private static func sanitizeToolCallPairing(_ messages: [MessageStruct]) -> [MessageStruct] {
        var out: [MessageStruct] = []
        var i = 0
        while i < messages.count {
            let m = messages[i]
            out.append(m)
            // Only assistant turns that would actually emit `tool_calls` need
            // balancing — that's the all-callIds-present case below. A turn
            // with any id-less call falls into the legacy prose path in
            // `wireMessages` and doesn't trigger the strict pairing check.
            let pendingIds = m.functions.compactMap { $0.callId }.filter { !$0.isEmpty }
            guard !pendingIds.isEmpty, pendingIds.count == m.functions.count else {
                i += 1
                continue
            }
            let nameById: [String: String] = Dictionary(uniqueKeysWithValues:
                m.functions.compactMap { call in
                    guard let id = call.callId, !id.isEmpty else { return nil }
                    return (id, call.name)
                })
            // Copy the run of `role:"function"` results that immediately
            // follows this assistant turn, recording which callIds returned.
            // The pairing OpenAI enforces is purely positional within this
            // run; once we hit any other role, the window closes.
            var matched = Set<String>()
            var j = i + 1
            while j < messages.count, messages[j].role == "function" {
                out.append(messages[j])
                if let id = messages[j].callId, !id.isEmpty {
                    matched.insert(id)
                }
                j += 1
            }
            // Iterate in the original call order so the stubs land in a
            // deterministic spot — easier to read in the wire dump if this
            // ever needs debugging again.
            for id in pendingIds where !matched.contains(id) {
                let name = nameById[id] ?? "tool"
                out.append(MessageStruct(
                    role: "function",
                    content: "{\"status\":\"cancelled\",\"message\":\"Tool call was interrupted before it returned a result.\"}",
                    name: name,
                    callId: id
                ))
            }
            i = j
        }
        return out
    }

    /// Base64 `data:` URL for an image attachment so it rides inline as an
    /// `image_url` content part. Returns nil if the bytes can't be read — the
    /// caller then falls back to the text hint rather than dropping the turn.
    private static func imageDataURL(for f: FileAttachment) -> String? {
        guard let data = try? Data(contentsOf: f.fileURL) else { return nil }
        let mime: String
        if f.mimeType.hasPrefix("image/") {
            mime = f.mimeType
        } else {
            switch f.fileURL.pathExtension.lowercased() {
            case "png":          mime = "image/png"
            case "gif":          mime = "image/gif"
            case "webp":         mime = "image/webp"
            case "heic", "heif": mime = "image/heic"
            default:             mime = "image/jpeg"
            }
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    // MARK: - Errors

    private static func error(_ message: String) -> NSError {
        NSError(domain: "OpenAIChat", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Pull `error.message` out of an OpenAI error body, same shape the image
    /// service handles.
    private static func errorDetail(from bodyStr: String) -> String? {
        guard let data = bodyStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let err = json["error"] as? [String: Any] {
            if let msg = err["message"] as? String { return msg }
            if let code = err["code"] as? String { return code }
        }
        return json["message"] as? String
    }
}
