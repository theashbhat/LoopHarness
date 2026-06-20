//
//  VisionSummaryService.swift
//  Loop
//
//  Generates a one-time text description of a user-uploaded image so the local
//  chat clients can stop re-sending the raw base64 image on every turn.
//
//  The problem: `AnthropicChat.wirePayload` / `OpenAIChat.wireMessages` rebuild
//  the whole conversation each turn, and an image attachment re-emits its full
//  base64 block every time — so a long thread pays the image's input tokens on
//  every request. The fix: send the image at full resolution only on the turn
//  that introduced it (the last human turn), and on later turns inline a cached
//  prose description instead. This service produces that description.
//
//  Flow: `MessagingVC` calls `ensureSummaries(for:conversationId:)` right after
//  it sends a user message. For each ready image attachment that doesn't yet
//  have a `visionSummary`, we fire a single background vision call (Anthropic or
//  OpenAI, whichever the user has keyed), then persist the result onto the
//  attachment via `SimpleConversationManager.updateAttachmentSummary`. By the
//  user's next turn the summary is usually ready; if it isn't (fast follow-up),
//  the chat clients fall back to re-sending the raw image, so the model never
//  silently loses sight of it. On vision failure / no provider key we fall back
//  to the attachment's on-device OCR text when present.
//
//  Idempotent: an in-flight guard plus the "already has a summary" check mean
//  re-invoking on every turn (or on conversation reload) is safe.
//

import Foundation

final class VisionSummaryService {
    static let shared = VisionSummaryService()
    private init() {}

    /// Serializes access to `inFlight` and ensures we only launch one job per
    /// attachment id even when `ensureSummaries` is called from several turns
    /// in quick succession.
    private let stateQueue = DispatchQueue(label: "loop.vision-summary.state")
    private var inFlight: Set<String> = []

    /// Cheap, vision-capable model per provider. We deliberately don't reuse the
    /// user's selected chat model — it may be text-only (the default is often
    /// Fireworks GLM 5.2) — and a fast small model is plenty for a descriptive
    /// caption. Picked per-provider so the summary bills to a key the user
    /// already has.
    private static let anthropicVisionModel = "claude-haiku-4-5-20251001"
    private static let openAIVisionModel = "gpt-4o"
    private static let fireworksVisionModel = "accounts/fireworks/models/kimi-k2p6"

    private static let prompt = """
    Describe this image in thorough detail so that someone who cannot see it \
    could confidently answer follow-up questions about it. Transcribe any text \
    verbatim, and cover layout, objects, people, colors, and any numbers, data, \
    or values present. Respond with plain prose only — no preamble, no headings, \
    no markdown.
    """

    /// Scan `messages` for ready image attachments lacking a description and
    /// kick off a background job for each. Safe to call repeatedly.
    func ensureSummaries(for messages: [MessageStruct], conversationId: String) {
        let pending = messages.compactMap { m -> FileAttachment? in
            guard let f = m.fileAttachment,
                  f.kind == .image,
                  f.status == .ready,
                  f.visionSummary == nil else { return nil }
            return f
        }
        guard !pending.isEmpty else { return }
        for attachment in pending {
            stateQueue.async {
                guard !self.inFlight.contains(attachment.id) else { return }
                self.inFlight.insert(attachment.id)
                self.generate(for: attachment, conversationId: conversationId)
            }
        }
    }

    // MARK: - Generation

    private func generate(for attachment: FileAttachment, conversationId: String) {
        guard let target = Self.visionTarget() else {
            // No vision-capable provider configured — best we can do is the
            // on-device OCR text, if any.
            finishWithOCRFallback(attachment, conversationId: conversationId)
            return
        }

        // A single synthetic user turn carrying just the image. Because it's the
        // only (hence last) user message, the chat clients send it at full
        // resolution — exactly what we want for the description pass.
        let probe = MessageStruct(role: "user", content: Self.prompt, fileAttachment: attachment)

        let handle: (MessageStruct?, Error?) -> Void = { [weak self] message, error in
            guard let self = self else { return }
            let text = message?.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let text = text, !text.isEmpty {
                self.finish(attachmentId: attachment.id,
                            summary: Self.capped(text),
                            conversationId: conversationId)
            } else {
                if let error = error {
                    print("VisionSummaryService: vision call failed (\(error.localizedDescription)); falling back to OCR")
                }
                self.finishWithOCRFallback(attachment, conversationId: conversationId)
            }
        }

        switch target.provider {
        case .anthropic:
            AnthropicChat.shared.chat(messages: [probe], tools: nil,
                                      modelIDOverride: target.modelID, completion: handle)
        case .openAI:
            OpenAIChat.shared.chat(messages: [probe], tools: nil,
                                   modelIDOverride: target.modelID, completion: handle)
        case .fireworks:
            FireworksChat.shared.chat(messages: [probe], tools: nil,
                                      modelIDOverride: target.modelID, completion: handle)
        case .apple:
            // visionTarget() only ever returns hosted providers; keep the
            // switch exhaustive.
            finishWithOCRFallback(attachment, conversationId: conversationId)
        }
    }

    /// Use the image's on-device OCR text as the description when a real vision
    /// call isn't possible. Leaves the attachment un-summarized (image keeps
    /// being sent raw) when there's no text either.
    private func finishWithOCRFallback(_ attachment: FileAttachment, conversationId: String) {
        if let ocr = attachment.extractedText, !ocr.isEmpty {
            finish(attachmentId: attachment.id,
                   summary: Self.capped("(On-device text extracted from the image — no full visual description available.)\n\(ocr)"),
                   conversationId: conversationId)
        } else {
            stateQueue.async { self.inFlight.remove(attachment.id) }
        }
    }

    private func finish(attachmentId: String, summary: String, conversationId: String) {
        // Store mutation hops to main — matches every other call into
        // SimpleConversationManager and keeps `_currentConversation` updates on
        // the main thread (chat completions fire on a URLSession delegate queue).
        DispatchQueue.main.async {
            SimpleConversationManager.shared.updateAttachmentSummary(
                attachmentId: attachmentId, summary: summary, conversationId: conversationId)
        }
        stateQueue.async { self.inFlight.remove(attachmentId) }
    }

    // MARK: - Provider selection

    private struct VisionTarget { let provider: ModelProvider; let modelID: String }

    /// Pick a vision-capable provider + cheap model for the description pass.
    /// Prefers the user's current provider when it's keyed (so the summary bills
    /// to the account they're already using), then the first keyed of
    /// Anthropic / OpenAI / Fireworks. Returns nil when none has a key — the
    /// caller then falls back to on-device OCR.
    private static func visionTarget() -> VisionTarget? {
        let current = ModelSelectionStore.current.provider
        for provider in [current, .anthropic, .openAI, .fireworks] {
            switch provider {
            case .anthropic where KeyStore.shared.source(for: .anthropic) != .missing:
                return VisionTarget(provider: .anthropic, modelID: anthropicVisionModel)
            case .openAI where KeyStore.shared.source(for: .openAI) != .missing:
                return VisionTarget(provider: .openAI, modelID: openAIVisionModel)
            case .fireworks where KeyStore.shared.source(for: .fireworks) != .missing:
                return VisionTarget(provider: .fireworks, modelID: fireworksVisionModel)
            default:
                continue
            }
        }
        return nil
    }

    /// Keep descriptions from ballooning the payload — well above any real
    /// caption, but a hard stop for a runaway OCR dump.
    private static func capped(_ text: String) -> String {
        let cap = FileAttachment.extractedTextCharCap
        return text.count > cap ? String(text.prefix(cap)) : text
    }
}
