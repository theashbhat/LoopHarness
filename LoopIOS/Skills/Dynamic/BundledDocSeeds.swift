//
//  BundledDocSeeds.swift
//  Loop
//
//  Sibling of BundledSkillSeeds. Where that one seeds runnable starter skills
//  into Workspace/Skills/, this seeds plain reference docs into the Workspace
//  root on first launch — currently a single architecture/code-map,
//  ABOUT_LOOP.md, so the agent can answer "how do you work?" by reading a
//  file the user can also open in the Files app.
//
//  Idempotent: writes only when the file is absent, so the user (or the
//  agent) can edit / delete it and the change survives subsequent launches.
//

import Foundation

enum BundledDocSeeds {

    struct Doc {
        /// Filename, relative to the Workspace root.
        let name: String
        let contents: String
    }

    /// Run from AgentHarness.init, after BundledSkillSeeds. For each doc,
    /// write it into the Workspace root only if it isn't already there.
    static func seedIfNeeded() {
        let fm = FileManager.default
        let root = Workspace.shared.rootURL

        for doc in all {
            let url = root.appendingPathComponent(doc.name)
            if fm.fileExists(atPath: url.path) { continue }
            do {
                try Workspace.shared.coordinatedWrite(to: url) { writeURL in
                    try doc.contents.write(to: writeURL, atomically: true, encoding: .utf8)
                }
                print("BundledDocSeeds: seeded \(doc.name)")
            } catch {
                print("BundledDocSeeds: failed to seed \(doc.name) — \(error)")
            }
        }
    }

    static let all: [Doc] = [aboutLoop]

    // MARK: - ABOUT_LOOP.md

    private static let aboutLoop = Doc(
        name: "ABOUT_LOOP.md",
        contents: #"""
# About Loop

This is the agent's own architecture and code map. When the user asks "how do
you work?", "what can you do?", "how are you built?", or anything about your
own internals, read this file and answer from it. It lives in the Workspace
root, so the user can open and edit it in the Files app too.

## What Loop is

Loop is a personal AI — a "living memory" — that runs as a native app the user
talks to by text (iPhone) and by voice (Mac, hold-to-talk). The same
conversation continues across both devices via iCloud sync.

## The app: two targets, one shared core

A single Xcode project (`Loop.xcodeproj`) builds two apps plus a share
extension:

- **Loop** — the iOS app (UIKit). Compiles the shared `LoopIOS/` folder. Chat
  UI lives in `MessagingVC`.
- **LoopMac** — the macOS app. Compiles `LoopMac/` plus most of `LoopIOS/`.
  The voice loop (record → transcribe → think → speak) is driven by
  `LoopMac/VoiceLoopCoordinator.swift`.
- **LoopShare** — a share extension for sending content into the workspace.

`LoopIOS/` is a *synchronized folder group*: any new source file added there is
automatically compiled into **both** Loop and LoopMac. Code that touches UIKit
must be guarded with `#if os(iOS)` so the Mac target still builds. A few files
(e.g. `MessagingVC.swift`) are explicitly excluded from the Mac target via
project membership exceptions — the Mac equivalent logic lives in
`VoiceLoopCoordinator`.

## The agent harness

`LoopIOS/AgentHarness/AgentHarness.swift` is the brain. It owns the markdown
documents that compose the system prompt — SOUL, USER, MEMORY, AGENTS,
HEARTBEAT, plus the tools narrative — and exposes one `chat(...)` entry point.
Online, it calls the cloud model; offline (or when the user picks Apple
Foundation), it falls back to the on-device Apple Intelligence model with a
slimmed prompt.

The five identity docs (`SOUL.md`, `USER.md`, `MEMORY.md`, `AGENTS.md`,
`HEARTBEAT.md`) are mirrored to the Workspace root as real files. The agent
edits them through the Self-Improvement skill; the user can edit them in the
Files app. They reload into every system prompt automatically.

## Skills

A skill is a self-contained capability the model can call as a tool. Every
skill follows the same shape:

- `static let shared` — singleton.
- `static let systemPromptFragment: String` — how the model is told the skill
  exists.
- `static let tools: [[String: Any]]` — OpenAI-style function schemas.
- `static let toolNames: Set<String>` and `func handles(functionName:) -> Bool`.
- `func handle(functionCall:completion:)` — runs the tool, returns a
  `role: "function"` message.
- `func statusText(for:) -> String?` — the shimmer label shown while it runs.

Bundled skills include: Notion, Scheduler, Web search (Exa), URL fetch,
Self-Improvement, File System, Spec Builder, Location, Image, Obsidian,
Calendar, Music, Skill Builder, Sub-Agent, and Integrations. The user (or the
agent) can also author new skills in JavaScript at runtime — those hot-load
from `Workspace/Skills/` and don't require a rebuild.

### The five dispatch points

A bundled skill is only fully wired when it's registered in all five places:

1. The global `tools` array in `LoopIOS/Structs/Messaging.swift` (schemas).
2. The prompt-fragment composition + skill catalog in
   `LoopIOS/AgentHarness/AgentHarness.swift`.
3. `LoopIOS/AgentHarness/SkillDispatcher.swift` — the headless dispatcher used
   by background/scheduled runs and sub-agents.
4. `LoopIOS/MessagingVC.swift` — the iOS chat `processMessage` chain.
5. `LoopMac/VoiceLoopCoordinator.swift` — the Mac voice `dispatchFunction`.

## The Workspace (the agent's file system)

`LoopIOS/Workspace/Workspace.swift` resolves a single root directory — preferring
the app's iCloud Drive container (`iCloud.com.bhat.intel`, visible to the user
in the Files app and synced across devices), falling back to a local
`Documents/Workspace` folder when iCloud is unavailable. Every File System tool
path is relative to this root; traversal and absolute paths are rejected.
There's a 1 MB per-file read/write cap to keep a runaway file from blowing up
the chat context. Cloned git repositories live under this same root.

## Sub-agents

`LoopIOS/SubAgents/` implements detached background workers. The primary agent
calls `spawn_sub_agent(task, kind)` where `kind` is `research`, `coding`, or
`general`. A sub-agent runs its own isolated message loop via
`SubAgentRuntime`, reusing the same model and the shared `SkillDispatcher`, so
it can reach every tool the main chat can. It has a hard budget (25 turns /
300 seconds), cannot spawn further sub-agents, and posts a single summary back
into the parent conversation when it finishes. A `coding` sub-agent gets a
coding-focused prompt and is meant to operate on a repository cloned into the
Workspace (read/edit files, check git status). The user (or the primary agent)
can cancel a running sub-agent via `cancel_sub_agent(id)` — this marks it as
failed and the runtime loop exits on the next turn check.

## Cloud

`LoopIOS/Data/Cloud.swift` is the network layer. `Cloud.connection.chat(...)`
routes through `AgentHarness`, which decides cloud vs. on-device and assembles
the full system prompt. Conversations persist via
`SimpleConversationManager` and sync over iCloud so iPhone and Mac stay in
lock-step.

## Open-source repository

Loop's own source code is open-sourced at **getathelas/LoopHarness**
(https://github.com/getathelas/LoopHarness). When the user asks how Loop works
internally, or wants to inspect specific implementation details, use the
GitHub skill tools to read the code directly:

- `github_file_contents` — read a specific file from the repo.
- `search_code` — search for symbols, patterns, or keywords across the repo.
- `list_github_repos` — confirm the repo exists and check metadata.
- `clone_github_repo` — clone the repo into the Workspace for deeper
  exploration or diffs.

These tools work against the public repo — no extra credentials are needed.
"""#
    )
}
