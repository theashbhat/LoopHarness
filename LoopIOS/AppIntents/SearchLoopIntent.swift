//
//  SearchLoopIntent.swift
//  Loop
//
//  Dedicated search intent that lets Siri search Loop's conversations and
//  notes. Searches locally first, then falls through to the agent.
//
//  Usage:  "What did Loop say about my Scout meeting?"
//

import AppIntents
import Foundation

@available(iOS 27.0, *)
struct SearchLoopIntent: AppIntent {

    static var title: LocalizedStringResource = "Search Loop"
    static var description = IntentDescription(
        "Search Loop conversations and notes.",
        categoryName: "Loop AI"
    )

    static var openAppWhenRun = true

    @Parameter(title: "Query", description: "What to search for in Loop.")
    var query: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Search conversations locally.
        let conversations = SimpleConversationManager.shared.getAllConversations()
        let lowerQuery = query.lowercased()
        let matches = conversations.filter { conv in
            conv.title.lowercased().contains(lowerQuery) ||
            conv.messages.contains { $0.content.lowercased().contains(lowerQuery) }
        }.prefix(5)

        if matches.isEmpty {
            // Fall through to the agent — open the app and ask Loop directly.
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .loopIntentMessageReceived,
                    object: nil,
                    userInfo: ["message": "Search my conversations and notes for: \(query)"]
                )
            }
            return .result(dialog: "Searching Loop for \"\(query)\"…")
        }

        let summaries = matches.map { "• \($0.title)" }.joined(separator: "\n")
        return .result(dialog: "Found \(matches.count) conversation(s):\n\(summaries)")
    }
}
