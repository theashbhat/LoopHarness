//
//  PendingConversationOpen.swift
//  Loop
//
//  One-shot box for a "open this conversation" request that arrives before
//  MessagingVC (or the conversation store) is ready to honor it — the
//  cold-start notification-tap path. A cron / runner-turn push is usually
//  tapped while the app is killed: `didReceive` fires before the storyboard's
//  MessagingVC is in the window hierarchy and before ConversationFileStore has
//  hydrated, so the immediate `getConversation(by:)` lookup returns nil and the
//  tap would otherwise be dropped. AppDelegate stashes the id here instead;
//  MessagingVC drains it in `viewDidLoad` and again on `.conversationStoreDidBecomeReady`.
//
//  Single slot (last write wins): if two notifications are tapped, the user
//  wants the most recent conversation, so clobbering the earlier id is correct.
//

import Foundation

final class PendingConversationOpen {
    static let shared = PendingConversationOpen()
    private init() {}

    private var conversationId: String?
    private let lock = NSLock()

    /// Stash a conversation id to open once the chat surface is ready.
    func set(_ id: String) {
        lock.lock()
        conversationId = id
        lock.unlock()
    }

    /// Atomically read + clear the stashed id, so a drain on view-load can't
    /// race a drain on store-ready into opening the same conversation twice.
    func take() -> String? {
        lock.lock()
        let id = conversationId
        conversationId = nil
        lock.unlock()
        return id
    }
}
