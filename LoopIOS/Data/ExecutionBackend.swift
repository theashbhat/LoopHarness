//
//  ExecutionBackend.swift
//  Loop
//
//  Execution backends: where Loop runs from.
//
//  Loop always has a built-in **Local** backend (on-device / iCloud state). On
//  top of that the user can add any number of **remote SSH VM** backends, each
//  with its own SSH endpoint and workspace path. One backend is *selected* at a
//  time; new conversations are created on it.
//
//  Each backend keeps its own isolated set of conversations: a conversation is
//  stamped with the owning backend's id (`SimpleConversation.backend`), and the
//  router resolves reads/writes by that id. Switching the selected backend never
//  moves or mixes conversations between backends.
//
//  Two pieces of state, both owned by `ExecutionBackendStore`:
//    • The ordered list of remote backends (the local one is implicit) plus the
//      currently selected id. Device-local (UserDefaults): a remote VM + its key
//      are device-specific, so we don't sync the selection across devices.
//    • Per-backend SSH connection settings. Non-secret fields (host/port/user/
//      workspace) live in UserDefaults keyed by backend id; the private key +
//      passphrase live in the Keychain, keyed by backend id. Secrets are never
//      written to UserDefaults and never logged. Mirrors `SSHConfigStore`'s
//      split-storage pattern.
//
//  Pure Foundation so it compiles for the iOS, macOS, and visionOS targets.
//

import Foundation
import Security

// MARK: - Backend entry model

/// One execution backend the user can run Loop from. There is always a built-in
/// `local` backend that can't be deleted; remote backends are SSH-accessible VMs
/// the user adds, each with its own id and connection settings.
struct ExecutionBackend: Identifiable, Equatable {

    /// Stable identifier and conversation marker. `localID` for the built-in
    /// local backend; `legacyRemoteID` for the single OpenClaw VM that predates
    /// this list (migrated in place so its existing conversations keep
    /// resolving); a fresh UUID string for any backend added afterwards.
    let id: String
    var name: String
    /// SSH endpoint + workspace. Ignored for the local backend.
    var config: OpenClawConfig

    /// The built-in local backend's id (and its conversation marker).
    static let localID = "local"
    /// Id of the single OpenClaw VM from before backends became a list. Kept so
    /// conversations stamped `"openclaw"` still resolve after migration.
    static let legacyRemoteID = "openclaw"

    init(id: String = UUID().uuidString,
         name: String,
         config: OpenClawConfig = OpenClawConfig()) {
        self.id = id
        self.name = name
        self.config = config
    }

    /// The built-in local backend.
    static var local: ExecutionBackend {
        ExecutionBackend(id: localID, name: "Local", config: OpenClawConfig())
    }

    var isLocal: Bool { id == Self.localID }
    /// Every backend except Local can be removed.
    var isDeletable: Bool { !isLocal }

    /// Friendly label, falling back to the endpoint (or a placeholder).
    var displayName: String {
        if !name.isEmpty { return name }
        if !config.host.isEmpty { return config.host }
        return "Untitled backend"
    }

    /// Subtitle for the list row.
    var subtitle: String {
        if isLocal { return "On device / iCloud" }
        let summary = config.endpointSummary
        return summary.isEmpty ? "Not configured" : summary
    }
}

// MARK: - Backend store (list + selection + validation)

/// Owns the list of remote backends, the selected backend, and the per-backend
/// validation flag. Posts `didChangeNotification` on any mutation so Settings
/// and the conversation manager can react.
final class ExecutionBackendStore {

    static let shared = ExecutionBackendStore()

    static let didChangeNotification = Notification.Name("ExecutionBackendStoreDidChange")

    // MARK: Storage keys

    private static let listKey = "loop.execution.backends.v1"
    private static let selectionKey = "loop.execution.backend.selectedID"
    private static let validatedKey = "loop.execution.backend.validatedIDs"

    // Legacy single-OpenClaw layout, migrated once on first load.
    private static let legacySelectionKey = "loop.execution.backend"
    private static let legacyValidatedKey = "loop.execution.openclaw.validated"
    private static let legacyMetaKey = "loop.openclaw.connection.v1"
    private static let legacyKeyAccount = "loop.openclaw.privateKey"
    private static let legacyPassAccount = "loop.openclaw.passphrase"

    private let defaults = UserDefaults.standard

    /// Remote backends only, in add order (the local backend is implicit).
    private(set) var remoteBackends: [ExecutionBackend] = []

    private init() {
        load()
    }

    // MARK: - Collection

    /// All backends, Local first, then remotes in add order.
    var backends: [ExecutionBackend] {
        [.local] + remoteBackends
    }

    func backend(id: String) -> ExecutionBackend? {
        backends.first { $0.id == id }
    }

    /// Inserts a new remote backend or updates an existing one in place.
    /// Local is implicit and can't be added/updated through here.
    @discardableResult
    func addOrUpdate(_ backend: ExecutionBackend) -> ExecutionBackend {
        guard !backend.isLocal else { return .local }
        if let idx = remoteBackends.firstIndex(where: { $0.id == backend.id }) {
            remoteBackends[idx] = backend
        } else {
            remoteBackends.append(backend)
        }
        save()
        postChange()
        return backend
    }

    /// Removes a remote backend and its secrets. Local can't be deleted. If the
    /// deleted backend was selected, selection falls back to Local.
    func delete(id: String) {
        guard id != ExecutionBackend.localID,
              let idx = remoteBackends.firstIndex(where: { $0.id == id }) else { return }
        let removed = remoteBackends.remove(at: idx)
        deleteSecrets(for: removed.id)
        setValidatedFlag(false, for: removed.id)
        #if os(iOS)
        OpenClawMessagePoller.shared.clearState(forBackend: removed.id)
        #endif
        if rawSelectedID == id {
            defaults.set(ExecutionBackend.localID, forKey: Self.selectionKey)
        }
        save()
        postChange()
    }

    // MARK: - Selection

    private var rawSelectedID: String {
        defaults.string(forKey: Self.selectionKey) ?? ExecutionBackend.localID
    }

    /// Currently selected backend. Defaults to Local; falls back to Local if the
    /// stored id no longer exists (e.g. it was deleted on another device).
    var selectedBackend: ExecutionBackend {
        backend(id: rawSelectedID) ?? .local
    }

    var selectedBackendID: String { selectedBackend.id }

    /// Selects a backend by id. Unknown ids are ignored.
    func select(id: String) {
        guard backend(id: id) != nil else { return }
        defaults.set(id, forKey: Self.selectionKey)
        postChange()
    }

    // MARK: - Validation (per backend id)

    private var validatedIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.validatedKey) ?? [])
    }

    /// Whether the backend's saved connection last passed validation.
    func isValidated(id: String) -> Bool {
        validatedIDs.contains(id)
    }

    /// Records (or clears) a backend's validated state and notifies observers.
    func setValidated(_ value: Bool, for id: String) {
        setValidatedFlag(value, for: id)
        postChange()
    }

    private func setValidatedFlag(_ value: Bool, for id: String) {
        var ids = validatedIDs
        if value { ids.insert(id) } else { ids.remove(id) }
        defaults.set(Array(ids), forKey: Self.validatedKey)
    }

    // MARK: - Active backend

    /// The selected remote backend, but only when it's configured and validated
    /// — i.e. the backend new conversations should be created on remotely. nil
    /// means Local is active, which is the graceful default whenever the
    /// selected remote isn't ready (unconfigured, unvalidated, or it's Local).
    var activeRemoteBackend: ExecutionBackend? {
        let sel = selectedBackend
        guard !sel.isLocal, sel.config.isConfigured, isValidated(id: sel.id) else { return nil }
        return sel
    }

    /// Id of the active remote backend, or nil when Local is active.
    var activeRemoteBackendID: String? { activeRemoteBackend?.id }

    // MARK: - Persistence

    private struct Meta: Codable {
        let id: String
        let name: String
        let host: String
        let port: Int
        let username: String
        let workspacePath: String
        /// Optional for backward compatibility: entries written before the
        /// OpenClaw-CLI migration decode as nil and default to `main`.
        var agentId: String?
    }

    private func load() {
        if let data = defaults.data(forKey: Self.listKey),
           let metas = try? JSONDecoder().decode([Meta].self, from: data) {
            remoteBackends = metas.map { meta in
                ExecutionBackend(
                    id: meta.id,
                    name: meta.name,
                    config: OpenClawConfig(
                        host: meta.host,
                        port: meta.port,
                        username: meta.username,
                        privateKey: readKeychain(account: Self.keyAccount(meta.id)) ?? "",
                        passphrase: readKeychain(account: Self.passAccount(meta.id)) ?? "",
                        workspacePath: meta.workspacePath,
                        agentId: meta.agentId ?? "main"))
            }
            return
        }
        migrateLegacyIfPresent()
    }

    private func save() {
        let metas = remoteBackends.map {
            Meta(id: $0.id, name: $0.name,
                 host: $0.config.host, port: $0.config.port,
                 username: $0.config.username, workspacePath: $0.config.workspacePath,
                 agentId: $0.config.trimmedAgentId)
        }
        if let data = try? JSONEncoder().encode(metas) {
            defaults.set(data, forKey: Self.listKey)
        }
        for b in remoteBackends {
            writeKeychain(account: Self.keyAccount(b.id), value: b.config.privateKey)
            writeKeychain(account: Self.passAccount(b.id), value: b.config.passphrase)
        }
    }

    /// One-time migration of the old single-OpenClaw layout into the list. The
    /// migrated backend keeps the legacy id (`openclaw`) so conversations stamped
    /// with that marker keep resolving to it.
    private func migrateLegacyIfPresent() {
        guard let data = defaults.data(forKey: Self.legacyMetaKey),
              let meta = try? JSONDecoder().decode(LegacyMeta.self, from: data),
              !(meta.host.isEmpty && meta.username.isEmpty) else {
            remoteBackends = []
            return
        }

        let cfg = OpenClawConfig(
            host: meta.host,
            port: meta.port == 0 ? 22 : meta.port,
            username: meta.username,
            privateKey: readKeychain(account: Self.legacyKeyAccount) ?? "",
            passphrase: readKeychain(account: Self.legacyPassAccount) ?? "",
            workspacePath: meta.workspacePath)
        let migrated = ExecutionBackend(id: ExecutionBackend.legacyRemoteID,
                                        name: "OpenClaw VM", config: cfg)
        remoteBackends = [migrated]
        save() // writes secrets under the new per-id accounts

        // Carry over the prior selection + validation.
        if defaults.string(forKey: Self.legacySelectionKey) == "openclaw" {
            defaults.set(migrated.id, forKey: Self.selectionKey)
        }
        if defaults.bool(forKey: Self.legacyValidatedKey) {
            setValidatedFlag(true, for: migrated.id)
        }

        // Clear legacy storage so it isn't re-read or left dangling.
        defaults.removeObject(forKey: Self.legacyMetaKey)
        defaults.removeObject(forKey: Self.legacyValidatedKey)
        deleteKeychain(account: Self.legacyKeyAccount)
        deleteKeychain(account: Self.legacyPassAccount)
    }

    private struct LegacyMeta: Codable {
        let host: String
        let port: Int
        let username: String
        let workspacePath: String
    }

    private static func keyAccount(_ id: String) -> String { "loop.execution.key.\(id)" }
    private static func passAccount(_ id: String) -> String { "loop.execution.pass.\(id)" }

    private func deleteSecrets(for id: String) {
        deleteKeychain(account: Self.keyAccount(id))
        deleteKeychain(account: Self.passAccount(id))
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: - Keychain helpers (generic-password, mirroring SSHConfigStore)

    private func readKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeKeychain(account: String, value: String) {
        deleteKeychain(account: account)
        guard !value.isEmpty else { return }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    private func deleteKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Remote connection config

/// Connection + workspace settings for a remote SSH VM backend. SSH auth reuses
/// the same public-key flow as `SSHConfigStore`; `sshConfig` adapts these fields
/// for `SSHSkill`.
struct OpenClawConfig: Equatable {
    var host: String
    var port: Int
    var username: String
    /// PEM private key. Stored in the Keychain, never UserDefaults.
    var privateKey: String
    /// Optional key passphrase. Keychain-backed.
    var passphrase: String
    /// Absolute (or `~`-relative) path to the workspace directory on the VM.
    /// Used by the Files/Skills tabs (`<workspacePath>/skills`, etc). Conversations
    /// are no longer stored here — they come from OpenClaw's own session store
    /// (`~/.openclaw/agents/<agentId>/sessions`), driven through the `openclaw` CLI.
    var workspacePath: String
    /// OpenClaw agent id whose sessions Loop reads/drives (the `<agentId>` in
    /// `~/.openclaw/agents/<agentId>/sessions`). Defaults to `main`.
    var agentId: String

    init(host: String = "",
         port: Int = 22,
         username: String = "",
         privateKey: String = "",
         passphrase: String = "",
         workspacePath: String = "",
         agentId: String = "main") {
        self.host = host
        self.port = port
        self.username = username
        self.privateKey = privateKey
        self.passphrase = passphrase
        self.workspacePath = workspacePath
        self.agentId = agentId
    }

    /// Agent id with surrounding whitespace removed, falling back to `main` when
    /// empty so a blank field never produces a malformed session path.
    var trimmedAgentId: String {
        let a = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? "main" : a
    }

    /// Reachable + has somewhere to write. Required before validation or remote
    /// conversation creation.
    var isConfigured: Bool {
        !host.isEmpty && !username.isEmpty && !privateKey.isEmpty && !trimmedWorkspacePath.isEmpty
    }

    /// Workspace path with surrounding whitespace and any trailing slash
    /// removed, so callers can append `/conversations` safely.
    var trimmedWorkspacePath: String {
        var p = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Adapts the endpoint into the `SSHConfig` shape `SSHSkill` consumes for
    /// command execution. Not persisted by `SSHConfigStore`.
    var sshConfig: SSHConfig {
        SSHConfig(name: "Execution Backend",
                  host: host,
                  port: port,
                  username: username,
                  privateKey: privateKey,
                  passphrase: passphrase)
    }

    var endpointSummary: String {
        let user = username.isEmpty ? "" : "\(username)@"
        let portPart = (port == 22 || port == 0) ? "" : ":\(port)"
        return "\(user)\(host)\(portPart)"
    }
}
