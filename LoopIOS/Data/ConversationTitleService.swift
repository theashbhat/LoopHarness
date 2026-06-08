//
//  ConversationTitleService.swift
//  Loop
//
//  Auto-titles conversations once they have enough content to be worth
//  naming. Fires from the iOS MessagingVC and the Mac VoiceLoopCoordinator
//  immediately after a plain assistant text reply lands — that's the
//  earliest moment we have both sides of an exchange.
//
//  Why a dedicated service (instead of going through Cloud / AgentHarness):
//  - The agent harness's system prompt is the whole SOUL/USER/MEMORY +
//    every tool catalog; sending that for a 5-word title is wasteful and
//    occasionally confuses the model into emitting tool calls.
//  - Title generation should use a small fast/cheap model regardless of
//    what the user picked for chat (they may be on Opus). We hard-code
//    Haiku for Anthropic and gpt-4o-mini for OpenAI.
//  - Fire-and-forget with per-conversation in-flight dedupe so the same
//    chat can't kick off two concurrent requests if the trigger fires
//    twice in quick succession (multi-turn tool batches).
//
//  Cross-platform: lives in `LoopIOS/Data/` so the file-system-synced
//  group picks it up for iOS, Mac, and Vision. No UIKit/AppKit imports.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

final class ConversationTitleService {
    static let shared = ConversationTitleService()

    /// Per-conversation in-flight set so a rapid second trigger (e.g. two
    /// quick assistant turns) doesn't fire two requests for the same chat.
    private let inFlightLock = NSLock()
    private var inFlight: Set<String> = []

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false  // no point retrying a title
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - Public API

    /// Best-effort: look at the conversation + its messages and, if it's
    /// the right moment to title, kick off a request. No-ops when:
    /// - `preserveCustomTitle` is true AND the conversation already has a
    ///   non-default title (we never clobber a user rename).
    /// - There isn't a real user-AND-assistant exchange yet (e.g., still
    ///   in onboarding, or assistant turn was tool-only).
    /// - A request is already in flight for this id.
    /// - No provider key (Anthropic or OpenAI) is configured.
    ///
    /// Pass `preserveCustomTitle: false` for the periodic refresh path so
    /// previously-auto-generated titles get updated as the conversation's
    /// topic drifts — every-N-messages callers want a fresh take, not "keep
    /// whatever was set the first time."
    func generateIfNeeded(for conversation: SimpleConversation,
                          messages: [MessageStruct],
                          preserveCustomTitle: Bool = true) {
        if preserveCustomTitle {
            guard isDefaultTitle(conversation.title) else { return }
        }
        guard hasRealExchange(messages: messages) else { return }

        let convId = conversation.id
        inFlightLock.lock()
        let alreadyInFlight = inFlight.contains(convId)
        if !alreadyInFlight { inFlight.insert(convId) }
        inFlightLock.unlock()
        guard !alreadyInFlight else { return }

        guard let provider = pickProvider() else {
            release(convId)
            return
        }
        let snippet = buildSnippet(messages: messages)
        provider.request(snippet: snippet, session: session) { [weak self] title in
            guard let self = self else { return }
            defer { self.release(convId) }
            guard let raw = title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return }
            let cleaned = Self.cleanTitle(raw)
            guard !cleaned.isEmpty else { return }
            self.applyTitle(cleaned, to: convId, preserveCustomTitle: preserveCustomTitle)
        }
    }

    /// Trigger generation directly off the persisted store. Used by
    /// `SimpleConversationManager.addMessage` once it's hit a milestone
    /// count — converts the lightweight `SimpleMessage` rows into the
    /// `MessageStruct` shape the inference helpers expect, then delegates
    /// to `generateIfNeeded` with `preserveCustomTitle: false` so periodic
    /// refreshes can replace earlier auto-generated titles. Pre-trigger
    /// gating (the count milestone) is the caller's job; this method only
    /// guards on the existing in-flight + provider-availability checks.
    func regenerateFromPersisted(conversationId: String) {
        guard let conv = SimpleConversationManager.shared.getConversation(by: conversationId) else { return }
        let messages: [MessageStruct] = conv.messages.map { sm in
            MessageStruct(id: sm.id,
                          role: sm.role,
                          content: sm.content,
                          model: sm.model ?? "GPT 5.5 Instant",
                          name: sm.name)
        }
        generateIfNeeded(for: conv, messages: messages, preserveCustomTitle: false)
    }

    /// Whether the conversation has crossed a title-refresh boundary. Fires
    /// at the first real exchange (2 messages) so the user sees a real title
    /// fast, then every 5 messages after to track topic drift. Counted off
    /// user-and-assistant messages only — system prompts, tool results, and
    /// onboarding scaffolding don't bump the milestone.
    static func shouldTrigger(forUserAssistantCount count: Int) -> Bool {
        if count == 2 { return true }
        return count > 2 && count % 5 == 0
    }

    // MARK: - Pre-conditions

    /// True for titles the auto-generator created or for default titles
    /// produced by `createConversation` / `createNewConversation` flows.
    /// User-renamed titles always fail this check so they're never
    /// overwritten.
    private func isDefaultTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed == "Untitled" { return true }
        if trimmed == "New Conversation" { return true }  // SimpleConversationManager default
        if trimmed == "General Questions" { return true } // legacy default
        if trimmed.hasPrefix("New Chat ") { return true } // iOS createNewConversation
        if trimmed.hasPrefix("Chat ") { return true }     // iOS ensureCurrentConversation
        if trimmed.hasPrefix("Vision Chat ") { return true } // visionOS new-conv button
        return false
    }

    /// True when the conversation has at least one real user message AND
    /// one real assistant reply. Onboarding turns and synthetic UI
    /// placeholders don't count — the model wouldn't get a useful title
    /// from "User: Skip / Assistant: Got it".
    private func hasRealExchange(messages: [MessageStruct]) -> Bool {
        let realUser = messages.contains { isReal(msg: $0, role: "user") }
        let realAssistant = messages.contains { isReal(msg: $0, role: "assistant") }
        return realUser && realAssistant
    }

    private func isReal(msg: MessageStruct, role: String) -> Bool {
        guard msg.role == role else { return false }
        guard !msg.content.isEmpty else { return false }
        guard msg.onboardingCard == nil else { return false }
        if msg.id.hasPrefix("image-") || msg.id.hasPrefix("pdf-") || msg.id.hasPrefix("story-") { return false }
        return true
    }

    // MARK: - Provider selection

    /// Prefer the user's currently selected chat provider so titles use
    /// whichever model they're already paying for / running. Falls through
    /// to whatever's actually available — Apple Foundation last because the
    /// on-device model is slowest of the four but always available.
    ///
    /// Apple is included so users on the default on-device model (no keys
    /// set) still get titled conversations. Without this, a fresh-install
    /// chat just stays "New Chat 5/24/26, 6:06 PM" forever.
    private func pickProvider() -> TitleProvider? {
        let preferred = ModelSelectionStore.current.provider
        if let p = provider(for: preferred) { return p }

        // User's selected provider has no key (e.g. they're on Apple, or
        // their cloud key was cleared). Try the cheap-cloud fallbacks in
        // order, then on-device. This way someone on Apple still gets a
        // title via Haiku if they happen to have an Anthropic key paste'd.
        for fallback in [ModelProvider.anthropic, .openAI, .fireworks, .apple] {
            if fallback == preferred { continue }
            if let p = provider(for: fallback) { return p }
        }
        return nil
    }

    /// Materialize a `TitleProvider` for `pref` if it's actually usable —
    /// either the matching API key is present, or it's Apple and on-device
    /// inference is available. Returns nil otherwise so `pickProvider` can
    /// fall through to the next candidate.
    private func provider(for pref: ModelProvider) -> TitleProvider? {
        switch pref {
        case .apple:
            return Self.appleFoundationAvailable() ? .apple : nil
        case .anthropic:
            if let key = KeyStore.shared.value(for: .anthropic), !key.isEmpty {
                return .anthropic(key: key)
            }
            return nil
        case .openAI:
            if let key = KeyStore.shared.value(for: .openAI), !key.isEmpty {
                return .openAI(key: key)
            }
            return nil
        case .fireworks:
            if let key = KeyStore.shared.value(for: .fireworks), !key.isEmpty {
                return .fireworks(key: key)
            }
            return nil
        }
    }

    /// Whether `SystemLanguageModel` can actually serve a request. False on
    /// devices below iOS 26 / macOS 26, or when Apple Intelligence is
    /// disabled / the model isn't downloaded yet. We don't want to "pick"
    /// a provider that will silently no-op every request.
    fileprivate static func appleFoundationAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    // MARK: - Snippet

    /// Build the prompt body the model gets. Cap at the first few real
    /// turns and truncate each to keep the request tiny — a title doesn't
    /// need the whole transcript.
    private func buildSnippet(messages: [MessageStruct]) -> String {
        let real = messages.filter { isReal(msg: $0, role: $0.role) }.prefix(6)
        return real.map { msg in
            let label = msg.role == "user" ? "User" : "Assistant"
            let body: String
            if msg.content.count > 600 {
                body = String(msg.content.prefix(600)) + "…"
            } else {
                body = msg.content
            }
            return "\(label): \(body)"
        }.joined(separator: "\n\n")
    }

    // MARK: - Apply

    /// Clean common model tics: surrounding quotes, trailing punctuation,
    /// stray "Title:" prefix, hard cap to 60 chars so the sidebar can render.
    static func cleanTitle(_ raw: String) -> String {
        var s = raw
        // Strip a "Title:" prefix the model sometimes adds.
        if let range = s.range(of: "title:", options: [.caseInsensitive, .anchored]) {
            s.removeSubrange(range)
            s = s.trimmingCharacters(in: .whitespaces)
        }
        // Drop surrounding quote marks (straight + smart).
        for q in ["\"", "'", "`", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"] {
            if s.hasPrefix(q) { s.removeFirst(q.count) }
            if s.hasSuffix(q) { s.removeLast(q.count) }
        }
        // Trim trailing punctuation that doesn't read well as a sidebar label.
        while let last = s.last, last == "." || last == "," || last == ":" || last == ";" {
            s.removeLast()
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse internal whitespace so a stray newline doesn't bleed.
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // Hard cap.
        if s.count > 60 { s = String(s.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return s
    }

    private func applyTitle(_ title: String, to convId: String, preserveCustomTitle: Bool = true) {
        DispatchQueue.main.async {
            let manager = SimpleConversationManager.shared
            guard var conv = manager.getConversation(by: convId) else { return }
            // Initial-generation path re-checks `isDefaultTitle` after the
            // round-trip so a rename mid-flight isn't clobbered. The
            // periodic-refresh path (called every 5 messages from addMessage)
            // intentionally bypasses that — its whole job is to update an
            // existing auto-generated title with the conversation's new
            // direction. Once a real rename UI exists, the rename should
            // set a "user-edited" flag we check here regardless of mode.
            if preserveCustomTitle {
                guard self.isDefaultTitle(conv.title) else { return }
            }
            // No-op if the model came back with exactly what's already on disk.
            guard conv.title != title else { return }
            conv.title = title
            manager.saveConversation(conv)
        }
    }

    private func release(_ convId: String) {
        inFlightLock.lock()
        inFlight.remove(convId)
        inFlightLock.unlock()
    }
}

// MARK: - Provider

/// Stamped at trigger time so the API call doesn't have to re-check
/// KeyStore (which is main-thread-affine and racey if the user toggles
/// keys during the request window).
private enum TitleProvider {
    case anthropic(key: String)
    case openAI(key: String)
    case fireworks(key: String)
    /// On-device via FoundationModels. No key, no network — slower than the
    /// cheap-cloud models but always works if Apple Intelligence is enabled.
    case apple

    func request(snippet: String,
                 session: URLSession,
                 completion: @escaping (String?) -> Void) {
        switch self {
        case .anthropic(let key):
            Self.sendAnthropic(key: key, snippet: snippet, session: session, completion: completion)
        case .openAI(let key):
            Self.sendOpenAI(key: key, snippet: snippet, session: session, completion: completion)
        case .fireworks(let key):
            Self.sendFireworks(key: key, snippet: snippet, session: session, completion: completion)
        case .apple:
            Self.sendApple(snippet: snippet, completion: completion)
        }
    }

    private static let systemPrompt = """
You generate a short, descriptive title (3-5 words) for a chat conversation. Capture the topic specifically — "Wedding venue brainstorm" not "Wedding planning". Title Case. No quotes, no period, no prefix. Just the title.
"""

    private static let userInstruction = """
Title this conversation in 3-5 words:

"""

    // MARK: Anthropic (Haiku 4.5)

    private static func sendAnthropic(key: String,
                                       snippet: String,
                                       session: URLSession,
                                       completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 32,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userInstruction + snippet],
            ],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let task = session.dataTask(with: req) { data, response, error in
            if let error = error {
                print("TitleService anthropic error: \(error.localizedDescription)")
                completion(nil); return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                print("TitleService anthropic HTTP \(http.statusCode): \(bodyStr)")
                completion(nil); return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let first = content.first,
                  let text = first["text"] as? String else {
                completion(nil); return
            }
            completion(text)
        }
        task.resume()
    }

    // MARK: OpenAI (gpt-4o-mini)

    private static func sendOpenAI(key: String,
                                    snippet: String,
                                    session: URLSession,
                                    completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "max_tokens": 32,
            "temperature": 0.4,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userInstruction + snippet],
            ],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let task = session.dataTask(with: req) { data, response, error in
            if let error = error {
                print("TitleService openai error: \(error.localizedDescription)")
                completion(nil); return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                print("TitleService openai HTTP \(http.statusCode): \(bodyStr)")
                completion(nil); return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String else {
                completion(nil); return
            }
            completion(text)
        }
        task.resume()
    }

    // MARK: Fireworks (Kimi K2.6 via Fireworks inference)

    private static func sendFireworks(key: String,
                                      snippet: String,
                                      session: URLSession,
                                      completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://api.fireworks.ai/inference/v1/chat/completions") else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "accounts/fireworks/models/kimi-k2p6",
            "max_tokens": 32,
            "temperature": 0.4,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userInstruction + snippet],
            ],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let task = session.dataTask(with: req) { data, response, error in
            if let error = error {
                print("TitleService fireworks error: \(error.localizedDescription)")
                completion(nil); return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                print("TitleService fireworks HTTP \(http.statusCode): \(bodyStr)")
                completion(nil); return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String else {
                completion(nil); return
            }
            completion(text)
        }
        task.resume()
    }

    // MARK: Apple Foundation (on-device)

    /// On-device via `SystemLanguageModel`. No network, no key — the title
    /// is generated locally so this works even on a freshly-installed app
    /// with no API keys. Slower than the cheap-cloud models (sub-second on
    /// recent Apple Silicon, a few seconds otherwise) but title generation
    /// is fire-and-forget so the user never waits on it.
    private static func sendApple(snippet: String,
                                  completion: @escaping (String?) -> Void) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                completion(nil); return
            }
            // FoundationModels takes one combined prompt — there's no
            // system/user role split at this layer. Stitch them with a
            // separator the model can latch onto.
            let prompt = systemPrompt + "\n\n" + userInstruction + snippet
            Task {
                do {
                    let session = LanguageModelSession()
                    let response = try await session.respond(to: prompt)
                    completion(response.content)
                } catch {
                    print("TitleService apple error: \(error.localizedDescription)")
                    completion(nil)
                }
            }
            return
        }
        #endif
        completion(nil)
    }
}
