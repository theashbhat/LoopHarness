//
//  CardRenderer.swift
//  Loop
//
//  Pluggable renderer interface for cards. Each CardKind maps to a concrete
//  renderer that produces a 4:3 landscape poster PNG. Future backends (HTML→image,
//  Higgsfield, vectors) conform to CardRendering and register themselves.
//

#if os(iOS)
import UIKit
#endif
import Foundation

/// Protocol for card renderers. Each implementation takes a card's payload and
/// produces a poster image (4:3 landscape, 1200×900 default).
protocol CardRendering {
    /// The kind this renderer handles.
    var kind: CardKind { get }

    /// Render a poster image for the given card. Completion delivers the
    /// absolute file URL of the saved PNG, or an error.
    func render(card: Card, completion: @escaping (Result<URL, Error>) -> Void)
}

/// Registry that dispatches renderCard(kind, payload) to the correct backend.
/// v1 ships with image and markdown renderers; future kinds drop in without
/// changing the tool surface.
final class CardRendererRegistry {
    static let shared = CardRendererRegistry()

    private var renderers: [CardKind: CardRendering] = [:]

    private init() {
        #if os(iOS)
        register(ImageCardRenderer())
        register(MarkdownCardRenderer())
        #endif
    }

    func register(_ renderer: CardRendering) {
        renderers[renderer.kind] = renderer
    }

    /// Render a card using the appropriate backend.
    func render(card: Card, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let renderer = renderers[card.kind] else {
            completion(.failure(CardRendererError.noRenderer(card.kind)))
            return
        }
        renderer.render(card: card, completion: completion)
    }

    enum CardRendererError: Error, LocalizedError {
        case noRenderer(CardKind)
        case renderFailed(String)

        var errorDescription: String? {
            switch self {
            case .noRenderer(let k): return "No renderer registered for kind '\(k.rawValue)'"
            case .renderFailed(let m): return "Render failed: \(m)"
            }
        }
    }
}
