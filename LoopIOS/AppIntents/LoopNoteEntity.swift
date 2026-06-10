//
//  LoopNoteEntity.swift
//  Loop
//
//  AppEntity + IndexedEntity for Obsidian notes managed through Loop, making
//  them searchable via Siri and Spotlight.
//
//  "What did Loop say about my Scout meeting?" — Siri matches against
//  the indexed note title and snippet.
//

import AppIntents
import CoreSpotlight
import Foundation

// MARK: - Note Entity

@available(iOS 27.0, *)
struct LoopNoteEntity: AppEntity, IndexedEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: "Loop Note",
            numericFormat: "\(placeholder: .int) notes"
        )
    }

    static var defaultQuery = LoopNoteQuery()

    /// Vault-relative path (doubles as the stable identifier).
    var id: String
    var title: String
    var snippet: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(snippet)"
        )
    }

    /// Spotlight-indexable attributes.
    var attributeSet: CSSearchableItemAttributeSet? {
        let attrs = CSSearchableItemAttributeSet()
        attrs.displayName = title
        attrs.contentDescription = snippet
        return attrs
    }
}

// MARK: - Note Query

@available(iOS 27.0, *)
struct LoopNoteQuery: EntityQuery {

    func entities(for identifiers: [String]) async throws -> [LoopNoteEntity] {
        guard ObsidianClient.isConfigured else { return [] }

        var results: [LoopNoteEntity] = []
        for path in identifiers {
            if let entity = try? await fetchNote(path: path) {
                results.append(entity)
            }
        }
        return results
    }

    func suggestedEntities() async throws -> [LoopNoteEntity] {
        guard ObsidianClient.isConfigured else { return [] }

        return await withCheckedContinuation { continuation in
            ObsidianClient.shared.today { json, error in
                guard let todayPath = json?["path"] as? String else {
                    continuation.resume(returning: [])
                    return
                }
                ObsidianClient.shared.listFolder(path: todayPath) { listJSON, listError in
                    guard let files = listJSON?["files"] as? [[String: Any]] else {
                        continuation.resume(returning: [])
                        return
                    }
                    let entities = files.compactMap { file -> LoopNoteEntity? in
                        guard let name = file["name"] as? String,
                              let path = file["path"] as? String else { return nil }
                        return LoopNoteEntity(
                            id: path,
                            title: name.replacingOccurrences(of: ".md", with: ""),
                            snippet: ""
                        )
                    }
                    continuation.resume(returning: entities)
                }
            }
        }
    }

    /// Fetch a single note by path from the Obsidian relay.
    private func fetchNote(path: String) async throws -> LoopNoteEntity {
        return try await withCheckedThrowingContinuation { continuation in
            ObsidianClient.shared.readNote(path: path) { json, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let content = (json?["content"] as? String) ?? ""
                let title = path.components(separatedBy: "/").last?
                    .replacingOccurrences(of: ".md", with: "") ?? path
                let snippet = String(content.prefix(200))
                continuation.resume(returning: LoopNoteEntity(
                    id: path, title: title, snippet: snippet
                ))
            }
        }
    }
}
