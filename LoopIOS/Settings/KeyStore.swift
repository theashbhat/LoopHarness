//
//  KeyStore.swift
//  Loop
//
//  Central store for user-supplied API keys (Deepgram, ElevenLabs, OpenAI,
//  Exa, Cursor, Obsidian relay). Values live in the Keychain so they survive
//  re-installs and stay off the filesystem. Reads fall back to Info.plist so
//  the dev build keeps working before the user has typed anything into the
//  in-app Settings pane.
//

import Foundation
import Security
import os

/// Persisted API key + base-URL bag. Single source of truth for every code
/// path that previously read `Bundle.main.object(forInfoDictionaryKey:)` for
/// these values.
final class KeyStore {

    /// Logical identity of each managed value. The `rawValue` doubles as both
    /// the Keychain account name and the legacy Info.plist key — keeping the
    /// two aligned lets old builds keep working until the user opens
    /// Settings > Keys for the first time.
    enum Key: String, CaseIterable {
        case deepgram       = "DEEPGRAM_API_KEY"
        case elevenLabs     = "ELEVEN_LABS_KEY"
        case exa            = "EXA_API_KEY"
        case openAI         = "OPENAI_API_KEY"
        case anthropic      = "ANTHROPIC_API_KEY"
        case fireworks      = "FIREWORKS_API_KEY"
        case cursor         = "CURSOR_API_KEY"
        case obsidianAPI    = "OBSIDIAN_API_KEY"
        case obsidianBaseURL = "OBSIDIAN_BASE_URL"
        case obsidianVaultName = "OBSIDIAN_VAULT_NAME"
        case slackUserToken = "SLACK_USER_TOKEN"
        case notionIntegrationToken = "NOTION_INTEGRATION_TOKEN"
        case githubPAT              = "GITHUB_PAT"
        case githubBaseURL          = "GITHUB_BASE_URL"
        case devin                  = "DEVIN_API_KEY"
        case devinOrgID             = "DEVIN_ORG_ID"
        case xAPIKey                = "X_API_KEY"
        case xAPISecret             = "X_API_SECRET"
        case xAccessToken           = "X_ACCESS_TOKEN"
        case xAccessTokenSecret     = "X_ACCESS_TOKEN_SECRET"
        case sfBayTransit           = "SF_BAY_511_API_KEY"
        case googleWorkspaceAccessToken  = "GOOGLE_WORKSPACE_ACCESS_TOKEN"
        case googleWorkspaceRefreshToken = "GOOGLE_WORKSPACE_REFRESH_TOKEN"
        case googleWorkspaceClientId     = "GOOGLE_WORKSPACE_CLIENT_ID"
        case googleWorkspaceClientSecret = "GOOGLE_WORKSPACE_CLIENT_SECRET"

        /// User-facing label shown in Settings.
        var displayName: String {
            switch self {
            case .deepgram:               return "Deepgram"
            case .elevenLabs:             return "ElevenLabs"
            case .exa:                    return "Exa"
            case .openAI:                 return "OpenAI"
            case .anthropic:              return "Anthropic"
            case .fireworks:              return "Fireworks"
            case .cursor:                 return "Cursor"
            case .obsidianAPI:            return "Obsidian API Key"
            case .obsidianBaseURL:        return "Obsidian Base URL"
            case .obsidianVaultName:      return "Obsidian Vault Name"
            case .slackUserToken:         return "Slack User Token"
            case .notionIntegrationToken: return "Notion Integration Token"
            case .githubPAT:              return "GitHub Personal Access Token"
            case .githubBaseURL:          return "GitHub API Base URL"
            case .devin:                  return "Devin API Key"
            case .devinOrgID:             return "Devin Organization ID"
            case .xAPIKey:                return "X API Key"
            case .xAPISecret:             return "X API Secret"
            case .xAccessToken:           return "X Access Token"
            case .xAccessTokenSecret:     return "X Access Token Secret"
            case .sfBayTransit:           return "511 SF Bay API Key"
            case .googleWorkspaceAccessToken:  return "Google Workspace Access Token"
            case .googleWorkspaceRefreshToken: return "Google Workspace Refresh Token"
            case .googleWorkspaceClientId:     return "Google Workspace Client ID"
            case .googleWorkspaceClientSecret: return "Google Workspace Client Secret"
            }
        }

        /// Short hint explaining what the value is for, shown under each row.
        var subtitle: String {
            switch self {
            case .deepgram:               return "Streaming STT + Aura TTS"
            case .elevenLabs:             return "Expressive TTS voices"
            case .exa:                    return "Web search + answer skill"
            case .openAI:                 return "Image generation + OpenAI TTS, and GPT models for the agent"
            case .anthropic:              return "Claude models for the agent"
            case .fireworks:              return "Fireworks inference platform (Kimi K2.6, etc.)"
            case .cursor:                 return "Cursor agent integration"
            case .obsidianAPI:            return "Bearer token for the Obsidian relay"
            case .obsidianBaseURL:        return "Public URL of the Obsidian relay"
            case .obsidianVaultName:      return "Vault name as shown in Obsidian — used to build obsidian:// links"
            case .slackUserToken:         return "xoxp-… token from your personal Slack app · read & send on your behalf"
            case .notionIntegrationToken: return "ntn_… token from a Notion internal integration · read, create, append pages"
            case .githubPAT:              return "github_pat_… / ghp_… token · read PRs/issues/files, review and merge with confirmation"
            case .githubBaseURL:          return "Optional. Defaults to https://api.github.com. Set for GitHub Enterprise (e.g. https://github.acme.com/api/v3)"
            case .devin:                  return "cog_… service-user API key from app.devin.ai → Settings → Service Users. Used with the Devin v3 API; pair it with the Devin Organization ID below."
            case .devinOrgID:             return "Required. Looks like org-…. Find it in app.devin.ai → Settings → Service Users (shown next to your service users)."
            case .xAPIKey:                return "OAuth 1.0a consumer key from developer.x.com → Your App → Keys & Tokens"
            case .xAPISecret:             return "OAuth 1.0a consumer secret — shown once when you regenerate the API key"
            case .xAccessToken:           return "User-level access token with read+write permission from developer.x.com"
            case .xAccessTokenSecret:     return "User-level access token secret — shown once at generation time"
            case .sfBayTransit:           return "Free API token from 511.org/open-data/token — powers real-time Muni arrival predictions"
            case .googleWorkspaceAccessToken:  return "OAuth2 access token from Google Cloud Console · powers Drive, Gmail, Calendar"
            case .googleWorkspaceRefreshToken: return "Optional. OAuth2 refresh token — lets the app request a new access token when the current one expires"
            case .googleWorkspaceClientId:     return "Optional. OAuth2 client id from Google Cloud Console — needed for token refresh"
            case .googleWorkspaceClientSecret: return "Optional. OAuth2 client secret from Google Cloud Console — needed for token refresh"
            }
        }
    }

    /// User-facing grouping of related `Key` values. The Settings UI lists
    /// one row per `Service` (e.g. "GitHub") and the editor stacks an input
    /// for each of the service's `keys` (PAT first, optional API base URL
    /// second). Adding a new key means: (a) add the `Key` case above, (b)
    /// either add a new `Service` case here or extend an existing one's `keys`.
    enum Service: String, CaseIterable {
        case openAI, anthropic, fireworks, deepgram, elevenLabs, exa
        case cursor, devin
        case github, slack, notion, obsidian
        case twitter
        case sfBayTransit
        case googleWorkspace

        /// Row title in the list + window title in the editor.
        var displayName: String {
            switch self {
            case .openAI:     return "OpenAI"
            case .anthropic:  return "Anthropic"
            case .fireworks:  return "Fireworks"
            case .deepgram:   return "Deepgram"
            case .elevenLabs: return "ElevenLabs"
            case .exa:        return "Exa"
            case .cursor:     return "Cursor"
            case .devin:      return "Devin"
            case .github:     return "GitHub"
            case .slack:      return "Slack"
            case .notion:     return "Notion"
            case .obsidian:   return "Obsidian"
            case .twitter:    return "X (Twitter)"
            case .sfBayTransit: return "511 SF Bay"
            case .googleWorkspace: return "Google Workspace"
            }
        }

        /// One-line summary of what the service powers, shown under the list
        /// row and at the top of the editor. Per-key purpose (e.g. "API base
        /// URL — optional, defaults to api.github.com") still comes from each
        /// `Key.subtitle` and is shown beside the matching input row.
        var summary: String {
            switch self {
            case .openAI:     return "Image generation, OpenAI TTS, and GPT models for the agent"
            case .anthropic:  return "Claude models for the agent"
            case .fireworks:  return "Fireworks inference platform — run Kimi K2.6 and other open models via Fireworks"
            case .deepgram:   return "Streaming STT + Aura TTS"
            case .elevenLabs: return "Expressive TTS voices"
            case .exa:        return "Web search + answer skill"
            case .cursor:     return "Dispatch coding tasks to Cursor cloud agents (opens PRs)"
            case .devin:      return "Dispatch coding tasks to Devin cloud agents (opens PRs, live transcript)"
            case .github:     return "Review/merge PRs, open PRs and issues, browse repos and notifications"
            case .slack:      return "Read channels/DMs/mentions, search, and send messages with confirmation"
            case .notion:     return "Read and write Notion pages and databases"
            case .obsidian:   return "Read and write your Obsidian vault through a self-hosted relay"
            case .twitter:    return "Post tweets to X (Twitter) with OAuth 1.0a"
            case .sfBayTransit: return "Real-time SF Muni bus/train arrival predictions via the 511 API"
            case .googleWorkspace: return "Google Drive, Gmail, and Calendar via OAuth2 access token"
            }
        }

        /// Ordered list of keys this service surfaces in its editor. The first
        /// element is the *primary* key — the one whose presence decides
        /// "configured" (✓ in the list). Every subsequent key is treated as
        /// optional from the UI's perspective; the skill itself decides what's
        /// truly required at call time.
        var keys: [Key] {
            switch self {
            case .openAI:     return [.openAI]
            case .anthropic:  return [.anthropic]
            case .fireworks:  return [.fireworks]
            case .deepgram:   return [.deepgram]
            case .elevenLabs: return [.elevenLabs]
            case .exa:        return [.exa]
            case .cursor:     return [.cursor]
            case .devin:      return [.devin, .devinOrgID]
            case .github:     return [.githubPAT, .githubBaseURL]
            case .slack:      return [.slackUserToken]
            case .notion:     return [.notionIntegrationToken]
            case .obsidian:   return [.obsidianAPI, .obsidianBaseURL, .obsidianVaultName]
            case .twitter:    return [.xAPIKey, .xAPISecret, .xAccessToken, .xAccessTokenSecret]
            case .sfBayTransit: return [.sfBayTransit]
            case .googleWorkspace: return [.googleWorkspaceAccessToken, .googleWorkspaceRefreshToken, .googleWorkspaceClientId, .googleWorkspaceClientSecret]
            }
        }

        /// Convenience: the key whose presence flips the list-row checkmark.
        var primaryKey: Key { keys[0] }

        /// Inverse lookup so deep-link callers (`showKeys(selecting: .slackUserToken)`,
        /// IntegrationsVC's per-row push) can hand us a specific `Key` and we
        /// route them to the right service editor — optionally focusing the
        /// matching input row inside it.
        static func containing(_ key: Key) -> Service? {
            return Service.allCases.first { $0.keys.contains(key) }
        }
    }

    /// Model-facing instruction returned when a skill needs a key the user
    /// hasn't configured yet. Skills wrap this string in a function-role
    /// result; the model then phrases the ask to the user in its own voice,
    /// promising the value will be stored securely in the iOS Keychain
    /// on-device. Centralised so every "missing key" path says the same
    /// thing in the same tone.
    static func missingKeyInstruction(for keys: [Key], purpose: String) -> String {
        let names: String
        switch keys.count {
        case 0:  names = "an API key"
        case 1:  names = "a \(keys[0].displayName)"
        case 2:  names = "a \(keys[0].displayName) and a \(keys[1].displayName)"
        default:
            let head = keys.dropLast().map { $0.displayName }.joined(separator: ", ")
            names = "a \(head), and a \(keys.last!.displayName)"
        }
        return """
        No API key is configured for \(purpose). Tell the user — in your own \
        words — that you don't currently have a way to do that, but if they \
        give you \(names), the app will store it securely in the iOS Keychain \
        on-device and you'll be able to help. They can add it in \
        Settings → Keys. Do not retry the tool until they've added a key.
        """
    }

    static let shared = KeyStore()

    /// Posted after a write so live screens (key list, in-flight clients)
    /// can refresh without polling.
    static let didChangeNotification = Notification.Name("KeyStoreDidChange")

    private static let service = "com.bhat.intel.keys"
    /// Gate for the one-shot migration that moves pre-existing non-sync
    /// Keychain entries into the synchronizable namespace so they ride iCloud
    /// Keychain (and therefore survive a delete/reinstall on devices signed
    /// into the same Apple ID). Bumped if the migration shape ever changes.
    private static let syncMigrationFlag = "loop.keystore.migratedToSync.v1"

    private static let log = Logger(subsystem: "com.bhat.intel", category: "KeyStore")

    /// Human-readable text for an `OSStatus` so swallowed Keychain failures
    /// show up as something actionable instead of a bare number.
    private static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }

    private init() {
        migrateToSynchronizableIfNeeded()
    }

    // MARK: - Reads

    /// Effective value used by app code. Keychain wins; falls back to the
    /// Info.plist literal so a fresh checkout still works before the user
    /// has touched the Settings pane.
    func value(for key: Key) -> String? {
        if let stored = keychainValue(for: key), !stored.isEmpty {
            return stored
        }
        return infoPlistValue(for: key)
    }

    /// Source of the currently-effective value. Lets Settings render a
    /// "Stored on this device" vs. "Bundled default" badge so users know
    /// whether they've overridden a key yet.
    enum Source { case keychain, infoPlist, missing }

    func source(for key: Key) -> Source {
        if let stored = keychainValue(for: key), !stored.isEmpty { return .keychain }
        if let _ = infoPlistValue(for: key) { return .infoPlist }
        return .missing
    }

    // MARK: - Writes

    /// Persists `value` to the Keychain. Passing nil/empty removes the
    /// stored override (reads will fall back to Info.plist). Returns `false`
    /// if the Keychain rejected the write/delete so callers can surface it
    /// instead of pretending the save stuck.
    @discardableResult
    func setValue(_ value: String?, for key: Key) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok: Bool
        if let v = trimmed, !v.isEmpty {
            ok = writeKeychain(value: v, account: key.rawValue) == errSecSuccess
        } else {
            ok = deleteKeychain(account: key.rawValue)
        }
        NotificationCenter.default.post(
            name: KeyStore.didChangeNotification,
            object: nil,
            userInfo: ["key": key.rawValue]
        )
        return ok
    }

    // MARK: - Display helpers

    /// "sk-…XXXX" style preview shown in lists. Keeps the last four chars so
    /// the user can tell which key is which without exposing the secret.
    func maskedPreview(for key: Key) -> String {
        guard let raw = value(for: key), !raw.isEmpty else { return "Not set" }
        // For URLs, show the host instead of masking — there's no secret to
        // hide and the URL is the whole point. Same for the Devin org id,
        // which is a `org-…` identifier (not a secret) the user needs to be
        // able to read back when verifying their setup.
        if key == .obsidianBaseURL || key == .obsidianVaultName || key == .githubBaseURL || key == .devinOrgID {
            return raw
        }
        let suffixLen = 4
        if raw.count <= suffixLen + 2 {
            return String(repeating: "•", count: max(raw.count, 4))
        }
        let suffix = raw.suffix(suffixLen)
        return "•••• \(suffix)"
    }

    // MARK: - Info.plist fallback

    private func infoPlistValue(for key: Key) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key.rawValue) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Treat unexpanded xcconfig placeholders (e.g. "$(OPENAI_API_KEY)")
        // as missing.
        if trimmed.isEmpty || trimmed.hasPrefix("$(") { return nil }
        return trimmed
    }

    // MARK: - Keychain primitives

    private func baseQuery(account: String) -> [String: Any] {
        // `kSecAttrSynchronizable` acts as a *filter*: queries without it only
        // match non-sync items, and queries with it only match sync items.
        // Putting it in the base query means reads, writes, updates, and
        // deletes all operate on the synchronizable bucket consistently — and
        // iCloud Keychain takes care of pushing them across the user's
        // devices and surviving a delete/reinstall.
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeyStore.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            // Synchronizable items only exist in the data-protection keychain.
            // iOS targets it by default; macOS defaults to the legacy
            // file-based keychain, so without this every write/read on the Mac
            // silently misses (and `SecItemAdd` returns errSecMissingEntitlement
            // for a non-sandboxed app). Pinning it makes both platforms agree.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Same as `baseQuery` but targets the *non-sync* bucket. Used only by the
    /// one-shot migration so we can find legacy device-local items written by
    /// an older build that didn't set `kSecAttrSynchronizable`.
    private func legacyBaseQuery(account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeyStore.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func keychainValue(for key: Key) -> String? {
        var query = baseQuery(account: key.rawValue)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    @discardableResult
    private func writeKeychain(value: String, account: String) -> OSStatus {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let updateAttrs: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return errSecSuccess }

        // No entry yet (errSecItemNotFound) — add a fresh one. Any other
        // SecItemUpdate failure also falls through to add; the real cause
        // surfaces in the SecItemAdd status logged below.
        var addAttrs = query
        addAttrs[kSecValueData as String] = data
        // `AfterFirstUnlock` (not the `ThisDeviceOnly` variant) is the right
        // accessibility class for synchronizable items: it allows background
        // reads (e.g. cron-triggered API calls) and is compatible with iCloud
        // Keychain sync. `ThisDeviceOnly` would silently block the sync.
        addAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
        if addStatus != errSecSuccess {
            KeyStore.log.error(
                "Keychain write for \(account, privacy: .public) failed — update=\(updateStatus) add=\(addStatus) (\(KeyStore.message(for: addStatus), privacy: .public))"
            )
        }
        return addStatus
    }

    @discardableResult
    private func deleteKeychain(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        // Nothing to delete is still a successful "no override" outcome.
        let ok = status == errSecSuccess || status == errSecItemNotFound
        if !ok {
            KeyStore.log.error(
                "Keychain delete for \(account, privacy: .public) failed — \(status) (\(KeyStore.message(for: status), privacy: .public))"
            )
        }
        return ok
    }

    // MARK: - One-shot migration to synchronizable

    /// Copy any pre-existing non-sync Keychain entries (written by an older
    /// build) into the synchronizable bucket so they ride iCloud Keychain
    /// going forward. Idempotent and gated by a UserDefaults flag, so the
    /// scan only runs once per device install.
    private func migrateToSynchronizableIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: KeyStore.syncMigrationFlag) { return }

        for key in Key.allCases {
            guard let legacy = legacyKeychainValue(for: key), !legacy.isEmpty else { continue }
            // Only drop the legacy device-local copy once the synchronizable
            // write actually succeeds — otherwise a failed migration would
            // destroy the user's key.
            if writeKeychain(value: legacy, account: key.rawValue) == errSecSuccess {
                SecItemDelete(legacyBaseQuery(account: key.rawValue) as CFDictionary)
            }
        }
        defaults.set(true, forKey: KeyStore.syncMigrationFlag)
    }

    private func legacyKeychainValue(for key: Key) -> String? {
        var query = legacyBaseQuery(account: key.rawValue)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }
}
