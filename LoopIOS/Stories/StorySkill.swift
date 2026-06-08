//
//  StorySkill.swift
//  Loop
//
//  Skill definition for the Stories feature. Exposes `generate_story` as a
//  tool the model can call to produce an HTML infographic from structured
//  data. Mirrors the PDFSkill interface (static `tools` + `handles` +
//  `handle`) so it slots into the AgentHarness catalog and SkillDispatcher
//  exactly like every other bundled skill.
//
//  Submit-and-return: the render is kicked off on StoryGenerationService and
//  a function-result is returned immediately so the model can write a short
//  ack while the WKWebView renders. The story card swaps into the chat via
//  StorySkillHost when the render completes.
//

#if os(iOS) || os(macOS)

import Foundation

/// Skill that generates HTML story infographics. Registers as a tool the LLM
/// can call via the SkillDispatcher.
final class StorySkill {
    static let shared = StorySkill()
    private init() {}

    static let systemPromptFragment: String = """
You can generate a visual, full-screen "story" — a 1080×1920 portrait HTML infographic with animated scenes and tap-to-advance navigation — using the generate_story tool. It renders as a tappable card in chat that opens a full-screen, Instagram-style story player.

When to call:
- The user asks for a "story", a "recap", a visual summary, a shareable card, an "infographic", or "show me X as a story".
- You've just gathered data worth presenting visually (a day's activity, a workout, a set of stats, highlights) and a poster-style visual beats a wall of text.

Sequencing (important — avoid duplicate cards):
- Gather ALL the data you need FIRST (health queries, web lookups, etc.), THEN call generate_story exactly once with the finished payload. Do NOT call it speculatively before you have the numbers and then call it again — every call drops a separate card in the chat.
- One generate_story call per user request. If you realize you need more data after starting, fetch the data and only THEN make the single call.

Templates and their EXACT `data` schema — match these key names precisely, or fields render blank:

`DailyRecap` — general day/period summary (stats + goals + highlights). `data` shape:
{
  "emoji": "📊",
  "title": "Your Tuesday",
  "subtitle": "June 3, 2025",
  "stats":   [ { "emoji": "✉️", "value": "47", "label": "Emails" }, … ],   // value can be string or number
  "goals":   [ { "label": "Deep Work", "current": 3.5, "target": 4 }, … ], // current & target are NUMBERS; % is computed
  "highlights": [ { "emoji": "🚀", "text": "Shipped the stories feature" }, … ]
}

`ActivitySummary` — fitness/activity data (metrics grid + progress ring + timeline). `data` shape:
{
  "icon": "🥾",
  "title": "Morning Hike",
  "subtitle": "Mt. Tamalpais",
  "metrics":  [ { "emoji": "📏", "label": "Distance", "value": "12.4", "unit": "mi" }, … ],
  "goal":     { "current": 12.4, "target": 10, "label": "distance goal", "caption": "Exceeded by 24%!" }, // ONE object; numbers
  "timeline": [ { "time": "6:30 AM", "text": "Started at the trailhead" }, … ]
}

How to write `data`:
- Use EXACTLY the keys above. For goals/ring progress, send numeric `current` and `target` (not a pre-computed "%" string) — the template computes the percentage. Highlights/timeline entries are objects with a `text` field, not bare strings.
- Keep it tight — a story is glanceable: ~4 stats/metrics, 2–3 goals, 3–5 highlights. Not a report.

Rules:
- One story per call. After it renders, write a short conversational reply — don't repeat the story's contents back at the user; just let them know it's ready to tap.
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "generate_story",
                "description": "Generate a visual HTML story infographic (1080×1920 portrait, animated, tap-to-advance scenes). Renders as a tappable card in chat that opens a full-screen story player. Use when the user wants a 'story', a visual recap, a shareable summary card, or an infographic.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Title for the story, shown on the card and first scene. Concise — 'Your Tuesday', 'Morning Run', not a full sentence.",
                        ],
                        "template": [
                            "type": "string",
                            "enum": ["DailyRecap", "ActivitySummary"],
                            "description": "Which template to use. DailyRecap for general summaries with stats/goals/highlights. ActivitySummary for fitness/activity data with metrics, a ring chart, and a timeline.",
                        ],
                        "data": [
                            "type": "object",
                            "description": "JSON data object to fill into the template. Shape depends on the chosen template — stats/goals/highlights for DailyRecap, metrics/ring/timeline for ActivitySummary.",
                        ],
                    ] as [String: Any],
                    "required": ["title", "template", "data"],
                ] as [String: Any],
            ] as [String: Any],
        ]
    ]

    static let toolNames: Set<String> = ["generate_story"]

    func handles(functionName: String) -> Bool {
        return StorySkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "generate_story":
            if let t = (call.arguments["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return "creating \(StorySkill.truncate(t, to: 50)) story"
            }
            return "creating story"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "generate_story":
            guard let title = (functionCall.arguments["title"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                completion(MessageStruct(
                    role: "function",
                    content: "I need a `title` to call generate_story.",
                    name: "generate_story"
                ))
                return
            }
            guard let templateStr = functionCall.arguments["template"] as? String,
                  let template = StoryAttachment.Template(rawValue: templateStr) else {
                completion(MessageStruct(
                    role: "function",
                    content: "I need a valid `template`: 'DailyRecap' or 'ActivitySummary'.",
                    name: "generate_story"
                ))
                return
            }
            guard let data = functionCall.arguments["data"] as? [String: Any] else {
                completion(MessageStruct(
                    role: "function",
                    content: "I need a `data` object to fill into the template.",
                    name: "generate_story"
                ))
                return
            }
            generateStory(title: title,
                          template: template,
                          data: data,
                          completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the story tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Tool handler

    /// Submit-and-return: kick the render off and synthesize a function
    /// result immediately so the model can write its short ack while the
    /// WKWebView is rendering. The story card swaps in via the host callbacks
    /// when the render completes (or fails).
    private func generateStory(title: String,
                               template: StoryAttachment.Template,
                               data: [String: Any],
                               completion: @escaping (MessageStruct) -> Void) {
        // Pin the render to whichever conversation is active *now* so a
        // tab-switch between submit and finish doesn't drop the card in the
        // wrong place.
        let convId = SimpleConversationManager.shared.currentConversation?.id
        let attachment = StoryGenerationService.shared.submit(
            title: title,
            template: template,
            data: data,
            conversationId: convId
        )
        let summary = "Story generation queued (id: \(attachment.id), template: \(template.rawValue)). The story card will appear inline shortly. Acknowledge briefly to the user; do not wait for the render."
        completion(MessageStruct(
            role: "function",
            content: summary,
            name: "generate_story"
        ))
    }

    // MARK: - Helpers

    private static func truncate(_ s: String, to max: Int) -> String {
        if s.count <= max { return s }
        let idx = s.index(s.startIndex, offsetBy: max)
        return String(s[..<idx]) + "…"
    }
}

#endif
