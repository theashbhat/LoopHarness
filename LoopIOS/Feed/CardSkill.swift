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

Reading & editing existing cards:
- Call `list_feed_cards` to see the cards currently visible in the user's feed \
  (newest first, archived excluded). It returns each card's `card_id`, kind, \
  title, body, tags, source, and state. Use it before editing so you target the \
  right card by `card_id`.
- Call `edit_card` with a `card_id` and only the fields you want to change \
  (`title`, `body`, `tags`, `source`, or `image_prompt` for image cards). \
  Omitted fields are left untouched. Edits re-render the card automatically.
- When the user says "update/change/fix that card" or names a card to revise, \
  list first if you don't already know the `card_id`, then edit it — don't \
  create a duplicate with `generate_card`.
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
        ],
        [
            "type": "function",
            "function": [
                "name": "list_feed_cards",
                "description": "List the cards currently visible in the user's feed (non-archived, newest first). Returns each card's id, kind, title, body, tags, source, and state. Use before editing to find the right card_id.",
                "parameters": [
                    "type": "object",
                    "properties": [:] as [String: Any]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "edit_card",
                "description": "Edit an existing feed card in place. Provide the card_id and only the fields to change; omitted fields are left as-is. The card re-renders automatically.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "card_id": [
                            "type": "string",
                            "description": "ID of the card to edit (from list_feed_cards or generate_card)."
                        ],
                        "title": [
                            "type": "string",
                            "description": "New title (≤6 words)."
                        ],
                        "body": [
                            "type": "string",
                            "description": "New body. For markdown cards this is the rendered content; for image cards prefer 'image_prompt'."
                        ],
                        "image_prompt": [
                            "type": "string",
                            "description": "New image prompt for an image card. Changing this regenerates the poster image."
                        ],
                        "source": [
                            "type": "string",
                            "description": "New attribution string."
                        ],
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Replacement list of lowercase tags (replaces existing tags)."
                        ]
                    ],
                    "required": ["card_id"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    ]

    static let toolNames: Set<String> = ["generate_card", "list_feed_cards", "edit_card"]

    // MARK: - Routing

    func handles(functionName: String) -> Bool {
        CardSkill.toolNames.contains(functionName)
    }

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "generate_card":
            handleGenerate(functionCall: functionCall, completion: completion)
        case "list_feed_cards":
            handleList(completion: completion)
        case "edit_card":
            handleEdit(functionCall: functionCall, completion: completion)
        default:
            completion(MessageStruct(role: "function",
                                     content: "Unknown card tool '\(functionCall.name)'.",
                                     name: functionCall.name))
        }
    }

    // MARK: - generate_card

    private func handleGenerate(functionCall: FunctionCallStruct,
                                completion: @escaping (MessageStruct) -> Void) {
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

    // MARK: - list_feed_cards

    private func handleList(completion: @escaping (MessageStruct) -> Void) {
        let cards = CardStore.shared.feedCards
        let payload: [[String: Any]] = cards.map { card in
            [
                "card_id": card.id,
                "kind": card.kind.rawValue,
                "title": card.title,
                "body": card.body,
                "tags": card.tags,
                "source": card.source ?? "",
                "state": card.state.rawValue,
                "created_at": CardStore.dateFormatter.string(from: card.createdAt)
            ]
        }
        let result: [String: Any] = ["status": "ok", "count": cards.count, "cards": payload]
        completion(MessageStruct(role: "function", content: Self.jsonString(result), name: "list_feed_cards"))
    }

    // MARK: - edit_card

    private func handleEdit(functionCall: FunctionCallStruct,
                            completion: @escaping (MessageStruct) -> Void) {
        let args = functionCall.arguments

        guard let cardId = args["card_id"] as? String, !cardId.isEmpty else {
            completion(MessageStruct(role: "function",
                                     content: "{\"error\":\"Missing 'card_id'.\"}",
                                     name: "edit_card"))
            return
        }

        guard let existing = CardStore.shared.card(for: cardId) else {
            completion(MessageStruct(role: "function",
                                     content: "{\"error\":\"No card found with card_id '\(cardId)'. Call list_feed_cards to see valid ids.\"}",
                                     name: "edit_card"))
            return
        }

        // For image cards the stored body IS the image prompt, so an edit to
        // either field maps onto `body`. Track whether the rendered output needs
        // regenerating (content changed).
        let newTitle = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let newSource = args["source"] as? String
        let newTags = args["tags"] as? [String]
        let bodyArg = existing.kind == .image
            ? (args["image_prompt"] as? String ?? args["body"] as? String)
            : (args["body"] as? String)
        let newBody = bodyArg.flatMap { $0.isEmpty ? nil : $0 }

        guard newTitle != nil || newBody != nil || newSource != nil || newTags != nil else {
            completion(MessageStruct(role: "function",
                                     content: "{\"error\":\"Nothing to edit. Provide at least one of: title, body, image_prompt, source, tags.\"}",
                                     name: "edit_card"))
            return
        }

        let contentChanged = newTitle != nil || newBody != nil

        let updated = CardStore.shared.update(id: cardId) { card in
            if let newTitle { card.title = newTitle }
            if let newBody { card.body = newBody }
            if let newSource { card.source = newSource }
            if let newTags { card.tags = newTags }
        }

        guard let updated else {
            completion(MessageStruct(role: "function",
                                     content: "{\"error\":\"Failed to update card '\(cardId)'.\"}",
                                     name: "edit_card"))
            return
        }

        // Re-render so any stored poster stays in sync with the new content.
        // Image cards only regenerate when their prompt actually changed (it's
        // an expensive image-model call); markdown re-renders are cheap/local.
        if contentChanged && (updated.kind == .markdown || newBody != nil) {
            CardRendererRegistry.shared.render(card: updated) { _ in }
        }

        let result: [String: Any] = [
            "status": "ok",
            "card_id": updated.id,
            "kind": updated.kind.rawValue,
            "title": updated.title,
            "tags": updated.tags,
            "message": "Card updated."
        ]
        completion(MessageStruct(role: "function", content: Self.jsonString(result), name: "edit_card"))
    }

    /// Serialize a JSON-object dictionary to a string, falling back to a minimal
    /// ok payload on failure.
    private static func jsonString(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"status\":\"ok\"}"
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
