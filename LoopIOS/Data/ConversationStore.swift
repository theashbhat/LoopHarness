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
//  Manager` owns a `ConversationStoreRouter`. The conversation *list* reflects
//  only the active backend (joining an OpenClaw VM replaces the local list with
//  the VM's sessions; selecting Local restores the on-device list), while
//  id-targeted reads/writes still route to whichever store owns a given
//  conversation id so an in-flight conversation on a now-hidden backend is never
//  corrupted. New conversations are created in the *active* backend — local
//  unless the user has selected and validated OpenClaw.
//
//  Pure Foundation so it compiles for the iOS, macOS, and visionOS targets.
//

import Foundation

/// Coarse category of the backend a conversation lives on, used for display
/// (the sidebar "VM" badge). The concrete backend is identified by id in
/// `SimpleConversation.backend`; this enum just distinguishes local from any
/// remote backend. A nil/`"local"` marker is `.local`; anything else `.remote`.
enum ConversationBackend: String {
    case local
    case remote

    /// User-facing label for badges and settings copy.
    var displayName: String {
        switch self {
        case .local:  return "Local"
        case .remote: return "Remote VM"
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
    /// Replace an existing message (matched by id) in place, preserving order.
    /// Used when a message's content/attachment changes after first write —
    /// e.g. an image flips from generating to ready. No-op if not present.
    func updateMessage(_ message: SimpleMessage, inConversation conversationId: String)
    func removeMessage(id messageId: String, fromConversation conversationId: String)
}

// MARK: - Router

/// Fans conversation operations across the local store and any number of remote
/// backend stores (keyed by backend id). Ownership of a given id is decided by
/// which store already knows it (local first), so existing conversations keep
/// behaving exactly as before even as backends are added or removed. New
/// conversations are created in the active backend, as reported by
/// `activeRemoteID` (nil ⇒ local).
final class ConversationStoreRouter {

    let local: ConversationStore

    /// Remote stores keyed by backend id. Empty in the default, local-only
    /// state, in which the router behaves exactly like the local store alone.
    private(set) var remotes: [String: ConversationStore]

    /// The active remote backend id, or nil when local is active. Evaluated
    /// fresh on every create so changing the selection takes effect immediately.
    private let activeRemoteID: () -> String?

    init(local: ConversationStore,
         remotes: [String: ConversationStore] = [:],
         activeRemoteID: @escaping () -> String?) {
        self.local = local
        self.remotes = remotes
        self.activeRemoteID = activeRemoteID
    }

    /// Replace the set of remote stores at runtime — used when the user adds,
    /// edits, or removes backends without relaunching.
    func setRemotes(_ remotes: [String: ConversationStore]) {
        self.remotes = remotes
    }

    /// All stores, local first. Local-first ordering means an id present in more
    /// than one (a vanishingly unlikely UUID collision) resolves to local.
    private var stores: [ConversationStore] {
        [local] + Array(remotes.values)
    }

    /// Where new conversations should be created. Falls back to local whenever
    /// no remote backend is active — the graceful-degradation path when the
    /// selected remote is unconfigured, unvalidated, or simply Local.
    var activeStore: ConversationStore {
        if let id = activeRemoteID(), let store = remotes[id] { return store }
        return local
    }

    /// The store that owns `id`: whichever already has it cached. Unknown ids
    /// (a conversation being created this instant) resolve to the active store
    /// so the first message lands in the same backend as the conversation.
    func store(forConversationId id: String) -> ConversationStore {
        if local.conversation(id: id) != nil { return local }
        for store in remotes.values where store.conversation(id: id) != nil { return store }
        return activeStore
    }

    // MARK: Reads

    /// The conversation *list* shows only the active backend — joining an
    /// OpenClaw VM replaces the local list with the VM's sessions, and selecting
    /// Local restores the on-device list. (Targeted reads/writes below still
    /// resolve by ownership so an in-flight conversation on a now-hidden backend
    /// is never corrupted.)
    func allConversations() -> [SimpleConversation] {
        activeStore.allConversations()
    }

    /// Resolve a specific id across every store (not just the active one) so a
    /// conversation that is still open while its backend is hidden keeps loading.
    func conversation(id: String) -> SimpleConversation? {
        for store in stores {
            if let conv = store.conversation(id: id) { return conv }
        }
        return nil
    }

    /// Used by launch / `loadLastConversation`, so it must follow the active
    /// backend — opening onto the active backend's most recent chat.
    func mostRecentlyUpdatedConversation() -> SimpleConversation? {
        activeStore.mostRecentlyUpdatedConversation()
    }

    func messages(forConversation id: String) -> [SimpleMessage] {
        store(forConversationId: id).messages(forConversation: id)
    }

    /// Only the visible (active) backend drives the sidebar spinner; a hidden
    /// backend syncing in the background shouldn't show a spinner the user can't
    /// relate to any visible content.
    var isSyncing: Bool {
        activeStore.isSyncing
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

    func updateMessage(_ message: SimpleMessage, inConversation conversationId: String) {
        store(forConversationId: conversationId).updateMessage(message, inConversation: conversationId)
    }

    func removeMessage(id messageId: String, fromConversation conversationId: String) {
        store(forConversationId: conversationId).removeMessage(id: messageId, fromConversation: conversationId)
    }
}
