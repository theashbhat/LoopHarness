//
//  SSEStreamReaderTests.swift
//  LoopIOSTests
//
//  Tests for SSEStreamReader: content assembly, tool-call accumulation
//  from streamed deltas, usage parsing, and reasoning content.
//

import XCTest
@testable import Loop

final class SSEStreamReaderTests: XCTestCase {

    // MARK: - Helpers

    /// Feed SSE lines to a reader and collect the result synchronously.
    private func feedLines(_ lines: [String],
                           file: StaticString = #file,
                           line: UInt = #line) -> SSEStreamReader.Result? {
        let expectation = expectation(description: "SSE completion")
        var captured: SSEStreamReader.Result?

        let metrics = InferenceMetrics(provider: "Test", model: "test-model", toolCount: 0)
        let reader = SSEStreamReader(metrics: metrics) { result in
            if case .success(let r) = result {
                captured = r
            }
            expectation.fulfill()
        }

        // Simulate URLSession delivering data then completing.
        let session = URLSession.shared
        let fakeTask = session.dataTask(with: URLRequest(url: URL(string: "https://example.com")!))

        for ssePayload in lines {
            let data = (ssePayload + "\n").data(using: .utf8)!
            reader.urlSession(session, dataTask: fakeTask, didReceive: data)
        }
        reader.urlSession(session, task: fakeTask, didCompleteWithError: nil)

        wait(for: [expectation], timeout: 2)
        return captured
    }

    private func chunk(content: String) -> String {
        let json: [String: Any] = [
            "choices": [["delta": ["content": content]]] as [[String: Any]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return "data: \(String(data: data, encoding: .utf8)!)"
    }

    private func toolCallChunk(index: Int, id: String? = nil,
                                name: String? = nil,
                                arguments: String? = nil) -> String {
        var fn: [String: Any] = [:]
        if let n = name { fn["name"] = n }
        if let a = arguments { fn["arguments"] = a }
        var tc: [String: Any] = ["index": index, "function": fn]
        if let id = id { tc["id"] = id }
        let json: [String: Any] = [
            "choices": [["delta": ["tool_calls": [tc]]]] as [[String: Any]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return "data: \(String(data: data, encoding: .utf8)!)"
    }

    // MARK: - Tests

    func testContentAssembly() {
        let result = feedLines([
            chunk(content: "Hello"),
            chunk(content: " world"),
            chunk(content: "!"),
            "data: [DONE]",
        ])

        XCTAssertEqual(result?.content, "Hello world!")
        XCTAssertTrue(result?.toolCalls.isEmpty ?? true)
    }

    func testSingleToolCallAssembly() {
        let result = feedLines([
            toolCallChunk(index: 0, id: "call_abc", name: "exa_search"),
            toolCallChunk(index: 0, arguments: "{\"query\":"),
            toolCallChunk(index: 0, arguments: "\"test\"}"),
            "data: [DONE]",
        ])

        XCTAssertEqual(result?.toolCalls.count, 1)
        let call = result?.toolCalls.first
        XCTAssertEqual(call?.name, "exa_search")
        XCTAssertEqual(call?.callId, "call_abc")
        XCTAssertEqual(call?.arguments["query"] as? String, "test")
    }

    func testParallelToolCallAssembly() {
        let result = feedLines([
            toolCallChunk(index: 0, id: "call_1", name: "file_read"),
            toolCallChunk(index: 1, id: "call_2", name: "file_list"),
            toolCallChunk(index: 0, arguments: "{\"path\":\"/a\"}"),
            toolCallChunk(index: 1, arguments: "{\"path\":\"/b\"}"),
            "data: [DONE]",
        ])

        XCTAssertEqual(result?.toolCalls.count, 2)
        XCTAssertEqual(result?.toolCalls[0].name, "file_read")
        XCTAssertEqual(result?.toolCalls[0].arguments["path"] as? String, "/a")
        XCTAssertEqual(result?.toolCalls[1].name, "file_list")
        XCTAssertEqual(result?.toolCalls[1].arguments["path"] as? String, "/b")
    }

    func testUsageParsing() {
        let usageJSON: [String: Any] = [
            "choices": [] as [Any],
            "usage": [
                "prompt_tokens": 100,
                "completion_tokens": 50,
                "total_tokens": 150,
                "prompt_tokens_details": ["cached_tokens": 30],
            ] as [String: Any],
        ]
        let data = try! JSONSerialization.data(withJSONObject: usageJSON)
        let usageLine = "data: \(String(data: data, encoding: .utf8)!)"

        let result = feedLines([
            chunk(content: "Hi"),
            usageLine,
            "data: [DONE]",
        ])

        XCTAssertEqual(result?.usage?.promptTokens, 100)
        XCTAssertEqual(result?.usage?.completionTokens, 50)
        XCTAssertEqual(result?.usage?.totalTokens, 150)
        XCTAssertEqual(result?.cachedTokens, 30)
    }

    func testReasoningContent() {
        let reasoningJSON: [String: Any] = [
            "choices": [["delta": ["reasoning_content": "thinking..."]]] as [[String: Any]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: reasoningJSON)
        let reasoningLine = "data: \(String(data: data, encoding: .utf8)!)"

        let result = feedLines([
            reasoningLine,
            chunk(content: "Answer"),
            "data: [DONE]",
        ])

        XCTAssertEqual(result?.reasoningContent, "thinking...")
        XCTAssertEqual(result?.content, "Answer")
    }

    func testDoneMarkerIgnored() {
        let result = feedLines([
            chunk(content: "test"),
            "data: [DONE]",
        ])

        XCTAssertEqual(result?.content, "test")
    }

    func testEmptyLinesSkipped() {
        let result = feedLines([
            "",
            "   ",
            chunk(content: "ok"),
            "",
            "data: [DONE]",
        ])

        XCTAssertEqual(result?.content, "ok")
    }
}
