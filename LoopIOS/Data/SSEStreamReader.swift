//
//  SSEStreamReader.swift
//  Loop
//
//  Server-Sent Events (SSE) stream reader for OpenAI-compatible chat
//  completion endpoints. Reads `data: {...}` lines from a streamed HTTP
//  response and incrementally assembles content deltas and tool-call
//  fragments into a final `MessageStruct`.
//
//  Used by OpenAIChat and FireworksChat (both use the same SSE wire format).
//  Anthropic uses a different event schema — see AnthropicChat for its
//  streaming path.
//

import Foundation

/// Assembles a streamed OpenAI-compatible chat completion into a single
/// `MessageStruct`. Handles:
///   - Content deltas (`choices[0].delta.content`)
///   - Tool-call deltas (`choices[0].delta.tool_calls[].function.{name, arguments}`)
///   - Reasoning content (`choices[0].delta.reasoning_content`)
///   - Usage object on the final chunk (when `stream_options.include_usage` is set)
///   - `[DONE]` sentinel
final class SSEStreamReader: NSObject, URLSessionDataDelegate {

    /// Result delivered on completion.
    struct Result {
        let content: String
        let toolCalls: [FunctionCallStruct]
        let reasoningContent: String?
        let usage: TokenUsage?
        let cachedTokens: Int?
    }

    private let completion: (Swift.Result<Result, Error>) -> Void
    private var metrics: InferenceMetrics
    /// Fired on the URLSession delegate queue with each text delta as it
    /// arrives, so the UI can show partial output before the full response
    /// lands. Held strongly: the reader is owned by the session router only
    /// for the request's lifetime, so there's no retain cycle to weaken.
    private let onDelta: ((String) -> Void)?

    // Accumulation state
    private var contentBuffer = ""
    private var reasoningBuffer = ""

    /// In-flight tool calls keyed by their array index (which OpenAI streams
    /// as `tool_calls[i].index`). Each entry accumulates name and argument
    /// fragments across multiple chunks.
    private struct ToolCallAccumulator {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }
    private var toolCallAccumulators: [Int: ToolCallAccumulator] = [:]

    private var usage: TokenUsage?
    private var cachedTokens: Int?

    /// Partial line buffer for cases where a chunk boundary splits a `data:`
    /// line mid-stream.
    private var lineBuffer = ""

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
            let code = http.statusCode
            // We'll get the error body in didCompleteWithError or via a
            // subsequent data callback; for now just note the status.
            completion(.failure(NSError(
                domain: "SSEStreamReader",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) from provider"])))
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

        // Process complete lines (SSE is newline-delimited).
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
        // Process any remaining partial line.
        if !lineBuffer.isEmpty {
            processLine(lineBuffer)
            lineBuffer = ""
        }
        finalizeResult()
    }

    // MARK: - SSE line processing

    private func processLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data: ") else { return }
        let payload = String(trimmed.dropFirst(6))
        if payload == "[DONE]" { return }

        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Usage comes on the final chunk when `stream_options.include_usage`
        // is set. OpenAI puts it at the top level alongside `choices`.
        if let u = json["usage"] as? [String: Any] {
            if let prompt = u["prompt_tokens"] as? Int,
               let comp = u["completion_tokens"] as? Int,
               let total = u["total_tokens"] as? Int {
                usage = TokenUsage(promptTokens: prompt,
                                   completionTokens: comp,
                                   totalTokens: total)
            }
            if let details = u["prompt_tokens_details"] as? [String: Any],
               let cached = details["cached_tokens"] as? Int {
                cachedTokens = cached
            }
        }

        guard let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else {
            return
        }

        // Content delta
        if let text = delta["content"] as? String, !text.isEmpty {
            contentBuffer += text
            onDelta?(text)
        }

        // Reasoning content delta
        if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
            reasoningBuffer += reasoning
        }

        // Tool-call deltas
        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                let idx = tc["index"] as? Int ?? 0
                var acc = toolCallAccumulators[idx] ?? ToolCallAccumulator()
                if let id = tc["id"] as? String { acc.id = id }
                if let fn = tc["function"] as? [String: Any] {
                    if let name = fn["name"] as? String { acc.name += name }
                    if let args = fn["arguments"] as? String { acc.arguments += args }
                }
                toolCallAccumulators[idx] = acc
            }
        }
    }

    // MARK: - Finalize

    private func finalizeResult() {
        let calls: [FunctionCallStruct] = toolCallAccumulators
            .sorted { $0.key < $1.key }
            .map { (_, acc) in
                var argsDict: [String: Any] = [:]
                if let d = acc.arguments.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    argsDict = parsed
                }
                return FunctionCallStruct(
                    name: acc.name,
                    arguments: argsDict,
                    callId: acc.id.isEmpty ? nil : acc.id)
            }

        metrics.didComplete(usage: usage, cachedTokens: cachedTokens)

        let result = Result(
            content: contentBuffer,
            toolCalls: calls,
            reasoningContent: reasoningBuffer.isEmpty ? nil : reasoningBuffer,
            usage: usage,
            cachedTokens: cachedTokens)
        completion(.success(result))
    }
}
