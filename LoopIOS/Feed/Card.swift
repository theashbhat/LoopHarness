//
//  Card.swift
//  Loop
//
//  Data model for Feed cards. Persisted as JSON in workspace://cards/<id>.json.
//  Image assets live at workspace://cards/assets/<id>.png.
//

import Foundation

/// The visual kind of a card — determines which renderer produces the poster.
enum CardKind: String, Codable {
    case image
    case markdown
}

/// Lifecycle state of a card in the user's feed.
enum CardState: String, Codable {
    case new
    case kept
    case archived
}

/// A single feed card produced by the `generate_card` tool.
struct Card: Codable, Identifiable {
    let id: String
    let kind: CardKind
    var title: String
    var body: String
    /// Relative path to the rendered poster image inside workspace (e.g.
    /// "cards/assets/<id>.png"). Nil while the renderer is still working.
    var imageURL: String?
    /// Attribution / provenance string (e.g. "calendar", "user request").
    var source: String?
    /// Freeform tags for filtering/search.
    var tags: [String]
    let createdAt: Date
    var state: CardState

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body
        case imageURL = "image_url"
        case source, tags
        case createdAt = "created_at"
        case state
    }

    init(id: String = UUID().uuidString,
         kind: CardKind,
         title: String,
         body: String,
         imageURL: String? = nil,
         source: String? = nil,
         tags: [String] = [],
         createdAt: Date = Date(),
         state: CardState = .new) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.imageURL = imageURL
        self.source = source
        self.tags = tags
        self.createdAt = createdAt
        self.state = state
    }
}
