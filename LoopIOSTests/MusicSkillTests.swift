//
//  MusicSkillTests.swift
//  LoopIOSTests
//
//  Tests for MusicSkill tool schema and dispatch validation. The queue-
//  rebuild and playlist-creation paths need a live MusicKit session (device
//  or simulator with Apple Music), so they are covered by the manual repro
//  steps in the PR description. These tests verify the parts that can run
//  without hardware.
//

import XCTest
@testable import Loop

final class MusicSkillTests: XCTestCase {

    private let skill = MusicSkill.shared

    // MARK: - Tool schema validation

    func testToolNamesMatchToolDefinitions() {
        let definedNames = MusicSkill.tools.compactMap { tool -> String? in
            (tool["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertEqual(Set(definedNames), MusicSkill.toolNames,
                       "toolNames must exactly match the names in the tools array")
    }

    func testPlayMusicSchemaIncludesQueueMode() {
        let playTool = MusicSkill.tools.first { tool in
            (tool["function"] as? [String: Any])?["name"] as? String == "play_music"
        }
        let params = ((playTool?["function"] as? [String: Any])?["parameters"] as? [String: Any])
        let props = params?["properties"] as? [String: Any]

        XCTAssertNotNil(props?["queue_mode"], "play_music must expose queue_mode")
        let qm = props?["queue_mode"] as? [String: Any]
        let allowed = qm?["enum"] as? [String]
        XCTAssertEqual(allowed, ["replace", "append"])
    }

    func testCreatePlaylistSchemaRequiresNameAndTrackIds() {
        let tool = MusicSkill.tools.first { tool in
            (tool["function"] as? [String: Any])?["name"] as? String == "create_playlist"
        }
        let params = ((tool?["function"] as? [String: Any])?["parameters"] as? [String: Any])
        let required = params?["required"] as? [String]
        XCTAssertTrue(required?.contains("name") == true)
        XCTAssertTrue(required?.contains("track_ids") == true)
    }

    // MARK: - Dispatch routing

    func testHandlesRecognisesAllMusicTools() {
        for name in MusicSkill.toolNames {
            XCTAssertTrue(skill.handles(functionName: name),
                          "MusicSkill should handle \(name)")
        }
        XCTAssertFalse(skill.handles(functionName: "unknown_tool"))
    }

    func testStatusTextForPlayMusicReturnsExpected() {
        let call = FunctionCallStruct(
            name: "play_music",
            arguments: ["target_id": "12345", "target_type": "song", "queue_mode": "append"]
        )
        XCTAssertEqual(skill.statusText(for: call), "starting playback")
    }

    func testStatusTextForCreatePlaylistIncludesName() {
        let call = FunctionCallStruct(
            name: "create_playlist",
            arguments: ["name": "Focus Mix", "track_ids": ["a", "b"]]
        )
        XCTAssertEqual(skill.statusText(for: call), "creating playlist \"Focus Mix\"")
    }
}
