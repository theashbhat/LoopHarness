//
//  DeepgramTTS.swift
//  Loop
//
//  Minimal Deepgram Speak v1 streaming client. Was nested inside
//  MessagingVC.swift on iOS; lifted here so the macOS app can use the same
//  WebSocket + AVAudioEngine pipeline. Pure platform-neutral — no UIKit,
//  no AVAudioSession (the caller manages session activation on iOS).
//

import Foundation
import AVFoundation

final class DeepgramTTS: NSObject, URLSessionWebSocketDelegate {
    private let apiKey: String
    private let voice: String
    private let sampleRate: Int
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let playbackFormat: AVAudioFormat
    private var didFinish = false
    private var stopRequested = false
    private var scheduledChunks = 0
    private var receivedFlushed = false

    /// Serializes WS-open state and the pending-text buffer so `speak(text:)`
    /// (called on whatever thread the caller uses, often main) and the
    /// delegate callbacks (fired on the session's `delegateQueue`) can't race.
    /// Caller bug we're fixing: speak() used to call task.send() before
    /// didOpenWithProtocol fired, which URLSession reports as
    /// `NSPOSIXErrorDomain Code=57 "Socket is not connected"`.
    private let stateQueue = DispatchQueue(label: "DeepgramTTS.state")
    private var didOpen = false
    private var pendingSpeak: String?

    var onError: ((Error) -> Void)?
    var onFinished: (() -> Void)?
    /// Fires exactly once, when the first PCM chunk arrives over the WS.
    var onFirstAudio: (() -> Void)?
    private var didEmitFirstAudio = false
    /// Per-buffer RMS of the audio being sent to the mixer, in [0, 1].
    /// Drives the avatar's speaking-mode pulse so it tracks the actual
    /// synthesized speech instead of a canned sine. Set on the main queue.
    var onOutputAmplitude: ((Float) -> Void)?

    /// Voice options: aura-2-orion-en, aura-2-thalia-en, aura-2-asteria-en, aura-2-arcas-en, etc.
    /// See https://developers.deepgram.com/docs/tts-models for the full list.
    private let speed: Double

    init(apiKey: String,
         voice: String = "aura-2-thalia-en",
         sampleRate: Int = 48000,
         speed: Double = 1.2) {
        self.apiKey = apiKey
        self.voice = voice
        self.sampleRate = sampleRate
        self.speed = speed
        self.playbackFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        super.init()
    }

    func start() -> Bool {
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: playbackFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: playbackFormat)
        timePitch.rate = Float(max(1.0 / 32.0, min(32.0, speed)))
        // Tap the output to publish per-buffer RMS to the avatar. Installed
        // BEFORE engine.start() so the engine prepares with the tap in place.
        // mainMixerNode taps don't affect playback; just observe the bus.
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: mixerFormat) { [weak self] buffer, _ in
            self?.publishAmplitude(from: buffer)
        }
        do {
            try engine.start()
        } catch {
            print("DeepgramTTS engine.start() failed: \(error)")
            engine.mainMixerNode.removeTap(onBus: 0)
            return false
        }
        player.play()
        connect()
        return true
    }

    private func publishAmplitude(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        var sumSq: Float = 0
        for i in 0..<n {
            let v = channel[i]
            sumSq += v * v
        }
        let rms = sqrt(sumSq / Float(n))
        // The Aura PCM lands at conservative levels; small boost so the
        // 0…1 amplitude is in a usable range without clipping the loudest
        // peaks. Same shape as the mic-side amplitude pipeline.
        let boosted = min(Float(1.0), max(Float(0.0), rms * 6))
        DispatchQueue.main.async { [weak self] in
            self?.onOutputAmplitude?(boosted)
        }
    }

    private func connect() {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/speak")!
        components.queryItems = [
            URLQueryItem(name: "model", value: voice),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
        ]
        guard let url = components.url else {
            onError?(NSError(domain: "DeepgramTTS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"]))
            return
        }
        var request = URLRequest(url: url)
        request.addValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let cfg = URLSessionConfiguration.default
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: OperationQueue())
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop()
    }

    func speak(text: String) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            if self.didOpen {
                self.sendSpeakLocked(text)
            } else {
                // Buffer until didOpenWithProtocol flushes us.
                self.pendingSpeak = (self.pendingSpeak ?? "") + text
            }
        }
    }

    /// Must run on `stateQueue`.
    private func sendSpeakLocked(_ text: String) {
        guard let task = task else { return }
        let speakMsg: [String: Any] = ["type": "Speak", "text": text]
        if let data = try? JSONSerialization.data(withJSONObject: speakMsg),
           let str = String(data: data, encoding: .utf8) {
            task.send(.string(str)) { err in
                if let err = err { print("DeepgramTTS speak send error: \(err)") }
            }
        }
        task.send(.string("{\"type\":\"Flush\"}")) { err in
            if let err = err { print("DeepgramTTS flush send error: \(err)") }
        }
    }

    func stop() {
        stopRequested = true
        task?.send(.string("{\"type\":\"Clear\"}")) { _ in }
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if engine.isRunning {
            player.stop()
            engine.mainMixerNode.removeTap(onBus: 0)
            engine.stop()
        }
        // Make sure the avatar drops back to its idle/canned wobble once
        // playback ends. The tap is gone so no more publishes; this last
        // 0 nudges the EMA in AvatarView to decay back to zero promptly.
        DispatchQueue.main.async { [weak self] in self?.onOutputAmplitude?(0) }
        emitFinishedOnce()
    }

    private func emitFinishedOnce() {
        guard !didFinish else { return }
        didFinish = true
        onFinished?()
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                self.receiveLoop()
            case .failure(let err):
                if !self.stopRequested {
                    // Halt the player BEFORE handing the error to the caller.
                    // Otherwise scheduled-but-not-yet-played chunks keep
                    // draining while the caller's fallback path spins up a
                    // second TTS, and the user hears Aura's partial speech
                    // followed by the fallback's full speech back-to-back.
                    if self.engine.isRunning {
                        self.player.stop()
                        self.engine.mainMixerNode.removeTap(onBus: 0)
                        self.engine.stop()
                    }
                    self.onError?(err)
                }
                self.emitFinishedOnce()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let chunk):
            scheduleAudio(chunk)
        case .string(let text):
            if let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let type = json["type"] as? String
                if type == "Flushed" {
                    receivedFlushed = true
                    finishAfterDrain()
                } else if type == "Warning" {
                    print("DeepgramTTS warning: \(text)")
                }
            }
        @unknown default:
            break
        }
    }

    private func scheduleAudio(_ chunk: Data) {
        let int16Count = chunk.count / MemoryLayout<Int16>.size
        guard int16Count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat,
                                            frameCapacity: AVAudioFrameCount(int16Count)) else {
            return
        }
        if !didEmitFirstAudio {
            didEmitFirstAudio = true
            onFirstAudio?()
        }
        buffer.frameLength = AVAudioFrameCount(int16Count)
        chunk.withUnsafeBytes { rawBuf in
            guard let int16Base = rawBuf.bindMemory(to: Int16.self).baseAddress,
                  let floatChannel = buffer.floatChannelData?[0] else { return }
            let scale: Float = 1.0 / Float(Int16.max)
            for i in 0..<int16Count {
                floatChannel[i] = Float(int16Base[i]) * scale
            }
        }
        scheduledChunks += 1
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self = self else { return }
            self.scheduledChunks -= 1
            self.finishAfterDrain()
        }
    }

    private func finishAfterDrain() {
        guard receivedFlushed, scheduledChunks <= 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.engine.isRunning {
                self.player.stop()
                self.engine.mainMixerNode.removeTap(onBus: 0)
                self.engine.stop()
            }
            self.onOutputAmplitude?(0)
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
            self.session?.invalidateAndCancel()
            self.session = nil
            self.emitFinishedOnce()
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            self.didOpen = true
            if let pending = self.pendingSpeak {
                self.pendingSpeak = nil
                self.sendSpeakLocked(pending)
            }
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        // If the WS closed before it ever opened, this is usually an auth or
        // upgrade-handshake failure — much more useful to surface that than to
        // let the queued send() bubble up as "Socket is not connected".
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.didOpen && !self.stopRequested {
                let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
                let detail = reasonText.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "close code \(closeCode.rawValue)"
                let err = NSError(
                    domain: "DeepgramTTS",
                    code: closeCode.rawValue,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Deepgram WebSocket closed before opening (\(detail)). Likely an invalid API key, network block, or Deepgram outage."]
                )
                self.onError?(err)
            }
            self.emitFinishedOnce()
        }
    }
}
