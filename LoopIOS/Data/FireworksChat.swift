//
//  FireworksChat.swift
//  Loop
//
//  Direct client-side Fireworks inference path. Used by AgentHarness when
//  the selected model's provider is `.fireworks` and the user has a
//  FIREWORKS_API_KEY set in the Keys panel (or bundled via
//  Secrets.xcconfig). Talks straight to
//  api.fireworks.ai/inference/v1/chat/completions with the user's own key.
//
//  Wire format is OpenAI-compatible: same `messages` shape, same
//  `{type:"function", function:{…}}` tool schemas, same `tool_calls` ↔
//  `role:"tool"` + `tool_call_id` pairing. So this client delegates message
//  mapping and tool-call sanitisation to `OpenAIChat` and only differs in:
//    • endpoint (api.fireworks.ai instead of api.openai.com)
//    • model id (accounts/fireworks/models/kimi-k2p6)
//    • error domain so a failure surfaces as "Fireworks API error: …"
//

import Foundation

final class FireworksChat {

    static let shared = FireworksChat()
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

    private let endpoint = URL(string: "https://api.fireworks.ai/inference/v1/chat/completions")!

    // MARK: - Prompt caching
    //
    // Fireworks supports automatic prefix caching on their OpenAI-
    // compatible endpoint. Like OpenAI, no explicit request parameter
    // is needed — the server detects repeated prefixes and serves them
    // from KV cache. To maximize hit rate we rely on the same ordering
    // invariant the harness already maintains: system → tools → history
    // → latest user message. Fireworks does not currently expose a
    // response field reporting cache hits, so we log latency only.

    private let maxCompletionTokens = 4096

    func chat(messages: [MessageStruct],
              tools: [[String: Any]]? = nil,
              onPartial: ((String) -> Void)? = nil,
              completion: @escaping (MessageStruct?, Error?) -> Void) {

        guard let apiKey = KeyStore.shared.value(for: .fireworks),
              !apiKey.isEmpty else {
            completion(nil, Self.error(
                "Fireworks is selected but no Fireworks key is set. Add FIREWORKS_API_KEY in Settings ▸ Keys, or switch the model in Settings ▸ Model."))
            return
        }

        let modelID = ModelSelectionStore.current.apiModelID ?? "accounts/fireworks/models/kimi-k2p6"

        var body: [String: Any] = [
            "model": modelID,
            "messages": OpenAIChat.wireMessages(from: messages),
            "max_completion_tokens": maxCompletionTokens,
        ]
        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }

        body["stream"] = true
        body["stream_options"] = ["include_usage": true]

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            completion(nil, Self.error("Failed to encode the Fireworks request body."))
            return
        }

        var metrics = InferenceMetrics(provider: "Fireworks", model: modelID, toolCount: (tools ?? []).count)
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
                completion(nil, Self.error("Fireworks streaming error: \(error.localizedDescription)"))
            }
        }

        let task = streamingSession.dataTask(with: req)
        streamingSessionDelegate.register(task: task, reader: reader)
        LocalInferenceController.shared.track(task)
        task.resume()
    }

    // MARK: - Errors

    private static func error(_ message: String) -> NSError {
        NSError(domain: "FireworksChat", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

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
