//
//  ToolRouterTests.swift
//  LoopIOSTests
//
//  Unit tests for ToolRouter: keyword matching, core tool inclusion,
//  fallback to full set, and 128-tool cap enforcement.
//

import XCTest
@testable import Loop

final class ToolRouterTests: XCTestCase {

    // MARK: - Helpers

    private func makeTool(name: String) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": "test",
                "parameters": ["type": "object", "properties": [:]] as [String: Any],
            ] as [String: Any],
        ]
    }

    private var sampleTools: [[String: Any]] {
        // Build a representative set: core + a few domain tools.
        var tools: [[String: Any]] = []
        // Core tools
        for name in ["read_self_doc", "update_self_doc", "file_list", "file_read",
                      "file_write", "open_panel", "schedule_task"] {
            tools.append(makeTool(name: name))
        }
        // Calendar
        tools.append(makeTool(name: "calendar"))
        tools.append(makeTool(name: "create_calendar_event"))
        tools.append(makeTool(name: "list_upcoming_events"))
        // Slack
        tools.append(makeTool(name: "send_slack_message"))
        tools.append(makeTool(name: "search_slack"))
        // GitHub
        tools.append(makeTool(name: "create_pull_request"))
        tools.append(makeTool(name: "list_pull_requests"))
        // Music
        tools.append(makeTool(name: "play_music"))
        tools.append(makeTool(name: "find_music"))
        // Web
        tools.append(makeTool(name: "exa_search"))
        tools.append(makeTool(name: "fetch_url"))
        return tools
    }

    // MARK: - Tests

    func testCalendarKeywordSelectsCalendarTools() {
        let (selected, omitted) = ToolRouter.select(
            allTools: sampleTools,
            userMessage: "What's on my calendar today?")

        let names = selected.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertTrue(names.contains("calendar"))
        XCTAssertTrue(names.contains("create_calendar_event"))
        // Slack tools should be omitted
        XCTAssertFalse(names.contains("send_slack_message"))
        XCTAssertTrue(omitted.contains("slack"))
    }

    func testSlackKeywordSelectsSlackTools() {
        let (selected, _) = ToolRouter.select(
            allTools: sampleTools,
            userMessage: "Send a slack message to the team")

        let names = selected.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertTrue(names.contains("send_slack_message"))
        XCTAssertFalse(names.contains("calendar"))
    }

    func testCoreToolsAlwaysIncluded() {
        let (selected, _) = ToolRouter.select(
            allTools: sampleTools,
            userMessage: "What's on my calendar?")

        let names = Set(selected.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        })
        XCTAssertTrue(names.contains("read_self_doc"))
        XCTAssertTrue(names.contains("file_list"))
        XCTAssertTrue(names.contains("open_panel"))
    }

    func testAmbiguousMessageIncludesAllTools() {
        let (selected, omitted) = ToolRouter.select(
            allTools: sampleTools,
            userMessage: "Help me with something")

        // No keyword matches → full set returned.
        XCTAssertEqual(selected.count, sampleTools.count)
        XCTAssertTrue(omitted.isEmpty)
    }

    func testVeryShortMessageIncludesAllTools() {
        let (selected, _) = ToolRouter.select(
            allTools: sampleTools,
            userMessage: "hi")

        XCTAssertEqual(selected.count, sampleTools.count)
    }

    func testMultipleGroupsCanMatch() {
        let (selected, omitted) = ToolRouter.select(
            allTools: sampleTools,
            userMessage: "Check my calendar and send a slack message")

        let names = Set(selected.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        })
        XCTAssertTrue(names.contains("calendar"))
        XCTAssertTrue(names.contains("send_slack_message"))
        // Music should be omitted
        XCTAssertTrue(omitted.contains("music"))
    }

    func testCapEnforced() {
        var manyTools: [[String: Any]] = []
        for i in 0..<150 {
            manyTools.append(makeTool(name: "tool_\(i)"))
        }
        // Use ambiguous message → full set, which then gets capped.
        let (selected, _) = ToolRouter.select(
            allTools: manyTools,
            userMessage: "Do everything")

        XCTAssertEqual(selected.count, ToolRouter.maxTools)
    }

    func testToolWithNoNameKept() {
        var tools = sampleTools
        // Malformed tool — no "function" key.
        tools.append(["type": "function"])

        let (selected, _) = ToolRouter.select(
            allTools: tools,
            userMessage: "What's on my calendar?")

        // The malformed tool should still be in the output (safety).
        XCTAssertTrue(selected.contains { ($0["function"] as? [String: Any]) == nil && ($0["type"] as? String) == "function" })
    }
}
