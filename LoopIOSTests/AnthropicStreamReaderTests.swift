//
//  AnthropicStreamReaderTests.swift
//  LoopIOSTests
//
//  Tests for AnthropicStreamReader: tool-call assembly, onDelta suppression
//  once tool_use blocks are detected, and content accumulation.
//

import XCTest
@testable import Loop

final class AnthropicStreamReaderTests: XCTestCase {

    // MARK: - Helpers

    /// Feed SSE event lines to an AnthropicStreamReader and return the result.
    private func feedLines(_ lines: [String],
                           collectDeltas: Bool = false,
                           file: StaticString = #file,
                           line: UInt = #line) -> (result: AnthropicStreamReader.Result?, deltas: [String]) {
        let expectation = expectation(description: "Anthropic completion")
        var captured: AnthropicStreamReader.Result?
        var deltas: [String] = []

        let metrics = InferenceMetrics(provider: "Test", model: "test-model", toolCount: 0)
        let reader = AnthropicStreamReader(
            metrics: metrics,
            onDelta: collectDeltas ? { delta in deltas.append(delta) } : nil
        ) { result in
            if case .success(let r) = result {
                captured = r
            }
            expectation.fulfill()
        }

        let session = URLSession.shared
        let fakeTask = session.dataTask(with: URLRequest(url: URL(string: "https://example.com")!))

        for ssePayload in lines {
            let data = (ssePayload + "\n").data(using: .utf8)!
            reader.urlSession(session, dataTask: fakeTask, didReceive: data)
        }
        reader.urlSession(session, task: fakeTask, didCompleteWithError: nil)

        wait(for: [expectation], timeout: 2)
        return (captured, deltas)
    }

    private func event(_ type: String, json: [String: Any]) -> [String] {
        let data = try! JSONSerialization.data(withJSONObject: json)
        let payload = String(data: data, encoding: .utf8)!
        return ["event: \(type)", "data: \(payload)"]
    }

    // MARK: - Tests

    func testTextOnlyContentAssembly() {
        let lines: [String] =
            event("message_start", json: ["message": ["usage": ["input_tokens": 10]]]) +
            event("content_block_start", json: ["index": 0, "content_block": ["type": "text", "text": ""]]) +
            event("content_block_delta", json: ["index": 0, "delta": ["type": "text_delta", "text": "Hello"]]) +
            event("content_block_delta", json: ["index": 0, "delta": ["type": "text_delta", "text": " world"]]) +
            event("content_block_stop", json: ["index": 0]) +
            event("message_stop", json: [:])

        let (result, _) = feedLines(lines)
        XCTAssertEqual(result?.content, "Hello world")
        XCTAssertTrue(result?.toolCalls.isEmpty ?? true)
    }

    func testToolCallAssembly() {
        let lines: [String] =
            event("message_start", json: ["message": ["usage": ["input_tokens": 5]]]) +
            event("content_block_start", json: ["index": 0, "content_block": ["type": "tool_use", "id": "call_123", "name": "exa_search"]]) +
            event("content_block_delta", json: ["index": 0, "delta": ["type": "input_json_delta", "partial_json": "{\"query\":"]]) +
            event("content_block_delta", json: ["index": 0, "delta": ["type": "input_json_delta", "partial_json": "\"test\"}"]]) +
            event("content_block_stop", json: ["index": 0]) +
            event("message_stop", json: [:])

        let (result, _) = feedLines(lines)
        XCTAssertEqual(result?.toolCalls.count, 1)
        XCTAssertEqual(result?.toolCalls.first?.name, "exa_search")
        XCTAssertEqual(result?.toolCalls.first?.callId, "call_123")
        XCTAssertEqual(result?.toolCalls.first?.arguments["query"] as? String, "test")
    }

    func testTextBeforeToolCallSuppressedFromDelta() {
        // Claude emits a text block ("I'll search for that") then a tool_use.
        // The text should accumulate in content but NOT fire onDelta once
        // the tool_use block starts (preventing leakage into the streaming bubble).
        let lines: [String] =
            event("message_start", json: ["message": ["usage": ["input_tokens": 5]]]) +
            event("content_block_start", json: ["index": 0, "content_block": ["type": "text", "text": ""]]) +
            event("content_block_delta", json: ["index": 0, "delta": ["type": "text_delta", "text": "Searching"]]) +
            event("content_block_stop", json: ["index": 0]) +
            event("content_block_start", json: ["index": 1, "content_block": ["type": "tool_use", "id": "call_abc", "name": "search"]]) +
            // Any text delta after tool_use starts should not fire onDelta
            event("content_block_delta", json: ["index": 1, "delta": ["type": "input_json_delta", "partial_json": "{\"q\":\"x\"}"]]) +
            event("content_block_stop", json: ["index": 1]) +
            event("message_stop", json: [:])

        let (result, deltas) = feedLines(lines, collectDeltas: true)

        // Content buffer has the pre-tool text
        XCTAssertEqual(result?.content, "Searching")
        // Tool call is assembled
        XCTAssertEqual(result?.toolCalls.count, 1)
        XCTAssertEqual(result?.toolCalls.first?.name, "search")
        // The text delta "Searching" DID fire because it arrived before the tool_use block
        XCTAssertEqual(deltas, ["Searching"])
    }

    func testTextDeltaAfterToolUseStartSuppressed() {
        // Edge case: a text_delta arrives on a text block AFTER a tool_use
        // block has already started (shouldn't normally happen, but tests
        // the guard). The delta should NOT fire onDelta.
        let lines: [String] =
            event("message_start", json: ["message": ["usage": ["input_tokens": 5]]]) +
            event("content_block_start", json: ["index": 0, "content_block": ["type": "tool_use", "id": "call_1", "name": "tool"]]) +
            event("content_block_delta", json: ["index": 0, "delta": ["type": "input_json_delta", "partial_json": "{}"]]) +
            event("content_block_stop", json: ["index": 0]) +
            // Hypothetical late text block
            event("content_block_start", json: ["index": 1, "content_block": ["type": "text", "text": ""]]) +
            event("content_block_delta", json: ["index": 1, "delta": ["type": "text_delta", "text": "leaked"]]) +
            event("content_block_stop", json: ["index": 1]) +
            event("message_stop", json: [:])

        let (result, deltas) = feedLines(lines, collectDeltas: true)

        // Content buffer captured it (for the disclosure prose)
        XCTAssertEqual(result?.content, "leaked")
        // But it was NOT streamed live
        XCTAssertTrue(deltas.isEmpty)
    }

    func testUsageParsing() {
        let lines: [String] =
            event("message_start", json: ["message": ["usage": ["input_tokens": 100]]]) +
            event("content_block_start", json: ["index": 0, "content_block": ["type": "text", "text": ""]]) +
            event("content_block_delta", json: ["index": 0, "delta": ["type": "text_delta", "text": "Hi"]]) +
            event("content_block_stop", json: ["index": 0]) +
            event("message_delta", json: ["usage": ["output_tokens": 50]]) +
            event("message_stop", json: [:])

        let (result, _) = feedLines(lines)
        XCTAssertEqual(result?.usage?.promptTokens, 100)
        XCTAssertEqual(result?.usage?.completionTokens, 50)
        XCTAssertEqual(result?.usage?.totalTokens, 150)
    }

    func testErrorMidStreamFiresFailure() {
        let expectation = expectation(description: "Error completion")
        var capturedError: Error?

        let metrics = InferenceMetrics(provider: "Test", model: "test-model", toolCount: 0)
        let reader = AnthropicStreamReader(metrics: metrics) { result in
            if case .failure(let error) = result {
                capturedError = error
            }
            expectation.fulfill()
        }

        let session = URLSession.shared
        let fakeTask = session.dataTask(with: URLRequest(url: URL(string: "https://example.com")!))

        // Feed some text
        let textLines = event("content_block_start", json: ["index": 0, "content_block": ["type": "text", "text": ""]]) +
            event("content_block_delta", json: ["index": 0, "delta": ["type": "text_delta", "text": "Partial"]])
        for line in textLines {
            let data = (line + "\n").data(using: .utf8)!
            reader.urlSession(session, dataTask: fakeTask, didReceive: data)
        }

        // Simulate connectivity failure
        let networkError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        reader.urlSession(session, task: fakeTask, didCompleteWithError: networkError)

        wait(for: [expectation], timeout: 2)
        XCTAssertNotNil(capturedError)
        XCTAssertEqual((capturedError as NSError?)?.code, NSURLErrorNetworkConnectionLost)
    }
}
