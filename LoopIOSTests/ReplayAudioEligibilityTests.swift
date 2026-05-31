//
//  ReplayAudioEligibilityTests.swift
//  LoopIOSTests
//
//  Tests for the "Replay Audio" context-menu eligibility logic:
//  assistant messages with speakable content should be eligible;
//  user messages, system messages, and empty-content messages should not.
//

import XCTest
@testable import Loop

final class ReplayAudioEligibilityTests: XCTestCase {

    private let sanitizer = SpeechSanitizer()

    /// Helper that mirrors MessagingVC.messageHasReplayableAudio.
    private func hasReplayableAudio(_ message: MessageStruct) -> Bool {
        guard message.role == "assistant" else { return false }
        let cleaned = sanitizer.sanitize(message.content)
        return !cleaned.isEmpty
    }

    // MARK: - Eligible messages

    func testAssistantWithTextIsEligible() {
        let msg = MessageStruct(role: "assistant", content: "Hello, how can I help?")
        XCTAssertTrue(hasReplayableAudio(msg))
    }

    func testAssistantWithLongTextIsEligible() {
        let msg = MessageStruct(role: "assistant", content: "Here is a detailed explanation of the topic you asked about.")
        XCTAssertTrue(hasReplayableAudio(msg))
    }

    // MARK: - Ineligible messages

    func testUserMessageIsNotEligible() {
        let msg = MessageStruct(role: "user", content: "What time is it?")
        XCTAssertFalse(hasReplayableAudio(msg))
    }

    func testSystemMessageIsNotEligible() {
        let msg = MessageStruct(role: "system", content: "You are a helpful assistant.")
        XCTAssertFalse(hasReplayableAudio(msg))
    }

    func testFunctionMessageIsNotEligible() {
        let msg = MessageStruct(role: "function", content: "result data")
        XCTAssertFalse(hasReplayableAudio(msg))
    }

    func testAssistantWithEmptyContentIsNotEligible() {
        let msg = MessageStruct(role: "assistant", content: "")
        XCTAssertFalse(hasReplayableAudio(msg))
    }

    func testAssistantWithOnlyMarkdownIsNotEligible() {
        // Content that is entirely a code fence — sanitizer strips it.
        let msg = MessageStruct(role: "assistant", content: "```\nprint('hi')\n```")
        XCTAssertFalse(hasReplayableAudio(msg))
    }
}
