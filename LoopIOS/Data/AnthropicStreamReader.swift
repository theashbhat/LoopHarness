//
//  AnthropicStreamReader.swift
//  Loop
//
//  SSE stream reader for Anthropic's Messages API streaming format.
//  Anthropic uses typed events (message_start, content_block_start,
//  content_block_delta, content_block_stop, message_delta, message_stop)
//  rather than OpenAI's flat `data:` chunks.
//

import Foundation

final class AnthropicStreamReader: NSObject, URLSessionDataDelegate {

    struct Result {
        let content: String
        let toolCalls: [FunctionCallStruct]
        let usage: TokenUsage?
        /// Time-to-first-token in seconds, for the per-message latency readout.
        let ttft: TimeInterval?
    }

    private let completion: (Swift.Result<Result, Error>) -> Void
    private var metrics: InferenceMetrics
    /// Fired on the URLSession delegate queue with each text delta as it
    /// arrives. Held strongly — see `SSEStreamReader.onDelta`.
    private let onDelta: ((String) -> Void)?

    private var contentBuffer = ""
    private var inputTokens: Int = 0
    private var outputTokens: Int = 0

    /// Each content block has an index; tool_use blocks accumulate name, id,
    /// and a JSON-arguments string across deltas.
    private struct ToolUseAccumulator {
        var id: String = ""
        var name: String = ""
        var inputJSON: String = ""
    }
    private var toolUseBlocks: [Int: ToolUseAccumulator] = [:]
    /// Track content block types by index so deltas can route correctly.
    private var blockTypes: [Int: String] = [:]

    private var lineBuffer = ""
    private var currentEventType = ""
    private var receivedFirstChunk = false

    init(metrics: InferenceMetrics,
         onDelta: ((String) -> Void)? = nil,
         completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        self.metrics = metrics
        self.onDelta = onDelta
        self.completion = completion
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            completionHandler(.cancel)
            completion(.failure(NSError(
                domain: "AnthropicStreamReader",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) from Anthropic"])))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        if !receivedFirstChunk {
            receivedFirstChunk = true
            metrics.didReceiveFirstChunk()
        }

        guard let chunk = String(data: data, encoding: .utf8) else { return }
        lineBuffer += chunk

        while let range = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<range.lowerBound])
            lineBuffer = String(lineBuffer[range.upperBound...])
            processLine(line)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            completion(.failure(error))
            return
        }
        if !lineBuffer.isEmpty {
            processLine(lineBuffer)
            lineBuffer = ""
        }
        finalizeResult()
    }

    // MARK: - SSE parsing

    private func processLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("event: ") {
            currentEventType = String(trimmed.dropFirst(7))
            return
        }

        guard trimmed.hasPrefix("data: ") else { return }
        let payload = String(trimmed.dropFirst(6))
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        switch currentEventType {
        case "message_start":
            if let msg = json["message"] as? [String: Any],
               let u = msg["usage"] as? [String: Any],
               let input = u["input_tokens"] as? Int {
                inputTokens = input
            }

        case "content_block_start":
            guard let idx = json["index"] as? Int,
                  let block = json["content_block"] as? [String: Any],
                  let type = block["type"] as? String else { return }
            blockTypes[idx] = type
            if type == "tool_use" {
                var acc = ToolUseAccumulator()
                if let id = block["id"] as? String { acc.id = id }
                if let name = block["name"] as? String { acc.name = name }
                toolUseBlocks[idx] = acc
            }

        case "content_block_delta":
            guard let idx = json["index"] as? Int,
                  let delta = json["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return }

            if deltaType == "text_delta", let text = delta["text"] as? String {
                contentBuffer += text
                onDelta?(text)
            } else if deltaType == "input_json_delta",
                      let partial = delta["partial_json"] as? String {
                toolUseBlocks[idx]?.inputJSON += partial
            }

        case "message_delta":
            if let u = json["usage"] as? [String: Any],
               let output = u["output_tokens"] as? Int {
                outputTokens = output
            }

        default:
            break
        }
    }

    // MARK: - Finalize

    private func finalizeResult() {
        let calls: [FunctionCallStruct] = toolUseBlocks
            .sorted { $0.key < $1.key }
            .map { (_, acc) in
                var argsDict: [String: Any] = [:]
                if let d = acc.inputJSON.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    argsDict = parsed
                }
                return FunctionCallStruct(
                    name: acc.name,
                    arguments: argsDict,
                    callId: acc.id.isEmpty ? nil : acc.id)
            }

        var usage: TokenUsage?
        if inputTokens > 0 || outputTokens > 0 {
            usage = TokenUsage(promptTokens: inputTokens,
                               completionTokens: outputTokens,
                               totalTokens: inputTokens + outputTokens)
        }
        metrics.didComplete(usage: usage)

        completion(.success(Result(
            content: contentBuffer,
            toolCalls: calls,
            usage: usage,
            ttft: metrics.ttft)))
    }
}
