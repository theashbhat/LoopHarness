//
//  BrowseGenerationService.swift
//  Loop
//
//  Service layer that coordinates browse sessions. Mirrors
//  StoryGenerationService: the skill hands it a request, it spins up a
//  BrowseSession (the WKWebView driver), drops a live preview card into the
//  chat via the host, streams per-step updates, and resolves with the final
//  grounded attachment when the agent finishes.
//
//  It also keeps a registry of live sessions so the full-screen player can
//  borrow the running web view (read-only mirror) while a session is in
//  flight, then fall back to the on-disk replay bundle once it ends.
//

#if os(iOS)

import UIKit

/// Implemented by MessagingVC to receive browse lifecycle events. The host
/// owns placing/refreshing the preview card on the assistant message.
protocol BrowseSkillHost: AnyObject {
    func browseSkillDidStart(_ attachment: BrowseAttachment)
    func browseSkillDidUpdate(_ attachment: BrowseAttachment)
    func browseSkillDidFinish(_ attachment: BrowseAttachment)
}

@MainActor
final class BrowseGenerationService: NSObject {
    static let shared = BrowseGenerationService()

    weak var host: BrowseSkillHost?

    private var liveSessions: [String: BrowseSession] = [:]

    private override init() { super.init() }

    /// Live session for an attachment id, if one is still running (used by the
    /// full-screen player to mirror what the agent currently sees).
    func liveSession(for id: String) -> BrowseSession? {
        return liveSessions[id]
    }

    /// Run a browse session to completion. Drops the live card immediately,
    /// streams updates, and returns the terminal session so the skill can
    /// build its grounded tool result.
    @discardableResult
    func run(url: URL,
             instructions: String,
             maxSteps: Int,
             viewport: CGSize,
             conversationId: String?) async -> BrowseSession {
        let session = BrowseSession(
            attachmentId: UUID().uuidString,
            url: url,
            instructions: instructions,
            maxSteps: maxSteps,
            viewport: viewport,
            conversationId: conversationId
        )
        session.delegate = self
        liveSessions[session.attachmentId] = session

        host?.browseSkillDidStart(session.attachment)

        let final = await session.run()

        host?.browseSkillDidFinish(final)
        liveSessions[session.attachmentId] = nil
        return session
    }
}

extension BrowseGenerationService: BrowseSessionDelegate {
    func browseSession(_ session: BrowseSession, didUpdate attachment: BrowseAttachment) {
        host?.browseSkillDidUpdate(attachment)
    }
}

#endif
