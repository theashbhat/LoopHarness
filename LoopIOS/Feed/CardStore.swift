//
//  CardStore.swift
//  Loop
//
//  Persistence layer for Feed cards. Cards are stored as individual JSON files
//  at workspace://cards/<id>.json. Thread-safe in-memory cache backed by disk.
//

import Foundation

final class CardStore {
    static let shared = CardStore()

    /// Notification posted when a new card is added. Object is the Card.
    static let cardAddedNotification = Notification.Name("CardStore.cardAdded")
    /// Notification posted when a card's state changes.
    static let cardUpdatedNotification = Notification.Name("CardStore.cardUpdated")

    private let cardsFolder = "cards"
    private let assetsFolder = "cards/assets"

    private var cache: [String: Card] = [:]
    private let lock = NSLock()

    /// ISO 8601 encoder/decoder with fractional seconds for round-trip fidelity.
    static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CardStore.dateFormatter.string(from: date))
        }
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            guard let date = CardStore.dateFormatter.date(from: str) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date: \(str)")
            }
            return date
        }
        return d
    }()

    private init() {
        ensureDirectories()
        loadAll()
    }

    // MARK: - Public API

    /// All cards ordered newest-first. `new` cards before `kept`; `archived` excluded.
    var feedCards: [Card] {
        lock.lock(); defer { lock.unlock() }
        return cache.values
            .filter { $0.state != .archived }
            .sorted { lhs, rhs in
                if lhs.state == .new && rhs.state != .new { return true }
                if lhs.state != .new && rhs.state == .new { return false }
                return lhs.createdAt > rhs.createdAt
            }
    }

    /// All cards including archived (for settings recovery).
    var allCards: [Card] {
        lock.lock(); defer { lock.unlock() }
        return cache.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Persist a new card and broadcast.
    @discardableResult
    func add(_ card: Card) -> Card {
        lock.lock()
        cache[card.id] = card
        lock.unlock()
        writeToDisk(card)
        NotificationCenter.default.post(name: CardStore.cardAddedNotification, object: card)
        return card
    }

    /// Update a card's state (keep/archive) and persist.
    func updateState(id: String, state: CardState) {
        lock.lock()
        guard var card = cache[id] else { lock.unlock(); return }
        card.state = state
        cache[id] = card
        lock.unlock()
        writeToDisk(card)
        NotificationCenter.default.post(name: CardStore.cardUpdatedNotification, object: card)
    }

    /// Permanently delete a card: removes it from the cache, deletes its JSON
    /// and any rendered poster asset from disk, and broadcasts an update.
    func remove(id: String) {
        lock.lock()
        let card = cache[id]
        cache[id] = nil
        lock.unlock()
        guard let card = card else { return }

        let fm = FileManager.default
        let jsonURL = Workspace.shared.rootURL
            .appendingPathComponent(cardsFolder, isDirectory: true)
            .appendingPathComponent("\(id).json")
        try? fm.removeItem(at: jsonURL)
        if let poster = posterURL(for: card) {
            try? fm.removeItem(at: poster)
        }
        NotificationCenter.default.post(name: CardStore.cardUpdatedNotification, object: card)
    }

    /// Update a card's image URL after rendering completes.
    func updateImageURL(id: String, imageURL: String) {
        lock.lock()
        guard var card = cache[id] else { lock.unlock(); return }
        card.imageURL = imageURL
        cache[id] = card
        lock.unlock()
        writeToDisk(card)
        NotificationCenter.default.post(name: CardStore.cardUpdatedNotification, object: card)
    }

    /// Retrieve a card by id.
    func card(for id: String) -> Card? {
        lock.lock(); defer { lock.unlock() }
        return cache[id]
    }

    /// Absolute URL for a card's poster asset.
    func posterURL(for card: Card) -> URL? {
        guard let rel = card.imageURL else { return nil }
        return resolveWorkspaceURL(rel)
    }

    /// The workspace-relative path where a card's poster should be saved.
    func posterRelativePath(for cardId: String) -> String {
        return "\(assetsFolder)/\(cardId).png"
    }

    // MARK: - Disk I/O

    private func ensureDirectories() {
        let ws = Workspace.shared
        let fm = FileManager.default
        let cardsDir = ws.rootURL.appendingPathComponent(cardsFolder, isDirectory: true)
        let assetsDir = ws.rootURL.appendingPathComponent(assetsFolder, isDirectory: true)
        try? fm.createDirectory(at: cardsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
    }

    private func writeToDisk(_ card: Card) {
        let url = Workspace.shared.rootURL
            .appendingPathComponent(cardsFolder, isDirectory: true)
            .appendingPathComponent("\(card.id).json")
        do {
            let data = try CardStore.encoder.encode(card)
            try data.write(to: url, options: .atomic)
        } catch {
            print("CardStore: failed to write \(card.id): \(error)")
        }
    }

    private func loadAll() {
        let dir = Workspace.shared.rootURL.appendingPathComponent(cardsFolder, isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let card = try? CardStore.decoder.decode(Card.self, from: data) else { continue }
            cache[card.id] = card
        }
        print("CardStore: loaded \(cache.count) cards from disk")
    }

    private func resolveWorkspaceURL(_ relativePath: String) -> URL {
        return Workspace.shared.rootURL.appendingPathComponent(relativePath)
    }
}
