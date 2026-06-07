//
//  iCloudKVSDefaults.swift
//  Loop (iOS)
//
//  Write-through facade over `UserDefaults.standard` + `NSUbiquitousKeyValueStore`
//  for the small set of UX preferences that should follow the user across
//  reinstalls and Apple-ID-linked devices: onboarding completion, TTS
//  provider/voice/speed, audio mute state, selected model.
//
//  Reads stay synchronous against `UserDefaults` so call sites don't change
//  their shape — KVS is only consulted via the external-change observer, which
//  mirrors remote writes back into UserDefaults and posts a local notification
//  for any VC that wants to refresh.
//
//  Why a thin wrapper rather than going all-in on KVS:
//  - UserDefaults reads are zero-async, KVS reads aren't guaranteed to be
//    populated until first sync.
//  - Keeping UserDefaults as the read path means existing call sites can flip
//    over piecemeal — they just swap `UserDefaults.standard` for
//    `iCloudKVSDefaults.shared` and the values now happen to also live in
//    iCloud.
//

import Foundation

final class iCloudKVSDefaults {

    static let shared = iCloudKVSDefaults()

    /// Posted after a KVS-external change has been mirrored into UserDefaults.
    /// userInfo["keys"] is `[String]` listing what changed — handy for VCs
    /// that observe a small subset.
    static let didChangeNotification = Notification.Name("iCloudKVSDefaultsDidChange")

    /// Keys this helper is allowed to mirror. Anything not in this set is a
    /// silent no-op for the KVS half — keeps us well under the 1 MB / 1024-key
    /// KVS quota and prevents accidental mirroring of runtime state.
    private static let mirroredKeys: Set<String> = [
        "loop.ios.onboarding.completed",
        "loop.ios.onboarding.lastStep",
        "ttsProvider",
        "speechSpeed",
        "audioMuted",
        "offlineVoiceIdentifier",
        "loop.modelSelection",
    ]

    /// Prefix-matched keys mirrored in addition to the exact-match set:
    ///  - `ttsVoice.<provider>` — per-provider TTS voice selection.
    ///  - `loop.ssh.` — saved SSH connection list + selected connection, so SSH
    ///    settings follow the user across devices (the private keys themselves
    ///    ride iCloud Keychain via the synchronizable Keychain items).
    private static let mirroredPrefixes: [String] = ["ttsVoice.", "loop.ssh."]

    private let local = UserDefaults.standard
    private let kvs = NSUbiquitousKeyValueStore.default
    private var bootstrapped = false

    private init() {}

    // MARK: - Bootstrap

    /// Install the external-change observer, pull whatever KVS already has
    /// down into UserDefaults, and ask the system for a fresh sync pulse.
    /// Safe to call multiple times — only the first call does work.
    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(kvsChangedExternally(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs
        )
        // Initial pull: anything KVS already knows about (e.g. set by a
        // different device, or restored after reinstall) gets copied into
        // UserDefaults so the next synchronous read picks it up.
        mirrorAllKVSKeysIntoLocal()
        kvs.synchronize()
    }

    /// Forces an upward sync pulse — useful from `applicationWillResignActive`
    /// so a turn's worth of writes ship to iCloud before the app suspends.
    func flush() {
        kvs.synchronize()
    }

    // MARK: - Reads (passthrough to UserDefaults)

    func bool(forKey key: String) -> Bool { local.bool(forKey: key) }
    func integer(forKey key: String) -> Int { local.integer(forKey: key) }
    func string(forKey key: String) -> String? { local.string(forKey: key) }
    func object(forKey key: String) -> Any? { local.object(forKey: key) }

    // MARK: - Writes (write-through)

    func set(_ value: Bool, forKey key: String) {
        local.set(value, forKey: key)
        if shouldMirror(key) {
            kvs.set(value, forKey: key)
        }
        postDidChange(for: key)
    }

    func set(_ value: Int, forKey key: String) {
        local.set(value, forKey: key)
        if shouldMirror(key) {
            kvs.set(Int64(value), forKey: key)
        }
        postDidChange(for: key)
    }

    func set(_ value: String?, forKey key: String) {
        local.set(value, forKey: key)
        if shouldMirror(key) {
            if let v = value {
                kvs.set(v, forKey: key)
            } else {
                kvs.removeObject(forKey: key)
            }
        }
        postDidChange(for: key)
    }

    /// Surface every local write through the same notification the KVS-external
    /// mirror uses, so observers (e.g. the nav-bar speaker button) refresh
    /// regardless of who wrote — including code paths that go through this
    /// facade directly rather than a dedicated typed store. Posted on the
    /// caller's thread; observers that touch UIKit should hop to main.
    private func postDidChange(for key: String) {
        NotificationCenter.default.post(
            name: iCloudKVSDefaults.didChangeNotification,
            object: nil,
            userInfo: ["keys": [key]]
        )
    }

    // MARK: - Private

    private func shouldMirror(_ key: String) -> Bool {
        if Self.mirroredKeys.contains(key) { return true }
        return Self.mirroredPrefixes.contains { key.hasPrefix($0) }
    }

    private func mirrorAllKVSKeysIntoLocal() {
        var changed: [String] = []
        for (key, value) in kvs.dictionaryRepresentation {
            guard shouldMirror(key) else { continue }
            local.set(value, forKey: key)
            changed.append(key)
        }
        if !changed.isEmpty {
            NotificationCenter.default.post(
                name: iCloudKVSDefaults.didChangeNotification,
                object: nil,
                userInfo: ["keys": changed]
            )
        }
    }

    @objc private func kvsChangedExternally(_ note: Notification) {
        // The system tells us which keys changed (and why) — we don't really
        // care about the reason, but we do want to mirror only the keys we
        // claim ownership of so a stray third-party write can't pollute
        // UserDefaults.
        let info = note.userInfo
        guard let raw = info?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
            return
        }
        var mirrored: [String] = []
        for key in raw where shouldMirror(key) {
            if let v = kvs.object(forKey: key) {
                local.set(v, forKey: key)
            } else {
                local.removeObject(forKey: key)
            }
            mirrored.append(key)
        }
        if !mirrored.isEmpty {
            NotificationCenter.default.post(
                name: iCloudKVSDefaults.didChangeNotification,
                object: nil,
                userInfo: ["keys": mirrored]
            )
        }
    }
}
