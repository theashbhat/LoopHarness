//
//  ModelSelection.swift
//  Loop
//
//  User-facing choice of which language model handles the next turn.
//  Persisted in iCloud-KVS-backed UserDefaults so the pick survives
//  relaunches and syncs across devices. Mac surfaces it as a grouped menu
//  (Apple / OpenAI ▸ / Anthropic ▸); iOS reads the same store.
//
//  AgentHarness reads `ModelSelectionStore.current` at dispatch time and
//  routes by `.provider`:
//    .apple     → on-device Apple Foundation model (FoundationModels)
//    .openAI    → OpenAIChat   (direct, user's OPENAI_API_KEY)
//    .anthropic → AnthropicChat (direct, user's ANTHROPIC_API_KEY)
//    .fireworks → FireworksChat  (direct, user's FIREWORKS_API_KEY)
//  Reachability still wins — offline always falls back to Apple, since the
//  hosted providers can't work without a network. The selection is just the
//  user's *preferred* model when the network is available.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Top-level provider grouping. Drives the Mac menu's submenus and the
/// AgentHarness routing switch.
enum ModelProvider: String, CaseIterable {

    /// Whether Apple's on-device Foundation model is usable on this
    /// device/OS. Returns `false` on pre-iOS 26, when Apple Intelligence
    /// is disabled, or when the model hasn't finished downloading.
    static var isAppleFoundationAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    /// The highest-priority provider that already has a usable API key in
    /// the Keychain. Returns `nil` when no hosted provider is configured.
    static var firstKeyedProvider: ModelProvider? {
        let ranked: [(ModelProvider, KeyStore.Key)] = [
            (.anthropic, .anthropic),
            (.openAI, .openAI),
            (.fireworks, .fireworks),
        ]
        for (provider, key) in ranked {
            if KeyStore.shared.source(for: key) != .missing {
                return provider
            }
        }
        return nil
    }

    /// `true` when at least one hosted-provider API key is configured.
    static var hasAnyProviderKey: Bool {
        firstKeyedProvider != nil
    }

    case apple
    case openAI
    case anthropic
    case fireworks

    var displayName: String {
        switch self {
        case .apple:     return "Apple"
        case .openAI:    return "OpenAI"
        case .anthropic: return "Anthropic"
        case .fireworks: return "Fireworks"
        }
    }
}

enum ModelSelection: String, CaseIterable {

    // Apple — on-device, no key, requires iOS 26 / macOS 26.
    case appleFoundation = "appleFoundation"

    // OpenAI. rawValue "gpt55" is intentionally preserved so selections
    // stored by the previous two-case enum keep resolving after upgrade.
    case gpt55 = "gpt55"
    case gpt51 = "gpt51"
    case gpt41 = "gpt41"
    case gpt4o = "gpt4o"

    // Anthropic / Claude.
    case claudeOpus47   = "claudeOpus47"
    case claudeSonnet46 = "claudeSonnet46"
    case claudeHaiku45  = "claudeHaiku45"

    // Fireworks — models served via Fireworks inference.
    case fireworksKimiK26 = "fireworksKimiK26"
    case fireworksGLM52  = "fireworksGLM52"

    var provider: ModelProvider {
        switch self {
        case .appleFoundation:
            return .apple
        case .gpt55, .gpt51, .gpt41, .gpt4o:
            return .openAI
        case .claudeOpus47, .claudeSonnet46, .claudeHaiku45:
            return .anthropic
        case .fireworksKimiK26, .fireworksGLM52:
            return .fireworks
        }
    }

    /// Human-readable label used in menus and message attribution.
    var displayName: String {
        switch self {
        case .appleFoundation: return "Apple Foundation"
        case .gpt55:           return "GPT-5.5"
        case .gpt51:           return "GPT-5.1"
        case .gpt41:           return "GPT-4.1"
        case .gpt4o:           return "GPT-4o"
        case .claudeOpus47:    return "Claude Opus 4.7"
        case .claudeSonnet46:  return "Claude Sonnet 4.6"
        case .claudeHaiku45:   return "Claude Haiku 4.5"
        case .fireworksKimiK26: return "Kimi K2.6"
        case .fireworksGLM52:  return "GLM 5.2"
        }
    }

    /// Exact identifier sent on the wire to the provider's API. `nil` for the
    /// on-device Apple model (no HTTP call). If a provider renames a model,
    /// this is the one line per model to change — a wrong value surfaces as a
    /// visible "model not found" API error, never a silent fallback.
    var apiModelID: String? {
        switch self {
        case .appleFoundation: return nil
        case .gpt55:           return "gpt-5.5"
        case .gpt51:           return "gpt-5.1"
        case .gpt41:           return "gpt-4.1"
        case .gpt4o:           return "gpt-4o"
        case .claudeOpus47:    return "claude-opus-4-7"
        case .claudeSonnet46:  return "claude-sonnet-4-6"
        case .claudeHaiku45:   return "claude-haiku-4-5-20251001"
        case .fireworksKimiK26: return "accounts/fireworks/models/kimi-k2p6"
        case .fireworksGLM52:  return "accounts/fireworks/models/glm-5p2"
        }
    }

    /// String stamped onto outgoing assistant messages so the message-cell
    /// "model" label matches the picker. Apple keeps its existing wire value.
    var stampedMessageModel: String {
        switch provider {
        case .apple: return "Apple LLM"
        default:     return displayName
        }
    }

    /// Total context window size in tokens, or `nil` when the limit is
    /// unknown (Apple on-device model). Used to compute the "Context X%"
    /// byline chip after each assistant response.
    var contextWindowSize: Int? {
        switch self {
        case .appleFoundation:  return nil
        case .gpt55:            return 1_048_576
        case .gpt51:            return 1_048_576
        case .gpt41:            return 1_048_576
        case .gpt4o:            return 128_000
        case .claudeOpus47:     return 200_000
        case .claudeSonnet46:   return 200_000
        case .claudeHaiku45:    return 200_000
        case .fireworksKimiK26: return 131_072
        case .fireworksGLM52:  return 1_048_576
        }
    }

    /// Look up a model's context window by its `stampedMessageModel` label.
    /// Returns `nil` when the label doesn't match any known model.
    static func contextWindowSize(forStamp stamp: String) -> Int? {
        allCases.first { $0.stampedMessageModel == stamp }?.contextWindowSize
    }

    /// Models for a provider, in menu order.
    static func models(for provider: ModelProvider) -> [ModelSelection] {
        allCases.filter { $0.provider == provider }
    }

    /// API key the user must have configured for this model to actually work,
    /// or `nil` for providers that need no credential (Apple runs on-device).
    /// Pickers use this to gate selection on a missing key with a "add it now"
    /// prompt, so the user never silently lands on a model whose next turn
    /// will auth-fail.
    var requiredKey: KeyStore.Key? {
        switch provider {
        case .apple:     return nil
        case .openAI:    return .openAI
        case .anthropic: return .anthropic
        case .fireworks: return .fireworks
        }
    }

    /// Whether this model can accept image input. Drives the per-turn vision
    /// fallback: a turn that must send a raw image is routed to a vision-capable
    /// model when the selected one can't see images (see
    /// `AgentHarness.chat`). If a provider adds/removes vision support, this is
    /// the one place to update.
    var supportsVision: Bool {
        switch self {
        case .appleFoundation:
            return false
        case .gpt55, .gpt51, .gpt41, .gpt4o:
            return true
        case .claudeOpus47, .claudeSonnet46, .claudeHaiku45:
            return true
        case .fireworksKimiK26:
            return true
        case .fireworksGLM52:
            // GLM 5.2 on Fireworks is text-only — image turns fall back to Kimi.
            return false
        }
    }

    /// Whether this model can actually run right now: a hosted model needs its
    /// API key configured; Apple needs the on-device model available.
    var isUsable: Bool {
        guard let key = requiredKey else {
            return ModelProvider.isAppleFoundationAvailable
        }
        return KeyStore.shared.source(for: key) != .missing
    }

    /// A vision-capable, currently-usable model to handle an image turn when the
    /// selected model can't. Prefers the same provider (so keys/billing stay
    /// consistent — e.g. GLM 5.2 → Kimi K2.6 on Fireworks), then falls back to
    /// the first usable vision model on any hosted provider. Returns nil when no
    /// vision-capable model is configured. Apple is never returned (no vision).
    static func visionCapableFallback(preferring provider: ModelProvider) -> ModelSelection? {
        if let sameProvider = models(for: provider).first(where: { $0.supportsVision && $0.isUsable }) {
            return sameProvider
        }
        for other in [ModelProvider.anthropic, .openAI, .fireworks] where other != provider {
            if let model = models(for: other).first(where: { $0.supportsVision && $0.isUsable }) {
                return model
            }
        }
        return nil
    }
}

enum ModelSelectionStore {
    private static let defaultsKey = "loop.modelSelection"

    /// Current user selection. With no explicit pick yet, prefer Kimi K2.6
    /// via Fireworks when a `FIREWORKS_API_KEY` is bundled (or stored) so a
    /// fresh build with the key in Secrets.xcconfig comes up on Kimi K2.6
    /// without the user having to open Settings ▸ Model. Otherwise fall back
    /// to `.appleFoundation`, which runs on-device and needs no key.
    static var current: ModelSelection {
        get {
            let raw = iCloudKVSDefaults.shared.string(forKey: defaultsKey) ?? ""
            if let stored = ModelSelection(rawValue: raw) { return stored }
            if KeyStore.shared.source(for: .fireworks) != .missing {
                return .fireworksKimiK26
            }
            return .appleFoundation
        }
        set {
            iCloudKVSDefaults.shared.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: .modelSelectionChanged, object: nil)
        }
    }
}

extension Notification.Name {
    /// Fired (on the posting thread) whenever the user picks a different
    /// model. The Mac menu listens for this to refresh its checkmark; the
    /// rest of the app reads `ModelSelectionStore.current` lazily at request
    /// time and doesn't need to subscribe.
    static let modelSelectionChanged = Notification.Name("loop.modelSelectionChanged")
}
