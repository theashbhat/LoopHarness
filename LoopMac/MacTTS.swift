//
//  MacTTS.swift
//  LoopMac
//
//  TTS provider selection for the Mac app, mirroring the iOS MessagingVC menu
//  but in a smaller form. Defaults to Deepgram Aura-2 (matching the iOS
//  default behavior the user prefers); on failure falls back to
//  AVSpeechSynthesizer.
//

import Foundation
import AVFoundation
import AppKit

/// Subset of iOS's TTSProvider that's wired up on Mac. We can grow this list
/// later — for now Aura covers the streaming low-latency path and "system"
/// is the always-works fallback.
enum MacTTSProvider: String, CaseIterable {
    case aura2              = "aura2"              // Deepgram Aura-2 (streaming, lowest latency)
    case elevenLabsV3       = "elevenLabsV3"       // ElevenLabs Eleven v3 (most expressive)
    case elevenLabsFlashV25 = "elevenLabsFlashV25" // ElevenLabs Flash v2.5 (low-latency)
    case openAIMiniTTS      = "openAIMiniTTS"      // OpenAI gpt-4o-mini-tts (steerable via instructions)
    case system             = "system"             // AVSpeechSynthesizer (offline)

    var displayName: String {
        switch self {
        case .aura2:              return "Deepgram Aura-2"
        case .elevenLabsV3:       return "ElevenLabs v3"
        case .elevenLabsFlashV25: return "ElevenLabs Flash v2.5"
        case .openAIMiniTTS:      return "OpenAI gpt-4o-mini-tts"
        case .system:             return "On-device (offline)"
        }
    }

    /// ElevenLabs `model_id` for the API request, or nil for non-ElevenLabs
    /// providers.
    var elevenLabsModelId: String? {
        switch self {
        case .elevenLabsV3:       return "eleven_v3"
        case .elevenLabsFlashV25: return "eleven_flash_v2_5"
        default:                  return nil
        }
    }
}

/// Settings + Aura voice list, persisted in UserDefaults so the user's pick
/// survives relaunches.
final class TTSSettings {
    static let shared = TTSSettings()

    private let defaults = UserDefaults.standard
    private let providerKey = "loopmac.ttsProvider"
    private let auraVoiceKey = "loopmac.ttsAuraVoice"
    private let elevenLabsV3VoiceKey = "loopmac.ttsElevenLabsV3Voice"
    private let elevenLabsFlashVoiceKey = "loopmac.ttsElevenLabsFlashVoice"
    private let openAIVoiceKey = "loopmac.ttsOpenAIVoice"

    /// Defaults to .aura2 to match the iOS preference the user mentioned.
    var provider: MacTTSProvider {
        get {
            let raw = defaults.string(forKey: providerKey) ?? MacTTSProvider.aura2.rawValue
            return MacTTSProvider(rawValue: raw) ?? .aura2
        }
        set {
            defaults.set(newValue.rawValue, forKey: providerKey)
            NotificationCenter.default.post(name: .ttsSettingsChanged, object: nil)
        }
    }

    var auraVoice: String {
        get { defaults.string(forKey: auraVoiceKey) ?? "aura-2-thalia-en" }
        set {
            defaults.set(newValue, forKey: auraVoiceKey)
            NotificationCenter.default.post(name: .ttsSettingsChanged, object: nil)
        }
    }

    static let auraVoices: [(label: String, id: String)] = [
        ("Thalia (warm female)",   "aura-2-thalia-en"),
        ("Asteria (calm female)",  "aura-2-asteria-en"),
        ("Luna (soft female)",     "aura-2-luna-en"),
        ("Helios (deep male)",     "aura-2-helios-en"),
        ("Orion (clear male)",     "aura-2-orion-en"),
        ("Arcas (narrative male)", "aura-2-arcas-en"),
    ]

    /// ElevenLabs voice library. Both v3 and Flash v2.5 share the same set;
    /// callers pick per-provider so v3 / Flash can store different picks.
    /// Kept in sync with iOS's `TTSProvider.voiceOptions`.
    static let elevenLabsVoices: [(label: String, id: String)] = [
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
        ("Agent (secret agent male)",     "ICIc5IiEgLitxGwyb7ZG"),
    ]

    private static let elevenLabsDefaultVoiceId = "21m00Tcm4TlvDq8ikWAM"

    func elevenLabsVoice(for provider: MacTTSProvider) -> String {
        switch provider {
        case .elevenLabsV3:
            return defaults.string(forKey: elevenLabsV3VoiceKey) ?? Self.elevenLabsDefaultVoiceId
        case .elevenLabsFlashV25:
            return defaults.string(forKey: elevenLabsFlashVoiceKey) ?? Self.elevenLabsDefaultVoiceId
        default:
            return Self.elevenLabsDefaultVoiceId
        }
    }

    func setElevenLabsVoice(_ id: String, for provider: MacTTSProvider) {
        switch provider {
        case .elevenLabsV3:
            defaults.set(id, forKey: elevenLabsV3VoiceKey)
        case .elevenLabsFlashV25:
            defaults.set(id, forKey: elevenLabsFlashVoiceKey)
        default:
            return
        }
        NotificationCenter.default.post(name: .ttsSettingsChanged, object: nil)
    }

    /// OpenAI gpt-4o-mini-tts voice library. Kept in sync with iOS's
    /// `TTSProvider.voiceOptions` for the `.openAIMiniTTS` case.
    static let openAIVoices: [(label: String, id: String)] = [
        "alloy", "echo", "fable", "onyx", "nova",
        "shimmer", "coral", "sage", "ash", "ballad", "verse",
    ].map { ($0.capitalized, $0) }

    static let openAIDefaultVoice = "shimmer"

    var openAIVoice: String {
        get { defaults.string(forKey: openAIVoiceKey) ?? Self.openAIDefaultVoice }
        set {
            defaults.set(newValue, forKey: openAIVoiceKey)
            NotificationCenter.default.post(name: .ttsSettingsChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let ttsSettingsChanged = Notification.Name("LoopMacTTSSettingsChanged")
}

/// Plays a finished assistant message via the chosen TTS provider. Returns
/// immediately; the caller observes `onFinished` to reset UI state. On
/// failure, falls back to AVSpeechSynthesizer.
final class MacSpeechPlayer {
    private var deepgramTTS: DeepgramTTS?
    private var audioPlayer: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var currentToken = 0
    /// Polls `audioPlayer.averagePower(forChannel:)` while an AVAudioPlayer-
    /// backed path (ElevenLabs) is producing audio. Runs only while playback
    /// is live; torn down in `stop()`.
    private var meteringTimer: Timer?

    /// Fired on the main thread when playback finishes (or errors out and
    /// falls back). Reset coordinator state here.
    var onFinished: (() -> Void)?

    /// Per-buffer output amplitude (0…1) of whatever provider is currently
    /// playing. The coordinator forwards this into the avatar's speaking-
    /// mode pulse so the orb tracks the actual TTS output instead of a
    /// canned sine. Always published on the main queue.
    var onOutputAmplitude: ((Float) -> Void)?

    /// Cancels any in-flight playback. Safe to call from anywhere.
    func stop() {
        currentToken &+= 1
        deepgramTTS?.stop()
        deepgramTTS = nil
        audioPlayer?.stop()
        audioPlayer = nil
        meteringTimer?.invalidate(); meteringTimer = nil
        // `stopSpeaking(at:)` synchronously blocks on AVSpeechSynthesizer's
        // internal Default-QoS speech-service thread. Calling it from the main
        // (user-interactive) thread is a priority inversion that trips the
        // Thread Performance Checker's "hang risk" warning, so hop to a
        // matching Default-QoS queue — stop() is fire-and-forget (callers
        // observe onFinished), and stopping when idle is harmless.
        DispatchQueue.global(qos: .default).async { [synthesizer] in
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        }
        // Drop the avatar's speaking amplitude to 0 so its EMA decays back
        // to the canned/idle behavior promptly.
        DispatchQueue.main.async { [weak self] in self?.onOutputAmplitude?(0) }
    }

    /// Start a 30 Hz metering timer that converts the AVAudioPlayer's
    /// dB power into a linear [0, 1] amplitude and publishes it. Used by
    /// the ElevenLabs path.
    private func startMetering(for player: AVAudioPlayer, token: Int) {
        meteringTimer?.invalidate()
        player.isMeteringEnabled = true
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak player] _ in
            guard let self = self, self.currentToken == token, let player = player, player.isPlaying else { return }
            player.updateMeters()
            let db = player.averagePower(forChannel: 0)
            // -80 dB ≈ silence; -10 dB is fairly loud. Map [-50, 0] → [0, 1]
            // and apply a small ceiling so peaks don't pin the orb.
            let normalized = max(0, min(1, (db + 50.0) / 50.0))
            self.onOutputAmplitude?(Float(normalized))
        }
    }

    /// Speak `text` using the provider currently selected in TTSSettings.
    func speak(_ text: String) {
        stop()
        currentToken &+= 1
        let token = currentToken
        let cleaned = SpeechSanitizer().sanitize(text)
        guard !cleaned.isEmpty else {
            DispatchQueue.main.async { [weak self] in self?.onFinished?() }
            return
        }

        // Offline → short-circuit to AVSpeechSynthesizer. Trying Aura /
        // ElevenLabs first would just hit WebSocket / HTTP timeouts before
        // falling through to the same on-device path, and the user hears
        // nothing for several seconds.
        let provider: MacTTSProvider = !Reachability.isOnline ? .system : TTSSettings.shared.provider
        switch provider {
        case .aura2:
            if speakViaAura(cleaned, token: token) { return }
            speakViaSystem(cleaned, token: token)
        case .elevenLabsV3, .elevenLabsFlashV25:
            if speakViaElevenLabs(cleaned, provider: provider, token: token) { return }
            speakViaSystem(cleaned, token: token)
        case .openAIMiniTTS:
            if speakViaOpenAI(cleaned, token: token) { return }
            speakViaSystem(cleaned, token: token)
        case .system:
            speakViaSystem(cleaned, token: token)
        }
    }

    // MARK: - Aura streaming

    private func speakViaAura(_ text: String, token: Int) -> Bool {
        guard let key = Self.deepgramKey else { return false }
        let tts = DeepgramTTS(apiKey: key,
                              voice: TTSSettings.shared.auraVoice,
                              speed: 1.2)
        // If Aura gets ANY PCM out before erroring, we treat the turn as
        // hers and skip the on-device fallback — replaying the full text on
        // top of partial Aura speech is more jarring than just stopping at
        // the partial. Flipped only on main, read only on main.
        var didReceiveAudio = false
        tts.onFirstAudio = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.currentToken == token else { return }
                didReceiveAudio = true
            }
        }
        tts.onError = { [weak self] err in
            DispatchQueue.main.async {
                guard let self = self, self.currentToken == token else { return }
                self.deepgramTTS = nil
                if didReceiveAudio {
                    print("Aura TTS error \(err) after first audio — keeping partial speech")
                    self.onFinished?()
                    return
                }
                print("Aura TTS error \(err) — falling back to on-device")
                self.speakViaSystem(text, token: token)
            }
        }
        tts.onFinished = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.currentToken == token else { return }
                self.deepgramTTS = nil
                self.onFinished?()
            }
        }
        tts.onOutputAmplitude = { [weak self] amp in
            // Token-guarded so a stale Aura that we abandoned can't keep
            // pushing into the active turn's avatar.
            guard let self = self, self.currentToken == token else { return }
            self.onOutputAmplitude?(amp)
        }
        guard tts.start() else {
            print("Aura TTS engine.start() failed — falling back")
            return false
        }
        self.deepgramTTS = tts
        tts.speak(text: text)
        return true
    }

    // MARK: - ElevenLabs HTTP

    /// Returns true if the request was kicked off; false if there's no key
    /// (caller falls back to on-device). Network/HTTP failures inside the
    /// task also fall back, but synchronously they can't here.
    private func speakViaElevenLabs(_ text: String, provider: MacTTSProvider, token: Int) -> Bool {
        guard let apiKey = Self.elevenLabsKey,
              let modelId = provider.elevenLabsModelId else { return false }

        let voiceId = TTSSettings.shared.elevenLabsVoice(for: provider)
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)") else {
            return false
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "text": text,
            "model_id": modelId,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
                "style": 0.4,
                "use_speaker_boost": true
            ]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return false }
        req.httpBody = bodyData

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self, self.currentToken == token else { return }
                if let error = error {
                    print("ElevenLabs TTS error: \(error) — falling back to on-device")
                    self.speakViaSystem(text, token: token)
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                    print("ElevenLabs TTS HTTP \(http.statusCode): \(bodyStr) — falling back to on-device")
                    self.speakViaSystem(text, token: token)
                    return
                }
                guard let data = data, !data.isEmpty else {
                    print("ElevenLabs TTS empty audio — falling back to on-device")
                    self.speakViaSystem(text, token: token)
                    return
                }
                self.playMP3Data(data, fallbackText: text, providerLabel: "ElevenLabs", token: token)
            }
        }.resume()
        return true
    }

    // MARK: - OpenAI gpt-4o-mini-tts HTTP

    /// Steers OpenAI's gpt-4o-mini-tts toward better list pacing and warmth.
    /// Mirrors the iOS `openAITTSInstructions`.
    private static let openAIInstructions = """
    Speak in a warm, natural, conversational tone. When reading lists, pause \
    briefly between items so each one is distinct. Vary pace and emphasis \
    like a person would.
    """

    /// Returns true if the request was kicked off; false if there's no key
    /// (caller falls back to on-device). Network/HTTP failures inside the
    /// task also fall back.
    private func speakViaOpenAI(_ text: String, token: Int) -> Bool {
        guard let apiKey = Self.openAIKey else { return false }

        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "input": text,
            "voice": TTSSettings.shared.openAIVoice,
            "response_format": "mp3",
            "instructions": Self.openAIInstructions
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return false }
        req.httpBody = bodyData

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self, self.currentToken == token else { return }
                if let error = error {
                    print("OpenAI TTS error: \(error) — falling back to on-device")
                    self.speakViaSystem(text, token: token)
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                    print("OpenAI TTS HTTP \(http.statusCode): \(bodyStr) — falling back to on-device")
                    self.speakViaSystem(text, token: token)
                    return
                }
                guard let data = data, !data.isEmpty else {
                    print("OpenAI TTS empty audio — falling back to on-device")
                    self.speakViaSystem(text, token: token)
                    return
                }
                self.playMP3Data(data, fallbackText: text, providerLabel: "OpenAI", token: token)
            }
        }.resume()
        return true
    }

    // MARK: - Shared MP3-buffer playback

    /// Plays full-buffer MP3 bytes (ElevenLabs / OpenAI) via AVAudioPlayer and
    /// drives avatar metering. Falls back to on-device if the bytes won't
    /// decode. Must be called on the main thread with a current token.
    private func playMP3Data(_ data: Data, fallbackText: String, providerLabel: String, token: Int) {
        guard let player = try? AVAudioPlayer(data: data) else {
            print("\(providerLabel) TTS bad audio — falling back to on-device")
            self.speakViaSystem(fallbackText, token: token)
            return
        }
        player.prepareToPlay()
        player.play()
        self.audioPlayer = player
        self.startMetering(for: player, token: token)
        let duration = max(player.duration, 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self, self.currentToken == token else { return }
            self.meteringTimer?.invalidate(); self.meteringTimer = nil
            self.audioPlayer = nil
            self.onOutputAmplitude?(0)
            self.onFinished?()
        }
    }

    // MARK: - On-device fallback

    private func speakViaSystem(_ text: String, token: Int) {
        let utter = AVSpeechUtterance(string: text)
        utter.rate = AVSpeechUtteranceDefaultSpeechRate
        if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utter.voice = voice
        }
        synthesizer.speak(utter)
        // Approximate finish — we don't wire the delegate here because the
        // Mac UI only needs a "speaking ended" signal close enough for the
        // visual state to flip back to idle.
        let approx = max(2.0, Double(text.count) * 0.05)
        DispatchQueue.main.asyncAfter(deadline: .now() + approx) { [weak self] in
            guard let self = self, self.currentToken == token else { return }
            self.onFinished?()
        }
    }

    // MARK: - Helpers

    private static var deepgramKey: String? {
        KeyStore.shared.value(for: .deepgram)
    }

    fileprivate static var elevenLabsKey: String? {
        KeyStore.shared.value(for: .elevenLabs)
    }

    fileprivate static var openAIKey: String? {
        KeyStore.shared.value(for: .openAI)
    }
}
