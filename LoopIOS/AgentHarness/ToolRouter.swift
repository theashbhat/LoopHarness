//
//  ToolRouter.swift
//  Loop
//
//  First-pass lightweight tool selector that picks relevant skill groups
//  based on the latest user message. Reduces the tool payload sent to the
//  provider on each turn — fewer tools means smaller requests, faster
//  serialization, and lower prompt-token cost.
//
//  A small "core" set is always included (self-improvement, file system,
//  navigation, scheduler, integration, sub-agent, skill builder, spec
//  builder). Domain-specific groups (calendar, slack, notion, obsidian,
//  github, music, etc.) are included only when the user message matches
//  their keyword triggers or when the message is too ambiguous to narrow
//  confidently.
//
//  The 128-tool OpenAI cap is enforced here, before payload construction,
//  so every provider benefits.
//

import Foundation

struct ToolRouter {

    /// Maximum tools any provider should receive. OpenAI hard-rejects > 128.
    static let maxTools = 128

    // MARK: - Skill groups

    /// Each group maps a set of keyword triggers to the function names it
    /// gates. Keywords are lowercase; matching is case-insensitive substring
    /// on the user message.
    struct SkillGroup {
        let name: String
        let keywords: [String]
        let toolNames: Set<String>
    }

    static let groups: [SkillGroup] = [
        SkillGroup(name: "calendar", keywords: [
            "calendar", "event", "schedule", "meeting", "appointment",
            "availability", "busy", "free", "remind",
        ], toolNames: [
            "calendar", "create_calendar_event", "list_upcoming_events",
            "check_calendar_availability",
        ]),
        SkillGroup(name: "slack", keywords: [
            "slack", "channel", "dm", "mention",
        ], toolNames: [
            "slack", "list_slack_channels", "send_slack_message",
            "search_slack", "slack_channel_history", "slack_mentions",
            "slack_thread_replies", "find_slack_user", "open_slack_dm",
        ]),
        SkillGroup(name: "notion", keywords: [
            "notion", "wiki", "database",
        ], toolNames: [
            "notion", "create_notion_page", "read_notion_page",
            "find_notion_page", "list_notion_pages", "append_to_notion_page",
            "move_notion_page", "publish_spec_to_notion",
        ]),
        SkillGroup(name: "obsidian", keywords: [
            "obsidian", "vault", "note", "daily note", "today note",
        ], toolNames: [
            "create_obsidian_note", "read_obsidian_note",
            "update_obsidian_note", "delete_obsidian_note",
            "find_obsidian", "list_obsidian_folder",
            "create_obsidian_folder", "delete_obsidian_folder",
            "move_obsidian_folder", "move_obsidian_note",
            "get_obsidian_layout", "create_obsidian_today_note",
            "get_obsidian_today",
        ]),
        SkillGroup(name: "github", keywords: [
            "github", "pr", "pull request", "issue", "commit", "repo",
            "branch", "merge", "review", "code review", "notification",
        ], toolNames: [
            "get_github_repo", "list_github_repos", "search_repos",
            "github_file_contents", "search_code", "github_whoami",
            "list_pull_requests", "get_pull_request", "create_pull_request",
            "merge_pull_request", "review_pull_request", "comment_pull_request",
            "list_issues", "get_issue", "create_issue", "close_issue",
            "comment_issue", "search_issues", "list_branches",
            "list_notifications", "mark_notification_read",
        ]),
        SkillGroup(name: "git", keywords: [
            "git", "clone", "pull", "repo",
        ], toolNames: [
            "git_clone", "git_pull", "git_status", "clone_github_repo",
        ]),
        SkillGroup(name: "web", keywords: [
            "search", "web", "google", "look up", "find online", "url",
            "website", "browse", "fetch",
        ], toolNames: [
            "exa_search", "exa_get_contents", "exa_list_websets", "fetch_url",
        ]),
        SkillGroup(name: "health", keywords: [
            "health", "steps", "workout", "heart rate", "sleep",
            "calories", "exercise", "distance", "body mass", "weight",
            "running", "walking",
        ], toolNames: [
            "health", "health_today_summary", "health_active_workout",
            "health_query",
        ]),
        SkillGroup(name: "music", keywords: [
            "music", "song", "play", "playlist", "album", "artist",
            "spotify", "apple music", "pause", "skip", "track",
        ], toolNames: [
            "find_music", "play_music", "control_music", "get_music_status",
            "create_playlist", "request_music_authorization", "set_music_mood",
        ]),
        SkillGroup(name: "location", keywords: [
            "location", "where am i", "map", "directions", "nearby",
            "places", "address", "gps", "navigate",
        ], toolNames: [
            "get_current_location", "show_places_on_map",
        ]),
        SkillGroup(name: "image", keywords: [
            "image", "picture", "photo", "generate image", "draw",
            "illustration", "dalle", "dall-e",
        ], toolNames: [
            "generate_image",
        ]),
        SkillGroup(name: "pdf", keywords: [
            "pdf", "document", "export pdf",
        ], toolNames: [
            "generate_pdf",
        ]),
        SkillGroup(name: "twitter", keywords: [
            "tweet", "twitter", "x.com", "post tweet",
        ], toolNames: [
            "post_tweet",
        ]),
        SkillGroup(name: "cursor", keywords: [
            "cursor", "coding agent",
        ], toolNames: [
            "cursor_dispatch_agent", "cursor_check_agent", "cursor_list_agents",
        ]),
        SkillGroup(name: "devin", keywords: [
            "devin",
        ], toolNames: [
            "devin_dispatch_agent", "devin_check_agent", "devin_list_agents",
        ]),
        SkillGroup(name: "ssh", keywords: [
            "ssh", "remote", "server", "terminal",
        ], toolNames: [
            "ssh_client",
        ]),
        SkillGroup(name: "muni", keywords: [
            "muni", "bus", "transit", "train", "bart",
        ], toolNames: [
            "muni_arrivals",
        ]),
    ]

    /// Tools always included regardless of message content. These are needed
    /// for core agent operation (self-improvement, file browsing, navigation,
    /// scheduling, integration management, sub-agents, skill authoring).
    static let coreToolNames: Set<String> = [
        // Self-improvement
        "read_self_doc", "update_self_doc",
        // File system
        "file_list", "file_read", "file_write", "file_edit",
        "file_delete", "file_move", "file_search", "folder_create",
        "share_file",
        // Navigation
        "open_panel",
        // Scheduler
        "schedule_task", "schedule_cron", "list_tasks", "list_crons",
        "delete_task", "delete_cron", "run_task_now",
        // Integration
        "list_integrations", "connect_integration", "set_api_key",
        "list_api_keys", "open_integration_settings",
        // Sub-agent
        "sub_agent",
        // Skill builder
        "save_skill", "list_skills", "delete_skill",
        // Spec builder
        "publish_spec_to_notion",
    ]

    // MARK: - Selection

    /// Select the subset of tools relevant to the user's latest message.
    /// Returns `(selected, omittedGroupNames)` for logging.
    static func select(
        allTools: [[String: Any]],
        userMessage: String
    ) -> (tools: [[String: Any]], omittedGroups: [String]) {
        let lower = userMessage.lowercased()

        // If the message is very short / ambiguous, include everything.
        if lower.count < 3 {
            return (cap(allTools), [])
        }

        var activeToolNames = coreToolNames
        var matchedGroups: [String] = []
        var omittedGroups: [String] = []

        for group in groups {
            let matched = group.keywords.contains { lower.contains($0) }
            if matched {
                activeToolNames.formUnion(group.toolNames)
                matchedGroups.append(group.name)
            } else {
                omittedGroups.append(group.name)
            }
        }

        // If no domain-specific group matched, include everything —
        // the user may be asking something we can't keyword-match.
        if matchedGroups.isEmpty {
            return (cap(allTools), [])
        }

        // Filter: keep tools whose function name is in the active set,
        // plus any tool we can't resolve a name for (safety).
        let selected = allTools.filter { schema in
            guard let fn = schema["function"] as? [String: Any],
                  let name = fn["name"] as? String else {
                return true
            }
            return activeToolNames.contains(name)
        }

        let result = cap(selected)
        print("ToolRouter: \(matchedGroups.joined(separator: ",")) → \(result.count)/\(allTools.count) tools  omitted: \(omittedGroups.joined(separator: ","))")
        return (result, omittedGroups)
    }

    /// Enforce the 128-tool cap. Drops from the tail (dynamic/MCP tools
    /// are appended last).
    private static func cap(_ tools: [[String: Any]]) -> [[String: Any]] {
        guard tools.count > maxTools else { return tools }
        let dropped = tools.count - maxTools
        let droppedNames = tools.suffix(dropped).compactMap { schema -> String? in
            (schema["function"] as? [String: Any])?["name"] as? String
        }
        print("ToolRouter: capping \(tools.count) → \(maxTools) tools; dropped: \(droppedNames)")
        return Array(tools.prefix(maxTools))
    }
}
