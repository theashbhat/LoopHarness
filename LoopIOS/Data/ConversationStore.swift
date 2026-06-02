//
//  ConversationStore.swift
//  Loop
//
//  Storage abstraction for conversations. Loop persists conversations to one
//  of two backends:
//
//    • Local / iCloud — `ConversationFileStore` (NDJSON under the iCloud
//      Documents container, syncing across the user's devices). This is the
//      default and is what every existing conversation uses.
//    • OpenClaw VM — `OpenClawConversationStore`, which mirrors the same
//      NDJSON-per-conversation format to a remote SSH-accessible workspace.
//
//  `ConversationStore` is the common surface both expose. `SimpleConversation-
//  Manager` owns a `ConversationStoreRouter` that fans reads across both stores
//  (so old local conversations stay visible) and routes writes to whichever
//  store owns a given conversation id. New conversations are created in the
//  *active* backend — local unless the user has selected and validated OpenClaw.
//
//  Pure Foundation so it compiles for the iOS, macOS, and visionOS targets.
//

import Foundation

/// The execution backend a conversation lives on. Persisted as
/// `SimpleConversation.backend` (a raw string) so older entries that predate
/// the field decode cleanly as `.local`.
enum ConversationBackend: String {
    case local
    case openclaw

    /// User-facing label for badges and settings copy.
    var displayName: String {
        switch self {
        case .local:    return "Local"
        case .openclaw: return "OpenClaw VM"
        }
    }
}

/// The persistence operations the message pipeline needs, regardless of where
/// the bytes ultimately land. `ConversationFileStore` and
/// `OpenClawConversationStore` both conform.
///
/// Reads are expected to be answered from an in-memory cache (never blocking on
/// disk or network); writes mutate the cache synchronously and flush to the
/// backing store asynchronously. Both stores post `.conversationStoreDidChange`
/// when their data changes so the UI can refresh.
protocol ConversationStore: AnyObject {
    /// Stable marker stamped onto conversations this store creates
    /// (`"local"` / `"openclaw"`). Matches a `ConversationBackend` raw value.
    var backendMarker: String { get }

    /// True while the store is reconciling with its backing store (iCloud
    /// metadata refresh, remote SSH sync). Drives the sidebar spinner.
    var isSyncing: Bool { get }

    func allConversations() -> [SimpleConversation]
    func conversation(id: String) -> SimpleConversation?
    func mostRecentlyUpdatedConversation() -> SimpleConversation?
    func messages(forConversation id: String) -> [SimpleMessage]

    func createConversation(title: String) -> SimpleConversation
    func saveConversation(_ conversation: SimpleConversation)
    func deleteConversation(id: String)
    func addMessage(_ message: SimpleMessage, toConversation id: String)
    func removeMessage(id messageId: String, fromConversation conversationId: String)
}

// MARK: - Router

/// Fans conversation operations across the local and (optional) OpenClaw
/// stores. Ownership of a given id is decided by which store already knows it
/// (local first), so existing local conversations keep behaving exactly as
/// before even after OpenClaw is enabled. New conversations are created in the
/// active backend, as reported by `isOpenClawActive`.
final class ConversationStoreRouter {

    let local: ConversationStore

    /// Present only when an OpenClaw store has been wired up. The router
    /// tolerates `nil` (the default, OpenClaw-disabled state) by behaving
    /// exactly like the local store alone.
    private(set) var openClaw: ConversationStore?

    /// Returns true when OpenClaw is the selected, configured, and validated
    /// backend — i.e. new conversations should be created remotely. Evaluated
    /// fresh on every create so toggling the setting takes effect immediately.
    private let isOpenClawActive: () -> Bool

    init(local: ConversationStore,
         openClaw: ConversationStore?,
         isOpenClawActive: @escaping () -> Bool) {
        self.local = local
        self.openClaw = openClaw
        self.isOpenClawActive = isOpenClawActive
    }

    /// Attach (or detach) the OpenClaw store at runtime — used when the user
    /// configures OpenClaw without relaunching.
    func setOpenClawStore(_ store: ConversationStore?) {
        openClaw = store
    }

    /// All stores, local first. Local-first ordering means an id present in
    /// both (a vanishingly unlikely UUID collision) resolves to local.
    private var stores: [ConversationStore] {
        if let openClaw = openClaw { return [local, openClaw] }
        return [local]
    }

    /// Where new conversations should be created. Falls back to local whenever
    /// OpenClaw isn't active, which is the graceful-degradation path when SSH
    /// is unconfigured or validation hasn't passed.
    var activeStore: ConversationStore {
        if isOpenClawActive(), let openClaw = openClaw { return openClaw }
        return local
    }

    /// The store that owns `id`: whichever already has it cached. Unknown ids
    /// (a conversation being created this instant) resolve to the active store
    /// so the first message lands in the same backend as the conversation.
    func store(forConversationId id: String) -> ConversationStore {
        if local.conversation(id: id) != nil { return local }
        if let openClaw = openClaw, openClaw.conversation(id: id) != nil { return openClaw }
        return activeStore
    }

    // MARK: Reads (aggregated)

    func allConversations() -> [SimpleConversation] {
        var seen = Set<String>()
        var merged: [SimpleConversation] = []
        for store in stores {
            for conv in store.allConversations() where !seen.contains(conv.id) {
                seen.insert(conv.id)
                merged.append(conv)
            }
        }
        return merged.sorted { $0.updatedAt > $1.updatedAt }
    }

    func conversation(id: String) -> SimpleConversation? {
        for store in stores {
            if let conv = store.conversation(id: id) { return conv }
        }
        return nil
    }

    func mostRecentlyUpdatedConversation() -> SimpleConversation? {
        stores
            .compactMap { $0.mostRecentlyUpdatedConversation() }
            .max { $0.updatedAt < $1.updatedAt }
    }

    func messages(forConversation id: String) -> [SimpleMessage] {
        store(forConversationId: id).messages(forConversation: id)
    }

    var isSyncing: Bool {
        stores.contains { $0.isSyncing }
    }

    // MARK: Writes (routed by ownership)

    func createConversation(title: String) -> SimpleConversation {
        activeStore.createConversation(title: title)
    }

    func saveConversation(_ conversation: SimpleConversation) {
        store(forConversationId: conversation.id).saveConversation(conversation)
    }

    func deleteConversation(id: String) {
        store(forConversationId: id).deleteConversation(id: id)
    }

    func addMessage(_ message: SimpleMessage, toConversation id: String) {
        store(forConversationId: id).addMessage(message, toConversation: id)
    }

    func removeMessage(id messageId: String, fromConversation conversationId: String) {
        store(forConversationId: conversationId).removeMessage(id: messageId, fromConversation: conversationId)
    }
}
