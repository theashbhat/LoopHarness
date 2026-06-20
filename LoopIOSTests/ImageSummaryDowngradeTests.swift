//
//  ImageSummaryDowngradeTests.swift
//  LoopIOSTests
//
//  Verifies the image-token optimization in the local chat clients: an image
//  attachment is sent at full resolution only on the human turn that
//  introduced it. On every later turn, once a `visionSummary` exists, the raw
//  base64 image is replaced by a text description — but if no summary exists
//  yet (the fast-follow-up race), the image is still re-sent so the model never
//  loses sight of it.
//
//  Exercises both `AnthropicChat.wirePayload` and `OpenAIChat.wireMessages`
//  without any network calls.
//

import XCTest
@testable import Loop

final class ImageSummaryDowngradeTests: XCTestCase {

    // A 1×1 transparent PNG — enough for `imageBlock`/`imageDataURL` to read
    // real bytes off disk and emit a vision block.
    private static let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

    private var tempURL: URL!

    override func setUpWithError() throws {
        let data = Data(base64Encoded: Self.onePixelPNGBase64)!
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("img-summary-test-\(UUID().uuidString).png")
        try data.write(to: tempURL)
    }

    override func tearDownWithError() throws {
        if let url = tempURL { try? FileManager.default.removeItem(at: url) }
    }

    private func imageAttachment(summary: String? = nil) -> FileAttachment {
        FileAttachment(
            fileURL: tempURL,
            fileName: "photo.png",
            kind: .image,
            mimeType: "image/png",
            status: .ready,
            visionSummary: summary
        )
    }

    private func userImageMessage(id: String, summary: String? = nil) -> MessageStruct {
        var m = MessageStruct(id: id, role: "user", content: "What's in this image?")
        m.fileAttachment = imageAttachment(summary: summary)
        return m
    }

    // MARK: - Anthropic

    /// Counts `{"type":"image"}` content blocks across all wire turns.
    private func anthropicImageBlockCount(_ wire: [[String: Any]]) -> Int {
        wire.reduce(0) { acc, turn in
            let blocks = (turn["content"] as? [[String: Any]]) ?? []
            return acc + blocks.filter { ($0["type"] as? String) == "image" }.count
        }
    }

    private func anthropicAllText(_ wire: [[String: Any]]) -> String {
        wire.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    func testAnthropicRawImageOnIntroducingTurn() {
        // The image is the last (and only) user turn → sent raw.
        let messages = [userImageMessage(id: "img-turn")]
        let (_, wire) = AnthropicChat.testableWirePayload(from: messages)
        XCTAssertEqual(anthropicImageBlockCount(wire), 1, "Image on its own turn must be sent raw")
    }

    func testAnthropicDowngradesPriorImageWithSummary() {
        let messages = [
            userImageMessage(id: "img-turn", summary: "A red bicycle leaning on a brick wall."),
            MessageStruct(role: "assistant", content: "It's a red bicycle."),
            MessageStruct(role: "user", content: "What color is the wall?"),
        ]
        let (_, wire) = AnthropicChat.testableWirePayload(from: messages)
        XCTAssertEqual(anthropicImageBlockCount(wire), 0,
                       "A summarized image on a prior turn must NOT re-send the raw image")
        XCTAssertTrue(anthropicAllText(wire).contains("A red bicycle leaning on a brick wall."),
                      "The cached description should be inlined as text")
    }

    func testAnthropicFallsBackToRawImageWhenNoSummaryYet() {
        // Prior-turn image but no summary generated yet → still sent raw.
        let messages = [
            userImageMessage(id: "img-turn", summary: nil),
            MessageStruct(role: "assistant", content: "It's a red bicycle."),
            MessageStruct(role: "user", content: "What color is the wall?"),
        ]
        let (_, wire) = AnthropicChat.testableWirePayload(from: messages)
        XCTAssertEqual(anthropicImageBlockCount(wire), 1,
                       "Without a summary the image must still be re-sent (correctness over savings)")
    }

    // MARK: - OpenAI

    /// Counts `image_url` content parts across all wire turns.
    private func openAIImageURLCount(_ wire: [[String: Any]]) -> Int {
        wire.reduce(0) { acc, turn in
            let parts = (turn["content"] as? [[String: Any]]) ?? []
            return acc + parts.filter { ($0["type"] as? String) == "image_url" }.count
        }
    }

    private func openAIAllText(_ wire: [[String: Any]]) -> String {
        wire.compactMap { turn -> String? in
            if let s = turn["content"] as? String { return s }
            if let parts = turn["content"] as? [[String: Any]] {
                return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            return nil
        }.joined(separator: "\n")
    }

    func testOpenAIRawImageOnIntroducingTurn() {
        let messages = [userImageMessage(id: "img-turn")]
        let wire = OpenAIChat.wireMessages(from: messages)
        XCTAssertEqual(openAIImageURLCount(wire), 1, "Image on its own turn must ride inline")
    }

    func testOpenAIDowngradesPriorImageWithSummary() {
        let messages = [
            userImageMessage(id: "img-turn", summary: "A red bicycle leaning on a brick wall."),
            MessageStruct(role: "assistant", content: "It's a red bicycle."),
            MessageStruct(role: "user", content: "What color is the wall?"),
        ]
        let wire = OpenAIChat.wireMessages(from: messages)
        XCTAssertEqual(openAIImageURLCount(wire), 0,
                       "A summarized image on a prior turn must NOT re-send the bytes")
        XCTAssertTrue(openAIAllText(wire).contains("A red bicycle leaning on a brick wall."),
                      "The cached description should be inlined as text")
    }

    func testOpenAIFallsBackToRawImageWhenNoSummaryYet() {
        let messages = [
            userImageMessage(id: "img-turn", summary: nil),
            MessageStruct(role: "assistant", content: "It's a red bicycle."),
            MessageStruct(role: "user", content: "What color is the wall?"),
        ]
        let wire = OpenAIChat.wireMessages(from: messages)
        XCTAssertEqual(openAIImageURLCount(wire), 1,
                       "Without a summary the image must still be re-sent")
    }
}
