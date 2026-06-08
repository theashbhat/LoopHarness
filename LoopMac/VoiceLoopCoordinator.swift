//
//  VoiceLoopCoordinator.swift
//  LoopMac
//
//  Owns one Mac voice turn: hold-to-record → STT → AgentHarness → CoreData
//  → TTS playback. Talks to the recorder window for live capture state and
//  to the conversation window for transcript rendering.
//
//  This is the macOS counterpart of MessageBox + MessagingVC's chat path on
//  iOS. The bits the two share — DeepgramSTT, AgentHarness, ConversationStore
//  — live in LoopIOS/ and are compiled into both targets.
//

import AppKit
import AVFoundation

extension Notification.Name {
    /// Mac-side mirror of the iOS notification (see
    /// LoopIOS/SpeechPipeline/VoiceLoopCoordinator.swift). Posted on the main
    /// queue alongside `onStateChange` so cross-platform observers like
    /// MusicController can listen with one subscription.
    static let voiceLoopStateDidChange = Notification.Name("voiceLoopStateDidChange")

    /// Posted whenever the user submits a turn — typed text via the recorder
    /// or a finished voice transcript — *regardless* of where it ends up
    /// (LLM, onboarding script, scrubbed empty, etc). Anything tracking "has
    /// the user said something yet?" should listen here instead of watching
    /// for `.thinking` on `voiceLoopStateDidChange`, because the conversational
    /// onboarding consumes text inline and never transitions through
    /// `.thinking`.
    static let voiceLoopUserMessageSubmitted = Notification.Name("voiceLoopUserMessageSubmitted")
}

protocol ConversationPresenter: AnyObject {
    func showAndReload()
    func appendUserMessage(_ text: String)
    /// Append a user-uploaded image/PDF as an inline bubble, optionally
    /// followed by accompanying text underneath. Mirrors `appendUserMessage`'s
    /// fast-path that adds a row without reloading the whole conversation.
    func appendUserAttachment(_ attachment: FileAttachment, text: String?)
    func appendAssistantMessage(_ text: String, model: String?)
    func setThinking(_ thinking: Bool, label: String?)
    /// Forward state transitions so the conversation window's avatar can
    /// reflect what Loop is doing. The presenter handles the mapping
    /// between `VoiceLoopCoordinator.State` and the avatar's own mode.
    func avatarStateChanged(_ state: VoiceLoopCoordinator.State)
    /// Real-time mic RMS (0…1) — used to drive the avatar's "listening"
    /// animation. Only meaningful in `.recording`; the avatar ignores it in
    /// any other mode.
    func avatarAmplitudeChanged(_ amplitude: Float)
    /// Fire a one-shot bloom on the avatar — visual punctuation when a
    /// user turn or assistant turn lands. No-op if the presenter has no
    /// visible avatar at the moment.
    func avatarPulse()
}

final class VoiceLoopCoordinator {
    /// Weak handle to whatever VoiceLoopCoordinator the app currently owns.
    /// The Mac coordinator is per-app (not a singleton like iOS's
    /// `.shared`), but cross-platform observers — MusicController in
    /// particular — need a stable lookup. Assigned in init.
    static weak var current: VoiceLoopCoordinator?

    weak var conversationPresenter: ConversationPresenter?

    /// Whether this coordinator currently owns the foreground tab. Background
    /// coordinators keep running their in-flight turn (so chat completions
    /// land in the right conversation even when the user has switched away),
    /// but they don't get to drive system-wide resources — TTS playback and
    /// the escape-to-cancel monitor are gated on this flag. Flipped by the
    /// conversation window's tab manager as the user moves between tabs.
    var isActive: Bool = true {
        didSet {
            // If we just lost focus while speaking, stop the TTS so the audio
            // doesn't keep playing under the new active tab.
            if !isActive, state == .speaking {
                speechPlayer.stop()
                state = .idle
            }
        }
    }

    /// Live state for the recorder bar.
    var onStateChange: ((State) -> Void)?
    /// Live RMS amplitude callback for the waveform animation, [0,1] range.
    var onAmplitude: ((Float) -> Void)?
    /// Live partial transcript while Deepgram is listening.
    var onPartial: ((String) -> Void)?
    /// Fires when STT returns nothing usable (no speech, or whitespace-only
    /// transcript). The recorder uses this to drop into text-entry mode so
    /// the user can type their message instead of re-recording.
    var onEmptyTranscript: (() -> Void)?

    enum State { case idle, recording, transcribing, thinking, speaking }

    /// Which speech-to-text backend is driving the current (or most recent)
    /// transcription session. `nil` before the first recording.
    enum STTEngine { case deepgram, apple }
    private(set) var activeSTTEngine: STTEngine?

    private(set) var state: State = .idle {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onStateChange?(self.state)
                self.conversationPresenter?.avatarStateChanged(self.state)
                NotificationCenter.default.post(name: .voiceLoopStateDidChange, object: nil)
            }
        }
    }

    // MARK: - Audio engine + Deepgram (mirrors MessageBox.beginStreamingRecording)
    private var audioEngine: AVAudioEngine?
    private var deepgramSTT: DeepgramSTT?
    private var appleSTT: AppleSTT?
    private var streamingFinalizeTimer: Timer?
    /// When the most recent recording started. Used to decide whether the
    /// hold was long enough to contain useful speech — see
    /// `minimumRecordingDuration`.
    private var recordingStartTime: Date?
    /// Anything shorter than this gets treated as "user didn't really mean
    /// to record" and routes into text-entry mode instead of being sent to
    /// STT. 1.0s catches the case where the user holds fn+ctrl past the
    /// tap threshold but releases before saying anything meaningful.
    private let minimumRecordingDuration: TimeInterval = 1.0

    // MARK: - Conversation
    private var conversation: SimpleConversation?
    private var messages: [MessageStruct] = []

    // MARK: - TTS
    private let speechPlayer = MacSpeechPlayer()

    // MARK: - Cancellation
    /// Identifies the currently-active turn. Every chat callback (and every
    /// tool dispatch completion) captures the token at the moment the call
    /// was kicked off and bails if it no longer matches — i.e. the user hit
    /// escape and we should drop whatever comes back. `nil` means no live
    /// turn (e.g. after a cancel).
    private var currentTurnToken: UUID?
    /// Id of the user message that started the current turn. We hold onto it
    /// so cancellation can scrub it from the store + presenter; without this
    /// the user's "previous message wasn't sent" expectation would be wrong
    /// because the message is persisted before we even kick off chat.
    private var currentTurnUserMessageId: String?
    /// Local key-event monitor that listens for escape while Loop is the
    /// active app. We install it once at init and leave it running — the
    /// `state == .thinking` check inside is the actual gate.
    private var escapeMonitor: Any?

    init() {
        VoiceLoopCoordinator.current = self
        speechPlayer.onFinished = { [weak self] in
            guard let self = self else { return }
            if self.state == .speaking { self.state = .idle }
        }
        // TTS output amplitude → avatar speaking-mode pulse. Guarded to
        // `.speaking` so a delayed callback after a tap-cancel can't bleed
        // into the next .listening turn and fake mic motion.
        speechPlayer.onOutputAmplitude = { [weak self] amp in
            guard let self = self, self.state == .speaking else { return }
            self.conversationPresenter?.avatarAmplitudeChanged(amp)
            self.onAmplitude?(amp)
        }
        loadConversation()
        installEscapeMonitor()

        // A sub-agent posts its summary into the parent conversation while
        // we may be idle; we need to refresh our local `messages` snapshot
        // so the next chat turn includes the sub-agent's output as context.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(subAgentDidPostMessage(_:)),
            name: .subAgentDidPostMessage,
            object: nil
        )
    }

    deinit {
        if let m = escapeMonitor { NSEvent.removeMonitor(m) }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func subAgentDidPostMessage(_ note: Notification) {
        let postedId = note.userInfo?["conversationId"] as? String
        guard let postedId = postedId else { return }
        // Only refresh if the message landed in the conversation we're
        // currently driving. Other conversations get picked up the next
        // time the user switches to them.
        guard let conv = conversation, conv.id == postedId else {
            // The Mac coordinator may have no `currentConversation` set on
            // the manager even though we're actively in one; treat any
            // matching-id post as ours if we haven't loaded yet.
            if conversation == nil {
                DispatchQueue.main.async { [weak self] in
                    self?.loadConversation()
                }
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let refreshed = SimpleConversationManager.shared.getConversation(by: postedId) {
                self.conversation = refreshed
            }
            self.rebuildMessagesFromStore()
            // Read the sub-agent's response aloud on the foreground tab.
            // `speak(_:)` internally guards on `isActive` so background tabs
            // stay silent, and `speechPlayer.speak(_:)` calls `stop()` first,
            // so any in-flight TTS gets interrupted before this one starts.
            let summary = (note.userInfo?["summary"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !summary.isEmpty {
                self.speak(summary)
            }
        }
    }

    private func loadConversation() {
        let manager = SimpleConversationManager.shared
        // `loadLastConversation` reads from the file store's in-memory cache,
        // which is populated by a cheap meta-only sync pass at app launch.
        // If iCloud hasn't yet delivered the user's history on this device
        // (or the device truly has no conversations), the cache may be empty
        // at this moment — we drop into the create-fresh-chat fallback so the
        // user can start typing immediately. Older conversations from iCloud
        // will stream into the sidebar as pass 2 hydration completes; the
        // sidebar's "Syncing…" indicator covers the gap.
        let conv = manager.loadLastConversation() ?? manager.createConversation(title: "Mac Chat \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))")
        self.conversation = conv
        // NOTE: don't push into `manager.currentConversation` here. With
        // multiple tabs, that field is owned by the conversation window's tab
        // manager — it has to track the *foreground* tab, not whichever
        // coordinator most recently init'd. Background coordinators that
        // grab the global pointer would otherwise steal image-gen callbacks
        // and similar "what tab is the user on?" lookups.
        rebuildMessagesFromStore()
    }

    private func rebuildMessagesFromStore() {
        guard let conv = conversation else { return }
        let entries = SimpleConversationManager.shared.getMessages(for: conv)
        let manager = SimpleConversationManager.shared
        var msgs: [MessageStruct] = [systemMessage()]
        for entry in entries {
            msgs.append(manager.messageStruct(from: entry))
        }
        self.messages = msgs
    }

    private func systemMessage() -> MessageStruct {
        // Persona + format constraints only. We deliberately do NOT hand-list
        // skills here — AgentHarness's composed prompt appends every bundled
        // skill's `systemPromptFragment` via `toolsDoc`, and the tool schemas
        // sent with each chat are the authoritative source of truth. Listing
        // a subset here used to mislead the model into thinking the omitted
        // skills (GitHub, Slack, Calendar, …) were unavailable on Mac.
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .medium
        let now = dateFormatter.string(from: Date())
        let prompt = """
You are an AI called Loop designed to be a living memory.

The user is on macOS, talking to you with hold-to-talk via control+fn from anywhere on their system. The same conversation continues seamlessly on the Loop iPhone app — every tool you have here is also available there, and vice versa.

Please keep your responses limited to 30 words and use markdown and emojis as needed to convey your ideas. Leverage bolding as you can.

The current date and time is \(now).
"""
        return MessageStruct(role: "system", content: prompt)
    }

    // MARK: - Recording lifecycle (called by HotKeyMonitor)

    func startRecording() {
        guard state == .idle || state == .speaking else { return }
        // Stop any in-progress speech playback.
        speechPlayer.stop()

        // Pick STT path. `STTProviderStore.current` is `.auto` by default and
        // reproduces the historical heuristic — Deepgram online (lower
        // latency, better partials) and Apple SFSpeechRecognizer when offline
        // or the Deepgram key is missing. The user can pin either engine in
        // Settings ▸ Model ▸ STT on iOS; the same store syncs over iCloud-KVS
        // so the Mac respects the override here.
        let useApple: Bool
        switch STTProviderStore.current {
        case .apple:    useApple = true
        case .deepgram: useApple = (Self.deepgramAPIKey == nil)
        case .auto:     useApple = !Reachability.isOnline || Self.deepgramAPIKey == nil
        }

        // Mac mic permission. We use AVCaptureDevice (not
        // AVAudioApplication.recordPermission) because the latter has a
        // long-standing macOS bug where it returns `.undetermined` even
        // after the user has hit Allow — the value the system actually
        // stores in TCC is the one AVCaptureDevice reports. Using
        // AVCaptureDevice keeps our check in lock-step with TCC's view of
        // the world, so a re-launch doesn't re-prompt.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            startRecordingWithPermission(useApple: useApple)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard granted, let self = self else { return }
                DispatchQueue.main.async { self.startRecordingWithPermission(useApple: useApple) }
            }
        case .denied, .restricted:
            print("⚠️ Microphone permission denied. Approve in System Settings → Privacy & Security → Microphone.")
        @unknown default:
            break
        }
    }

    /// Branches on whether we're using the on-device Apple recognizer or
    /// Deepgram for this turn. Apple needs a separate authorization prompt
    /// (NSSpeechRecognitionUsageDescription) which we request on demand —
    /// after the first grant, subsequent calls return immediately.
    private func startRecordingWithPermission(useApple: Bool) {
        if useApple {
            AppleSTT.requestAuthorization { [weak self] granted in
                guard let self = self else { return }
                if granted {
                    self.activeSTTEngine = .apple
                    self.beginEngineApple()
                } else {
                    print("⚠️ Speech recognition permission denied. Approve in System Settings → Privacy & Security → Speech Recognition.")
                }
            }
        } else if let key = Self.deepgramAPIKey {
            activeSTTEngine = .deepgram
            beginEngine(apiKey: key)
        }
    }

    private func beginEngine(apiKey: String) {
        let engine = AVAudioEngine()
        // Apply the user's chosen input device (if any) BEFORE we read the
        // input format — otherwise we'd pick up the system-default format
        // and the engine would still record from the default mic.
        MicrophoneManager.shared.applySelectedInput(to: engine)
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 16000,
                                               channels: 1,
                                               interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            print("⚠️ Mac voice: audio format/converter setup failed")
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
            guard let self = self else { return }
            // Live RMS for the recorder waveform.
            if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                let n = Int(buffer.frameLength)
                var sumSq: Float = 0
                for i in 0..<n {
                    let v = channel[i]; sumSq += v * v
                }
                let rms = sqrt(sumSq / Float(n))
                let boosted = min(Float(1.0), max(Float(0.0), rms * 10))
                DispatchQueue.main.async {
                    self.onAmplitude?(boosted)
                    self.conversationPresenter?.avatarAmplitudeChanged(boosted)
                }
            }

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
                let data = Data(bytes: int16, count: byteCount)
                stt.send(audio: data)
            }
        }

        do {
            engine.prepare()
            try engine.start()
            recordingStartTime = Date()
            EarconPlayer.shared.play(.listenStart)
            state = .recording
        } catch {
            print("⚠️ Mac voice: engine.start() failed (\(error))")
            EarconPlayer.shared.play(.error)
            teardownStreaming()
        }
    }

    /// Apple SFSpeechRecognizer path. No format conversion required —
    /// SFSpeech ingests the engine's native input format directly. Pipes
    /// partials/finals through the same coordinator callbacks Deepgram uses,
    /// so the rest of the pipeline doesn't need to know which engine ran.
    private func beginEngineApple() {
        let engine = AVAudioEngine()
        MicrophoneManager.shared.applySelectedInput(to: engine)
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            print("⚠️ Mac voice (Apple STT): audio format invalid")
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
        guard stt.start() else {
            // start() already fired onError; just bail.
            self.appleSTT = nil
            return
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                let n = Int(buffer.frameLength)
                var sumSq: Float = 0
                for i in 0..<n {
                    let v = channel[i]; sumSq += v * v
            }
                let rms = sqrt(sumSq / Float(n))
                let boosted = min(Float(1.0), max(Float(0.0), rms * 10))
                DispatchQueue.main.async {
                    self.onAmplitude?(boosted)
                    self.conversationPresenter?.avatarAmplitudeChanged(boosted)
                }
            }
            self.appleSTT?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            recordingStartTime = Date()
            EarconPlayer.shared.play(.listenStart)
            state = .recording
        } catch {
            print("⚠️ Mac voice (Apple STT): engine.start() failed (\(error))")
            EarconPlayer.shared.play(.error)
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

        // Too short to contain anything useful — skip STT entirely and drop
        // into text-entry mode. Avoids sending a 200ms clip to Deepgram only
        // to get an empty transcript back a second later, and matches the
        // user's expectation that "press but don't speak" surfaces text mode.
        if duration < minimumRecordingDuration {
            teardownStreaming()
            state = .idle
            onPartial?("")
            onEmptyTranscript?()
            return
        }

        state = .transcribing
        deepgramSTT?.finalizeStream()
        appleSTT?.finalize()

        streamingFinalizeTimer?.invalidate()
        streamingFinalizeTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.cancelToIdle() }
        }
    }

    private func cancelToIdle() {
        teardownStreaming()
        state = .idle
        onPartial?("")
    }

    private func teardownStreaming() {
        streamingFinalizeTimer?.invalidate(); streamingFinalizeTimer = nil
        if let engine = audioEngine {
            if engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        audioEngine = nil
        deepgramSTT?.disconnect()
        deepgramSTT = nil
        appleSTT?.cancel()
        appleSTT = nil
    }

    // MARK: - Transcript → AgentHarness → store → TTS

    private func completeWithTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        teardownStreaming()
        guard !trimmed.isEmpty else {
            // Empty transcript: don't send anything to the model. Drop back
            // to idle and ask the recorder to focus its text field so the
            // user can type what they meant to say.
            state = .idle
            onPartial?("")
            onEmptyTranscript?()
            return
        }
        sendUserText(trimmed)
    }

    func sendUserText(_ text: String) {
        // Announce the submission before anything else gets to consume the
        // text. The windowed Mac onboarding ("Send your first message")
        // listens to this so it can dismiss whether the message ends up at
        // the LLM, the conversational onboarding script, or scrubbed empty.
        NotificationCenter.default.post(name: .voiceLoopUserMessageSubmitted, object: nil)

        // Mid-onboarding text goes to the shared coordinator first. If it
        // consumes the input (echoes a bubble, advances the script), we
        // short-circuit before the regular LLM-bound `sendTurn`. The Mac
        // host already routes scripted prompts + chips through the chat;
        // this is the typed-text counterpart.
        //
        // Important: this path is also reached from `completeWithTranscript`
        // (voice STT finishes → sendUserText). At that point `state` is
        // `.transcribing` and the recorder UI sits on "Transcribing…" until
        // the next state change. Returning early without resetting state
        // would leave the recorder stuck. The onboarding consumed the
        // message — the turn is over from our perspective, so drop to .idle
        // and clear any partial transcript before bailing.
        if OnboardingCoordinator.shared.handleUserText(text) {
            state = .idle
            onPartial?("")
            return
        }
        sendTurn(userMessage: MessageStruct(role: "user", content: text))
    }

    /// Send a turn that includes a user-uploaded file (image or PDF). Mirrors
    /// `sendUserText` but stamps the message with the attachment so the
    /// conversation cell can render it inline. The model sees the file via
    /// the `[Attached file: …]` tag appended to `content` by `MessageStruct.dict`.
    func sendUserAttachment(_ attachment: FileAttachment, text: String?) {
        // Same "user just submitted" signal as the text path — keeps the
        // windowed onboarding's dismiss trigger uniform across drag-and-drop
        // attachments and typed messages.
        NotificationCenter.default.post(name: .voiceLoopUserMessageSubmitted, object: nil)
        var userMessage = MessageStruct(role: "user", content: text ?? "")
        userMessage.fileAttachment = attachment
        sendTurn(userMessage: userMessage)
    }

    /// Shared core of `sendUserText` / `sendUserAttachment`: persist, render,
    /// kick the LLM call. Kept here so both entrypoints stay in lock-step
    /// — when one grows a feature (e.g. cancellation token, RAG retrieval,
    /// telemetry), the other inherits it.
    private func sendTurn(userMessage: MessageStruct) {
        guard let conversation = conversation else { return }

        // Cancel any in-flight TTS immediately. The user just sent a new
        // message, so continuing to read the previous response aloud is
        // stale and disorienting — silence it before the earcon so the
        // "sent" chime isn't fighting the tail of the old speech.
        if state == .speaking {
            speechPlayer.stop()
            state = .idle
        }

        EarconPlayer.shared.play(.listenSend)
        SimpleConversationManager.shared.addMessage(userMessage, to: conversation)
        // Refresh our snapshot from the store by *this* coordinator's id,
        // not from `manager.currentConversation` — with multiple tabs alive,
        // `currentConversation` tracks the foreground tab, not us. Reading
        // it blindly used to clobber background coordinators' conversation
        // pointer with the foreground's, breaking their next send.
        if let conv = self.conversation,
           let refreshed = SimpleConversationManager.shared.getConversation(by: conv.id) {
            self.conversation = refreshed
        }
        messages.append(userMessage)

        // Stamp this turn with a fresh token. Every downstream callback
        // captures it and bails if it has since changed (escape → cancel).
        let token = UUID()
        currentTurnToken = token
        currentTurnUserMessageId = userMessage.id

        if let attachment = userMessage.fileAttachment {
            conversationPresenter?.appendUserAttachment(attachment, text: userMessage.content.isEmpty ? nil : userMessage.content)
        } else {
            conversationPresenter?.appendUserMessage(userMessage.content)
        }
        conversationPresenter?.showAndReload()
        conversationPresenter?.avatarPulse()
        conversationPresenter?.setThinking(true, label: "Thinking…")

        // Opportunistic context compaction: check thresholds and spawn a
        // background sub-agent if the context is large enough.
        let compactionTrigger = ContextCompactor.checkAndTrigger(
            messages: messages,
            conversationId: conversation.id
        )

        state = .thinking
        Cloud.connection.chat(messages: messages) { [weak self] response, error in
            DispatchQueue.main.async {
                if compactionTrigger == .hard, var r = response {
                    r.content += "\n\n(compacting context in the background)"
                    self?.handleChatResponse(r, error: error, token: token)
                } else {
                    self?.handleChatResponse(response, error: error, token: token)
                }
            }
        }
    }

    private func handleChatResponse(_ response: MessageStruct?, error: Error?, token: UUID) {
        guard currentTurnToken == token else { return }
        guard let response = response else {
            EarconPlayer.shared.play(.error)
            if let error = error {
                print("Mac chat error: \(error)")
            }
            // Surface the error's own localizedDescription when it carries
            // something specific (e.g. "Apple Intelligence is turned off…")
            // so the user knows what to actually fix; fall back to the
            // generic message only when we have no detail.
            let body: String
            if let detail = error?.localizedDescription,
               !detail.isEmpty,
               !detail.lowercased().hasPrefix("the operation couldn") {
                body = detail
            } else {
                body = "Sorry — I'm having trouble connecting. Please try again."
            }
            // Stamp the model that was *attempted* so the bubble matches
            // the user's menu pick rather than defaulting to "GPT 5.5
            // Instant" from MessageStruct's struct default.
            var msg = MessageStruct(role: "assistant", content: body)
            msg.model = ModelSelectionStore.current.stampedMessageModel
            persistAssistant(msg)
            conversationPresenter?.setThinking(false, label: nil)
            conversationPresenter?.appendAssistantMessage(msg.content, model: msg.model)
            currentTurnToken = nil
            currentTurnUserMessageId = nil
            state = .idle
            return
        }
        processAssistant(response, token: token)
    }

    /// Mirrors a slice of MessagingVC.processMessage — handles function calls
    /// by routing to the same Skills singletons used on iOS, then loops back.
    private func processAssistant(_ message: MessageStruct, token: UUID) {
        guard currentTurnToken == token else { return }

        if message.role == "function" {
            // Tool result coming back from a skill — send to harness.
            messages.append(message)
            state = .thinking
            conversationPresenter?.setThinking(true, label: "Thinking…")
            Cloud.connection.chat(messages: messages) { [weak self] response, error in
                DispatchQueue.main.async { self?.handleChatResponse(response, error: error, token: token) }
            }
            return
        }

        if !message.functions.isEmpty {
            // Assistant turn carried one or more tool_use blocks. Persist it
            // once (so the model sees its own call list on the next round-
            // trip), flip the shimmer to the first call's status, then fan
            // out every call concurrently and re-enter chat with all results.
            messages.append(message)
            if let first = message.functions.first {
                conversationPresenter?.setThinking(true, label: statusText(for: first))
            }
            dispatchAllCalls(in: message, token: token)
            return
        }

        // Plain assistant text — turn is complete.
        if !message.content.isEmpty {
            persistAssistant(message)
            conversationPresenter?.setThinking(false, label: nil)
            conversationPresenter?.appendAssistantMessage(message.content, model: message.model)
            conversationPresenter?.avatarPulse()
            currentTurnToken = nil
            currentTurnUserMessageId = nil
            speak(message.content)
        } else {
            currentTurnToken = nil
            currentTurnUserMessageId = nil
            state = .idle
            conversationPresenter?.setThinking(false, label: nil)
        }
    }

    /// Fan out every tool_use block on a single assistant turn. Mac mirrors
    /// the iOS path: dispatch all calls concurrently, batch their results,
    /// then re-enter chat with all of them in one user turn. The provider
    /// pairs each `tool_result` back to its originating `tool_use` via the
    /// persisted `callId`, so multi-step plans no longer stall after the
    /// first call.
    private func dispatchAllCalls(in message: MessageStruct, token: UUID) {
        let calls = message.functions
        let total = calls.count
        var resultBuffer = Array<MessageStruct?>(repeating: nil, count: total)
        var pendingCount = total

        for (index, call) in calls.enumerated() {
            dispatchFunction(call) { [weak self] result in
                guard let self = self else { return }
                guard self.currentTurnToken == token else { return }
                var r = result
                // Pair the result back so the next chat turn can emit a
                // structured `tool_result` instead of falling back to prose.
                if r.callId == nil { r.callId = call.callId }
                if r.name == nil   { r.name   = call.name }
                DispatchQueue.main.async {
                    resultBuffer[index] = r
                    pendingCount -= 1
                    if pendingCount == 0 {
                        self.finishToolBatch(resultBuffer.compactMap { $0 }, token: token)
                    }
                }
            }
        }
    }

    /// Append every tool result, then issue one chat round-trip. The
    /// response routes back through `handleChatResponse` so the existing
    /// error-handling + cancellation-token guard stay in one place.
    private func finishToolBatch(_ results: [MessageStruct], token: UUID) {
        guard currentTurnToken == token else { return }
        for r in results {
            messages.append(r)
        }
        state = .thinking
        conversationPresenter?.setThinking(true, label: "Thinking…")
        Cloud.connection.chat(messages: messages) { [weak self] response, error in
            DispatchQueue.main.async { self?.handleChatResponse(response, error: error, token: token) }
        }
    }

    private func dispatchFunction(_ function: FunctionCallStruct,
                                  completion: @escaping (MessageStruct) -> Void) {
        // Stamp the originating conversation onto the call so skills that
        // care about context (SubAgentSkill for parent-conversation
        // hand-off, TerminalSkill for session lookup) don't have to fall
        // back on the global `currentConversation` pointer. That global
        // tracks whichever tab the user is currently looking at — which
        // races with async tool dispatch on multi-tab Mac (user spawns
        // a sub-agent on chat #1, switches to chat #2, the sub-agent
        // completes and lands on chat #2 instead of #1).
        var function = function
        if function.conversationId == nil {
            function.conversationId = self.conversation?.id
        }
        let cont: (MessageStruct) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }
        if NotionSkill.shared.handles(functionName: function.name) {
            NotionSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if SlackSkill.shared.handles(functionName: function.name) {
            SlackSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if SchedulerSkill.shared.handles(functionName: function.name) {
            SchedulerSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if ExaSkill.shared.handles(functionName: function.name) {
            ExaSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if URLFetchSkill.shared.handles(functionName: function.name) {
            URLFetchSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if GitSkill.shared.handles(functionName: function.name) {
            GitSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if GitHubSkill.shared.handles(functionName: function.name) {
            GitHubSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if SelfImprovementSkill.shared.handles(functionName: function.name) {
            SelfImprovementSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if FileSystemSkill.shared.handles(functionName: function.name) {
            FileSystemSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if SpecBuilderSkill.shared.handles(functionName: function.name) {
            SpecBuilderSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if LocationSkill.shared.handles(functionName: function.name) {
            LocationSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if MacAppSkill.shared.handles(functionName: function.name) {
            MacAppSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if TerminalSkill.shared.handles(functionName: function.name) {
            TerminalSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if ObsidianSkill.shared.handles(functionName: function.name) {
            ObsidianSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if CalendarSkill.shared.handles(functionName: function.name) {
            CalendarSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if MusicSkill.shared.handles(functionName: function.name) {
            MusicSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if SkillBuilderSkill.shared.handles(functionName: function.name) {
            SkillBuilderSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if IntegrationSkill.shared.handles(functionName: function.name) {
            IntegrationSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if ImageSkill.shared.handles(functionName: function.name) {
            // ImageSkill returns the function-result synchronously (a "queued,
            // appears inline shortly" stub) and the actual bytes arrive later
            // via ImageGenerationService → ImageSkillHost on the conversation
            // window. cont() therefore feeds the stub straight back into the
            // chat loop so the model can write its short acknowledgment while
            // the network request is still in flight.
            ImageSkill.shared.handle(functionCall: function, completion: cont)
            return
        }
        if PDFSkill.shared.handles(functionName: function.name) {
            // Same submit-and-return pattern as ImageSkill: PDFSkill hands
            // the render to PDFGenerationService and returns a queued stub
            // immediately; the cell fills in via PDFSkillHost on the
            // conversation window when WKWebView finishes the render.
            PDFSkill.shared.handle(functionCall: function, completion: cont)
            return
        }
        if SubAgentSkill.shared.handles(functionName: function.name) {
            SubAgentSkill.shared.handle(functionCall: function, completion: cont)
            return
        }
        if DevinSkill.shared.handles(functionName: function.name) {
            DevinSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if CursorSkill.shared.handles(functionName: function.name) {
            CursorSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if GoogleDriveSkill.shared.handles(functionName: function.name) {
            GoogleDriveSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if GoogleGmailSkill.shared.handles(functionName: function.name) {
            GoogleGmailSkill.shared.handle(functionCall: function, completion: cont); return
        }
        if GoogleCalendarSkill.shared.handles(functionName: function.name) {
            GoogleCalendarSkill.shared.handle(functionCall: function, completion: cont); return
        }
        // Dynamic (user-authored JS) skills last — hot-loaded so the
        // registry is the source of truth for what's currently available.
        if DynamicSkillRegistry.shared.handles(functionName: function.name) {
            DynamicSkillRegistry.shared.handle(functionCall: function, completion: cont); return
        }
        // Unknown tool — fail gracefully.
        let fallback = MessageStruct(role: "function", content: "Tool \(function.name) is not available on Mac.", name: function.name)
        cont(fallback)
    }

    private func statusText(for call: FunctionCallStruct) -> String {
        if let s = ExaSkill.shared.statusText(for: call) { return s }
        if let s = NotionSkill.shared.statusText(for: call) { return s }
        if let s = SlackSkill.shared.statusText(for: call) { return s }
        if let s = SchedulerSkill.shared.statusText(for: call) { return s }
        if let s = SelfImprovementSkill.shared.statusText(for: call) { return s }
        if let s = FileSystemSkill.shared.statusText(for: call) { return s }
        if let s = SpecBuilderSkill.shared.statusText(for: call) { return s }
        if let s = MacAppSkill.shared.statusText(for: call) { return s }
        if let s = TerminalSkill.shared.statusText(for: call) { return s }
        if let s = ObsidianSkill.shared.statusText(for: call) { return s }
        if let s = CalendarSkill.shared.statusText(for: call) { return s }
        if let s = MusicSkill.shared.statusText(for: call) { return s }
        if let s = SkillBuilderSkill.shared.statusText(for: call) { return s }
        if let s = GitHubSkill.shared.statusText(for: call) { return s }
        if let s = PDFSkill.shared.statusText(for: call) { return s }
        if let s = SubAgentSkill.shared.statusText(for: call) { return s }
        if let s = DevinSkill.shared.statusText(for: call) { return s }
        if let s = CursorSkill.shared.statusText(for: call) { return s }
        if let s = GoogleDriveSkill.shared.statusText(for: call) { return s }
        if let s = GoogleGmailSkill.shared.statusText(for: call) { return s }
        if let s = GoogleCalendarSkill.shared.statusText(for: call) { return s }
        if let s = DynamicSkillRegistry.shared.statusText(for: call) { return s }
        return "running \(call.name.replacingOccurrences(of: "_", with: " "))"
    }

    private func persistAssistant(_ message: MessageStruct) {
        guard let conversation = conversation else { return }
        SimpleConversationManager.shared.addMessage(message, to: conversation)
        // Refresh our snapshot from the store by *this* coordinator's id,
        // not from `manager.currentConversation` — with multiple tabs alive,
        // `currentConversation` tracks the foreground tab, not us. Reading
        // it blindly used to clobber background coordinators' conversation
        // pointer with the foreground's, breaking their next send.
        if let conv = self.conversation,
           let refreshed = SimpleConversationManager.shared.getConversation(by: conv.id) {
            self.conversation = refreshed
        }
        messages.append(message)
        // Auto-title hook: same trigger as iOS — only fires when there's
        // a real user-and-assistant exchange and the chat still has its
        // default title. ConversationTitleService dedupes by conv id, so
        // calling on every assistant turn is safe.
        if let target = self.conversation {
            ConversationTitleService.shared.generateIfNeeded(
                for: target,
                messages: messages
            )
        }
    }

    // MARK: - TTS

    /// Hands off to MacSpeechPlayer, which dispatches to the user's chosen
    /// provider (Aura streaming by default, then OpenAI HTTP, then on-device).
    /// Background tabs skip TTS entirely — the assistant text is already in
    /// the store, so the user can read it (and hear future turns) once they
    /// switch to that tab.
    private func speak(_ rawText: String) {
        guard isActive else {
            state = .idle
            return
        }
        state = .speaking
        speechPlayer.speak(rawText)
    }

    /// Cut off any in-progress TTS playback and drop back to idle. Wired up
    /// to the quick-tap hotkey path so a tap of fn+ctrl while Loop is
    /// reading a response interrupts it — same gesture the user uses to
    /// open the text input, just with the side effect of silencing the
    /// assistant first.
    func stopSpeakingIfNeeded() {
        guard state == .speaking else { return }
        EarconPlayer.shared.play(.interrupt)
        speechPlayer.stop()
        state = .idle
    }

    // MARK: - Cancellation (escape while a turn is in flight)

    /// Aborts whatever turn-related work is happening and drops back to
    /// idle. Each non-idle, non-recording state has its own teardown:
    ///
    ///  - `.transcribing`: STT is finalizing. Disconnect the websocket and
    ///    forget the partial; nothing is persisted yet.
    ///  - `.thinking`: The user message is already in the store and a
    ///    chat/tool callback is in flight. Rotate the turn token (callback
    ///    becomes a no-op), erase the user message, rebuild from store so
    ///    intermediate tool messages also vanish.
    ///  - `.speaking`: TTS is mid-playback over the assistant's reply. Cut
    ///    the audio. The assistant message stays in the conversation —
    ///    deleting it would be jarring.
    ///
    /// In every case we end in `.idle` and fire `onEmptyTranscript`, which
    /// the recorder hooks to clear and focus its text field. So escape
    /// always gives the user a clean input slot to type into.
    func cancelCurrentTurn() {
        // Auditory cue for any active-state abort: one
        // brief low-E. The switch below covers what to clean up; the
        // earcon fires uniformly.
        switch state {
        case .transcribing, .thinking, .speaking:
            EarconPlayer.shared.play(.interrupt)
        case .idle, .recording:
            break
        }

        switch state {
        case .transcribing:
            teardownStreaming()
        case .thinking:
            currentTurnToken = nil
            if let userId = currentTurnUserMessageId, let conv = conversation {
                SimpleConversationManager.shared.removeMessage(id: userId, from: conv)
                if let refreshed = SimpleConversationManager.shared.getConversation(by: conv.id) {
                    self.conversation = refreshed
                }
            }
            currentTurnUserMessageId = nil
            rebuildMessagesFromStore()
            conversationPresenter?.setThinking(false, label: nil)
            conversationPresenter?.showAndReload()
        case .speaking:
            speechPlayer.stop()
        case .idle, .recording:
            // Recording is owned by the fn+ctrl hold gesture — escape has
            // no business interrupting it. Idle is a no-op.
            return
        }
        state = .idle
        onPartial?("")
        onEmptyTranscript?()
    }

    // MARK: - Conversation switching (sidebar)
    //
    // The sidebar in ConversationWindowController calls these when the user
    // picks a different conversation or hits the compose button. Both methods
    // bail cleanly out of any active turn first — switching mid-speech leaves
    // the previous speech-player running otherwise, and switching mid-think
    // would resolve the in-flight response into the wrong conversation.

    /// Switch the live conversation. No-op if `conversation.id` is already
    /// active. Side effect: SimpleConversationManager.currentConversation
    /// follows, which keeps sub-agent spawns / iPhone sync looking at the
    /// right thread.
    func switchToConversation(_ next: SimpleConversation) {
        if conversation?.id == next.id { return }
        if state != .idle { cancelCurrentTurn() }
        let manager = SimpleConversationManager.shared
        manager.currentConversation = next
        self.conversation = next
        rebuildMessagesFromStore()
        conversationPresenter?.showAndReload()
    }

    /// Compose-button path: create a fresh conversation and switch to it.
    /// Title mirrors `loadConversation`'s "Mac Chat <date>" so the sidebar
    /// shows something readable until the first message lands.
    @discardableResult
    func startNewConversation() -> SimpleConversation {
        if state != .idle { cancelCurrentTurn() }
        let manager = SimpleConversationManager.shared
        let title = "Mac Chat \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
        let fresh = manager.createConversation(title: title)
        manager.currentConversation = fresh
        self.conversation = fresh
        rebuildMessagesFromStore()
        conversationPresenter?.showAndReload()
        return fresh
    }

    /// The currently active conversation id, so the sidebar can highlight
    /// the matching row without poking the manager directly.
    var activeConversationId: String? { conversation?.id }

    private func installEscapeMonitor() {
        // Local-only monitor: we only want to react when Loop is the active
        // app. If the user is typing in another app, their escape keypress
        // belongs to that app.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 53 is the keycode for escape; using the keycode (not chars)
            // works regardless of keyboard layout.
            guard let self = self, event.keyCode == 53 else { return event }
            // Background coordinators ignore escape — only the foreground tab
            // should react. Otherwise N coordinators would all race to cancel.
            guard self.isActive else { return event }
            switch self.state {
            case .transcribing, .thinking, .speaking:
                self.cancelCurrentTurn()
                // Swallow the event so it doesn't also propagate (e.g.
                // closing the conversation window via cancelOperation).
                return nil
            case .idle, .recording:
                return event
            }
        }
    }

    // MARK: - Helpers

    private static var deepgramAPIKey: String? {
        return KeyStore.shared.value(for: .deepgram)
    }
}
