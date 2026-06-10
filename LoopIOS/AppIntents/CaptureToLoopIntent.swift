//
//  CaptureToLoopIntent.swift
//  Loop
//
//  App Intent that captures the user's current on-screen content description
//  and sends it to Loop as a new chat message. On iOS 27 Siri can read what's
//  on screen and pass it through the intent's String parameter.
//
//  Usage:  "Hey Siri, send this to Loop"
//

import AppIntents
import UIKit

@available(iOS 27.0, *)
struct CaptureToLoopIntent: AppIntent {

    static var title: LocalizedStringResource = "Send to Loop"
    static var description = IntentDescription(
        "Capture what's on screen and send it to Loop as a new chat message.",
        categoryName: "Loop AI"
    )

    static var openAppWhenRun = true

    @Parameter(title: "Content", description: "The on-screen content to send to Loop.")
    var content: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = content ?? ""

        guard !text.isEmpty else {
            return .result(dialog: "There was no content to send to Loop.")
        }

        guard let sceneDelegate = await currentSceneDelegate() else {
            return .result(dialog: "Loop isn't ready yet. Please open the app and try again.")
        }

        // Wrap the captured content so the agent knows it came from an
        // on-screen capture, not free-form dictation.
        let wrappedMessage = """
        [Captured from screen]
        \(text)
        """

        await MainActor.run {
            NotificationCenter.default.post(
                name: .loopIntentMessageReceived,
                object: nil,
                userInfo: ["message": wrappedMessage]
            )
        }

        return .result(dialog: "Sent to Loop.")
    }

    @MainActor
    private func currentSceneDelegate() -> SceneDelegate? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .delegate as? SceneDelegate
    }
}
