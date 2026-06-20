//
//  LoopConversationEntity.swift
//  Loop
//
//  AppEntity + IndexedEntity representation of a Loop conversation so Siri
//  and Spotlight can search across them.
//
//  "What did Loop say about my Scout meeting?"  — Siri matches the query
//  against the indexed title and content description fields and surfaces
//  matching conversations.
//

import AppIntents
import CoreSpotlight
import Foundation

// MARK: - Conversation Entity

@available(iOS 27.0, *)
struct LoopConversationEntity: AppEntity, IndexedEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: "Loop Conversation",
            numericFormat: "\(placeholder: .int) conversations"
        )
    }

    static var defaultQuery = LoopConversationQuery()

    var id: String
    var title: String
    var lastMessage: String
    var updatedAt: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(lastMessage)"
        )
    }

    /// Spotlight-indexable attributes so conversations surface in system search.
    var attributeSet: CSSearchableItemAttributeSet? {
        let attrs = CSSearchableItemAttributeSet()
        attrs.displayName = title
        attrs.contentDescription = lastMessage
        return attrs
    }
}

// MARK: - Conversation Query

@available(iOS 27.0, *)
struct LoopConversationQuery: EntityQuery {

    func entities(for identifiers: [String]) async throws -> [LoopConversationEntity] {
        let manager = SimpleConversationManager.shared
        return identifiers.compactMap { id in
            guard let conv = manager.getConversation(by: id) else { return nil }
            return LoopConversationEntity(from: conv)
        }
    }

    func suggestedEntities() async throws -> [LoopConversationEntity] {
        let all = SimpleConversationManager.shared.getAllConversations()
        let sorted = all.sorted { $0.updatedAt > $1.updatedAt }
        return sorted.prefix(20).map { LoopConversationEntity(from: $0) }
    }
}

// MARK: - Convenience initializer

@available(iOS 27.0, *)
extension LoopConversationEntity {
    init(from conversation: SimpleConversation) {
        self.id = conversation.id
        self.title = conversation.title
        self.lastMessage = conversation.messages.last?.content ?? ""
        self.updatedAt = conversation.updatedAt
    }
}
