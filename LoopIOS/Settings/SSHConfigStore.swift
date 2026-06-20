//
//  SSHConfigStore.swift
//  Loop
//
//  Persists the user's SSH connections. Loop supports multiple saved
//  connections in a user-defined order; one is marked *active* (`selectedID`,
//  falling back to the first). The active connection is what `config` returns —
//  the one the `ssh_client` skill, the SSH tunnel, and the background handoff
//  connect to.
//
//  Non-secret fields (id, name, host, port, username) live in UserDefaults as
//  a JSON list; the private key and passphrase for each connection live in the
//  Keychain, keyed by the connection's UUID. `config` is a compatibility shim
//  that reads/writes the default connection, so existing single-config callers
//  keep working unchanged.
//

import Foundation
import os
import Security

struct SSHConfig: Identifiable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var privateKey: String
    var passphrase: String

    init(id: UUID = UUID(),
         name: String = "",
         host: String = "",
         port: Int = 22,
         username: String = "",
         privateKey: String = "",
         passphrase: String = "") {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.privateKey = privateKey
        self.passphrase = passphrase
    }

    var isConfigured: Bool {
        !host.isEmpty && !username.isEmpty && !privateKey.isEmpty
    }

    /// Friendly label, falling back to the host (or a placeholder) when unnamed.
    var displayName: String {
        if !name.isEmpty { return name }
        if !host.isEmpty { return host }
        return "Untitled connection"
    }

    /// `user@host` (with `:port` when non-standard) for the list subtitle.
    var endpointSummary: String {
        let user = username.isEmpty ? "" : "\(username)@"
        let portPart = (port == 22 || port == 0) ? "" : ":\(port)"
        return "\(user)\(host)\(portPart)"
    }
}

final class SSHConfigStore {

    static let shared = SSHConfigStore()

    // MARK: - Storage keys

    private static let listKey = "loop.ssh.connections.v2"
    private static let selectedKey = "loop.ssh.selectedID"

    // Legacy single-config keys (migrated on first load).
    private static let legacyHostKey = "loop.ssh.host"
    private static let legacyPortKey = "loop.ssh.port"
    private static let legacyUsernameKey = "loop.ssh.username"
    private static let legacyKeyAccount = "loop.ssh.privateKey"
    private static let legacyPassAccount = "loop.ssh.passphrase"

    /// Gate for the one-shot seed from build-time `Secrets.xcconfig` values
    /// (surfaced via Info.plist `$(SSH_*)` substitution). Set only after a seed
    /// actually lands, so the user's later edits/deletes aren't re-clobbered —
    /// but a fresh checkout that adds the xcconfig keys still seeds on next run.
    private static let seededFromInfoPlistFlag = "loop.ssh.seededFromInfoPlist.v1"

    private let defaults = UserDefaults.standard

    /// Saved connections, in user-defined display order.
    private(set) var connections: [SSHConfig] = []

    /// The user-selected active connection. `nil` falls back to the first
    /// connection, so existing installs keep their old "first = default" behavior
    /// until the user explicitly picks one.
    private(set) var selectedID: UUID?

    /// Posted after the connection list changes because of an iCloud sync from
    /// another device, so an open list view can refresh.
    static let didChangeNotification = Notification.Name("loop.ssh.connectionsDidChange")

    private init() {
        load()
        // Reload when SSH settings arrive from another device via iCloud KVS.
        NotificationCenter.default.addObserver(
            self, selector: #selector(kvsChanged(_:)),
            name: iCloudKVSDefaults.didChangeNotification, object: nil)
    }

    /// True while `save()` is writing, so the KVS write it performs doesn't
    /// re-enter `load()` (which would rebuild `connections` from the keychain
    /// mid-save — before the secrets are written — and clobber the in-memory key).
    private var isSaving = false

    @objc private func kvsChanged(_ note: Notification) {
        guard !isSaving else { return }   // ignore our own writes
        let keys = (note.userInfo?["keys"] as? [String]) ?? []
        guard keys.contains(where: { $0.hasPrefix("loop.ssh.") }) else { return }
        load()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// The id of the connection that's actually active right now — the explicit
    /// selection if still valid, otherwise the first connection.
    var effectiveSelectedID: UUID? {
        if let selectedID, connections.contains(where: { $0.id == selectedID }) {
            return selectedID
        }
        return connections.first?.id
    }

    /// Mark a connection active. Everything that reads `config` (ssh_client
    /// skill, SSH tunnel, the background handoff) immediately uses it.
    func select(id: UUID) {
        guard connections.contains(where: { $0.id == id }) else { return }
        selectedID = id
        iCloudKVSDefaults.shared.set(id.uuidString, forKey: Self.selectedKey)
    }

    /// Reorder the connection list (display order only; does not change which is
    /// active — that's `selectedID`).
    func move(from: Int, to: Int) {
        guard connections.indices.contains(from), to >= 0, to <= connections.count else { return }
        let item = connections.remove(at: from)
        connections.insert(item, at: min(to, connections.count))
        save()
    }

    // MARK: - Default-connection shim (legacy single-config API)

    /// The active connection (the selected one, or the first). Reads return an
    /// empty, unconfigured config when none exist; writes upsert the first.
    var config: SSHConfig {
        get { connections.first(where: { $0.id == effectiveSelectedID }) ?? SSHConfig() }
        set {
            if var first = connections.first {
                first.host = newValue.host
                first.port = newValue.port
                first.username = newValue.username
                first.privateKey = newValue.privateKey
                first.passphrase = newValue.passphrase
                if first.name.isEmpty { first.name = newValue.host }
                connections[0] = first
            } else {
                var created = newValue
                if created.name.isEmpty { created.name = newValue.host }
                connections = [created]
            }
            save()
        }
    }

    // MARK: - Collection API

    func connection(id: UUID) -> SSHConfig? {
        connections.first { $0.id == id }
    }

    /// True if a non-empty private key is actually stored in the keychain for
    /// this connection. The editor uses it to confirm a save really persisted
    /// (in-memory state always "has" the key, so it can't reveal a write failure).
    func privateKeyPersists(id: UUID) -> Bool {
        let account = Self.keyAccount(id)
        let value = readKeychain(account: account)
        Self.log.info("privateKeyPersists id=\(id.uuidString, privacy: .public) account=\(account, privacy: .public) found=\(value != nil, privacy: .public) len=\(value?.count ?? -1, privacy: .public)")
        return !(value ?? "").isEmpty
    }

    /// Inserts a new connection (appended) or updates an existing one in place.
    func addOrUpdate(_ connection: SSHConfig) {
        if let idx = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[idx] = connection
        } else {
            connections.append(connection)
        }
        save()
    }

    func delete(id: UUID) {
        guard let idx = connections.firstIndex(where: { $0.id == id }) else { return }
        let removed = connections.remove(at: idx)
        deleteSecrets(for: removed.id)
        if selectedID == removed.id {
            selectedID = nil
            iCloudKVSDefaults.shared.set(nil, forKey: Self.selectedKey)
        }
        save()
    }

    /// Promotes a connection to the default position (top of the list).
    func makeDefault(id: UUID) {
        guard let idx = connections.firstIndex(where: { $0.id == id }), idx != 0 else { return }
        let item = connections.remove(at: idx)
        connections.insert(item, at: 0)
        save()
    }

    // MARK: - Persistence

    private struct Meta: Codable {
        let id: UUID
        let name: String
        let host: String
        let port: Int
        let username: String
    }

    private func makeConfig(_ meta: Meta) -> SSHConfig {
        SSHConfig(
            id: meta.id,
            name: meta.name,
            host: meta.host,
            port: meta.port,
            username: meta.username,
            privateKey: readKeychain(account: Self.keyAccount(meta.id)) ?? "",
            passphrase: readKeychain(account: Self.passAccount(meta.id)) ?? "")
    }

    private func load() {
        if let raw = iCloudKVSDefaults.shared.string(forKey: Self.selectedKey) {
            selectedID = UUID(uuidString: raw)
        }
        // Preferred: the connection list synced via iCloud KVS (JSON string).
        if let json = iCloudKVSDefaults.shared.string(forKey: Self.listKey),
           let data = json.data(using: .utf8),
           let metas = try? JSONDecoder().decode([Meta].self, from: data) {
            connections = metas.map(makeConfig)
            return
        }
        // Legacy: an older build stored the list as `Data` in local UserDefaults.
        // Migrate it up to KVS (and `save()` re-writes the secrets as
        // synchronizable Keychain items so they start syncing too).
        if let data = defaults.data(forKey: Self.listKey),
           let metas = try? JSONDecoder().decode([Meta].self, from: data) {
            connections = metas.map(makeConfig)
            save()
            defaults.removeObject(forKey: Self.listKey)
            return
        }
        migrateLegacyIfPresent()
        // No stored or legacy connections: fall back to a connection baked in
        // at build time via Secrets.xcconfig (mirrors KeyStore's Info.plist
        // fallback for API keys).
        if connections.isEmpty {
            seedFromInfoPlistIfNeeded()
        }
    }

    /// One-time seed of a connection from the build-time `Secrets.xcconfig`
    /// values (Info.plist `$(SSH_*)`). Only runs when nothing else is stored,
    /// and only marks itself done once a config actually lands — so adding the
    /// xcconfig keys to an existing install still takes effect on the next run.
    private func seedFromInfoPlistIfNeeded() {
        guard !defaults.bool(forKey: Self.seededFromInfoPlistFlag) else { return }
        guard let seed = Self.infoPlistConfig() else { return }
        connections = [seed]
        save()
        defaults.set(true, forKey: Self.seededFromInfoPlistFlag)
        Self.log.info("Seeded SSH connection from Secrets.xcconfig host=\(seed.host, privacy: .public) user=\(seed.username, privacy: .public)")
    }

    private func save() {
        isSaving = true
        defer { isSaving = false }

        // Write secrets FIRST so anything that reads back (incl. a reload) sees
        // the real keys. (The KVS write below fires didChangeNotification; the
        // isSaving guard suppresses the re-entrant load, but ordering is correct
        // regardless.)
        for c in connections {
            writeKeychain(account: Self.keyAccount(c.id), value: c.privateKey)
            writeKeychain(account: Self.passAccount(c.id), value: c.passphrase)
        }

        let metas = connections.map {
            Meta(id: $0.id, name: $0.name, host: $0.host, port: $0.port, username: $0.username)
        }
        if let data = try? JSONEncoder().encode(metas),
           let json = String(data: data, encoding: .utf8) {
            iCloudKVSDefaults.shared.set(json, forKey: Self.listKey)
        }
    }

    /// One-time migration of the old single-connection layout into the list.
    private func migrateLegacyIfPresent() {
        let host = defaults.string(forKey: Self.legacyHostKey) ?? ""
        let username = defaults.string(forKey: Self.legacyUsernameKey) ?? ""
        let key = readKeychain(account: Self.legacyKeyAccount) ?? ""
        let pass = readKeychain(account: Self.legacyPassAccount) ?? ""

        guard !host.isEmpty || !username.isEmpty || !key.isEmpty else {
            connections = []
            return
        }

        let port = defaults.integer(forKey: Self.legacyPortKey)
        let migrated = SSHConfig(
            id: UUID(),
            name: host,
            host: host,
            port: port == 0 ? 22 : port,
            username: username,
            privateKey: key,
            passphrase: pass)
        connections = [migrated]
        save()

        // Clear legacy storage so it isn't re-read or left dangling.
        defaults.removeObject(forKey: Self.legacyHostKey)
        defaults.removeObject(forKey: Self.legacyPortKey)
        defaults.removeObject(forKey: Self.legacyUsernameKey)
        deleteKeychain(account: Self.legacyKeyAccount)
        deleteKeychain(account: Self.legacyPassAccount)
    }

    // MARK: - Build-time config (Secrets.xcconfig → Info.plist)

    /// A non-empty Info.plist string, treating an unexpanded `$(VAR)`
    /// placeholder (the xcconfig key was left blank) as missing — same rule
    /// KeyStore uses for API keys.
    private static func infoPlistString(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("$(") { return nil }
        return trimmed
    }

    /// Builds a connection from the `SSH_*` build-time values, or nil when the
    /// minimum (host + username) isn't present. Port defaults to 22; the name
    /// falls back to the host.
    private static func infoPlistConfig() -> SSHConfig? {
        guard let host = infoPlistString("SSH_HOST"),
              let username = infoPlistString("SSH_USERNAME") else { return nil }
        let port = infoPlistString("SSH_PORT").flatMap { Int($0) } ?? 22
        let name = infoPlistString("SSH_NAME") ?? host
        let privateKey = infoPlistString("SSH_PRIVATE_KEY_B64").flatMap(decodeBase64Key) ?? ""
        let passphrase = infoPlistString("SSH_PASSPHRASE") ?? ""
        return SSHConfig(
            name: name, host: host, port: port, username: username,
            privateKey: privateKey, passphrase: passphrase)
    }

    /// Decodes a base64-encoded private key. Accepts both standard base64 and
    /// base64url (`-`/`_`), so the value can be encoded with `base64 | tr '+/'
    /// '-_'` to avoid xcconfig truncating it at a `//` (which it reads as a
    /// comment). Tolerates embedded whitespace and missing padding.
    private static func decodeBase64Key(_ raw: String) -> String? {
        var b64 = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard !b64.isEmpty else { return nil }
        let remainder = b64.count % 4
        if remainder > 0 { b64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: b64),
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    private static func keyAccount(_ id: UUID) -> String { "loop.ssh.key.\(id.uuidString)" }
    private static func passAccount(_ id: UUID) -> String { "loop.ssh.pass.\(id.uuidString)" }

    private func deleteSecrets(for id: UUID) {
        deleteKeychain(account: Self.keyAccount(id))
        deleteKeychain(account: Self.passAccount(id))
    }

    // MARK: - Keychain helpers

    /// Service namespace for the (best-effort) iCloud-synced copy.
    private static let service = "com.bhat.intel.ssh"

    /// OSStatus of the last private-key write attempt (for editor diagnostics).
    private(set) var lastKeyWriteStatus: OSStatus = errSecSuccess

    /// Local-first storage for SSH secrets. The PRIMARY copy is a protected file
    /// in the app container — reliable regardless of Keychain/iCloud state (the
    /// Keychain was silently failing to persist the multi-line private key on
    /// some devices, while everything else — stored via iCloud KVS — saved fine).
    /// We ALSO best-effort write the Keychain (local item + iCloud-synchronizable
    /// mirror) so secrets ride the Keychain / sync across devices when that works.
    private func writeKeychain(account: String, value: String) {
        guard !value.isEmpty else {
            deleteKeychain(account: account)
            return
        }
        // Primary: protected local file.
        let savedFile = setFileSecret(account: account, value: value)

        // Best-effort: Keychain (plain local) + iCloud-synchronizable mirror.
        let data = Data(value.utf8)
        SecItemDelete(plainQuery(account: account) as CFDictionary)
        var add = plainQuery(account: account)
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
        mirrorToSync(account: account, data: data)

        let keychainReadable = (readData(plainQuery(account: account)) != nil)
        let fileReadback = (fileSecret(account: account) != nil)
        let persisted = savedFile || keychainReadable
        lastKeyWriteStatus = persisted ? errSecSuccess : errSecIO
        Self.log.info("writeKeychain account=\(account, privacy: .public) valueLen=\(value.count, privacy: .public) savedFile=\(savedFile, privacy: .public) fileReadback=\(fileReadback, privacy: .public) keychainReadable=\(keychainReadable, privacy: .public) file=\(Self.secretsFileURL.path, privacy: .public)")
        if !persisted {
            Self.log.error("SSH secret write failed for \(account, privacy: .public)")
        }
    }

    private func readKeychain(account: String) -> String? {
        // 1. Protected local file (primary).
        if let s = fileSecret(account: account) { return s }
        // 2. Keychain: plain device-local.
        if let s = readData(plainQuery(account: account)) { return s }
        // 3. Keychain: item synced in from another device (service-scoped, any sync).
        if let s = readData([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: Self.service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
        ]) { return s }
        // 4. Keychain: legacy items from older builds (no service, any sync).
        if let s = readData([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]) { return s }
        return nil
    }

    private func deleteKeychain(account: String) {
        setFileSecret(account: account, value: nil)
        SecItemDelete(plainQuery(account: account) as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: Self.service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ] as CFDictionary)
    }

    // MARK: - Local secret file (primary store)

    /// Protected JSON file holding `account -> secret`. Lives in Application
    /// Support (app sandbox), written with complete file protection (encrypted
    /// at rest while the device is locked). Local-only — never leaves the device.
    private static var secretsFileURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("LoopSSH", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("secrets.json")
    }

    private func loadSecretsFile() -> [String: String] {
        guard let data = try? Data(contentsOf: Self.secretsFileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func fileSecret(account: String) -> String? {
        let v = loadSecretsFile()[account]
        return (v?.isEmpty == false) ? v : nil
    }

    @discardableResult
    private func setFileSecret(account: String, value: String?) -> Bool {
        var dict = loadSecretsFile()
        if let value, !value.isEmpty { dict[account] = value } else { dict.removeValue(forKey: account) }
        guard let data = try? JSONEncoder().encode(dict) else { return false }
        do {
            try data.write(to: Self.secretsFileURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            Self.log.error("SSH secrets file write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Keychain primitives

    /// The original device-local layout: class + account only.
    private func plainQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
    }

    /// Read a non-empty UTF-8 value matching `query`, or nil.
    private func readData(_ query: [String: Any]) -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty else {
            return nil
        }
        return s
    }

    /// Best-effort write into the iCloud-synchronizable bucket for cross-device
    /// sync. Failures are ignored — the plain local copy is the source of truth.
    private func mirrorToSync(account: String, data: Data) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: Self.service,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess {
            return
        }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static let log = Logger(subsystem: "com.bhat.intel", category: "SSHConfigStore")
}
