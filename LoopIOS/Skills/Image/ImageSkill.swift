//
//  ImageSkill.swift
//  Loop
//
//  Built from LoopIOS/Specs/image_spec.md.
//

import Foundation

/// Side-effect surface ImageGenerationService uses to inject placeholder
/// and final image messages into the chat UI. The host (MessagingVC) owns
/// the messages array; the service lives outside UIKit and only signals
/// state changes.
///
/// Protocol methods are dispatched from the service on the main thread.
/// Retry is handled by the cell delegate calling
/// ImageGenerationService.retry(_:prompt:) directly — no protocol method
/// needed because the placeholder message is already in the host's chat.
protocol ImageSkillHost: AnyObject {
    /// A new generation has started. Insert a synthetic assistant message
    /// carrying `attachment` (in .generating state) so the user immediately
    /// sees a placeholder spinner inline.
    func imageSkillDidStartGenerating(_ attachment: ImageAttachment)
    /// Generation completed (success or failure). Find the placeholder by
    /// `attachment.id` and update it in place — same row, no scroll jump.
    func imageSkillDidFinishGenerating(_ attachment: ImageAttachment)
}

/// Lets Loop generate an image inline in chat through OpenAI's image
/// endpoint (gpt-image-2). The model uses `generate_image` to express
/// intent; ImageSkill makes the HTTP call, saves the PNG to Workspace, and
/// signals the host to render the bubble inline.
///
/// Iteration ("make it darker", "remove the background", etc.) is handled
/// at the LLM layer: the model sees prior turns + the previous prompt and
/// rewrites a new prompt to call the tool again. No img2img dependency.
final class ImageSkill {
    static let shared = ImageSkill()

    static let systemPromptFragment: String = """
You can generate ORIGINAL, invented images inline in chat using the generate_image tool. This is an AI art generator (gpt-image), NOT a way to find real photos.

CRITICAL — generate_image is expensive. Do NOT use it to find or show real, existing things:
- If the user wants to see real photos/pictures/images of an actual place, person, product, animal, event, or anything that exists in the world ("find me images of Ocean Beach", "show me photos of the Eiffel Tower", "what does a quokka look like"), use image_search instead. NEVER call generate_image for these.
- Only use generate_image when the user wants something invented or artistic that does not exist yet: a drawing, mockup, concept art, logo, moodboard, wallpaper, or an explicit "generate/draw/paint/illustrate" request.
- If you're unsure whether the user wants real photos or invented art, prefer image_search (it's far cheaper) or ask.

When to call generate_image:
- The user describes an invented image idea ("draw me…", "mockup of…", "moodboard…", "illustrate…").
- The user asks to iterate on a previously-generated image ("make it darker", "same scene but cinematic", "remove the background"). In that case, look at the prior generate_image call's prompt and write a new full prompt that incorporates the change — do not pass a delta, the tool always takes a full prompt.

Rules:
- One image per call. The tool currently supports a single image at a time; if the user asks for several variants, call it once and offer to iterate.
- The prompt is what gets sent verbatim to the image model. Be vivid and specific (subject, composition, style, mood, lighting, color palette).
- Pick the `aspect_ratio` that fits the subject: `square` (default) for icons/avatars/logos, `portrait` for phone wallpapers/posters/full-body shots, `landscape` for scenery/banners/desktop wallpapers. When the user names a shape ("wide", "tall", "wallpaper"), map it; otherwise default to square.
- After the image renders, write a short conversational reply — don't repeat the prompt back at the user, just acknowledge briefly so they can keep iterating.
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "generate_image",
                "description": "Generate one image inline in chat from a natural-language prompt. The image renders inline in the conversation; the user can download or regenerate it. Use this whenever the user asks for an image, mockup, moodboard, or visual idea — including iterations on a previously-generated image (rewrite the full prompt incorporating the requested change).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "prompt": [
                            "type": "string",
                            "description": "Full image prompt. Be specific: subject, composition, style, mood, lighting, color palette."
                        ],
                        "aspect_ratio": [
                            "type": "string",
                            "enum": ImageSkill.aspectTokens,
                            "description": "Shape of the image. `square` (1:1, default), `portrait` (2:3, tall), or `landscape` (3:2, wide). Choose to fit the subject; omit for square."
                        ]
                    ],
                    "required": ["prompt"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "generate_image"
    ]

    // MARK: - Image size

    /// Friendly aspect tokens exposed to the model in the tool schema. Kept as
    /// an `[String]` so it drops straight into the JSON-Schema `enum`.
    static let aspectTokens: [String] = ["square", "portrait", "landscape"]

    /// Default aspect when the model omits the argument — preserves the prior
    /// always-square behavior.
    static let defaultAspect = "square"

    /// Maps a friendly aspect token to the API `size` string the image
    /// endpoint expects. Single source of truth: if the model's accepted sizes
    /// change, edit here only. Unknown/nil tokens fall back to square so a
    /// bad argument can never break a generation.
    static func apiSize(forAspect aspect: String?) -> String {
        switch aspect?.lowercased() {
        case "portrait":  return "1024x1536"
        case "landscape": return "1536x1024"
        default:          return "1024x1024" // square + fallback
        }
    }

    func handles(functionName: String) -> Bool {
        return ImageSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "generate_image":
            if let p = (call.arguments["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                let preview = ImageSkill.truncate(p, to: 60)
                return "drawing \(preview)"
            }
            return "generating image"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "generate_image":
            guard let prompt = (functionCall.arguments["prompt"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty else {
                completion(MessageStruct(
                    role: "function",
                    content: "I need a `prompt` to call generate_image.",
                    name: "generate_image"
                ))
                return
            }
            let aspect = (functionCall.arguments["aspect_ratio"] as? String) ?? ImageSkill.defaultAspect
            generateImage(prompt: prompt, aspect: aspect, completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the Image tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Tool handler

    /// Submit-and-return: hand the request to ImageGenerationService and
    /// reply to the LLM immediately so it can write a short acknowledgment
    /// while the image is still cooking. The image bubble fills in via the
    /// host's didFinishGenerating callback whenever the network completes —
    /// the function result here is just to unblock the chat turn.
    private func generateImage(prompt: String,
                               aspect: String,
                               completion: @escaping (MessageStruct) -> Void) {
        // Pin this generation to whichever conversation is currently active
        // *now*, not whichever one happens to be foreground when the network
        // call finishes. Without this, the user can open a new tab while an
        // image is in flight and the bubble would race into the wrong tab on
        // Mac. The service carries the id through to the host callbacks.
        let convId = SimpleConversationManager.shared.currentConversation?.id
        let size = ImageSkill.apiSize(forAspect: aspect)
        let attachment = ImageGenerationService.shared.submit(prompt: prompt,
                                                              size: size,
                                                              conversationId: convId)
        let summary = "Image generation queued (id: \(attachment.id)). Image will appear inline in the chat shortly. Acknowledge briefly to the user; do not wait for the image."
        completion(MessageStruct(
            role: "function",
            content: summary,
            name: "generate_image"
        ))
    }

    // MARK: - Helpers

    private static func truncate(_ s: String, to max: Int) -> String {
        if s.count <= max { return s }
        let idx = s.index(s.startIndex, offsetBy: max)
        return String(s[..<idx]) + "…"
    }
}
