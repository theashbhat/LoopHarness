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
              completion: @escaping (MessageStruct?, Error?) -> Void) {

        guard let apiKey = KeyStore.shared.value(for: .fireworks),
              !apiKey.isEmpty else {
            completion(nil, Self.error(
                "Fireworks is selected but no Fireworks key is set. Add FIREWORKS_API_KEY in Settings ▸ Keys, or switch the model in Settings ▸ Model."))
            return
        }

        let modelID = ModelSelectionStore.current.apiModelID ?? "accounts/fireworks/models/kimi-k2p6"
        let requestStart = CFAbsoluteTimeGetCurrent()

        var body: [String: Any] = [
            "model": modelID,
            "messages": OpenAIChat.wireMessages(from: messages),
            "max_completion_tokens": maxCompletionTokens,
        ]
        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            completion(nil, Self.error("Failed to encode the Fireworks request body."))
            return
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        req.timeoutInterval = 120

        print("FireworksChat: POST \(endpoint) model=\(modelID) tools=\((tools ?? []).count) prefix_caching=auto")
        let task = session.dataTask(with: req) { data, response, error in
            let latency = CFAbsoluteTimeGetCurrent() - requestStart
            if let error = error {
                print("FireworksChat: FAILED after \(String(format: "%.2f", latency))s — \(error.localizedDescription)")
                completion(nil, Self.error("Network error talking to Fireworks: \(error.localizedDescription)"))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                let detail = Self.errorDetail(from: bodyStr) ?? "HTTP \(http.statusCode)"
                completion(nil, Self.error("Fireworks API error: \(detail)"))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                completion(nil, Self.error("Fireworks returned an unexpected payload."))
                return
            }

            let calls: [FunctionCallStruct]
            if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                calls = toolCalls.compactMap { entry in
                    guard let fn = entry["function"] as? [String: Any],
                          let name = fn["name"] as? String else { return nil }
                    let argsString = fn["arguments"] as? String ?? "{}"
                    var argsDict: [String: Any] = [:]
                    if let d = argsString.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        argsDict = parsed
                    }
                    let id = entry["id"] as? String
                    return FunctionCallStruct(name: name, arguments: argsDict, callId: id)
                }
            } else {
                calls = []
            }
            let content = (message["content"] as? String) ?? ""
            let reasoning = message["reasoning_content"] as? String
            var usage: TokenUsage? = nil
            if let u = json["usage"] as? [String: Any],
               let prompt = u["prompt_tokens"] as? Int,
               let comp = u["completion_tokens"] as? Int,
               let total = u["total_tokens"] as? Int {
                usage = TokenUsage(promptTokens: prompt,
                                   completionTokens: comp,
                                   totalTokens: total)
                print("FireworksChat: latency=\(String(format: "%.2f", latency))s prompt=\(prompt) completion=\(comp)")
            }
            let msg = MessageStruct(
                role: "assistant",
                content: content,
                model: ModelSelectionStore.current.stampedMessageModel,
                functions: calls,
                reasoningContent: reasoning,
                tokenUsage: usage)
            completion(msg, nil)
        }
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
