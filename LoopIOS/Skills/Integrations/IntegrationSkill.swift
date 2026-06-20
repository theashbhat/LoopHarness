//
//  IntegrationSkill.swift
//  Loop
//
//  Lets the user manage integrations and API keys by talking to the agent
//  rather than navigating to Settings → Integrations / Settings → Keys.
//
//  The skill is a thin façade over primitives that already exist:
//    - CalendarSkill.shared.{currentAuthorizationStatus, requestAccessIfNeeded}
//      for the only OS-permission integration we ship today.
//    - KeyStore.shared for credential reads/writes (Keychain-backed; shared
//      across iOS and Mac).
//    - NotificationCenter for asking the platform host (MessagingVC on iOS,
//      AppDelegate on Mac) to surface the in-app Integrations panel or open
//      the relevant system Privacy pane.
//
//  Skill never imports UIKit or AppKit; deep-link URLs are exposed as strings
//  in the userInfo dictionary so the host can resolve them with its own
//  workspace API.
//

import Foundation
import EventKit
#if canImport(HealthKit)
import HealthKit
#endif

/// Posted by the skill when the model invokes `open_integration_settings` so
/// the platform host can present the right surface.
///
/// `userInfo` keys:
/// - `"target"`: `"in_app"` (default — open the IntegrationsVC / window) or
///   `"calendar_privacy"` (open the system Privacy & Security → Calendars
///   pane).
/// - `"integrationName"`: optional name to scroll/highlight on the in-app
///   panel. v1 hosts ignore this; reserved for future use.
extension Notification.Name {
    static let integrationSkillRequestedSettings =
        Notification.Name("loop.integrations.openPanelRequested")
}

final class IntegrationSkill {

    static let shared = IntegrationSkill()
    private init() {}

    // MARK: - System prompt

    static let systemPromptFragment: String = """
You can manage the user's integrations and API keys directly:
- list_integrations: enumerate the integrations Loop knows about (Google Calendar via EventKit, Notion, Gmail, Slack, Google Workspace, Apple Health) and their current connection state. Notion, Slack, and Google Workspace are token-backed (ntn_… integration token, xoxp- user token, and OAuth2 access token respectively, all stored in the Keychain) — status flips to "connected" once the user pastes the relevant key. Apple Health is OS-permission-backed (like Calendar).
- connect_integration: kick off the connect flow for a named integration. For Google Calendar this triggers the OS permission prompt when status is undetermined; if access was previously denied, the tool returns a hint telling you to call open_integration_settings with target="calendar_privacy". For Slack, this returns a `needs_api_key` payload with instructions to walk the user through minting an xoxp- token and pasting it in Settings → Keys → Slack User Token.
- open_integration_settings: surfaces the in-app Integrations panel (target="in_app", default) or the system Privacy pane (target="calendar_privacy"). Use this when the user says "open integrations" / "let me see my settings".
- list_api_keys: reports which API keys are currently set (Deepgram, ElevenLabs, OpenAI, Exa, Cursor, Obsidian). Values are never returned — only whether each is present.
- set_api_key: store a value in the keychain. Accepts either the canonical name ("OPENAI_API_KEY") or a friendly alias ("openai"). IMPORTANT: voice transcription is lossy — always read the value back to the user character-by-character and confirm before calling this tool. If the user typed the value, you can call it directly.

Tips:
- For Calendar, prefer connect_integration over instructing the user to navigate menus.
- API keys are case-sensitive and usually look like "sk-…" or a long hex string — if you're unsure of any character, ask the user to spell or retype it.
- The existing Settings → Integrations / Settings → Keys panels still work; these tools are an additive voice path.
"""

    // MARK: - Tool catalog

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "list_integrations",
                "description": "List the integrations Loop supports and their current connection state. Use to answer 'is my calendar connected' or 'what integrations do I have'.",
                "parameters": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "connect_integration",
                "description": "Kick off the connect flow for a named integration. For Google Calendar this triggers the OS permission prompt when needed. Returns a status string the model can relay to the user.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "Integration identifier. One of: calendar, notion, gmail, slack, health."
                        ]
                    ],
                    "required": ["name"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "open_integration_settings",
                "description": "Surface the integrations settings UI. Defaults to the in-app Integrations panel; pass target=\"calendar_privacy\" to open the system Privacy & Security → Calendars pane (useful when Calendar access has been denied).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "target": [
                            "type": "string",
                            "description": "Where to open. \"in_app\" (default) opens Loop's own Integrations panel. \"calendar_privacy\" opens the system Privacy pane for Calendars."
                        ],
                        "integration_name": [
                            "type": "string",
                            "description": "Optional name of the integration to focus on (e.g. \"calendar\"). Currently informational only."
                        ]
                    ],
                    "required": []
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "list_api_keys",
                "description": "List the API keys Loop manages and whether each is currently set. Values are never returned, only presence.",
                "parameters": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "set_api_key",
                "description": "Persist an API key in the keychain. Accepts canonical names like \"OPENAI_API_KEY\" or friendly aliases like \"openai\". Pass an empty string to clear the value. IMPORTANT: read the value back to the user before calling — voice transcription of long secrets is lossy.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "Key identifier. Aliases accepted: openai, deepgram, elevenlabs, exa, cursor, obsidian_api, obsidian_base_url, obsidian_vault_name."
                        ],
                        "value": [
                            "type": "string",
                            "description": "The secret value. Pass empty string to clear."
                        ]
                    ],
                    "required": ["name", "value"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "list_integrations",
        "connect_integration",
        "open_integration_settings",
        "list_api_keys",
        "set_api_key"
    ]

    func handles(functionName: String) -> Bool {
        return Self.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "list_integrations":         return "checking your integrations"
        case "connect_integration":
            if let n = call.arguments["name"] as? String, !n.isEmpty {
                return "connecting \(n)"
            }
            return "connecting integration"
        case "open_integration_settings": return "opening integration settings"
        case "list_api_keys":             return "checking your API keys"
        case "set_api_key":
            if let n = call.arguments["name"] as? String, let key = Self.resolveKey(from: n) {
                return "saving your \(key.displayName) key"
            }
            return "saving API key"
        default: return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        let name = functionCall.name
        let args = functionCall.arguments

        switch name {
        case "list_integrations":
            completion(Self.functionMessage(name: name, payload: ["integrations": Self.integrationsCatalog()]))

        case "connect_integration":
            guard let which = args["name"] as? String else {
                completion(missingArgs(for: name, expected: "name"))
                return
            }
            connectIntegration(named: which, completion: completion)

        case "open_integration_settings":
            let target = (args["target"] as? String) ?? "in_app"
            let integrationName = args["integration_name"] as? String
            openIntegrationSettings(target: target, integrationName: integrationName, completion: completion)

        case "list_api_keys":
            completion(Self.functionMessage(name: name, payload: ["keys": Self.apiKeysCatalog()]))

        case "set_api_key":
            guard let key = args["name"] as? String,
                  let value = args["value"] as? String else {
                completion(missingArgs(for: name, expected: "name, value"))
                return
            }
            setApiKey(name: key, value: value, completion: completion)

        default:
            completion(MessageStruct(role: "assistant",
                                     content: "I don't know how to handle the integrations tool '\(name)'."))
        }
    }

    // MARK: - list_integrations

    /// JSON-serializable catalog mirroring the rows the in-app
    /// IntegrationsVC / IntegrationsWindowController render.
    private static func integrationsCatalog() -> [[String: Any]] {
        let calStatus = CalendarSkill.shared.currentAuthorizationStatus
        let calendar: [String: Any] = [
            "name": "calendar",
            "display_name": "Google Calendar",
            "status": calendarStatusString(calStatus),
            "hint": calendarHint(calStatus)
        ]
        let notionToken = KeyStore.shared.value(for: .notionIntegrationToken) ?? ""
        let notion: [String: Any] = [
            "name": "notion",
            "display_name": "Notion",
            "status": notionToken.isEmpty ? "not_connected" : "connected",
            "hint": notionToken.isEmpty
                ? "Paste an ntn_… integration token in Settings → Keys → Notion Integration Token."
                : "Connected via Notion integration token. Notion tools are live."
        ]
        let gmail: [String: Any] = [
            "name": "gmail",
            "display_name": "Gmail",
            "status": "coming_soon",
            "hint": "OAuth wiring is in progress; not yet available."
        ]
        let slackToken = KeyStore.shared.value(for: .slackUserToken) ?? ""
        let slack: [String: Any] = [
            "name": "slack",
            "display_name": "Slack",
            "status": slackToken.isEmpty ? "not_connected" : "connected",
            "hint": slackToken.isEmpty
                ? "Paste a personal xoxp- token in Settings → Keys → Slack User Token. The user can mint one at api.slack.com/apps with the scopes listed in Specs/3. Integrations Spec.md."
                : "Connected via personal user token. Slack tools are live."
        ]
        #if canImport(HealthKit) && os(iOS)
        let healthStatus = HealthKitManager.shared.currentAuthorizationStatus
        let health: [String: Any] = [
            "name": "health",
            "display_name": "Apple Health",
            "status": healthStatus.rawValue,
            "hint": healthHint(healthStatus)
        ]
        return [calendar, notion, gmail, slack, health]
        #else
        let health: [String: Any] = [
            "name": "health",
            "display_name": "Apple Health",
            "status": "unavailable",
            "hint": "HealthKit is not available on this platform."
        ]
        return [calendar, notion, gmail, slack, health]
        #endif
    }

    private static func calendarStatusString(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess, .authorized: return "connected"
        case .denied, .restricted, .writeOnly: return "denied"
        case .notDetermined: return "not_connected"
        @unknown default: return "not_connected"
        }
    }

    private static func calendarHint(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess, .authorized:
            return "Loop can read events from any calendar account the user has added to system settings."
        case .denied, .restricted, .writeOnly:
            return "Access was previously denied. Call open_integration_settings with target=\"calendar_privacy\" to send the user to the system Privacy pane."
        case .notDetermined:
            return "No permission decision yet. Call connect_integration with name=\"calendar\" to surface the system permission prompt."
        @unknown default:
            return "Status unknown."
        }
    }

    #if canImport(HealthKit) && os(iOS)
    private static func healthHint(_ status: HealthKitManager.AuthStatus) -> String {
        switch status {
        case .authorized:
            return "Apple Health is connected. Health query tools (health_today_summary, health_active_workout, health_query) are live."
        case .denied:
            return "Health access was previously denied. Tell the user to re-enable Loop in iOS Settings → Privacy & Security → Health."
        case .notDetermined:
            return "No permission decision yet. Call connect_integration with name=\"health\" to surface the Health permission prompt."
        case .unavailable:
            return "HealthKit is not available on this device."
        }
    }
    #endif

    // MARK: - connect_integration

    private func connectIntegration(named raw: String,
                                    completion: @escaping (MessageStruct) -> Void) {
        let which = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let toolName = "connect_integration"

        switch which {
        case "calendar", "google_calendar", "google calendar":
            let status = CalendarSkill.shared.currentAuthorizationStatus
            switch status {
            case .fullAccess, .authorized:
                completion(Self.functionMessage(name: toolName, payload: [
                    "name": "calendar",
                    "status": "already_connected"
                ]))
            case .denied, .restricted, .writeOnly:
                completion(Self.functionMessage(name: toolName, payload: [
                    "name": "calendar",
                    "status": "needs_system_settings",
                    "next_action": "Call open_integration_settings with target=\"calendar_privacy\" to send the user to the system Privacy pane."
                ]))
            case .notDetermined:
                CalendarSkill.shared.requestAccessIfNeeded { granted in
                    completion(Self.functionMessage(name: toolName, payload: [
                        "name": "calendar",
                        "status": granted ? "connected" : "denied"
                    ]))
                }
            @unknown default:
                completion(Self.functionMessage(name: toolName, payload: [
                    "name": "calendar",
                    "status": "unknown"
                ]))
            }

        case "notion":
            let token = KeyStore.shared.value(for: .notionIntegrationToken) ?? ""
            if !token.isEmpty {
                completion(Self.functionMessage(name: toolName, payload: [
                    "name": "notion",
                    "status": "already_connected",
                    "message": "Notion is already connected via an integration token. Notion tools are live."
                ]))
            } else {
                completion(Self.functionMessage(name: toolName, payload: [
                    "name": "notion",
                    "status": "needs_api_key",
                    "next_action": "Tell the user to paste their Notion integration token (starts with ntn_) in Settings → Keys → Notion Integration Token. They can create one at notion.so/my-integrations → New integration → copy the Internal Integration Secret."
                ]))
            }

        case "gmail":
            completion(Self.functionMessage(name: toolName, payload: [
                "name": "gmail",
                "status": "coming_soon",
                "message": "Gmail integration isn't available yet — OAuth wiring is still in progress."
            ]))

        case "slack":
            let token = KeyStore.shared.value(for: .slackUserToken) ?? ""
            if !token.isEmpty {
                completion(Self.functionMessage(name: toolName, payload: [
                    "name": "slack",
                    "status": "already_connected",
                    "message": "Slack is already connected via a personal user token. Slack tools are live."
                ]))
            } else {
                completion(Self.functionMessage(name: toolName, payload: [
                    "name": "slack",
                    "status": "needs_api_key",
                    "next_action": "Tell the user to paste a Slack user OAuth token (starts with xoxp-) in Settings → Keys → Slack User Token. If they don't have one yet, walk them through: create an app at api.slack.com/apps → OAuth & Permissions → add User Token Scopes (channels:history, channels:read, groups:history, groups:read, im:history, im:read, im:write, mpim:history, mpim:read, users:read, chat:write, search:read) → Install to Workspace → copy the User OAuth Token."
                ]))
            }

        case "health", "apple_health", "apple health", "healthkit":
            #if canImport(HealthKit) && os(iOS)
            let status = HealthKitManager.shared.currentAuthorizationStatus
            switch status {
            case .authorized:
                completion(Self.functionMessage(name: toolName, payload: [
                    "name": "health",
                    "status": "already_connected"
                ]))
            case .denied:
                completion(Self.functionMessage(name: toolName, payload: [
                    "name": "health",
                    "status": "needs_system_settings",
                    "next_action": "Tell the user to re-enable Loop in iOS Settings → Privacy & Security → Health."
                ]))
            case .notDetermined:
                HealthKitManager.shared.requestAuthorization { granted, _ in
                    completion(Self.functionMessage(name: toolName, payload: [
                        "name": "health",
                        "status": granted ? "connected" : "denied"
                    ]))
                }
            case .unavailable:
                completion(Self.functionMessage(name: toolName, payload: [
                    "name": "health",
                    "status": "unavailable",
                    "message": "HealthKit is not available on this device."
                ]))
            }
            #else
            completion(Self.functionMessage(name: toolName, payload: [
                "name": "health",
                "status": "unavailable",
                "message": "HealthKit is not available on this platform."
            ]))
            #endif

        default:
            completion(Self.functionMessage(name: toolName, payload: [
                "error": "unknown_integration",
                "name": which,
                "hint": "Known integrations: calendar, notion, gmail, slack, health."
            ]))
        }
    }

    // MARK: - open_integration_settings

    private func openIntegrationSettings(target: String,
                                         integrationName: String?,
                                         completion: @escaping (MessageStruct) -> Void) {
        let normalized = target.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let validTargets: Set<String> = ["in_app", "calendar_privacy"]
        let resolvedTarget = validTargets.contains(normalized) ? normalized : "in_app"

        var userInfo: [String: Any] = ["target": resolvedTarget]
        if let n = integrationName, !n.isEmpty {
            userInfo["integrationName"] = n
        }

        // Bounce to main — observers (UIViewController push, NSWindow show)
        // touch UIKit/AppKit and must run there.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .integrationSkillRequestedSettings,
                object: nil,
                userInfo: userInfo
            )
        }

        completion(Self.functionMessage(name: "open_integration_settings", payload: [
            "ok": true,
            "target": resolvedTarget
        ]))
    }

    // MARK: - list_api_keys

    private static func apiKeysCatalog() -> [[String: Any]] {
        return KeyStore.Key.allCases.map { key in
            let isSet: Bool = {
                if let v = KeyStore.shared.value(for: key) { return !v.isEmpty }
                return false
            }()
            return [
                "name": key.rawValue,
                "alias": friendlyAlias(for: key),
                "display_name": key.displayName,
                "subtitle": key.subtitle,
                "is_set": isSet
            ] as [String: Any]
        }
    }

    /// Inverse of `resolveKey(from:)` — a stable short name for the model to
    /// refer to each key without having to know the full `OPENAI_API_KEY`
    /// constant.
    private static func friendlyAlias(for key: KeyStore.Key) -> String {
        switch key {
        case .deepgram:               return "deepgram"
        case .elevenLabs:             return "elevenlabs"
        case .exa:                    return "exa"
        case .openAI:                 return "openai"
        case .anthropic:              return "anthropic"
        case .fireworks:              return "fireworks"
        case .cursor:                 return "cursor"
        case .obsidianAPI:            return "obsidian_api"
        case .obsidianBaseURL:        return "obsidian_base_url"
        case .obsidianVaultName:      return "obsidian_vault_name"
        case .slackUserToken:         return "slack_user_token"
        case .notionIntegrationToken: return "notion"
        case .githubPAT:              return "github"
        case .githubBaseURL:          return "github_base_url"
        case .devin:                  return "devin"
        case .devinOrgID:             return "devin_org_id"
        case .xAPIKey:                return "x_api_key"
        case .xAPISecret:             return "x_api_secret"
        case .xAccessToken:           return "x_access_token"
        case .xAccessTokenSecret:     return "x_access_token_secret"
        case .sfBayTransit:           return "sf_bay_transit"
        case .googleWorkspaceAccessToken:  return "google_workspace_access_token"
        case .googleWorkspaceRefreshToken: return "google_workspace_refresh_token"
        case .googleWorkspaceClientId:     return "google_workspace_client_id"
        case .googleWorkspaceClientSecret: return "google_workspace_client_secret"
        case .agentMail:                   return "agentmail"
        case .agentMailInbox:              return "agentmail_inbox"
        case .serpAPI:                     return "serpapi"
        }
    }

    // MARK: - set_api_key

    private func setApiKey(name: String,
                           value: String,
                           completion: @escaping (MessageStruct) -> Void) {
        let toolName = "set_api_key"
        guard let key = Self.resolveKey(from: name) else {
            completion(Self.functionMessage(name: toolName, payload: [
                "error": "unknown_key",
                "name": name,
                "hint": "Aliases accepted: openai, deepgram, elevenlabs, exa, cursor, obsidian_api, obsidian_base_url, obsidian_vault_name."
            ]))
            return
        }
        // KeyStore.setValue trims internally and treats empty as "clear" —
        // mirror its semantics in the response so the model can phrase it
        // correctly to the user.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        KeyStore.shared.setValue(value, for: key)
        completion(Self.functionMessage(name: toolName, payload: [
            "ok": true,
            "key": key.displayName,
            "cleared": trimmed.isEmpty
        ]))
    }

    /// Map either a canonical `KeyStore.Key.rawValue` or a friendly alias to
    /// the enum case. Comparison is case-insensitive and tolerates the common
    /// variants the model might emit.
    private static func resolveKey(from raw: String) -> KeyStore.Key? {
        let n = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Try raw value first (e.g. "OPENAI_API_KEY").
        if let direct = KeyStore.Key.allCases.first(where: { $0.rawValue.lowercased() == n }) {
            return direct
        }
        switch n {
        case "openai", "open_ai", "open ai":                  return .openAI
        case "anthropic", "claude":                           return .anthropic
        case "fireworks":                                     return .fireworks
        case "deepgram":                                      return .deepgram
        case "elevenlabs", "eleven_labs", "eleven labs":      return .elevenLabs
        case "exa":                                           return .exa
        case "cursor":                                        return .cursor
        case "obsidian_api", "obsidian api", "obsidian":      return .obsidianAPI
        case "obsidian_base_url", "obsidian base url":        return .obsidianBaseURL
        case "obsidian_vault_name", "obsidian vault name":    return .obsidianVaultName
        case "slack", "slack_user_token", "slack user token": return .slackUserToken
        case "notion", "notion_integration_token":            return .notionIntegrationToken
        case "github", "github_pat", "gh":                    return .githubPAT
        case "github_base_url", "github base url", "ghe":     return .githubBaseURL
        case "devin":                                         return .devin
        case "devin_org_id", "devin org id", "devin_org":     return .devinOrgID
        case "x_api_key", "twitter_api_key":                  return .xAPIKey
        case "x_api_secret", "twitter_api_secret":            return .xAPISecret
        case "x_access_token", "twitter_access_token":        return .xAccessToken
        case "x_access_token_secret",
             "twitter_access_token_secret":                   return .xAccessTokenSecret
        case "sf_bay_transit", "sf_bay_511",
             "511", "511_sf_bay":                             return .sfBayTransit
        default:                                              return nil
        }
    }

    // MARK: - Helpers

    private func missingArgs(for name: String, expected: String) -> MessageStruct {
        return MessageStruct(role: "assistant",
                             content: "I need \(expected) to call \(name). Please provide them.")
    }

    private static func functionMessage(name: String, payload: Any) -> MessageStruct {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            json = "{}"
        }
        return MessageStruct(role: "function", content: json, name: name)
    }
}
