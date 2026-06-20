//
//  VoiceLoopCoordinator.swift
//  Loop
//
//  Phase A surface of the macOS VoiceLoopCoordinator (LoopMac/
//  VoiceLoopCoordinator.swift). On iOS the recording, STT, LLM, and TTS
//  pipelines already live inside MessageBox + MessagingVC; this object is
//  the thin observable they publish into so that the AvatarView and
//  EarconPlayer can react to state without that logic being restructured.
//
//  Phase B (later) would migrate the actual orchestration here so iOS and
//  Mac share one coordinator. Don't do that yet — this file is intentionally
//  small.
//

import Foundation

extension Notification.Name {
    /// Multicast version of `onStateChange`. Posted on the main queue alongside
    /// the single-observer callback so multiple views (nav-bar avatar AND the
    /// large-mode AgentView) can react without clobbering each other.
    static let voiceLoopStateDidChange = Notification.Name("voiceLoopStateDidChange")
    /// Multicast version of `onAmplitude`. Same rationale.
    static let voiceLoopAmplitudeDidChange = Notification.Name("voiceLoopAmplitudeDidChange")
    /// Fired when the coordinator wants the avatar to bloom — a visual
    /// punctuation cue for "the user just sent something" or "the
    /// assistant just finished". MainVC subscribes and calls
    /// `avatar.pulse()` on both the nav-bar and hero instances.
    static let voiceLoopAcknowledgePulse = Notification.Name("voiceLoopAcknowledgePulse")
    /// Posted when the active STT engine changes so the badge label can update.
    static let voiceLoopSTTEngineDidChange = Notification.Name("voiceLoopSTTEngineDidChange")
}

#if !os(macOS)
final class VoiceLoopCoordinator {
    static let shared = VoiceLoopCoordinator()

    /// Mirrors the Mac coordinator's State enum. Same five cases so a future
    /// shared implementation (Phase B) doesn't need a rename.
    enum State { case idle, recording, transcribing, thinking, speaking }

    /// Which speech-to-text backend is driving the current (or most recent)
    /// transcription session. `nil` before the first recording.
    enum STTEngine {
        case deepgram, apple

        /// Label stamped onto a dictated message ("Deepgram STT" / "Apple STT")
        /// and shown as a byline under the user's bubble.
        var displayLabel: String {
            switch self {
            case .deepgram: return "Deepgram STT"
            case .apple: return "Apple STT"
            }
        }
    }

    private(set) var activeSTTEngine: STTEngine? {
        didSet {
            guard activeSTTEngine != oldValue else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .voiceLoopSTTEngineDidChange, object: nil)
            }
        }
    }

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onStateChange?(self.state)
                NotificationCenter.default.post(name: .voiceLoopStateDidChange, object: nil)
            }
        }
    }

    /// Last published amplitude, kept as a property so multicast observers can
    /// read it without needing to hook the per-tick callback. Updated on the
    /// main queue.
    private(set) var latestAmplitude: Float = 0

    /// Live state for any UI observer (avatar mode, earcon trigger, etc).
    var onStateChange: ((State) -> Void)?
    /// Live RMS amplitude callback in [0, 1]. Only meaningful while
    /// `state == .recording`; observers should ignore it otherwise.
    var onAmplitude: ((Float) -> Void)?
    /// Live RMS amplitude of TTS output. Meaningful while
    /// `state == .speaking`. Wired separately from `onAmplitude` (which
    /// is mic-driven) so observers don't have to multiplex.
    var onOutputAmplitude: ((Float) -> Void)?
    /// Live partial transcript while STT is listening.
    var onPartial: ((String) -> Void)?
    /// Fires when STT returns nothing usable (no speech, or whitespace-only
    /// transcript). Mirrors the Mac coordinator's hook for "drop into text-
    /// entry mode."
    var onEmptyTranscript: (() -> Void)?

    private init() {}

    // MARK: - Publish API

    /// Called by MessageBox / MessagingVC as their existing pipelines
    /// transition. Setting to the same value is a no-op so callers don't
    /// have to dedupe.
    func setState(_ newState: State) {
        state = newState
    }

    func setSTTEngine(_ engine: STTEngine) {
        activeSTTEngine = engine
    }

    func publishAmplitude(_ amplitude: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.latestAmplitude = amplitude
            self?.onAmplitude?(amplitude)
            NotificationCenter.default.post(name: .voiceLoopAmplitudeDidChange, object: nil)
        }
    }

    func publishPartial(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onPartial?(text)
        }
    }

    func publishEmptyTranscript() {
        DispatchQueue.main.async { [weak self] in
            self?.onEmptyTranscript?()
        }
    }

    /// Fire a one-shot avatar bloom. Posted as a notification so any
    /// instance of AvatarView listening (nav-bar avatar, hero avatar,
    /// AgentLargeView) can pulse independently.
    func publishAcknowledgePulse() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .voiceLoopAcknowledgePulse, object: nil)
        }
    }

    /// Drives the avatar's speaking-mode pulse off the actual TTS output
    /// RMS. Producers (MessagingVC's AVAudioPlayer metering, DeepgramTTS's
    /// engine tap) post here; MainVC's subscription routes the value to
    /// `avatar.amplitude` so the speaking-mode formula consumes it.
    func publishOutputAmplitude(_ amplitude: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.onOutputAmplitude?(amplitude)
        }
    }
}
#endif
