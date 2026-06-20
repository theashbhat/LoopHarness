//
//  MusicSkill.swift
//  Loop
//
//  Bridges the agent's function-call schema to MusicController. Follows the
//  same shape as ObsidianSkill / NotionSkill so SkillDispatcher can route
//  by name. All heavy lifting (auth, catalog search, MusicKit playback,
//  ducking against TTS / recording, long-thread instrumental swap) lives
//  in MusicController.
//

import Foundation

struct MusicSkill {
    static let shared = MusicSkill()

    static let systemPromptFragment: String = """
You can put on music to match the moment via these tools:
- find_music: catalog search across songs, albums, and playlists. Pass `query`, optional `instrumental_only` (default false), optional `limit` (default 8).
- play_music: start playback of a `target_id` from a previous find_music result or a user-library id (p.… playlists, l.… albums, i.… songs). `target_type` ∈ "song" | "album" | "playlist". `queue_mode` ∈ "replace" | "append" (default "replace"). For playlists/albums the entire track list is queued, not just the first track.
- set_music_mood: high-level shortcut — pass `mood` and we pick a fitting track for you. Mood vocabulary: \(MusicMoodMap.vocabularyList). Pass `instrumental_only=true` to force a vocal-free pick.
- create_playlist: save a curated list of `track_ids` as a playlist in the user's Apple Music library. iOS only; on macOS this returns a friendly error.
- control_music: queue control. `action` ∈ "pause" | "resume" | "skip" | "stop". Use "stop" when the user wants music off entirely.
- get_music_status: see what's playing (title, artist, instrumental hint, paused-or-playing, why paused).
- request_music_authorization: explicitly trigger Apple Music's authorization dialog. Call this if set_music_mood or play_music returns `apple_music_unauthorized` — the response tells you which state the user is in so you can guide them.

How to behave:
- Use set_music_mood whenever the user describes a feeling ("put on something focused", "I'm sad", "let's get hyped"). Prefer it over find_music when the user hasn't named a specific track.
- In long, focused conversations, prefer instrumental tracks (set instrumental_only=true) so vocals don't fight with what we're saying.
- Don't churn the queue — only change tracks or mood when the conversation meaningfully shifts. Once a mood is set, leave it alone.
- Pausing for your own speech or while the mic is recording is automatic; do not call control_music(action="pause") for that. Only pause / stop when the user asks.
- Apple Music playback requires an active subscription. If a play call returns `apple_music_unauthorized`, tell the user plainly.
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "find_music",
                "description": "Search Apple Music's catalog for songs, albums, and playlists matching a query. Returns ids you can pass to play_music.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Search query — track name, artist, mood phrase, etc."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Max results per type. Default 8, max 25."
                        ],
                        "instrumental_only": [
                            "type": "boolean",
                            "description": "If true, only return tracks whose title/album look instrumental (piano, lo-fi, ambient, etc.)."
                        ]
                    ],
                    "required": ["query"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "play_music",
                "description": "Start playback of a song / album / playlist. Accepts catalog ids (from find_music) and user-library ids (p.… playlists, l.… albums, i.… songs).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "target_id": [
                            "type": "string",
                            "description": "Apple Music catalog or library id."
                        ],
                        "target_type": [
                            "type": "string",
                            "description": "song | album | playlist",
                            "enum": ["song", "album", "playlist"]
                        ],
                        "queue_mode": [
                            "type": "string",
                            "description": "replace (start fresh) or append (add to end of current queue). Default: replace.",
                            "enum": ["replace", "append"]
                        ]
                    ],
                    "required": ["target_id", "target_type"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "set_music_mood",
                "description": "Pick and play a track that fits a mood word — high-level shortcut. Use this whenever the user names a vibe rather than a specific track.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "mood": [
                            "type": "string",
                            "description": "Mood vocabulary: focused, calm, energetic, melancholy, upbeat, ambient, study, workout, sleep. Free-form synonyms (e.g. \"chill\", \"hype\") are accepted."
                        ],
                        "instrumental_only": [
                            "type": "boolean",
                            "description": "Force a vocal-free pick. Defaults to true for focus / study / sleep / ambient / calm moods."
                        ]
                    ],
                    "required": ["mood"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "create_playlist",
                "description": "Create a playlist in the user's Apple Music library and add the listed catalog track ids. iOS only.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Playlist name."],
                        "description": ["type": "string", "description": "Optional playlist description."],
                        "track_ids": [
                            "type": "array",
                            "description": "Apple Music catalog song ids (from find_music).",
                            "items": ["type": "string"]
                        ]
                    ],
                    "required": ["name", "track_ids"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "control_music",
                "description": "Queue control: pause / resume / skip / stop. Don't use pause for transient ducking under TTS or recording — that's automatic. Use stop to end playback entirely (auto-ducker won't auto-restart).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "description": "pause = pause queue; resume = resume after user-initiated pause; skip = skip to next track; stop = end playback and clear queue.",
                            "enum": ["pause", "resume", "skip", "stop"]
                        ]
                    ],
                    "required": ["action"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "get_music_status",
                "description": "Return what's currently playing: title, artist, instrumental hint, play/pause state, pause reason.",
                "parameters": ["type": "object", "properties": [:], "required": []]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "request_music_authorization",
                "description": "Explicitly trigger Apple Music's authorization dialog and return the resulting status.",
                "parameters": ["type": "object", "properties": [:], "required": []]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "find_music",
        "play_music",
        "set_music_mood",
        "create_playlist",
        "control_music",
        "get_music_status",
        "request_music_authorization"
    ]

    func handles(functionName: String) -> Bool {
        return MusicSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "find_music":
            if let q = call.arguments["query"] as? String, !q.isEmpty {
                return "searching Apple Music for \(q)"
            }
            return "searching Apple Music"
        case "play_music":
            return "starting playback"
        case "set_music_mood":
            if let m = call.arguments["mood"] as? String, !m.isEmpty {
                return "putting on something \(m)"
            }
            return "picking music"
        case "create_playlist":
            if let n = call.arguments["name"] as? String, !n.isEmpty {
                return "creating playlist \"\(n)\""
            }
            return "creating playlist"
        case "control_music":
            switch call.arguments["action"] as? String {
            case "pause":  return "pausing music"
            case "resume": return "resuming music"
            case "skip":   return "skipping track"
            case "stop":   return "stopping music"
            default:       return "controlling music"
            }
        case "get_music_status": return "checking music"
        default:                return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        let args = functionCall.arguments
        let name = functionCall.name

        switch name {

        case "find_music":
            guard let query = args["query"] as? String else {
                completion(missingArgs(for: name, expected: "query")); return
            }
            let limit = MusicSkill.intArg(args["limit"]) ?? 8
            let instrumental = (args["instrumental_only"] as? Bool) ?? false
            Task { @MainActor in
                do {
                    let json = try await MusicController.shared.findMusic(
                        query: query,
                        limit: limit,
                        instrumentalOnly: instrumental
                    )
                    completion(Self.functionMessage(name: name, json: json))
                } catch {
                    completion(Self.errorMessage(name: name, error: error))
                }
            }

        case "play_music":
            guard let targetId = args["target_id"] as? String,
                  let targetType = args["target_type"] as? String else {
                completion(missingArgs(for: name, expected: "target_id, target_type")); return
            }
            let mode = (args["queue_mode"] as? String) ?? "replace"
            Task { @MainActor in
                do {
                    let json = try await MusicController.shared.play(
                        targetId: targetId,
                        targetType: targetType,
                        queueMode: mode,
                        selectedBy: .agent
                    )
                    completion(Self.functionMessage(name: name, json: json))
                } catch {
                    completion(Self.errorMessage(name: name, error: error))
                }
            }

        case "set_music_mood":
            guard let mood = args["mood"] as? String else {
                completion(missingArgs(for: name, expected: "mood")); return
            }
            let instrumental = args["instrumental_only"] as? Bool
            Self.runWithTimeout(name: name, seconds: 25, completion: completion) {
                try await MusicController.shared.setMusicMood(
                    rawMood: mood,
                    instrumentalOverride: instrumental
                )
            }

        case "create_playlist":
            guard let playlistName = args["name"] as? String else {
                completion(missingArgs(for: name, expected: "name")); return
            }
            let description = args["description"] as? String
            let trackIds = (args["track_ids"] as? [Any])?.compactMap { $0 as? String } ?? []
            Task { @MainActor in
                do {
                    let json = try await MusicController.shared.createPlaylist(
                        name: playlistName,
                        description: description,
                        trackIds: trackIds
                    )
                    completion(Self.functionMessage(name: name, json: json))
                } catch {
                    completion(Self.errorMessage(name: name, error: error))
                }
            }

        case "control_music":
            guard let action = (args["action"] as? String)?.lowercased() else {
                completion(missingArgs(for: name, expected: "action (pause|resume|skip|stop)")); return
            }
            Task { @MainActor in
                do {
                    switch action {
                    case "pause":
                        MusicController.shared.pause(reason: .userExplicit)
                    case "resume":
                        try await MusicController.shared.userResume()
                    case "skip":
                        try await MusicController.shared.skip()
                    case "stop":
                        MusicController.shared.stop()
                    default:
                        completion(Self.functionMessage(name: name, json: [
                            "status": "error",
                            "error": "unknown_action",
                            "message": "action must be one of pause, resume, skip, stop (got '\(action)')."
                        ]))
                        return
                    }
                    completion(Self.functionMessage(name: name, json: ["status": "ok", "action": action]))
                } catch {
                    completion(Self.errorMessage(name: name, error: error))
                }
            }

        case "get_music_status":
            Task { @MainActor in
                let json = MusicController.shared.status()
                completion(Self.functionMessage(name: name, json: json))
            }

        case "request_music_authorization":
            Self.runWithTimeout(name: name, seconds: 25, completion: completion) {
                let authorized = await MusicController.shared.ensureAuthorized()
                let status = await MusicController.shared.lastAuthStatus
                return [
                    "status": "ok",
                    "authorized": authorized,
                    "auth_status": MusicController.statusName(status)
                ]
            }

        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the music tool '\(name)'."
            ))
        }
    }

    // MARK: - Helpers

    private func missingArgs(for name: String, expected: String) -> MessageStruct {
        return MessageStruct(
            role: "assistant",
            content: "I need \(expected) to call \(name). Please provide them."
        )
    }

    private static func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func functionMessage(name: String, json: [String: Any]) -> MessageStruct {
        let serialized: String
        if let data = try? JSONSerialization.data(withJSONObject: json, options: []),
           let str = String(data: data, encoding: .utf8) {
            serialized = str
        } else {
            serialized = "{}"
        }
        return MessageStruct(role: "function", content: serialized, name: name)
    }

    private static func errorMessage(name: String, error: Error) -> MessageStruct {
        let payload: [String: Any] = [
            "status": "error",
            "error": "music_skill_failure",
            "message": error.localizedDescription
        ]
        return functionMessage(name: name, json: payload)
    }

    /// Run an async MusicController operation under a wall-clock timeout and
    /// pipe the result (or a structured timeout error) back through the
    /// completion. This stops a hung MusicKit call — typically a stalled
    /// `prepareToPlay()` or a no-subscription `play()` — from freezing the
    /// agent loop indefinitely.
    private static func runWithTimeout(
        name: String,
        seconds: Double,
        completion: @escaping (MessageStruct) -> Void,
        operation: @escaping () async throws -> [String: Any]
    ) {
        Task { @MainActor in
            let didComplete = Atomic(false)

            let work = Task { @MainActor in
                do {
                    let json = try await operation()
                    if didComplete.swap(true) == false {
                        completion(functionMessage(name: name, json: json))
                    }
                } catch {
                    if didComplete.swap(true) == false {
                        completion(errorMessage(name: name, error: error))
                    }
                }
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if didComplete.swap(true) == false {
                    work.cancel()
                    let payload: [String: Any] = [
                        "status": "error",
                        "error": "music_skill_timeout",
                        "message": "The music tool didn't finish in \(Int(seconds))s — Apple Music may be unauthorized, the device may have no active subscription, or playback may not be available here."
                    ]
                    completion(functionMessage(name: name, json: payload))
                }
            }
        }
    }
}

/// Tiny main-actor-only flag the timeout helper uses to make sure
/// exactly one of {operation finished, timeout fired} reports back.
@MainActor
private final class Atomic {
    private var value: Bool
    init(_ initial: Bool) { value = initial }
    /// Set to true, return the previous value.
    func swap(_ new: Bool) -> Bool {
        let old = value
        value = new
        return old
    }
}
