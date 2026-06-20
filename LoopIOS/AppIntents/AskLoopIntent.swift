//
//  AskLoopIntent.swift
//  Loop
//
//  App Intent that lets Siri / Shortcuts send a natural-language query to
//  Loop. Opens the app and injects the query into the agent harness's chat.
//
//  Usage:  "Hey Siri, ask Loop what's on my calendar"
//

import AppIntents
import UIKit

@available(iOS 27.0, *)
struct AskLoopIntent: AppIntent {

    static var title: LocalizedStringResource = "Ask Loop"
    static var description = IntentDescription(
        "Send a question or request to Loop and get a response.",
        categoryName: "Loop AI"
    )

    static var openAppWhenRun = true

    @Parameter(title: "Question", description: "The question or request to send to Loop.")
    var query: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let sceneDelegate = await currentSceneDelegate() else {
            return .result(dialog: "Loop isn't ready yet. Please open the app and try again.")
        }

        // Post the query into the chat pipeline on the main thread. The
        // notification carries the text; MessagingVC picks it up via
        // `handleIntentMessage(_:)` and feeds it through `didSendMessageText`.
        await MainActor.run {
            NotificationCenter.default.post(
                name: .loopIntentMessageReceived,
                object: nil,
                userInfo: ["message": query]
            )
        }

        return .result(dialog: "Asking Loop: \(query)")
    }

    @MainActor
    private func currentSceneDelegate() -> SceneDelegate? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .delegate as? SceneDelegate
    }
}
