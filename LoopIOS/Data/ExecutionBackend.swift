//
//  ExecutionBackend.swift
//  Loop
//
//  Backend selection + OpenClaw VM connection settings.
//
//  Loop runs from local/iCloud state by default. The user can opt into an
//  "OpenClaw VM" — an SSH-accessible workspace Loop uses as a remote backend
//  for conversation storage (and, over time, files / config / runtime).
//
//  Two pieces of state:
//    • `ExecutionBackendStore` — which backend is selected and whether the
//      OpenClaw connection last validated successfully. Device-local
//      (UserDefaults): a remote VM + its key are device-specific, so we don't
//      sync the selection across devices.
//    • `OpenClawConfigStore` — the SSH endpoint (host/port/username), private
//      key + passphrase (Keychain, never UserDefaults), and the remote
//      workspace path. Mirrors `SSHConfigStore`'s split-storage pattern.
//
//  Secrets live only in the Keychain and are never logged.
//
//  Pure Foundation so it compiles for the iOS, macOS, and visionOS targets.
//

import Foundation
import Security

// MARK: - Selection store

/// Tracks the selected execution backend and the OpenClaw validation flag.
/// Posts `didChangeNotification` on any mutation so Settings and the
/// conversation router can react.
final class ExecutionBackendStore {

    static let shared = ExecutionBackendStore()

    static let didChangeNotification = Notification.Name("ExecutionBackendStoreDidChange")

    private static let selectionKey = "loop.execution.backend"
    /// Set true only after a successful SSH + workspace validation; cleared
    /// whenever the connection settings change. Gates remote conversation
    /// creation so we never route writes to an unproven endpoint.
    private static let validatedKey = "loop.execution.openclaw.validated"

    private let defaults = UserDefaults.standard

    private init() {}

    /// The backend new conversations are created in. Defaults to `.local`.
    var selectedBackend: ConversationBackend {
        get {
            guard let raw = defaults.string(forKey: Self.selectionKey),
                  let backend = ConversationBackend(rawValue: raw) else {
                return .local
            }
            return backend
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.selectionKey)
            postChange()
        }
    }

    /// Whether the saved OpenClaw connection passed validation. Set by the
    /// settings screen after a successful reachability check.
    var openClawValidated: Bool {
        get { defaults.bool(forKey: Self.validatedKey) }
        set {
            defaults.set(newValue, forKey: Self.validatedKey)
            postChange()
        }
    }

    /// True when OpenClaw is selected, fully configured, and validated — the
    /// only state in which new conversations should be created remotely.
    /// Anything short of this degrades gracefully to local behavior.
    var isOpenClawActive: Bool {
        selectedBackend == .openclaw
            && OpenClawConfigStore.shared.config.isConfigured
            && openClawValidated
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

// MARK: - OpenClaw connection config

/// Connection + workspace settings for the OpenClaw VM. SSH auth reuses the
/// same public-key flow as `SSHConfigStore`; `sshConfig` adapts these fields
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
    /// Conversations are stored under `<workspacePath>/conversations/`.
    var workspacePath: String

    init(host: String = "",
         port: Int = 22,
         username: String = "",
         privateKey: String = "",
         passphrase: String = "",
         workspacePath: String = "") {
        self.host = host
        self.port = port
        self.username = username
        self.privateKey = privateKey
        self.passphrase = passphrase
        self.workspacePath = workspacePath
    }

    /// Reachable + has somewhere to write. Required before validation or
    /// remote conversation creation.
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

    /// Adapts the OpenClaw endpoint into the `SSHConfig` shape `SSHSkill`
    /// consumes for command execution. Not persisted by `SSHConfigStore`.
    var sshConfig: SSHConfig {
        SSHConfig(name: "OpenClaw VM",
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

/// Persists the single OpenClaw connection. Non-secret fields in UserDefaults;
/// private key + passphrase in the Keychain. Mirrors `SSHConfigStore`.
final class OpenClawConfigStore {

    static let shared = OpenClawConfigStore()

    static let didChangeNotification = Notification.Name("OpenClawConfigStoreDidChange")

    private static let metaKey = "loop.openclaw.connection.v1"
    private static let keyAccount = "loop.openclaw.privateKey"
    private static let passAccount = "loop.openclaw.passphrase"

    private let defaults = UserDefaults.standard

    private init() {
        load()
    }

    private(set) var config: OpenClawConfig = OpenClawConfig()

    /// Replaces the stored config. Persists non-secret fields to UserDefaults
    /// and secrets to the Keychain, then posts a change notification.
    func update(_ newConfig: OpenClawConfig) {
        config = newConfig
        save()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: Persistence

    private struct Meta: Codable {
        let host: String
        let port: Int
        let username: String
        let workspacePath: String
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.metaKey),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else {
            config = OpenClawConfig()
            return
        }
        config = OpenClawConfig(
            host: meta.host,
            port: meta.port,
            username: meta.username,
            privateKey: readKeychain(account: Self.keyAccount) ?? "",
            passphrase: readKeychain(account: Self.passAccount) ?? "",
            workspacePath: meta.workspacePath
        )
    }

    private func save() {
        let meta = Meta(host: config.host,
                        port: config.port,
                        username: config.username,
                        workspacePath: config.workspacePath)
        if let data = try? JSONEncoder().encode(meta) {
            defaults.set(data, forKey: Self.metaKey)
        }
        writeKeychain(account: Self.keyAccount, value: config.privateKey)
        writeKeychain(account: Self.passAccount, value: config.passphrase)
    }

    // MARK: Keychain helpers (generic-password, mirroring SSHConfigStore)

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
