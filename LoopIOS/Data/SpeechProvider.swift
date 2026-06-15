//
//  SpeechProvider.swift
//  Loop
//
//  Typed stores for user-selectable speech pipeline providers. Mirrors
//  ModelSelectionStore in shape so Settings ▸ Model can pick all three
//  (inference + STT + TTS) from a single screen.
//
//  Both stores back onto iCloud-KVS so the choice syncs across devices.
//
//  Why STT lives here:
//  - MessageBox (iOS) currently hardcodes Deepgram-streaming with an SFSpeech
//    fallback for failure cases. Switching the user explicitly between
//    "Deepgram" and "Apple" requires reading a stored preference at
//    startRecording() time.
//  - LoopMac's VoiceLoopCoordinator picks based on reachability + key
//    presence. The same store gives the user an override when "auto" isn't
//    the right choice (e.g. forcing Apple on a slow network).
//
//  TTS already had a stored preference under iCloudKVSDefaults["ttsProvider"]
//  read directly inside MessagingVC. This wrapper consolidates that read so
//  Settings can write to the same key without recreating MessagingVC's
//  computed property.
//

import Foundation

// MARK: - STT

/// Speech-to-text engine. `auto` reproduces the historical heuristic (prefer
/// Deepgram when its key is set and the device is online; fall back to Apple).
/// `apple` and `deepgram` are explicit user overrides.
enum STTProvider: String, CaseIterable {
    case auto
    case apple
    case deepgram

    var displayName: String {
        switch self {
        case .auto:     return "Auto"
        case .apple:    return "Apple"
        case .deepgram: return "Deepgram"
        }
    }

    var summary: String {
        switch self {
        case .auto:
            return "Pick the best available — Deepgram when online with a key, Apple otherwise."
        case .apple:
            return "Apple's on-device speech recognizer. No network, no API key. Free."
        case .deepgram:
            return "Deepgram Nova-3 streaming over WebSocket. Fast and accurate; needs a key."
        }
    }

    var requiredKey: KeyStore.Key? {
        switch self {
        case .deepgram: return .deepgram
        default:        return nil
        }
    }
}

enum STTProviderStore {
    private static let defaultsKey = "loop.sttProvider"

    static var current: STTProvider {
        get {
            let raw = iCloudKVSDefaults.shared.string(forKey: defaultsKey) ?? ""
            return STTProvider(rawValue: raw) ?? .auto
        }
        set {
            iCloudKVSDefaults.shared.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: .sttProviderChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let sttProviderChanged = Notification.Name("loop.sttProviderChanged")
}

// MARK: - TTS

/// Streaming-TTS provider used for assistant audio. Lives here rather than in
/// MessagingVC so the macOS and visionOS targets (which exclude MessagingVC
/// from compilation) can still reference the enum for settings code.
///
/// Each case has its own API-key Info.plist slot and falls through to
/// AVSpeechSynthesizer if the key is missing or the request fails.
enum TTSProvider: String, CaseIterable {
    case aura2              = "aura2"              // Deepgram Aura-2 — fastest, flat prosody
    case elevenLabsV3       = "elevenLabsV3"       // ElevenLabs Eleven v3 — most expressive, ~600ms-1s TTFB
    case elevenLabsFlashV25 = "elevenLabsFlashV25" // ElevenLabs Flash v2.5 — low-latency (~75ms model TTFB), less expressive than v3
    case openAIMiniTTS      = "openAIMiniTTS"      // OpenAI gpt-4o-mini-tts — steerable via instructions
    case system             = "system"             // On-device AVSpeechSynthesizer (no network)

    /// Human-readable name shown in the speaker menu.
    var displayName: String {
        switch self {
        case .aura2:              return "Deepgram Aura-2"
        case .elevenLabsV3:       return "ElevenLabs v3"
        case .elevenLabsFlashV25: return "ElevenLabs Flash v2.5"
        case .openAIMiniTTS:      return "OpenAI gpt-4o-mini-tts"
        case .system:             return "On-device (offline)"
        }
    }

    /// Voice identifiers the user can pick for this provider, alongside a
    /// human label. For the `.system` case, voices come from
    /// AVSpeechSynthesisVoice.speechVoices() at runtime — handled separately.
    var voiceOptions: [(label: String, id: String)] {
        switch self {
        case .aura2:
            return [
                ("Thalia (warm female)",   "aura-2-thalia-en"),
                ("Asteria (calm female)",  "aura-2-asteria-en"),
                ("Luna (soft female)",     "aura-2-luna-en"),
                ("Helios (deep male)",     "aura-2-helios-en"),
                ("Orion (clear male)",     "aura-2-orion-en"),
                ("Arcas (narrative male)", "aura-2-arcas-en")
            ]
        case .elevenLabsV3, .elevenLabsFlashV25:
            return [
                ("Rachel (warm female)",  "21m00Tcm4TlvDq8ikWAM"),
                ("Bella (young female)",  "EXAVITQu4vr4xnSDxMaL"),
                ("Adam (deep male)",      "pNInz6obpgDQGcFmaJgB"),
                ("Antoni (calm male)",    "ErXwobaYiN019PkySvjV"),
                ("Elli (soft female)",    "MF3mGyEYCl7XYWbV9V6O"),
                ("Josh (steady male)",    "TxGEqnHWrfWFTfGW9XjX"),
                ("Hayes (english male)",          "sIivXWc5MTlPIP3kJXhg"),
                ("Rory (irish male)",             "hmMWXCj9K7N5mCPcRkfC"),
                ("Hannah (american female)",      "ZSNL4hPqCnqoMPaI4jGX"),
                ("Zoe (african american female)", "M6ic45wruJGWAxLFEMNK"),
                ("Agent (secret agent male)",     "ICIc5IiEgLitxGwyb7ZG")
            ]
        case .openAIMiniTTS:
            return ["alloy", "echo", "fable", "onyx", "nova",
                    "shimmer", "coral", "sage", "ash", "ballad", "verse"]
                .map { ($0.capitalized, $0) }
        case .system:
            return []
        }
    }

    /// Voice id used when the user hasn't picked one for this provider yet.
    var defaultVoiceId: String {
        switch self {
        case .aura2:              return "aura-2-thalia-en"
        case .elevenLabsV3:       return "21m00Tcm4TlvDq8ikWAM"
        case .elevenLabsFlashV25: return "ZSNL4hPqCnqoMPaI4jGX" // Hannah (american female)
        case .openAIMiniTTS:      return "shimmer"
        case .system:             return ""
        }
    }
}

/// Typed wrapper around the existing iCloudKVSDefaults["ttsProvider"] key.
/// The MessagingVC computed property has historically read this key directly;
/// keeping the raw read here lets Settings write the same store without
/// duplicating MessagingVC's default value.
enum TTSProviderStore {
    /// Storage key. Intentionally matches MessagingVC's existing read so a
    /// pre-existing preference roundtrips through this wrapper unchanged.
    static let defaultsKey = "ttsProvider"

    static var current: TTSProvider {
        get {
            let raw = iCloudKVSDefaults.shared.string(forKey: defaultsKey) ?? TTSProvider.elevenLabsFlashV25.rawValue
            return TTSProvider(rawValue: raw) ?? .elevenLabsFlashV25
        }
        set {
            iCloudKVSDefaults.shared.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: .ttsProviderChanged, object: nil)
        }
    }

    /// API key the user must have configured for the given provider to work,
    /// or nil for the on-device option. Mirrors `ModelSelection.requiredKey`.
    static func requiredKey(for provider: TTSProvider) -> KeyStore.Key? {
        switch provider {
        case .aura2:                                  return .deepgram
        case .elevenLabsV3, .elevenLabsFlashV25:      return .elevenLabs
        case .openAIMiniTTS:                          return .openAI
        case .system:                                 return nil
        }
    }
}

extension Notification.Name {
    static let ttsProviderChanged = Notification.Name("loop.ttsProviderChanged")
}
