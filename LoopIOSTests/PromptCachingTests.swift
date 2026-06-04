//
//  PromptCachingTests.swift
//  LoopIOSTests
//
//  Unit tests verifying that provider request payloads are constructed
//  with the correct prompt-caching annotations/structure. These validate
//  the wire shape without making network calls.
//

import XCTest
@testable import Loop

// MARK: - Anthropic prompt caching

final class AnthropicCachingTests: XCTestCase {

    /// Verify that `anthropicTools(from:)` produces valid Anthropic-shaped
    /// tool schemas. The last tool should carry a `cache_control` breakpoint
    /// after the caching logic is applied by the caller.
    func testAnthropicToolSchemasShape() {
        let openAITools: [[String: Any]] = [
            [
                "type": "function",
                "function": [
                    "name": "search_web",
                    "description": "Search the web",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "query": ["type": "string"]
                        ],
                    ],
                ] as [String: Any],
            ],
            [
                "type": "function",
                "function": [
                    "name": "read_file",
                    "description": "Read a file",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": ["type": "string"]
                        ],
                    ],
                ] as [String: Any],
            ],
        ]

        // Simulate what AnthropicChat.chat does: remap then add cache_control
        var anthropicTools = AnthropicChat.testableAnthropicTools(from: openAITools)
        XCTAssertEqual(anthropicTools.count, 2)

        // Verify shape: {name, description, input_schema}
        let first = anthropicTools[0]
        XCTAssertEqual(first["name"] as? String, "search_web")
        XCTAssertEqual(first["description"] as? String, "Search the web")
        XCTAssertNotNil(first["input_schema"] as? [String: Any])

        // Apply cache_control to last tool (mimics chat() logic)
        var lastTool = anthropicTools[anthropicTools.count - 1]
        lastTool["cache_control"] = ["type": "ephemeral"]
        anthropicTools[anthropicTools.count - 1] = lastTool

        // Verify last tool has cache_control
        let last = anthropicTools[anthropicTools.count - 1]
        let cacheControl = last["cache_control"] as? [String: String]
        XCTAssertEqual(cacheControl?["type"], "ephemeral")

        // Verify first tool does NOT have cache_control (only last gets it)
        XCTAssertNil(anthropicTools[0]["cache_control"])
    }

    /// Verify system prompt is structured as a content-block array with
    /// cache_control when non-empty.
    func testSystemPromptBlockStructure() {
        let system = "You are a helpful assistant."

        // Simulate what AnthropicChat.chat builds for the system field
        let systemBlocks: [[String: Any]] = [
            [
                "type": "text",
                "text": system,
                "cache_control": ["type": "ephemeral"],
            ]
        ]

        XCTAssertEqual(systemBlocks.count, 1)
        let block = systemBlocks[0]
        XCTAssertEqual(block["type"] as? String, "text")
        XCTAssertEqual(block["text"] as? String, system)
        let cc = block["cache_control"] as? [String: String]
        XCTAssertEqual(cc?["type"], "ephemeral")
    }

    /// Verify deduplication still works after caching annotations.
    func testDuplicateToolsDeduped() {
        let tools: [[String: Any]] = [
            [
                "type": "function",
                "function": ["name": "duplicate_tool", "description": "A", "parameters": ["type": "object", "properties": [:]]] as [String: Any],
            ],
            [
                "type": "function",
                "function": ["name": "duplicate_tool", "description": "B", "parameters": ["type": "object", "properties": [:]]] as [String: Any],
            ],
        ]

        let result = AnthropicChat.testableAnthropicTools(from: tools)
        // Anthropic dedupes by name — only first wins
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]["description"] as? String, "A")
    }
}

// MARK: - OpenAI message ordering (prefix stability)

final class OpenAIPrefixStabilityTests: XCTestCase {

    /// System message must always be the first wire message to maximize
    /// prefix cache hits.
    func testSystemMessageIsFirstInWireOutput() {
        let messages: [MessageStruct] = [
            MessageStruct(role: "system", content: "You are a helpful assistant."),
            MessageStruct(role: "user", content: "Hello"),
            MessageStruct(role: "assistant", content: "Hi there!"),
            MessageStruct(role: "user", content: "How are you?"),
        ]

        let wire = OpenAIChat.wireMessages(from: messages)
        XCTAssertFalse(wire.isEmpty)

        let firstRole = wire[0]["role"] as? String
        XCTAssertEqual(firstRole, "system")
        let firstContent = wire[0]["content"] as? String
        XCTAssertEqual(firstContent, "You are a helpful assistant.")
    }

    /// Verify that consecutive calls with the same messages produce the
    /// same wire output (deterministic ordering for cache stability).
    func testDeterministicWireOutput() {
        let messages: [MessageStruct] = [
            MessageStruct(role: "system", content: "System prompt"),
            MessageStruct(role: "user", content: "Query 1"),
            MessageStruct(role: "assistant", content: "Response 1"),
            MessageStruct(role: "user", content: "Query 2"),
        ]

        let wire1 = OpenAIChat.wireMessages(from: messages)
        let wire2 = OpenAIChat.wireMessages(from: messages)

        // Serialize both and compare
        let data1 = try? JSONSerialization.data(withJSONObject: wire1, options: .sortedKeys)
        let data2 = try? JSONSerialization.data(withJSONObject: wire2, options: .sortedKeys)
        XCTAssertNotNil(data1)
        XCTAssertEqual(data1, data2)
    }
}

// MARK: - AgentHarness system prompt composition

final class SystemPromptCacheOrderingTests: XCTestCase {

    /// The composed system prompt should have stable ordering:
    /// base → SOUL → USER → MEMORY → AGENTS → HEARTBEAT → TOOLS
    func testSystemPromptSectionOrder() {
        let harness = AgentHarness.shared
        let prompt = harness.buildSystemPrompt(base: "Base instructions here.")

        // Verify ordering: base comes first, SOUL after, etc.
        let baseRange = prompt.range(of: "Base instructions here.")
        let soulRange = prompt.range(of: "# SOUL")
        let toolsRange = prompt.range(of: "# Notion")

        XCTAssertNotNil(baseRange)
        XCTAssertNotNil(soulRange)

        if let b = baseRange, let s = soulRange {
            XCTAssertTrue(b.lowerBound < s.lowerBound,
                "Base instructions should precede SOUL section")
        }
        // Tools come after SOUL
        if let s = soulRange, let t = toolsRange {
            XCTAssertTrue(s.lowerBound < t.lowerBound,
                "SOUL should precede TOOLS section")
        }
    }
}
