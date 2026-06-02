//
//  InferenceMetrics.swift
//  Loop
//
//  Lightweight timing and payload instrumentation for inference requests.
//  Logs provider, model, tool count, payload size, request build time,
//  TTFB (first streamed chunk), total duration, and token usage without
//  exposing API keys, message contents, or tool arguments.
//

import Foundation

struct InferenceMetrics {

    let provider: String
    let model: String
    let toolCount: Int
    let payloadBytes: Int

    private let buildStart: CFAbsoluteTime
    private var requestStart: CFAbsoluteTime = 0
    private var firstChunkTime: CFAbsoluteTime = 0

    /// Begin a metrics span. Call at the top of a provider's `chat()`.
    init(provider: String, model: String, toolCount: Int) {
        self.provider = provider
        self.model = model
        self.toolCount = toolCount
        self.payloadBytes = 0
        self.buildStart = CFAbsoluteTimeGetCurrent()
    }

    /// Stamp payload size once the request body is serialized.
    mutating func didBuildPayload(bytes: Int) {
        let elapsed = CFAbsoluteTimeGetCurrent() - buildStart
        print("[\(provider)] build: \(String(format: "%.0f", elapsed * 1000))ms  payload: \(formatBytes(bytes))  tools: \(toolCount)  model: \(model)")
    }

    /// Call just before URLSession.dataTask / streaming begins.
    mutating func willSendRequest() {
        requestStart = CFAbsoluteTimeGetCurrent()
    }

    /// Call when the first streamed chunk arrives (streaming paths only).
    mutating func didReceiveFirstChunk() {
        guard firstChunkTime == 0 else { return }
        firstChunkTime = CFAbsoluteTimeGetCurrent()
        let ttfb = (firstChunkTime - requestStart) * 1000
        print("[\(provider)] TTFB: \(String(format: "%.0f", ttfb))ms")
    }

    /// Time-to-first-token (first streamed chunk) in seconds, or `nil` if no
    /// chunk has arrived yet. Surfaced to the UI for the per-message latency
    /// readout shown next to the model name.
    var ttft: TimeInterval? {
        guard firstChunkTime > 0, requestStart > 0 else { return nil }
        return firstChunkTime - requestStart
    }

    /// Call when the response is fully received. Logs total duration and
    /// token usage when available.
    func didComplete(usage: TokenUsage? = nil, cachedTokens: Int? = nil) {
        let now = CFAbsoluteTimeGetCurrent()
        let total = (now - requestStart) * 1000
        var line = "[\(provider)] done: \(String(format: "%.0f", total))ms"
        if firstChunkTime > 0 {
            let ttfb = (firstChunkTime - requestStart) * 1000
            line += "  ttfb: \(String(format: "%.0f", ttfb))ms"
        }
        if let u = usage {
            line += "  tokens: \(u.promptTokens)p/\(u.completionTokens)c/\(u.totalTokens)t"
        }
        if let cached = cachedTokens, cached > 0 {
            line += "  cached: \(cached)"
        }
        print(line)
    }

    private func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n)B" }
        if n < 1024 * 1024 { return "\(n / 1024)KB" }
        return String(format: "%.1fMB", Double(n) / (1024 * 1024))
    }
}
