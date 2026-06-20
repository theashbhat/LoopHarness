//
//  LoopRememberIntent.swift
//  Loop
//
//  App Intent that appends a quick note to today's Obsidian daily note via
//  the existing Obsidian skill / relay. Runs without opening the app so the
//  user can capture a thought from any context.
//
//  Usage:  "Hey Siri, remember to buy dog food for Leo"
//

import AppIntents
import Foundation

@available(iOS 27.0, *)
struct LoopRememberIntent: AppIntent {

    static var title: LocalizedStringResource = "Remember with Loop"
    static var description = IntentDescription(
        "Save a quick note to today's Obsidian daily note via Loop.",
        categoryName: "Loop AI"
    )

    /// This intent can run in the background — no need to open the app just
    /// to append a line to a note.
    static var openAppWhenRun = false

    @Parameter(title: "Note", description: "What you want Loop to remember.")
    var note: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard ObsidianClient.isConfigured else {
            return .result(dialog: "Obsidian isn't connected yet. Open Loop → Settings → Integrations to set it up.")
        }

        // Append the note to today's Obsidian daily note. The relay's
        // `update_obsidian_note` with mode "append" would work, but we
        // first need today's path. Use the convenience `createTodayNote`
        // which auto-files into the right day folder; if a note with the
        // same title already exists the relay returns the existing path,
        // so we fall back to an append update.
        let timestamp = LoopRememberIntent.shortTimestamp()
        let line = "- \(timestamp) \(note)"

        let result: String = try await withCheckedThrowingContinuation { continuation in
            // Try appending to the existing "Quick Notes" today-note first.
            ObsidianClient.shared.today { todayJSON, todayError in
                guard let todayPath = todayJSON?["path"] as? String else {
                    // Can't resolve today's folder — create a fresh note.
                    ObsidianClient.shared.createTodayNote(
                        title: "Quick Notes",
                        content: line
                    ) { json, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            let path = (json?["path"] as? String) ?? "today's folder"
                            continuation.resume(returning: path)
                        }
                    }
                    return
                }

                let notePath = todayPath + "/Quick Notes.md"
                ObsidianClient.shared.updateNote(
                    path: notePath,
                    content: "\n\(line)",
                    mode: "append"
                ) { json, error in
                    if error != nil {
                        // Note doesn't exist yet — create it.
                        ObsidianClient.shared.createTodayNote(
                            title: "Quick Notes",
                            content: "# Quick Notes\n\n\(line)"
                        ) { createJSON, createError in
                            if let createError = createError {
                                continuation.resume(throwing: createError)
                            } else {
                                let path = (createJSON?["path"] as? String) ?? "today's folder"
                                continuation.resume(returning: path)
                            }
                        }
                    } else {
                        continuation.resume(returning: notePath)
                    }
                }
            }
        }

        return .result(dialog: "Noted! Saved to \(result).")
    }

    /// Returns a short `HH:mm` timestamp for the bullet prefix.
    private static func shortTimestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: Date())
    }
}
