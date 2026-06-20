//
//  IntentNotifications.swift
//  Loop
//
//  Notification names shared between App Intents and the main chat UI.
//  Intents post these; MessagingVC subscribes and injects the payload
//  into the conversation.
//

import Foundation

extension Notification.Name {
    /// Posted by AskLoopIntent / CaptureToLoopIntent / SearchLoopIntent when
    /// they want to inject a user message into the active conversation.
    /// `userInfo["message"]` carries the String payload.
    static let loopIntentMessageReceived = Notification.Name("loopIntentMessageReceived")
}
