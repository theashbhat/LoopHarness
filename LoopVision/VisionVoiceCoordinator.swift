//
//  VisionVoiceCoordinator.swift
//  LoopVision
//
//  Owns one Vision Pro voice turn: pinch-hold → record → STT → AgentHarness
//  (via Cloud) → conversation store → spoken reply. This is the visionOS
//  counterpart of LoopMac/VoiceLoopCoordinator.swift; the shared pieces
//  (DeepgramSTT, AppleSTT, Cloud/AgentHarness, SimpleConversationManager,
//  KeyStore, MessageStruct) are the same LoopIOS/ sources LoopMac compiles.
//
//  The pinch gesture is wired to be the exact equivalent of holding
//  fn+control on the Mac (see LoopMac/HotKeyMonitor): `pinchBegan()` starts
//  capture, `pinchEnded()` stops it and sends the turn.
//
//  Concurrency intentionally mirrors the Mac coordinator: a plain class
//  (NOT an actor) whose state changes and callbacks are marshalled with
//  `DispatchQueue.main.async`. The AVAudioEngine input tap fires on the
//  audio render thread and touches `deepgramSTT` / `appleSTT` directly there,
//  exactly as the proven Mac path does — making this @MainActor would put
//  actor-isolated state on the render thread.
//
//  Audio mirrors the Mac/iOS AVAudioEngine tap rather than reinventing it;
//  visionOS (unlike macOS) does have AVAudioSession, so we activate a
//  play-and-record session the way the iOS MessageBox path does.
//

import Foundation
import AVFoundation
import Speech

final class VisionVoiceCoordinator {
    enum State { case idle, recording, transcribing, thinking, speaking }

    /// Pushed to the orb so it can mirror what Loop is doing. Always invoked
    /// on the main queue.
    var onStateChange: ((State) -> Void)?
    /// Live mic RMS in [0, 1] while `.recording`. Drives the orb's listening
    /// pulse — the orb ignores it in any other mode. Main queue.
    var onAmplitude: ((Float) -> Void)?
    /// Live partial transcript while STT is listening. Main queue.
    var onPartial: ((String) -> Void)?
    /// The user's final transcribed line for the turn, fired once STT
    /// resolves and just before it's sent to the model. Main queue.
    var onUserTranscript: ((String) -> Void)?
    /// The assistant's full reply as raw markdown, delivered *before* TTS
    /// starts so the UI can reveal it while (and before) it's spoken — the
    /// display half of the markdown/speech split. Main queue.
    var onAssistantText: ((String) -> Void)?
    /// A short human-readable label while a tool runs (e.g. "Running web
    /// search…"); empty string clears it. Main queue.
    var onActivity: ((String) -> Void)?

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onStateChange?(self.state)
                // Publish into the shared (iOS-shape) coordinator so the
                // cross-platform MusicController ducks/resumes playback during
                // a Vision voice turn, exactly as it does on iPhone. This is
                // the same `VoiceLoopCoordinator.shared` MusicController reads.
                VoiceLoopCoordinator.shared.setState(Self.published(self.state))
            }
        }
    }

    /// Our State and the shared coordinator's State have identical cases;
    /// kept as an explicit map so a future divergence is a compile error
    /// rather than a silent mismatch.
    private static func published(_ s: State) -> VoiceLoopCoordinator.State {
        switch s {
        case .idle:         return .idle
        case .recording:    return .recording
        case .transcribing: return .transcribing
        case .thinking:     return .thinking
        case .speaking:     return .speaking
        }
    }

    // MARK: - Audio + STT (mirrors LoopMac beginEngine / beginEngineApple)
    private var audioEngine: AVAudioEngine?
    private var deepgramSTT: DeepgramSTT?
    private var appleSTT: AppleSTT?
    private var streamingFinalizeTimer: Timer?
    private var recordingStartTime: Date?
    /// Shorter than this and we treat the pinch as "didn't really mean to
    /// record" and drop back to idle without hitting STT — same 1.0s guard
    /// the Mac coordinator uses for a too-quick fn+ctrl hold.
    private let minimumRecordingDuration: TimeInterval = 1.0

    // MARK: - Conversation
    private var conversation: SimpleConversation?
    private var messages: [MessageStruct] = []

    // MARK: - TTS
    /// Deepgram Aura streaming TTS — preferred when a Deepgram key is
    /// available (same engine the iPhone/Mac use). `AVSpeechSynthesizer` is
    /// the fallback when there's no key or the Aura socket fails mid-turn.
    private var deepgramTTS: DeepgramTTS?
    /// Strips markdown/URLs/code so the synthesizer never says "asterisk
    /// asterisk" — the same shared preprocessor iOS/Mac feed their TTS. The
    /// displayed text (via `onAssistantText`) keeps the raw markdown.
    private let speechSanitizer = SpeechSanitizer()
    private let synthesizer = AVSpeechSynthesizer()
    private let speechDelegate = SpeechDelegate()
    /// Identifies the active spoken reply so a late Aura callback (error /
    /// finished / amplitude) from a turn the user already interrupted can't
    /// bleed into the next one. Mirrors the Mac coordinator's turn token.
    private var speechToken: UUID?
    /// Whether the current Aura turn ever emitted a PCM chunk. Gates the
    /// system-voice fallback: `DeepgramTTS` reports its own normal-closure
    /// socket teardown to `onError` even after a *successful* playback, so
    /// falling back on any error double-speaks the whole reply. We only fall
    /// back when Aura produced no audio at all (a real auth/connection fail).
    private var auraProducedAudio = false

    init() {
        speechDelegate.owner = self
        synthesizer.delegate = speechDelegate
        loadConversation()
    }

    // MARK: - Pinch gesture entry points (the fn+control equivalent)

    /// Called on pinch-down. Idempotent: a held pinch fires the gesture's
    /// `onChanged` repeatedly, but only the first one (while idle/speaking)
    /// actually starts capture — exactly like `HotKeyMonitor.onHoldBegan`.
    func pinchBegan() {
        guard state == .idle || state == .speaking else { return }
        startRecording()
    }

    /// Called on pinch release — the `HotKeyMonitor.onHoldEnded` equivalent.
    /// Stops capture and (if the hold was long enough) sends the turn.
    func pinchEnded() {
        guard state == .recording else { return }
        finishRecording()
    }

    // MARK: - Recording lifecycle

    private func startRecording() {
        // Interrupt any in-progress reply, just like the Mac coordinator
        // stops `speechPlayer` when a new hold starts. Invalidate the speech
        // token first so the torn-down Aura client's onFinished can't flip
        // us back to idle mid-record.
        speechToken = nil
        deepgramTTS?.stop()
        deepgramTTS = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        let useApple = !Reachability.isOnline || Self.deepgramAPIKey == nil

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            beginCapture(useApple: useApple)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                guard granted else { return }
                DispatchQueue.main.async { self?.beginCapture(useApple: useApple) }
            }
        case .denied:
            print("⚠️ LoopVision: microphone denied. Approve in Settings → Privacy → Microphone.")
        @unknown default:
            break
        }
    }

    private func beginCapture(useApple: Bool) {
        if useApple {
            AppleSTT.requestAuthorization { [weak self] granted in
                // requestAuthorization already lands on the main queue.
                guard let self else { return }
                if granted { self.beginEngineApple() }
                else { print("⚠️ LoopVision: speech recognition not authorized.") }
            }
        } else if let key = Self.deepgramAPIKey {
            beginEngine(apiKey: key)
        }
    }

    /// Activates a play-and-record session, taps the input node, converts to
    /// 16 kHz mono PCM and streams it to Deepgram. Mirrors the Mac
    /// `beginEngine(apiKey:)` path one-to-one, plus the AVAudioSession setup
    /// that macOS doesn't need but visionOS (like iOS) does.
    private func beginEngine(apiKey: String) {
        guard configureSession() else { return }

        let engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 16000,
                                               channels: 1,
                                               interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            print("⚠️ LoopVision voice: audio format/converter setup failed")
            return
        }

        let stt = DeepgramSTT(apiKey: apiKey)
        self.deepgramSTT = stt
        self.audioEngine = engine

        stt.onPartial = { [weak self] text in
            DispatchQueue.main.async { self?.onPartial?(text) }
        }
        stt.onFinal = { [weak self] text in
            DispatchQueue.main.async { self?.completeWithTranscript(text) }
        }
        stt.onError = { [weak self] err in
            print("Deepgram error: \(err)")
            DispatchQueue.main.async { self?.cancelToIdle() }
        }
        stt.connect()

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.publishRMS(from: buffer)

            guard let stt = self.deepgramSTT else { return }
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard outCapacity > 0,
                  let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else { return }

            var providedInput = false
            var convError: NSError?
            let status = converter.convert(to: outBuffer, error: &convError) { _, statusOut in
                if providedInput { statusOut.pointee = .noDataNow; return nil }
                providedInput = true; statusOut.pointee = .haveData
                return buffer
            }
            if status == .error || outBuffer.frameLength == 0 { return }

            if let int16 = outBuffer.int16ChannelData?[0] {
                let byteCount = Int(outBuffer.frameLength) * MemoryLayout<Int16>.size
                stt.send(audio: Data(bytes: int16, count: byteCount))
            }
        }

        startEngine(engine)
    }

    /// Apple SFSpeechRecognizer fallback — no format conversion needed.
    /// Mirrors the Mac `beginEngineApple()` path.
    private func beginEngineApple() {
        guard configureSession() else { return }

        let engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            print("⚠️ LoopVision voice (Apple STT): audio format invalid")
            return
        }

        let stt = AppleSTT()
        self.appleSTT = stt
        self.audioEngine = engine

        stt.onPartial = { [weak self] text in
            DispatchQueue.main.async { self?.onPartial?(text) }
        }
        stt.onFinal = { [weak self] text in
            DispatchQueue.main.async { self?.completeWithTranscript(text) }
        }
        stt.onError = { [weak self] err in
            print("Apple STT error: \(err)")
            DispatchQueue.main.async { self?.cancelToIdle() }
        }
        guard stt.start() else { self.appleSTT = nil; return }

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.publishRMS(from: buffer)
            self.appleSTT?.append(buffer)
        }

        startEngine(engine)
    }

    private func startEngine(_ engine: AVAudioEngine) {
        do {
            engine.prepare()
            try engine.start()
            recordingStartTime = Date()
            state = .recording
        } catch {
            print("⚠️ LoopVision voice: engine.start() failed (\(error))")
            teardownStreaming()
        }
    }

    func finishRecording() {
        guard state == .recording else { return }

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartTime = nil

        if let engine = audioEngine, engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        // Too short to contain anything — skip STT, back to idle. Matches the
        // Mac coordinator's "press but don't speak" behaviour.
        if duration < minimumRecordingDuration {
            teardownStreaming()
            state = .idle
            DispatchQueue.main.async { [weak self] in self?.onPartial?("") }
            return
        }

        state = .transcribing
        deepgramSTT?.finalizeStream()
        appleSTT?.finalize()

        streamingFinalizeTimer?.invalidate()
        streamingFinalizeTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.cancelToIdle()
        }
    }

    private func cancelToIdle() {
        teardownStreaming()
        state = .idle
        DispatchQueue.main.async { [weak self] in self?.onPartial?("") }
    }

    private func teardownStreaming() {
        streamingFinalizeTimer?.invalidate(); streamingFinalizeTimer = nil
        if let engine = audioEngine, engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        deepgramSTT?.disconnect(); deepgramSTT = nil
        appleSTT?.cancel(); appleSTT = nil
        deactivateAudioSession()
    }

    // MARK: - Transcript → Cloud → store → speak

    private func completeWithTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        teardownStreaming()
        guard !trimmed.isEmpty else {
            state = .idle
            DispatchQueue.main.async { [weak self] in self?.onPartial?("") }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.onPartial?("")
            self?.onUserTranscript?(trimmed)
        }
        sendUserText(trimmed)
    }

    private func sendUserText(_ text: String) {
        guard let conversation else { return }

        // Cancel any in-flight TTS — the user just sent a new message, so
        // the previous response should stop playing immediately.
        if state == .speaking {
            speechToken = nil
            deepgramTTS?.stop(); deepgramTTS = nil
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
            state = .idle
        }

        let userMessage = MessageStruct(role: "user", content: text)
        SimpleConversationManager.shared.addMessage(userMessage, to: conversation)
        if let refreshed = SimpleConversationManager.shared.currentConversation {
            self.conversation = refreshed
        }
        messages.append(userMessage)

        state = .thinking
        Cloud.connection.chat(messages: messages) { [weak self] response, error in
            DispatchQueue.main.async { self?.handleChatResponse(response, error: error) }
        }
    }

    private func handleChatResponse(_ response: MessageStruct?, error: Error?) {
        guard let response else {
            if let error { print("LoopVision chat error: \(error)") }
            let msg = MessageStruct(role: "assistant",
                                    content: "Sorry — I'm having trouble connecting. Please try again.")
            persistAssistant(msg)
            onActivity?("")
            onAssistantText?(msg.content)
            speak(msg.content)
            return
        }
        processAssistant(response)
    }

    private func processAssistant(_ message: MessageStruct) {
        // Tool result coming back from a skill — feed it to the harness and
        // let the model continue, exactly like LoopMac/VoiceLoopCoordinator.
        if message.role == "function" {
            messages.append(message)
            state = .thinking
            Cloud.connection.chat(messages: messages) { [weak self] response, error in
                DispatchQueue.main.async { self?.handleChatResponse(response, error: error) }
            }
            return
        }

        // Model-issued tool call: route through the shared, platform-neutral
        // SkillDispatcher (the same router BackgroundScheduler uses). Any tool
        // that only exists on Mac (MacApp/Terminal — runtime-registered there,
        // absent from `LoopIOS/`) yields a structured "unknown tool" the model
        // recovers from. The result loops back via the `role == "function"`
        // branch above.
        if let function = message.function {
            messages.append(message)
            onActivity?(Self.activityLabel(for: function))
            SkillDispatcher.shared.dispatch(function) { [weak self] result in
                DispatchQueue.main.async { self?.processAssistant(result) }
            }
            return
        }

        if !message.content.isEmpty {
            persistAssistant(message)
            // Surface the reply (raw markdown) before any audio so the caption
            // reveals it as it's "generated" and clearly before it's spoken.
            onActivity?("")
            onAssistantText?(message.content)
            speak(message.content)
        } else {
            onActivity?("")
            state = .idle
        }
    }

    /// A terse spoken-style label for the tool the model just invoked, e.g.
    /// `web_search` → "Running web search…". Devin and Cursor dispatches —
    /// the high-signal cases the user is likeliest to be watching for — get
    /// the same skill-authored label iPhone shows ("dispatching Devin on
    /// owner/repo"). Other tools fall through to the generic pretty-print.
    private static func activityLabel(for call: FunctionCallStruct) -> String {
        if let s = DevinSkill.shared.statusText(for: call) { return s }
        if let s = CursorSkill.shared.statusText(for: call) { return s }
        let pretty = call.name
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return "Running \(pretty.isEmpty ? "tool" : pretty)…"
    }

    private func persistAssistant(_ message: MessageStruct) {
        guard let conversation else { return }
        SimpleConversationManager.shared.addMessage(message, to: conversation)
        if let refreshed = SimpleConversationManager.shared.currentConversation {
            self.conversation = refreshed
        }
        messages.append(message)
    }

    // MARK: - TTS

    /// Speak the reply with Deepgram Aura when a Deepgram key is available
    /// (the same streaming voice the iPhone/Mac use); fall back to the system
    /// `AVSpeechSynthesizer` when there's no key or Aura fails. Aura's
    /// per-buffer RMS is forwarded as `onAmplitude` so the orb's speaking
    /// pulse tracks the actual synthesized speech instead of a canned wobble.
    private func speak(_ text: String) {
        // Speech gets the sanitized text; the UI already received the raw
        // markdown via `onAssistantText`. If nothing remains to say (e.g. the
        // reply was only a link), don't hang in `.speaking`.
        let spoken = speechSanitizer.sanitize(text)
        guard !spoken.isEmpty else {
            speechToken = nil
            state = .idle
            return
        }

        state = .speaking
        let token = UUID()
        speechToken = token
        auraProducedAudio = false

        guard let key = Self.deepgramAPIKey else {
            speakWithSystemVoice(spoken)
            return
        }

        let tts = DeepgramTTS(apiKey: key)
        deepgramTTS = tts

        tts.onFirstAudio = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.speechToken == token else { return }
                // Aura is actually producing speech for this turn — from here
                // on, any error is post-playback teardown noise, not a reason
                // to re-speak through the system voice.
                self.auraProducedAudio = true
            }
        }
        tts.onOutputAmplitude = { [weak self] amp in
            DispatchQueue.main.async {
                guard let self, self.speechToken == token else { return }
                self.onAmplitude?(amp)
            }
        }
        tts.onError = { [weak self] err in
            DispatchQueue.main.async {
                guard let self, self.speechToken == token else { return }
                self.deepgramTTS = nil
                if self.auraProducedAudio {
                    // Aura already spoke (this is its normal socket close, or
                    // a late failure mid-stream). Do NOT fall back — that
                    // would replay the whole reply on top of what was heard.
                    self.speechToken = nil
                    if self.state == .speaking {
                        self.state = .idle
                        self.deactivateAudioSession()
                    }
                } else {
                    // True failure before any audio (bad key, blocked
                    // network, Aura down) — the system voice is the safety net.
                    print("DeepgramTTS failed before any audio: \(err) — using system voice")
                    self.speakWithSystemVoice(spoken)
                }
            }
        }
        tts.onFinished = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.speechToken == token else { return }
                // Success path only. If onError already handled this turn it
                // cleared `deepgramTTS`, so this no-ops.
                guard self.deepgramTTS === tts else { return }
                self.deepgramTTS = nil
                self.speechToken = nil
                if self.state == .speaking {
                    self.state = .idle
                    self.deactivateAudioSession()
                }
            }
        }

        guard tts.start() else {
            deepgramTTS = nil
            speakWithSystemVoice(spoken)
            return
        }
        tts.speak(text: spoken)
    }

    /// Always receives text already run through `speechSanitizer` by `speak`.
    private func speakWithSystemVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    fileprivate func speechDidFinish() {
        if state == .speaking {
            state = .idle
            deactivateAudioSession()
        }
    }

    /// Deactivate the audio session with `.notifyOthersOnDeactivation` so
    /// system media (Apple Music, Spotify, podcasts) auto-resumes after
    /// Loop's voice activity ends. visionOS has AVAudioSession (unlike macOS).
    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // best-effort; session may already be inactive
        }
    }

    // MARK: - Conversation selection (drives the split-view window)

    /// The conversation voice turns are currently appended to.
    var currentConversationID: String? { conversation?.id }

    /// Switch the active conversation (from the split-view sidebar). Any
    /// in-flight reply is interrupted first so audio from the old context
    /// can't bleed into the newly selected one.
    func useConversation(_ conv: SimpleConversation) {
        guard conv.id != conversation?.id else { return }
        speechToken = nil
        deepgramTTS?.stop(); deepgramTTS = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        let manager = SimpleConversationManager.shared
        manager.currentConversation = conv
        self.conversation = conv
        rebuildMessagesFromStore()
        if state != .idle { state = .idle }
    }

    // MARK: - Conversation bootstrap (mirrors Mac loadConversation)

    private func loadConversation() {
        let manager = SimpleConversationManager.shared
        let conv = manager.loadLastConversation()
            ?? manager.createConversation(title: "Vision Chat \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))")
        self.conversation = conv
        manager.currentConversation = conv
        rebuildMessagesFromStore()
    }

    private func rebuildMessagesFromStore() {
        guard let conv = conversation else { return }
        let manager = SimpleConversationManager.shared
        var msgs: [MessageStruct] = [systemMessage()]
        for entry in manager.getMessages(for: conv) {
            msgs.append(manager.messageStruct(from: entry))
        }
        self.messages = msgs
    }

    private func systemMessage() -> MessageStruct {
        let f = DateFormatter()
        f.dateStyle = .long; f.timeStyle = .medium
        let prompt = """
        You are an AI called Loop designed to be a living memory.

        The user is on Apple Vision Pro, talking to you with pinch-to-talk \
        (look at the Loop orb, pinch and hold to speak, release to send). The \
        orb floats in their real space alongside their other apps. They will \
        follow up via the Loop iPhone and Mac apps and the conversation \
        continues across devices.

        Please keep your responses limited to 30 words and use markdown and \
        emojis as needed. Leverage bolding as you can.

        The current date and time is \(f.string(from: Date())).
        """
        return MessageStruct(role: "system", content: prompt)
    }

    // MARK: - Helpers

    /// visionOS has AVAudioSession but supports a much narrower set of
    /// categories/modes/options than iPhone. The iOS capture recipe
    /// (`.measurement` mode + `.allowBluetooth`) makes Vision Pro's proxy
    /// session creation fail with OSStatus -50 ("Session lookup failed"),
    /// killing mic capture. Try visionOS-appropriate combos in order:
    ///   - `.voiceChat` applies acoustic echo cancellation, so the orb's
    ///     TTS playback isn't fed back into the mic during a turn.
    ///   - then progressively plainer fallbacks.
    /// Tolerate total failure: visionOS can also drive AVAudioEngine off the
    /// system-managed default session, so we still let the engine try.
    private func configureSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        let attempts: [(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)] = [
            (.playAndRecord, .voiceChat, [.duckOthers]),
            (.playAndRecord, .default,   [.duckOthers]),
            (.playAndRecord, .default,   []),
            (.record,        .default,   []),
        ]
        for (category, mode, options) in attempts {
            do {
                try session.setCategory(category, mode: mode, options: options)
                try session.setActive(true)
                return true
            } catch {
                continue
            }
        }
        print("⚠️ LoopVision voice: no AVAudioSession config accepted; relying on the system-managed default session")
        return true
    }

    private func publishRMS(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        var sumSq: Float = 0
        for i in 0..<n { let v = channel[i]; sumSq += v * v }
        let rms = sqrt(sumSq / Float(n))
        let boosted = min(Float(1.0), max(Float(0.0), rms * 10))
        DispatchQueue.main.async { [weak self] in self?.onAmplitude?(boosted) }
    }

    private static var deepgramAPIKey: String? {
        KeyStore.shared.value(for: .deepgram)
    }

    /// AVSpeechSynthesizerDelegate has to be an NSObject; keeping it as a
    /// tiny forwarder avoids making the whole coordinator an NSObject.
    private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
        weak var owner: VisionVoiceCoordinator?
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            owner?.speechDidFinish()
        }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            owner?.speechDidFinish()
        }
    }
}
