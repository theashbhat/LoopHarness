//
//  StorySkill.swift
//  Loop
//
//  Skill definition for the Stories feature. Exposes `generate_story` as a
//  tool the model can call to produce an HTML infographic from structured data.
//  Follows the existing skill pattern (see LoopIOS/Skills/).
//

#if os(iOS)

import Foundation

/// Skill that generates HTML story infographics. Registers as a tool the LLM
/// can call via the agent harness's skill dispatch system.
final class StorySkill {
    static let shared = StorySkill()
    private init() {}

    // MARK: - Tool Definition

    /// JSON schema for the `generate_story` tool, matching the format used by
    /// the skill dispatcher.
    static let toolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "generate_story",
            "description": "Generate a visual HTML story infographic (1080×1920 portrait format) with CSS animations and tap-to-advance scenes. Returns a rendered story card in chat.",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "Title for the story (shown on the card and first scene)",
                    ],
                    "template": [
                        "type": "string",
                        "enum": ["DailyRecap", "ActivitySummary"],
                        "description": "Which template to use. DailyRecap for general summaries with stats/goals/highlights. ActivitySummary for fitness/activity data with metrics, ring chart, and timeline.",
                    ],
                    "data": [
                        "type": "object",
                        "description": "JSON data payload to fill into the template. Schema depends on template chosen.",
                    ],
                ] as [String: Any],
                "required": ["title", "template", "data"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    // MARK: - Execution

    /// Handle a `generate_story` tool call from the model.
    ///
    /// - Parameters:
    ///   - arguments: The parsed arguments dictionary from the tool call.
    ///   - conversationId: Current conversation for routing the result.
    /// - Returns: A human-readable result string for the model's tool_result.
    func execute(arguments: [String: Any], conversationId: String?) -> String {
        guard let title = arguments["title"] as? String else {
            return "Error: missing 'title' argument"
        }
        guard let templateStr = arguments["template"] as? String,
              let template = StoryAttachment.Template(rawValue: templateStr) else {
            return "Error: invalid 'template'. Use 'DailyRecap' or 'ActivitySummary'."
        }
        guard let data = arguments["data"] as? [String: Any] else {
            return "Error: missing 'data' object"
        }

        // Submit to the generation service
        let attachment = StoryGenerationService.shared.submit(
            title: title,
            template: template,
            data: data,
            conversationId: conversationId
        )

        return "Story '\(title)' is being generated (id: \(attachment.id)). It will appear as a tappable card in chat."
    }
}

#endif
