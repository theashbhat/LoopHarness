//
//  MusicController.swift
//  Loop
//
//  Owns the MusicKit `ApplicationMusicPlayer`, the current queue, and the
//  coexistence logic that lets background music share the foreground with
//  Loop's TTS and microphone capture.
//
//  Coexistence model — no other audio code in Loop is touched:
//    – Recording / TTS / earcon sessions all already use `.mixWithOthers`,
//      so MusicKit output is allowed to play alongside in principle.
//    – Apple does not expose a per-app volume knob on
//      `ApplicationMusicPlayer`, and MPVolumeView's programmatic-slider
//      trick was disabled in iOS 11. So instead of trying to "duck" volume,
//      we pause music for the duration of speech I/O and resume after —
//      conceptually the same outcome (model voice / user speech sits on top)
//      and works identically on iOS and macOS.
//
//  Signal wiring (see plan: can-you-brainstorm-how-parsed-kahan.md):
//    – `.voiceLoopStateDidChange` → pause for recording/speaking, resume on idle
//    – `.conversationStoreDidChange` → "long thread" heuristic; swap an
//      agent-selected vocal queue for an instrumental queue
//    – `AVAudioSession.interruptionNotification` (iOS only) → pause/resume
//

import Foundation
import MusicKit
#if canImport(AVFAudio)
import AVFAudio
#endif

/// Sentinel thrown by `MusicController.raceWithTimeout` when a MusicKit
/// call exceeds its allotted wall-clock budget. Caught at the call site so
/// we can surface a friendly diagnostic instead of bubbling up as a raw
/// error.
struct MusicKitTimeoutError: Error {}

@MainActor
final class MusicController {

    static let shared = MusicController()

    // MARK: - Public state

    enum Selector { case user, agent }

    /// Why music is currently paused, if it is. Distinguishes auto-pauses
    /// from user-initiated ones so resume() only fires when the same source
    /// that paused us lifts its hold.
    enum PauseReason {
        case userExplicit       // stop_music or pause_music called by the agent on user request
        case duckRecording
        case duckSpeaking
        case interruption       // system interruption (phone call, etc.)
    }

    struct NowPlaying {
        let title: String
        let artist: String?
        let albumTitle: String?
        let isInstrumental: Bool
        let selectedBy: Selector
    }

    private(set) var nowPlaying: NowPlaying?
    private(set) var pauseReason: PauseReason?

    /// Opaque token set when music is ducked for a voice session. Cleared
    /// when the user explicitly stops music or changes the queue via system
    /// controls, so an orphaned auto-resume never fires after the user has
    /// moved on. A new `play_music` call replaces the token (the new track
    /// becomes the resume target).
    private(set) var resumeToken: UUID?

    // MARK: - Internals

    private let player = ApplicationMusicPlayer.shared
    private var subscriptions: [NSObjectProtocol] = []
    private var lastObservedMessageCount = 0
    private var swappedToInstrumentalForThisConversation = false
    private var currentConversationId: String?

    /// Min messages before we consider an auto-swap from vocal → instrumental.
    private let instrumentalThreshold = 10

    /// Songs tracked for queue-rebuild. On iOS 26+ the native
    /// Queue.insert(_:position:) is unreliable mid-playback, so we keep
    /// our own list and reconstruct the player queue on append.
    private var managedSongQueue: [Song] = []

    private init() {
        subscribeToSignals()
    }

    deinit {
        for token in subscriptions {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Idempotent bootstrap from app launch. Instantiates the singleton so
    /// its NotificationCenter subscribers are live before TTS/recording start
    /// posting events. Does NOT trigger the Apple Music authorization dialog —
    /// that's deferred until the user actually invokes a music tool, so a
    /// fresh launch doesn't prompt for Apple Music access.
    static func bootstrap() {
        _ = MusicController.shared
        print("MusicController: bootstrap — currentStatus=\(MusicController.statusName(MusicAuthorization.currentStatus))")
    }

    // MARK: - Authorization

    /// Human-readable status name for the system Apple Music auth state.
    /// Used in logs and surfaced through every tool response so the
    /// LLM (and the human reading the logs) can tell what state we're in.
    nonisolated static func statusName(_ status: MusicAuthorization.Status) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .authorized:    return "authorized"
        @unknown default:    return "unknown"
        }
    }

    /// Last status seen — exposed so tool responses can include it. Reading
    /// `MusicAuthorization.currentStatus` directly is fine too; this is
    /// just a convenience so we don't keep recomputing.
    private(set) var lastAuthStatus: MusicAuthorization.Status = MusicAuthorization.currentStatus

    func ensureAuthorized() async -> Bool {
        let before = MusicAuthorization.currentStatus
        lastAuthStatus = before
        print("MusicController: ensureAuthorized — currentStatus=\(MusicController.statusName(before))")

        switch before {
        case .authorized:
            return true
        case .notDetermined:
            print("MusicController: ensureAuthorized — calling MusicAuthorization.request() …")
            let after = await MusicAuthorization.request()
            lastAuthStatus = after
            print("MusicController: ensureAuthorized — request returned \(MusicController.statusName(after))")
            return after == .authorized
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Search

    func findMusic(query: String,
                   limit: Int = 8,
                   instrumentalOnly: Bool = false) async throws -> [String: Any] {
        guard await ensureAuthorized() else { return unauthorizedResult }

        var request = MusicCatalogSearchRequest(term: query, types: [Song.self, Album.self, Playlist.self])
        request.limit = max(1, min(25, limit))
        let response = try await request.response()

        let songs: [[String: Any]] = response.songs.compactMap { song in
            let hint = isInstrumentalHint(title: song.title, album: song.albumTitle)
            if instrumentalOnly && !hint { return nil }
            return [
                "id": song.id.rawValue,
                "type": "song",
                "title": song.title,
                "artist": song.artistName,
                "album": song.albumTitle ?? "",
                "instrumental_hint": hint
            ]
        }.prefix(limit).map { $0 }

        let albums: [[String: Any]] = response.albums.prefix(limit).map { album in
            [
                "id": album.id.rawValue,
                "type": "album",
                "title": album.title,
                "artist": album.artistName
            ]
        }

        let playlists: [[String: Any]] = response.playlists.prefix(limit).map { playlist in
            [
                "id": playlist.id.rawValue,
                "type": "playlist",
                "title": playlist.name,
                "curator": playlist.curatorName ?? ""
            ]
        }

        return [
            "status": "ok",
            "songs": songs,
            "albums": albums,
            "playlists": playlists
        ]
    }

    // MARK: - Playback

    func play(targetId: String,
              targetType: String,
              queueMode: String = "replace",
              selectedBy: Selector = .agent) async throws -> [String: Any] {
        guard await ensureAuthorized() else { return unauthorizedResult }

        switch targetType.lowercased() {
        case "song":
            let id = MusicItemID(targetId)
            let song: Song?
            if targetId.hasPrefix("i.") {
                var req = MusicLibraryRequest<Song>()
                req.filter(matching: \.id, equalTo: id)
                song = try await req.response().items.first
            } else {
                var req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: id)
                req.limit = 1
                song = try await req.response().items.first
            }
            guard let song else { return notFoundResult }
            if queueMode == "append" {
                try await appendSongToQueue(song)
            } else {
                managedSongQueue = [song]
                player.queue = .init(for: [song])
            }
            if queueMode != "append" {
                captureNowPlaying(title: song.title,
                                  artist: song.artistName,
                                  album: song.albumTitle,
                                  selectedBy: selectedBy)
            }

        case "album":
            let id = MusicItemID(targetId)
            let album: Album?
            if targetId.hasPrefix("l.") {
                var req = MusicLibraryRequest<Album>()
                req.filter(matching: \.id, equalTo: id)
                album = try await req.response().items.first
            } else {
                var req = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: id)
                req.limit = 1
                album = try await req.response().items.first
            }
            guard let album else { return notFoundResult }
            if queueMode == "append" {
                try await player.queue.insert(album, position: .tail)
            } else {
                managedSongQueue = []
                player.queue = .init(for: [album])
            }
            if queueMode != "append" {
                captureNowPlaying(title: album.title,
                                  artist: album.artistName,
                                  album: album.title,
                                  selectedBy: selectedBy)
            }

        case "playlist":
            let id = MusicItemID(targetId)
            let playlist: Playlist?
            if targetId.hasPrefix("p.") {
                var req = MusicLibraryRequest<Playlist>()
                req.filter(matching: \.id, equalTo: id)
                playlist = try await req.response().items.first
            } else {
                var req = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: id)
                req.limit = 1
                playlist = try await req.response().items.first
            }
            guard let playlist else { return notFoundResult }
            if queueMode == "append" {
                try await player.queue.insert(playlist, position: .tail)
            } else {
                managedSongQueue = []
                player.queue = .init(for: [playlist])
            }
            if queueMode != "append" {
                captureNowPlaying(title: playlist.name,
                                  artist: playlist.curatorName,
                                  album: nil,
                                  selectedBy: selectedBy)
            }

        default:
            return ["status": "error",
                    "error": "bad_target_type",
                    "message": "target_type must be song, album, or playlist."]
        }

        if queueMode == "append" {
            var out: [String: Any] = ["status": "ok", "action": "appended"]
            if let np = nowPlaying {
                out["now_playing"] = [
                    "title": np.title,
                    "artist": np.artist ?? "",
                    "is_instrumental": np.isInstrumental
                ]
            }
            return out
        }

        try await player.prepareToPlay()
        try await player.play()
        pauseReason = nil
        reduckIfVoiceSessionActive()

        AgentActivityLog.shared.log(.status, "playing \(nowPlaying?.title ?? "music")")

        var out: [String: Any] = ["status": "ok"]
        if let np = nowPlaying {
            out["now_playing"] = [
                "title": np.title,
                "artist": np.artist ?? "",
                "is_instrumental": np.isInstrumental
            ]
        }
        return out
    }

    // MARK: - Queue append (iOS 26+ workaround)

    /// Append a song without interrupting playback. Tries the native
    /// `Queue.insert` first; on failure rebuilds the queue from
    /// `managedSongQueue` and restores the current playback position.
    private func appendSongToQueue(_ song: Song) async throws {
        // Fast path: native insert (works pre-iOS 26).
        do {
            try await player.queue.insert(song, position: .tail)
            managedSongQueue.append(song)
            print("MusicController: appended via native insert")
            return
        } catch {
            print("MusicController: native insert failed (\(error)), rebuilding queue")
        }

        // Snapshot the queue if we haven't been tracking (e.g. prior play was
        // an album/playlist). Best-effort — entries that aren't Song-typed
        // are silently dropped.
        if managedSongQueue.isEmpty {
            for entry in player.queue.entries {
                if case .song(let s) = entry.item { managedSongQueue.append(s) }
            }
            print("MusicController: snapshotted \(managedSongQueue.count) songs from queue")
        }

        let wasPlaying = player.state.playbackStatus == .playing
        let savedTime = player.playbackTime

        managedSongQueue.append(song)

        // Find the currently-playing song so we rebuild from that point.
        var currentIdx = 0
        if let currentEntry = player.queue.currentEntry,
           case .song(let currentSong) = currentEntry.item {
            currentIdx = managedSongQueue.firstIndex(where: { $0.id == currentSong.id }) ?? 0
        }

        let remaining = Array(managedSongQueue.suffix(from: currentIdx))
        managedSongQueue = remaining

        if wasPlaying { player.pause() }

        player.queue = .init(for: remaining)
        try await player.prepareToPlay()
        player.playbackTime = savedTime

        if wasPlaying {
            try await player.play()
            pauseReason = nil
            reduckIfVoiceSessionActive()
        }
        print("MusicController: appended via queue rebuild (\(remaining.count) tracks in queue)")
    }

    func setMusicMood(rawMood: String, instrumentalOverride: Bool?) async throws -> [String: Any] {
        let mood = MusicMoodMap.parse(rawMood)
        let instrumental = instrumentalOverride ?? mood.prefersInstrumental
        print("MusicController: setMusicMood mood=\(mood.rawValue) instrumental=\(instrumental)")

        print("MusicController: setMusicMood ensureAuthorized…")
        guard await ensureAuthorized() else {
            print("MusicController: setMusicMood → unauthorized")
            return unauthorizedResult
        }

        // Search the catalog directly so we keep the typed Song handle and
        // skip the dictionary round-trip + re-fetch that play(targetId:)
        // would otherwise do.
        print("MusicController: setMusicMood searching \"\(mood.searchQuery)\"…")
        var search = MusicCatalogSearchRequest(term: mood.searchQuery, types: [Song.self, Playlist.self])
        search.limit = 10
        let response: MusicCatalogSearchResponse
        do {
            response = try await MusicController.raceWithTimeout(seconds: 6) {
                try await search.response()
            }
        } catch is MusicKitTimeoutError {
            print("MusicController: setMusicMood search TIMED OUT — MusicKit didn't respond in 6s")
            return musicKitNoResponseResult
        } catch {
            print("MusicController: setMusicMood search FAILED — \(error)")
            throw error
        }
        print("MusicController: setMusicMood got \(response.songs.count) songs, \(response.playlists.count) playlists")

        let song = response.songs.first { song in
            if !instrumental { return true }
            return isInstrumentalHint(title: song.title, album: song.albumTitle)
        }

        if let song = song {
            print("MusicController: setMusicMood queueing song \"\(song.title)\"")
            managedSongQueue = [song]
            player.queue = .init(for: [song])
            captureNowPlaying(title: song.title,
                              artist: song.artistName,
                              album: song.albumTitle,
                              selectedBy: .agent)
            print("MusicController: setMusicMood calling player.play()…")
            do {
                try await MusicController.raceWithTimeout(seconds: 6) {
                    try await self.player.play()
                }
            } catch is MusicKitTimeoutError {
                print("MusicController: setMusicMood player.play() TIMED OUT in 6s")
                return musicKitNoResponseResult
            } catch {
                print("MusicController: setMusicMood player.play() FAILED — \(error)")
                throw error
            }
            pauseReason = nil
            reduckIfVoiceSessionActive()
            AgentActivityLog.shared.log(.status, "playing \(song.title)")
            return [
                "status": "ok",
                "mood": mood.rawValue,
                "now_playing": [
                    "title": song.title,
                    "artist": song.artistName,
                    "is_instrumental": isInstrumentalHint(title: song.title, album: song.albumTitle)
                ]
            ]
        }

        if let playlist = response.playlists.first {
            print("MusicController: setMusicMood queueing playlist \"\(playlist.name)\"")
            managedSongQueue = []
            player.queue = .init(for: [playlist])
            captureNowPlaying(title: playlist.name,
                              artist: playlist.curatorName,
                              album: nil,
                              selectedBy: .agent)
            print("MusicController: setMusicMood calling player.play()…")
            do {
                try await MusicController.raceWithTimeout(seconds: 6) {
                    try await self.player.play()
                }
            } catch is MusicKitTimeoutError {
                print("MusicController: setMusicMood player.play() TIMED OUT in 6s")
                return musicKitNoResponseResult
            } catch {
                print("MusicController: setMusicMood player.play() FAILED — \(error)")
                throw error
            }
            pauseReason = nil
            reduckIfVoiceSessionActive()
            AgentActivityLog.shared.log(.status, "playing \(playlist.name)")
            return [
                "status": "ok",
                "mood": mood.rawValue,
                "now_playing": [
                    "title": playlist.name,
                    "artist": playlist.curatorName ?? "",
                    "is_instrumental": false
                ]
            ]
        }

        print("MusicController: setMusicMood → no_results")
        return ["status": "error",
                "error": "no_results",
                "message": "Couldn't find a \(mood.rawValue) track."]
    }

    func pause(reason: PauseReason = .userExplicit) {
        guard player.state.playbackStatus == .playing else { return }
        player.pause()
        pauseReason = reason
        if reason == .userExplicit {
            resumeToken = nil
            AgentActivityLog.shared.log(.status, "paused music")
        }
    }

    // MARK: - Voice-session ducking

    /// Synchronously pause music and arm the resume token. Call this
    /// **before** the earcon plays so the music drops before the cue sounds.
    /// The notification-based path in `handleVoiceLoopState` still acts as a
    /// safety net (if the caller forgets, the duck will still happen on the
    /// next state change), but calling this explicitly avoids the async
    /// latency of the NotificationCenter round-trip.
    func duckForVoiceSession() {
        guard player.state.playbackStatus == .playing else { return }
        player.pause()
        pauseReason = .duckRecording
        resumeToken = UUID()
        print("MusicController: ducked for voice session (token=\(resumeToken!.uuidString.prefix(8)))")
    }

    /// Resume music after a voice session if the resume token is still valid
    /// and we paused for a duck reason. Fails silently on any error so the
    /// user is never spammed with alerts.
    func resumeAfterVoiceSession() {
        guard resumeToken != nil else {
            print("MusicController: resumeAfterVoiceSession — no resume token, skipping")
            return
        }
        guard pauseReason == .duckRecording || pauseReason == .duckSpeaking else {
            print("MusicController: resumeAfterVoiceSession — pauseReason is \(String(describing: pauseReason)), skipping")
            return
        }
        Task { [weak self] in
            do {
                try await self?.player.play()
                await MainActor.run {
                    self?.pauseReason = nil
                    print("MusicController: resumed after voice session")
                }
            } catch {
                print("MusicController: resumeAfterVoiceSession failed — \(error)")
                // Fail silently. The track may no longer be in the queue,
                // Apple Music might have errored, etc.
            }
        }
    }

    /// If the voice loop is in a non-idle state (recording, thinking,
    /// speaking, …), immediately re-pause the player so a `play()` or
    /// `setMusicMood()` call made mid-turn doesn't bleed audio. The new
    /// track stays queued and becomes the resume target when the turn ends.
    private func reduckIfVoiceSessionActive() {
        #if os(macOS)
        let voiceState = VoiceLoopCoordinator.current?.state ?? .idle
        #else
        let voiceState = VoiceLoopCoordinator.shared.state
        #endif
        guard voiceState != .idle else { return }
        player.pause()
        pauseReason = .duckSpeaking
        resumeToken = UUID()
        print("MusicController: re-paused for active voice session (state=\(voiceState))")
    }

    func resume(reason: PauseReason? = nil) async throws {
        // Only resume if the caller's reason matches why we paused — so
        // an "idle" tick after recording doesn't accidentally restart a
        // user-paused queue.
        if let r = reason, pauseReason != r { return }
        guard pauseReason != nil else { return }
        try await player.play()
        pauseReason = nil
    }

    func userResume() async throws {
        try await player.play()
        pauseReason = nil
        AgentActivityLog.shared.log(.status, "resumed music")
    }

    func skip() async throws {
        try await player.skipToNextEntry()
    }

    func stop() {
        player.stop()
        pauseReason = .userExplicit
        resumeToken = nil
        nowPlaying = nil
        managedSongQueue = []
        AgentActivityLog.shared.log(.status, "stopped music")
    }

    func status() -> [String: Any] {
        let s = player.state
        var out: [String: Any] = [
            "status": "ok",
            "is_playing": s.playbackStatus == .playing,
            "playback_status": String(describing: s.playbackStatus)
        ]
        if let r = pauseReason {
            out["pause_reason"] = String(describing: r)
        }
        out["will_auto_resume"] = resumeToken != nil
        if let np = nowPlaying {
            out["now_playing"] = [
                "title": np.title,
                "artist": np.artist ?? "",
                "is_instrumental": np.isInstrumental,
                "selected_by": np.selectedBy == .user ? "user" : "agent"
            ]
        }
        return out
    }

    // MARK: - Playlist creation

    func createPlaylist(name: String,
                        description: String?,
                        trackIds: [String]) async throws -> [String: Any] {
        #if os(macOS)
        // MusicKit's `MusicLibrary.createPlaylist` is iOS/iPadOS/visionOS only.
        // On macOS the library API isn't exposed; the user can drag a saved
        // queue into the Music app to make a playlist manually for now.
        return [
            "status": "error",
            "error": "unsupported_on_macos",
            "message": "Creating Apple Music playlists isn't available on macOS — Apple hasn't exposed MusicLibrary.createPlaylist for Mac yet. Use the iOS app to make playlists, or queue songs with play_music here."
        ]
        #else
        guard await ensureAuthorized() else { return unauthorizedResult }

        var resolved: [Song] = []
        for raw in trackIds {
            let id = MusicItemID(raw)
            var req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: id)
            req.limit = 1
            if let song = try await req.response().items.first {
                resolved.append(song)
            }
        }

        // Try combined creation first; fall back to two-step for iOS 27+
        // where the combined response decoder may be out of sync.
        let playlist: Playlist
        do {
            playlist = try await MusicLibrary.shared.createPlaylist(
                name: name,
                description: description,
                items: resolved
            )
        } catch {
            print("MusicController: createPlaylist combined call failed — \(error)")
            playlist = try await MusicLibrary.shared.createPlaylist(
                name: name,
                description: description,
                items: [] as [Song]
            )
            for song in resolved {
                try await MusicLibrary.shared.add(song, to: playlist)
            }
        }

        AgentActivityLog.shared.log(.status,
            "created playlist \"\(name)\" with \(resolved.count) tracks")

        return [
            "status": "ok",
            "playlist_id": playlist.id.rawValue,
            "name": playlist.name,
            "track_count": resolved.count
        ]
        #endif
    }

    // MARK: - Signal subscriptions

    private func subscribeToSignals() {
        let nc = NotificationCenter.default

        let stateToken = nc.addObserver(
            forName: .voiceLoopStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleVoiceLoopState() }
        }
        subscriptions.append(stateToken)

        let convToken = nc.addObserver(
            forName: .conversationStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleConversationChange() }
        }
        subscriptions.append(convToken)

        #if os(iOS)
        let interruptToken = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
        subscriptions.append(interruptToken)
        #endif
    }

    private func handleVoiceLoopState() {
        #if os(macOS)
        guard let coordinator = VoiceLoopCoordinator.current else { return }
        let state = coordinator.state
        #else
        let state = VoiceLoopCoordinator.shared.state
        #endif
        switch state {
        case .recording:
            // Pause if currently playing; remember why so we can auto-resume.
            // The caller may have already called duckForVoiceSession()
            // synchronously — in that case the player is already paused and
            // this is a no-op.
            if player.state.playbackStatus == .playing {
                player.pause()
                pauseReason = .duckRecording
                if resumeToken == nil { resumeToken = UUID() }
            }
        case .speaking:
            if player.state.playbackStatus == .playing {
                player.pause()
                pauseReason = .duckSpeaking
                if resumeToken == nil { resumeToken = UUID() }
            }
        case .thinking, .transcribing:
            // Mid-voice-flow — the assistant hasn't spoken yet. Keep music
            // paused so there's no audible gap between recording-end and
            // TTS-start. Resume is deferred to `.idle`.
            break
        case .idle:
            // The voice turn is fully complete (TTS finished, mic closed).
            // Resume only if we ducked and the resume token is still valid
            // (not cleared by a user-explicit stop or track change).
            if resumeToken != nil,
               pauseReason == .duckRecording || pauseReason == .duckSpeaking {
                resumeAfterVoiceSession()
            }
        }
    }

    private func handleConversationChange() {
        guard let conversation = SimpleConversationManager.shared.currentConversation else { return }

        if conversation.id != currentConversationId {
            currentConversationId = conversation.id
            swappedToInstrumentalForThisConversation = false
            lastObservedMessageCount = conversation.messages.count
            return
        }

        let count = conversation.messages.count
        defer { lastObservedMessageCount = count }

        guard !swappedToInstrumentalForThisConversation,
              count >= instrumentalThreshold,
              lastObservedMessageCount < instrumentalThreshold,
              let np = nowPlaying,
              np.selectedBy == .agent,
              !np.isInstrumental,
              player.state.playbackStatus == .playing else {
            return
        }

        swappedToInstrumentalForThisConversation = true
        AgentActivityLog.shared.log(.status,
            "long thread — swapping to instrumental")

        Task { [weak self] in
            guard let self = self else { return }
            do {
                _ = try await self.setMusicMood(rawMood: "focused", instrumentalOverride: true)
            } catch {
                print("MusicController: instrumental swap failed — \(error)")
            }
        }
    }

    #if os(iOS)
    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            if player.state.playbackStatus == .playing {
                pause(reason: .interruption)
            }
        case .ended:
            if let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
                if opts.contains(.shouldResume) && pauseReason == .interruption {
                    Task { [weak self] in
                        try? await self?.resume(reason: .interruption)
                    }
                }
            }
        @unknown default:
            break
        }
    }
    #endif

    // MARK: - Helpers

    /// Returned when MusicKit's own network call doesn't come back inside
    /// our short per-call window. Almost always means the **MusicKit
    /// service capability isn't enabled on the App ID** at
    /// developer.apple.com → Identifiers → <App ID> → MusicKit → Edit. Without
    /// it MusicKit can't fetch a developer token and just stalls forever
    /// instead of throwing.
    private var musicKitNoResponseResult: [String: Any] {
        [
            "status": "error",
            "error": "musickit_no_response",
            "auth_status": MusicController.statusName(lastAuthStatus),
            "message": "MusicKit didn't respond. The most common cause is that the MusicKit service capability isn't enabled on this app's App ID at developer.apple.com (Identifiers → com.bhat.intel → MusicKit). Other possibilities: device is offline, or the simulator doesn't have an Apple Music account signed in."
        ]
    }

    private var unauthorizedResult: [String: Any] {
        let statusName = MusicController.statusName(lastAuthStatus)
        let hint: String
        switch lastAuthStatus {
        case .notDetermined:
            hint = "The authorization request didn't return .authorized. Either the user dismissed the dialog or the Music capability isn't enabled on this app's developer-portal App ID."
        case .denied:
            hint = "The user denied Apple Music access. They can change it in Settings → Privacy → Media & Apple Music."
        case .restricted:
            hint = "Apple Music is restricted on this device (parental controls or MDM)."
        case .authorized:
            hint = "Authorized, but a downstream call still failed — probably no active Apple Music subscription."
        @unknown default:
            hint = "Unknown authorization status."
        }
        return [
            "status": "error",
            "error": "apple_music_unauthorized",
            "auth_status": statusName,
            "message": hint
        ]
    }

    private var notFoundResult: [String: Any] {
        ["status": "error", "error": "not_found", "message": "That item wasn't found in the catalog."]
    }

    private func captureNowPlaying(title: String,
                                   artist: String?,
                                   album: String?,
                                   selectedBy: Selector) {
        nowPlaying = NowPlaying(
            title: title,
            artist: artist,
            albumTitle: album,
            isInstrumental: isInstrumentalHint(title: title, album: album),
            selectedBy: selectedBy
        )
    }

    /// Race a MusicKit call against a wall-clock timeout. Throws
    /// `MusicKitTimeoutError` if the operation doesn't finish in time, lets
    /// real errors propagate, and returns the operation's value on success.
    /// Apple's `Task.sleep(for: .seconds(…))` honors task cancellation, so
    /// the loser of the race exits cleanly.
    fileprivate static func raceWithTimeout<T: Sendable>(
        seconds: Double,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MusicKitTimeoutError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func isInstrumentalHint(title: String, album: String?) -> Bool {
        let h = (title + " " + (album ?? "")).lowercased()
        return h.contains("instrumental") ||
               h.contains("piano") ||
               h.contains("ambient") ||
               h.contains("lo-fi") ||
               h.contains("lofi") ||
               h.contains("study")
    }
}
