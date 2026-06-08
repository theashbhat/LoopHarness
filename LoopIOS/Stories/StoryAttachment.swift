//
//  StoryAttachment.swift
//  Loop
//
//  Defines the story attachment type for chat messages. Mirrors the existing
//  ImageAttachment / PDFAttachment pattern: starts at .generating, flips to
//  .ready with a rendered HTML file URL, or .failed with a reason.
//

import Foundation

/// A generated HTML story (1080×1920 portrait infographic) attached to a chat
/// message. The cell renders it as a scaled thumbnail card; tapping opens the
/// full-screen story player with tap-to-advance navigation.
struct StoryAttachment: Codable {
    enum Status: String, Codable, Equatable {
        case generating
        case ready
        case failed
    }

    /// Predefined template identifiers. Each corresponds to an HTML template
    /// bundled in Stories/Templates/.
    enum Template: String, Codable, Equatable {
        case dailyRecap = "DailyRecap"
        case activitySummary = "ActivitySummary"
    }

    let id: String
    let title: String
    let template: Template
    /// The JSON data payload that was fed into the template.
    let jsonPayload: String
    /// URL to the rendered self-contained HTML file in the workspace.
    var fileURL: URL?
    var status: Status
    var failureReason: String?
    let conversationId: String?

    init(id: String = UUID().uuidString,
         title: String,
         template: Template,
         jsonPayload: String,
         fileURL: URL? = nil,
         status: Status = .generating,
         failureReason: String? = nil,
         conversationId: String? = nil) {
        self.id = id
        self.title = title
        self.template = template
        self.jsonPayload = jsonPayload
        self.fileURL = fileURL
        self.status = status
        self.failureReason = failureReason
        self.conversationId = conversationId
    }
}
