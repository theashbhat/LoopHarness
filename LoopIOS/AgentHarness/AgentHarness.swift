//
//  AgentHarness.swift
//  Loop
//
//  Central hub for the agent. Owns the markdown documents that compose the
//  system message (SOUL.md, USER.md, MEMORY.md, AGENTS.md, HEARTBEAT.md,
//  TOOLS.md) and the tool schemas, and exposes a single `chat(...)` entry
//  point that builds the system message, dispatches to Cloud's HTTP API
//  online, and falls back to on-device Apple Intelligence offline.
//
//  Created by Ash Bhat on 5/8/26.
//

import Foundation
import FoundationModels

final class AgentHarness {

    static let shared = AgentHarness()

    // MARK: - Markdown documents
    //
    // Each of these maps to a .md file the harness will eventually persist
    // to disk and update over time. They start empty so the harness is a
    // no-op composition layer until something writes to them.

    var soul: String = """
    # Soul

    You are a helpful personal assistant on the user's phone.

    Be concise — this is a mobile interface. Prefer short, actionable responses.
    Have personality. Don't be robotic.
    If you're unsure, ask rather than guess.
    """

    var userDoc: String = """
    # User

    (Not yet configured — learn about the user through conversation and update this file.)
    """

    var memory: String = """
    # Memory

    (Empty — the agent will populate this as conversations happen.)
    """

    var agents: String = """
    # Agents

    ## Rules
    - Keep responses mobile-friendly (short paragraphs, bullet points)
    - Never fabricate information — say when you don't know
    - Ask before taking external actions (sending messages, making calls)

    """

    var heartbeat: String = """
    # Heartbeat

    If nothing needs attention, stay quiet.

    ## Apple Health
    When the user asks about steps, distance walked/run, active calories,
    workouts, heart rate, resting heart rate, sleep, or body mass, use
    the Health tools:
    - `health_today_summary` for a quick snapshot of today's activity.
    - `health_active_workout` when they ask about a workout in progress
      (e.g. "what's my pace?", "how long have I been running?").
    - `health_query(metric, range)` for any specific metric over a time
      window (yesterday, this_week, last_7_days, or custom ISO range).
    If Health is not connected, the tools return `health_not_authorized`
    — prompt the user to connect Apple Health in Settings → Integrations.
    """

    /// TOOLS.md narrative. Defaults to the concatenation of every Skill's
    /// `systemPromptFragment` so the model has a sensible description of
    /// what's available without anything being persisted yet.
    var toolsDoc: String = ""

    // MARK: - Tool schemas
    //
    // The OpenAI-style function schemas advertised to the model. Defaults to
    // the global `tools` (NotionSkill + CronSkill + ExaSkill).

    var toolSchemas: [[String: Any]] = tools

    /// Set by MessagingVC at viewDidLoad. Used by /new, /reset, and /compact
    /// to apply UI-level side effects without the harness depending on UIKit.
    weak var slashCommandHost: SlashCommandHost?

    /// Cached length of the static (bundled-skill) section of `toolsDoc`. The
    /// dynamic-skill fragment lives after this offset; we truncate to it and
    /// re-append every reload so removed skills disappear from the prompt.
    private var staticToolsDocLength: Int = 0

    /// Same trick for tool schemas — everything before this index is the
    /// static bundled set; dynamic skills get appended on every refresh.
    private var staticToolSchemasCount: Int = 0

    /// Human-readable catalog of the bundled skills, surfaced by the side
    /// drawer's "Skills" tab. This intentionally mirrors the `systemPromptFragment`
    /// list assembled in `init()` below (same order) — when you add a skill
    /// there, add its display row here so the sidebar stays in sync.
    static let bundledSkillCatalog: [(name: String, summary: String, tools: [[String: Any]])] = {
        var catalog: [(name: String, summary: String, tools: [[String: Any]])] = [
            ("Notion",           "Read and write Notion pages and databases", NotionSkill.tools),
            ("Slack",            "Read channels/DMs/mentions, search, and send messages with confirmation", SlackSkill.tools),
            ("Scheduler",        "Schedule reminders and recurring background tasks", SchedulerSkill.tools),
            ("Web Search",       "Search the web for up-to-date information", ExaSkill.tools),
            ("URL Fetch",        "Fetch and read a single web page (no API key)", URLFetchSkill.tools),
            ("Git",              "Clone, pull, and check status of git repositories", GitSkill.tools),
            ("GitHub",           "Review/merge/comment on PRs, open PRs and issues, browse repos and notifications", GitHubSkill.tools),
            ("Self-Improvement", "Update the agent's own SOUL / USER / AGENTS docs", SelfImprovementSkill.tools),
            ("File System",      "Browse and edit files in the workspace", FileSystemSkill.tools),
            ("Spec Builder",     "Draft execution specs from a goal", SpecBuilderSkill.tools),
            ("Location",         "Look up the device's current location", LocationSkill.tools + MapsSkill.tools),
            ("Image",            "Generate images from a text prompt", ImageSkill.tools),
            ("PDF",              "Generate a clean, page-aware PDF from a markdown document", PDFSkill.tools),
            ("Obsidian",         "Read and write the Obsidian vault", ObsidianSkill.tools),
            ("Calendar",         "Read and create calendar events", CalendarSkill.tools),
            ("Music",            "Search and control Apple Music", MusicSkill.tools),
            ("Skill Builder",    "Author new local skills on the fly", SkillBuilderSkill.tools),
            ("Sub-Agent",        "Spawn a focused sub-agent for a subtask", SubAgentSkill.tools),
            ("Integration",      "Manage third-party service connections", IntegrationSkill.tools),
            ("Cursor",           "Dispatch coding tasks to Cursor cloud agents (opens PRs)", CursorSkill.tools),
            ("Devin",            "Dispatch coding tasks to Devin cloud agents (opens PRs, live transcript)", DevinSkill.tools),
            ("X (Twitter)",      "Post tweets to X (Twitter) with confirmation", TwitterSkill.tools),
            ("SSH",              "Execute shell commands on a remote host via SSH", SSHSkill.tools),
        ]
        #if canImport(HealthKit) && os(iOS)
        catalog.append(("Apple Health", "Read-only access to steps, distance, workouts, heart rate, sleep, body mass", HealthSkill.tools))
        #endif
        return catalog
    }()

    private init() {
        var fragments: [String] = [
            NotionSkill.systemPromptFragment,
            SlackSkill.systemPromptFragment,
            SchedulerSkill.systemPromptFragment,
            ExaSkill.systemPromptFragment,
            URLFetchSkill.systemPromptFragment,
            GitSkill.systemPromptFragment,
            GitHubSkill.systemPromptFragment,
            SelfImprovementSkill.systemPromptFragment,
            FileSystemSkill.systemPromptFragment,
            SpecBuilderSkill.systemPromptFragment,
            LocationSkill.systemPromptFragment,
            MapsSkill.systemPromptFragment,
            ImageSkill.systemPromptFragment,
            PDFSkill.systemPromptFragment,
            ObsidianSkill.systemPromptFragment,
            CalendarSkill.systemPromptFragment,
            MusicSkill.systemPromptFragment,
            SkillBuilderSkill.systemPromptFragment,
            SubAgentSkill.systemPromptFragment,
            IntegrationSkill.systemPromptFragment,
            NavigationSkill.systemPromptFragment,
            CursorSkill.systemPromptFragment,
            DevinSkill.systemPromptFragment,
            TwitterSkill.systemPromptFragment,
            SSHSkill.systemPromptFragment,
        ]
        #if canImport(HealthKit) && os(iOS)
        fragments.append(HealthSkill.systemPromptFragment)
        #endif
        self.toolsDoc = fragments.joined(separator: "\n\n")
        self.staticToolsDocLength = toolsDoc.count
        self.staticToolSchemasCount = toolSchemas.count

        // Override the templated defaults with anything the agent has
        // persisted from prior sessions. Missing files just leave the
        // defaults in place. Touching Workspace.shared here also bootstraps
        // the iCloud container resolution + legacy migration.
        _ = Workspace.shared
        loadPersistedSelfDocs()

        // Seed any bundled starter skills into the workspace on first launch.
        // Currently there are none (BundledSkillSeeds.all is empty), so this is
        // a no-op; kept so a starter can be reintroduced later. Subsequent
        // launches detect existing files on disk and skip.
        BundledSkillSeeds.seedIfNeeded()

        // Seed the reference docs (ABOUT_LOOP.md — the agent's own code map)
        // into the Workspace root on first launch. Idempotent: skipped once
        // the file exists, so user/agent edits survive.
        BundledDocSeeds.seedIfNeeded()

        // Initial scan + refresh of dynamic-skill schemas. The registry's
        // didReload hook keeps us in sync as skills get added/removed
        // mid-session.
        DynamicSkillRegistry.shared.didReload = { [weak self] in
            self?.refreshDynamicSkills()
        }
        DynamicSkillRegistry.shared.reload()

        // Same plumbing for remote MCP servers the user has installed. We
        // share `refreshDynamicSkills` because both registries land in the
        // same trailing section of `toolSchemas` / `toolsDoc`.
        MCPRegistry.shared.didReload = { [weak self] in
            self?.refreshDynamicSkills()
        }

        refreshDynamicSkills()

        // Resume polling any Cursor cloud agents dispatched in a prior
        // session so their PR link still posts back after a relaunch.
        CursorAgentService.shared.resumePending()

        // Same for any Devin sessions in flight from a previous run — the
        // shared service re-arms its poll timer and flushes terminal-but-
        // unposted jobs back into their parent conversation.
        DevinAgentService.shared.resumePending()

        // Wake the MusicController singleton so its NotificationCenter
        // subscribers (voiceLoopStateDidChange, conversationStoreDidChange,
        // AVAudioSession.interruption) exist before TTS or recording start
        // posting events. Idempotent — calling shared a second time is fine.
        Task { @MainActor in MusicController.bootstrap() }

        // Touch the HealthKit manager so its init-time backfill of the
        // "user has been prompted" flag runs before the agent fields a
        // health query. Without this, a user who granted access in a
        // prior app version would see the first query incorrectly fail
        // with health_not_authorized.
        #if canImport(HealthKit) && os(iOS)
        _ = HealthKitManager.shared
        #endif
    }

    // MARK: - Dynamic skill integration

    /// Truncate the bundled-skill section of `toolsDoc` / `toolSchemas` back
    /// to its static prefix and re-append whatever the registry currently
    /// knows about. Called whenever a skill is added, updated, or removed.
    func refreshDynamicSkills() {
        // Trim back to the static prefix.
        if toolsDoc.count > staticToolsDocLength {
            toolsDoc = String(toolsDoc.prefix(staticToolsDocLength))
        }
        if toolSchemas.count > staticToolSchemasCount {
            toolSchemas = Array(toolSchemas.prefix(staticToolSchemasCount))
        }

        let fragment = DynamicSkillRegistry.shared.systemPromptFragment()
        if !fragment.isEmpty {
            toolsDoc = toolsDoc.isEmpty
                ? fragment
                : toolsDoc + "\n\n" + fragment
        }
        toolSchemas.append(contentsOf: DynamicSkillRegistry.shared.toolSchemas())

        let mcpFragment = MCPRegistry.shared.systemPromptFragment()
        if !mcpFragment.isEmpty {
            toolsDoc = toolsDoc.isEmpty
                ? mcpFragment
                : toolsDoc + "\n\n" + mcpFragment
        }
        toolSchemas.append(contentsOf: MCPRegistry.shared.toolSchemas())
    }

    /// Collapse tool schemas to one entry per function name, first-wins.
    ///
    /// The tool list is assembled from several uncoordinated sources — the
    /// static `tools` global, `registerSkill(...)` (called multiple times on
    /// macOS for MacApp tools), and `DynamicSkillRegistry` re-appended every
    /// turn — and nothing upstream enforces uniqueness. OpenAI and the legacy
    /// Cloud backend silently tolerated duplicates; Anthropic hard-rejects
    /// them ("tools: Tool names must be unique"). Deduping once at the send
    /// chokepoint keeps every provider valid, and is the right layer for it:
    /// duplicate function names are ambiguous for *any* model, not just a
    /// quirk of one API. First-wins preserves the authoritative bundled/static
    /// definition over a later dynamic re-add of the same name.
    static func uniqueToolSchemas(_ schemas: [[String: Any]]) -> [[String: Any]] {
        var seen = Set<String>()
        var out: [[String: Any]] = []
        out.reserveCapacity(schemas.count)
        for schema in schemas {
            guard let fn = schema["function"] as? [String: Any],
                  let name = fn["name"] as? String else {
                // No resolvable name — keep it and let the provider surface
                // any complaint rather than silently dropping a tool.
                out.append(schema)
                continue
            }
            if seen.insert(name).inserted {
                out.append(schema)
            }
        }
        return out
    }

    // MARK: - Skill registration (platform-conditional)
    //
    // Skills that ship in only one target (e.g. MacAppSkill, which is macOS-
    // only) call this from their host's launch flow to extend the harness
    // with their tool schemas + prompt fragment. iOS-bundled skills register
    // statically via the `tools` array at top of Messaging.swift; this is the
    // dynamic equivalent for cross-platform additions.
    func registerSkill(tools newTools: [[String: Any]],
                       systemPromptFragment fragment: String) {
        toolSchemas.append(contentsOf: newTools)
        if !fragment.isEmpty {
            toolsDoc = toolsDoc.isEmpty ? fragment : toolsDoc + "\n\n" + fragment
        }
    }

    // MARK: - System message composition

    /// Compose the full system prompt by stacking the base instructions on
    /// top of every populated markdown document. Empty documents are
    /// skipped so the prompt stays compact during the early bootstrap.
    func buildSystemPrompt(base: String) -> String {
        var sections: [String] = []
        if !base.isEmpty       { sections.append(base) }
        if !soul.isEmpty       { sections.append("# SOUL\n\(soul)") }
        if !userDoc.isEmpty    { sections.append("# USER\n\(userDoc)") }
        if !memory.isEmpty     { sections.append("# MEMORY\n\(memory)") }
        if !agents.isEmpty     { sections.append("# AGENTS\n\(agents)") }
        if !heartbeat.isEmpty  { sections.append("# HEARTBEAT\n\(heartbeat)") }
        if !toolsDoc.isEmpty   { sections.append(toolsDoc) }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Chat entry point

    /// Drop-in replacement for `Cloud.chat`. Rebuilds the system message
    /// from the harness's documents (using the caller's existing system
    /// message as the "base instructions"), then dispatches.
    func chat(messages: [MessageStruct],
              tools: [[String: Any]]? = nil,
              completion: @escaping(MessageStruct?, Error?) -> Void) {

        // Slash commands short-circuit before any inference call. The latest
        // user message is the trigger; if it starts with a recognized
        // /<command>, SlashCommands.handle returns a deterministic reply and
        // applies any UI side effect through slashCommandHost.
        if let lastUser = messages.last(where: { $0.role == "user" }),
           let command = SlashCommands.parse(lastUser.content) {
            let reply = SlashCommands.handle(command,
                                             harness: self,
                                             messages: messages,
                                             host: slashCommandHost)
            DispatchQueue.main.async { completion(reply, nil) }
            return
        }

        // Pick up any external edits the user made via the Files app since
        // the last call. Cheap (5 file stats + reads only when mtime changed).
        loadPersistedSelfDocs()

        // Debounced reload of dynamic skills and MCP servers. The registries
        // use mtime checks internally, so a reload is cheap, but the MCP
        // path fires network requests to every enabled server. Throttle both
        // to avoid churn on rapid multi-turn sequences.
        let now = Date()
        if now.timeIntervalSince(lastDynamicSkillReload) >= reloadDebounceInterval {
            DynamicSkillRegistry.shared.reload()
            lastDynamicSkillReload = now
        }
        if now.timeIntervalSince(lastMCPReload) >= reloadDebounceInterval {
            MCPRegistry.shared.reload()
            lastMCPReload = now
        }

        // Two reasons to take the offline (Apple Foundation) path:
        //   1. The device is offline — the cloud is unreachable, so no other
        //      option exists.
        //   2. The user has explicitly picked Apple Foundation in Settings ▸
        //      Model. Honor it even when the cloud is reachable.
        //
        // Decided BEFORE composing the cloud system prompt — Apple's
        // on-device model has a much smaller context window and can't
        // accept the harness's full SOUL/USER/MEMORY/AGENTS/TOOLS dump
        // without overflowing. Offline gets the caller's original messages.
        if !Reachability.isOnline || ModelSelectionStore.current.provider == .apple {
            offlineRespond(messages: messages, completion: completion)
            return
        }

        let uniqueTools = AgentHarness.uniqueToolSchemas(tools ?? toolSchemas)

        // Route tools: pick relevant skill groups based on the latest user
        // message. Falls back to the full set when ambiguous.
        let lastUserContent = messages.last(where: { $0.role == "user" })?.content ?? ""
        let (toolsToSend, _) = ToolRouter.select(allTools: uniqueTools,
                                                  userMessage: lastUserContent)

        let baseInstructions = messages.first(where: { $0.role == "system" })?.content ?? ""
        let composedSystem = buildSystemPrompt(base: baseInstructions)
        var rebuilt: [MessageStruct] = [MessageStruct(role: "system", content: composedSystem)]
        rebuilt.append(contentsOf: messages.filter { $0.role != "system" })

        // Hosted provider selected → talk straight to it with the user's own
        // key (Settings ▸ Keys). This deliberately bypasses the `Cloud`
        // backend: the open-source export ships `Cloud.url` as a placeholder,
        // so the backend path can't succeed for a fresh checkout. Errors (no
        // key, wrong model id, bad key, quota) are surfaced to the caller,
        // NOT silently downgraded to the on-device Apple model — that silent
        // fallback is exactly what made a missing key look like "the agent
        // ignores my model settings". Apple is opt-in via Settings ▸ Model
        // (handled by the `.apple` branch above).
        switch ModelSelectionStore.current.provider {
        case .anthropic:
            AnthropicChat.shared.chat(messages: rebuilt, tools: toolsToSend, completion: completion)
        case .openAI:
            OpenAIChat.shared.chat(messages: rebuilt, tools: toolsToSend, completion: completion)
        case .fireworks:
            FireworksChat.shared.chat(messages: rebuilt, tools: toolsToSend, completion: completion)
        case .apple:
            // Unreachable — `.apple` returned via offlineRespond above. Kept
            // so the switch stays exhaustive if providers are added.
            offlineRespond(messages: messages, completion: completion)
        }
    }

    // MARK: - Offline path
    //
    // Slimmed-down responder for when the device is offline. No tools, no
    // function calls — just a single-prompt round-trip through Apple's
    // on-device language model.

    private func offlineRespond(messages: [MessageStruct],
                                completion: @escaping(MessageStruct?, Error?) -> Void) {
        if #available(iOS 26.0, macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                let prompt = makeOfflinePrompt(from: messages)
                Task {
                    do {
                        let session = LanguageModelSession()
                        let response = try await session.respond(to: prompt)
                        let reply = MessageStruct(role: "assistant",
                                                  content: response.content,
                                                  model: "Apple LLM")
                        DispatchQueue.main.async { completion(reply, nil) }
                    } catch {
                        print("AgentHarness offline: LanguageModelSession.respond threw — \(error)")
                        DispatchQueue.main.async {
                            completion(nil, NSError(
                                domain: "AgentHarness",
                                code: -2,
                                userInfo: [NSLocalizedDescriptionKey: "Apple Foundation model couldn't respond: \(error.localizedDescription)"]
                            ))
                        }
                    }
                }
                return
            case .unavailable(let reason):
                print("AgentHarness offline: SystemLanguageModel unavailable — \(reason)")
                let message: String
                switch reason {
                case .appleIntelligenceNotEnabled:
                    message = "Apple Intelligence is turned off. Enable it in System Settings → Apple Intelligence & Siri to use the offline model."
                case .modelNotReady:
                    message = "Apple's on-device model is still downloading. Try again in a few minutes."
                case .deviceNotEligible:
                    message = "This Mac doesn't support Apple's on-device language model. Switch to GPT-5.5 in Model settings."
                @unknown default:
                    message = "Apple's on-device model is unavailable on this Mac."
                }
                completion(nil, NSError(domain: "AgentHarness", code: -3,
                                        userInfo: [NSLocalizedDescriptionKey: message]))
                return
            }
        }
        print("AgentHarness offline: FoundationModels framework requires macOS 26 / iOS 26.")
        completion(nil, NSError(domain: "AgentHarness", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Offline model requires macOS 26 or later."]))
    }

    // MARK: - Self-improvement: live + persisted self docs
    //
    // The five markdown documents that compose the agent's identity are
    // mirrored to .md files under Documents/loop_self/ so changes the model
    // makes via SelfImprovementSkill survive a cold start. The in-memory
    // properties above are the source of truth at request time;
    // updateSelfDoc(_:content:) keeps memory and disk in sync.

    enum SelfDoc: String, CaseIterable {
        case soul, user, memory, agents, heartbeat

        /// File name on disk — uppercase, matching the spec layout.
        var filename: String { return "\(rawValue.uppercased()).md" }
    }

    func readSelfDoc(_ doc: SelfDoc) -> String {
        switch doc {
        case .soul:      return soul
        case .user:      return userDoc
        case .memory:    return memory
        case .agents:    return agents
        case .heartbeat: return heartbeat
        }
    }

    /// Update the in-memory copy of a self-doc and (by default) persist it.
    /// `persist=false` is used by the file-system skill when the change is
    /// already on disk, to avoid writing the same content twice.
    func updateSelfDoc(_ doc: SelfDoc, content: String, persist: Bool = true) {
        switch doc {
        case .soul:      soul = content
        case .user:      userDoc = content
        case .memory:    memory = content
        case .agents:    agents = content
        case .heartbeat: heartbeat = content
        }
        if persist {
            persistSelfDoc(doc, content: content)
        }
    }

    private func selfDocURL(for doc: SelfDoc) -> URL {
        return Workspace.shared.rootURL.appendingPathComponent(doc.filename)
    }

    /// Write the in-memory default for every self-doc to disk if the file
    /// isn't already there. Idempotent — existing user edits are preserved.
    /// Called by the onboarding coordinator on first launch so the user
    /// immediately sees SOUL.md / USER.md / MEMORY.md / AGENTS.md /
    /// HEARTBEAT.md in their iCloud workspace (and can open them in Files
    /// or edit them externally) without having to wait for a tool call to
    /// trigger the first persistence.
    func seedSelfDocsIfMissing() {
        let fm = FileManager.default
        for doc in SelfDoc.allCases {
            let url = selfDocURL(for: doc)
            if fm.fileExists(atPath: url.path) { continue }
            let content = readSelfDoc(doc)
            do {
                try Workspace.shared.coordinatedWrite(to: url) { writeURL in
                    try content.write(to: writeURL, atomically: true, encoding: .utf8)
                }
                print("AgentHarness: seeded \(doc.filename)")
            } catch {
                print("AgentHarness: failed to seed \(doc.filename) — \(error)")
            }
        }
    }

    private func persistSelfDoc(_ doc: SelfDoc, content: String) {
        let url = selfDocURL(for: doc)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("AgentHarness: failed to persist \(doc.filename) — \(error)")
        }
    }

    /// mtime cache so we only re-read context files that the user edited
    /// externally (or the agent rewrote on disk) since the last refresh.
    private var lastLoadedMtimes: [SelfDoc: Date] = [:]

    /// Minimum interval between consecutive DynamicSkillRegistry /
    /// MCPRegistry reload calls. Avoids churning the filesystem and
    /// network on rapid-fire multi-turn sequences. External-edit
    /// detection still works — the registries' own mtime guards mean
    /// a no-op reload is ~5 file stats, but even that is wasted if the
    /// last reload was < 10 s ago. The `didReload` callback still fires
    /// for real changes at any time (e.g. user drops a skill mid-turn).
    private let reloadDebounceInterval: TimeInterval = 10
    private var lastDynamicSkillReload: Date = .distantPast
    private var lastMCPReload: Date = .distantPast

    private func loadPersistedSelfDocs() {
        let fm = FileManager.default
        for doc in SelfDoc.allCases {
            let url = selfDocURL(for: doc)
            guard fm.fileExists(atPath: url.path) else { continue }
            try? Workspace.shared.ensureDownloaded(url)

            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = attrs?[.modificationDate] as? Date
            if let mtime = mtime, lastLoadedMtimes[doc] == mtime { continue }

            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  !content.isEmpty else { continue }

            switch doc {
            case .soul:      soul = content
            case .user:      userDoc = content
            case .memory:    memory = content
            case .agents:    agents = content
            case .heartbeat: heartbeat = content
            }
            lastLoadedMtimes[doc] = mtime ?? Date()
        }
    }

    private func makeOfflinePrompt(from messages: [MessageStruct]) -> String {
        var prompt = """
        I've attached the chat history below.
        Please respond as the assistant with the next response in this sequence.

        """
        for m in messages {
            switch m.role {
            case "system":    prompt += "System: \(m.content)\n"
            case "user":      prompt += "User: \(m.content)\n"
            case "assistant": prompt += "Assistant: \(m.content)\n"
            default:          continue
            }
        }
        prompt += "Assistant:"
        return prompt
    }
}
