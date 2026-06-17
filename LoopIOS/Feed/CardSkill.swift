//
//  CardSkill.swift
//  Loop
//
//  Tool registration for `generate_card`. Creates a Card, persists it via
//  CardStore, dispatches rendering via CardRendererRegistry, and posts a
//  notification so the UI can show a pill alert.
//

import Foundation

final class CardSkill {
    static let shared = CardSkill()
    private init() {}

    // MARK: - System prompt fragment

    static let systemPromptFragment: String = """
You can generate feed cards for the user using the `generate_card` tool. Cards \
appear in the user's Feed tab as visual poster-style summaries they can swipe \
through, keep, or archive.

When to call:
- The user asks for a card, summary card, or visual recap on a topic.
- A natural summarization moment: "card on my day tomorrow", "card about X".

Kinds:
- `image`: provide an `image_prompt` — a vivid descriptive prompt for image \
  generation. The title is overlaid on the generated image.
- `markdown`: the `body` is rendered as styled text on a dark poster. Good for \
  schedules, lists, quick-reference info.

Rules:
- Pick `image` when the topic is visual/emotional (pets, scenery, inspiration).
- Pick `markdown` when the content is textual/informational (schedule, checklist).
- Keep `title` short (≤6 words). Body should be concise and scannable.
- Tags are optional lowercase keywords for future filtering.
"""

    // MARK: - Tool schema

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "generate_card",
                "description": "Generate a visual feed card. Image cards produce an AI-generated poster; markdown cards render styled text. Cards appear in the Feed tab.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "kind": [
                            "type": "string",
                            "enum": ["image", "markdown"],
                            "description": "Card type: 'image' (AI-generated visual) or 'markdown' (styled text poster)."
                        ],
                        "title": [
                            "type": "string",
                            "description": "Short card title (≤6 words)."
                        ],
                        "body": [
                            "type": "string",
                            "description": "Card body text. For markdown cards this is the content rendered on the poster. For image cards this is a subtitle/caption."
                        ],
                        "image_prompt": [
                            "type": "string",
                            "description": "Required when kind='image'. Vivid descriptive prompt for the image generator (subject, style, mood, lighting, colors)."
                        ],
                        "source": [
                            "type": "string",
                            "description": "Optional attribution (e.g. 'calendar', 'user request')."
                        ],
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional lowercase tags for filtering."
                        ]
                    ],
                    "required": ["kind", "title", "body"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    ]

    static let toolNames: Set<String> = ["generate_card"]

    // MARK: - Routing

    func handles(functionName: String) -> Bool {
        CardSkill.toolNames.contains(functionName)
    }

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        guard functionCall.name == "generate_card" else {
            completion(MessageStruct(role: "function",
                                     content: "Unknown card tool '\(functionCall.name)'.",
                                     name: functionCall.name))
            return
        }

        let args = functionCall.arguments

        guard let kindStr = args["kind"] as? String,
              let kind = CardKind(rawValue: kindStr) else {
            completion(MessageStruct(role: "function",
                                     content: "{\"error\":\"Missing or invalid 'kind'. Must be 'image' or 'markdown'.\"}",
                                     name: "generate_card"))
            return
        }

        guard let title = args["title"] as? String, !title.isEmpty else {
            completion(MessageStruct(role: "function",
                                     content: "{\"error\":\"Missing 'title'.\"}",
                                     name: "generate_card"))
            return
        }

        guard let body = args["body"] as? String, !body.isEmpty else {
            completion(MessageStruct(role: "function",
                                     content: "{\"error\":\"Missing 'body'.\"}",
                                     name: "generate_card"))
            return
        }

        if kind == .image {
            guard let imagePrompt = args["image_prompt"] as? String, !imagePrompt.isEmpty else {
                completion(MessageStruct(role: "function",
                                         content: "{\"error\":\"'image_prompt' is required when kind='image'.\"}",
                                         name: "generate_card"))
                return
            }
            // For image cards, the body used for rendering is the image_prompt
            let card = Card(kind: kind, title: title, body: imagePrompt,
                            source: args["source"] as? String,
                            tags: (args["tags"] as? [String]) ?? [])
            generateCard(card, displayBody: body, completion: completion)
        } else {
            let card = Card(kind: kind, title: title, body: body,
                            source: args["source"] as? String,
                            tags: (args["tags"] as? [String]) ?? [])
            generateCard(card, displayBody: body, completion: completion)
        }
    }

    // MARK: - Generation

    private func generateCard(_ card: Card, displayBody: String,
                              completion: @escaping (MessageStruct) -> Void) {
        // Persist the card immediately (state: .new, no poster yet)
        CardStore.shared.add(card)

        // Reply to the LLM right away so the turn unblocks
        let result: [String: Any] = [
            "status": "ok",
            "card_id": card.id,
            "kind": card.kind.rawValue,
            "title": card.title,
            "message": "Card created and rendering poster. It will appear in the Feed shortly."
        ]
        let json = (try? JSONSerialization.data(withJSONObject: result))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"status\":\"ok\"}"
        completion(MessageStruct(role: "function", content: json, name: "generate_card"))

        // Kick off async rendering
        CardRendererRegistry.shared.render(card: card) { renderResult in
            switch renderResult {
            case .success:
                print("CardSkill: poster rendered for card \(card.id)")
            case .failure(let error):
                print("CardSkill: render failed for card \(card.id): \(error.localizedDescription)")
            }
        }
    }
}
