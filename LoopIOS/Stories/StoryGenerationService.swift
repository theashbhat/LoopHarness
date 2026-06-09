//
//  StoryGenerationService.swift
//  Loop
//
//  Service layer that coordinates story generation. Mirrors the
//  PDFGenerationService pattern: accepts a request, creates a placeholder
//  StoryAttachment in .generating state, renders the HTML via StoryGenerator,
//  and notifies the host on completion.
//

#if os(iOS) || os(macOS)

import Foundation

/// Implemented by MessagingVC (iOS) or ConversationWindowController (Mac) to
/// receive story lifecycle events.
protocol StorySkillHost: AnyObject {
    func storySkillDidStartGenerating(_ attachment: StoryAttachment)
    func storySkillDidFinishGenerating(_ attachment: StoryAttachment)
}

final class StoryGenerationService {
    static let shared = StoryGenerationService()

    weak var host: StorySkillHost?

    private init() {}

    // MARK: - Public API

    /// Submit a story generation request. Returns the placeholder attachment
    /// synchronously so the caller can render a loading cell immediately.
    @discardableResult
    func submit(title: String,
                template: StoryAttachment.Template,
                jsonPayload: String,
                attachmentId: String? = nil,
                conversationId: String? = nil) -> StoryAttachment {
        let id = attachmentId ?? UUID().uuidString
        var attachment = StoryAttachment(
            id: id,
            title: title,
            template: template,
            jsonPayload: jsonPayload,
            status: .generating,
            conversationId: conversationId
        )

        DispatchQueue.main.async { [weak self] in
            self?.host?.storySkillDidStartGenerating(attachment)
        }

        // Generate on a background queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let outputDir = self?.storiesDirectory()
                let fileURL = try StoryGenerator.shared.generate(
                    template: template,
                    jsonPayload: jsonPayload,
                    outputDirectory: outputDir
                )
                attachment.fileURL = fileURL
                attachment.status = .ready
            } catch {
                attachment.status = .failed
                attachment.failureReason = error.localizedDescription
            }

            DispatchQueue.main.async {
                self?.host?.storySkillDidFinishGenerating(attachment)
            }
        }

        return attachment
    }

    /// Convenience: submit with a dictionary payload.
    @discardableResult
    func submit(title: String,
                template: StoryAttachment.Template,
                data: [String: Any],
                conversationId: String? = nil) -> StoryAttachment {
        let jsonString: String
        if let jsonData = try? JSONSerialization.data(withJSONObject: data),
           let str = String(data: jsonData, encoding: .utf8) {
            jsonString = str
        } else {
            jsonString = "{}"
        }
        return submit(title: title, template: template, jsonPayload: jsonString, conversationId: conversationId)
    }

    // MARK: - Private

    private func storiesDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Stories", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

#endif
