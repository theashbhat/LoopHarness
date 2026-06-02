//
//  ProviderAbstractions.swift
//  Loop
//
//  Forward-looking provider seams for the execution-backend work. `Conversation-
//  Store` (in ConversationStore.swift) is the one that's load-bearing today —
//  it's what lets conversations persist to either the local file store or the
//  OpenClaw VM. The protocols below sketch the *other* surfaces a backend will
//  eventually own (files, skills, runtime, model config) so that when those
//  land they slot into a named seam instead of forcing a wider refactor.
//
//  These are intentionally thin. They are NOT wired into the app yet — Loop's
//  current file/skill/model paths are unchanged. They exist to mark the shape
//  of the abstraction and give the OpenClaw backend a place to grow into
//  without overbuilding ahead of need.
//
//  Pure Foundation so it compiles for the iOS, macOS, and visionOS targets.
//

import Foundation

/// A backend an execution environment can provide. Both the local environment
/// and the OpenClaw VM are expected to vend a `ConversationStore` today and the
/// stores below over time. Grouping them lets the app ask one object "what can
/// this backend do?" rather than threading individual stores around.
protocol ExecutionEnvironment: AnyObject {
    var backend: ConversationBackend { get }
    var conversations: ConversationStore { get }

    // Optional capabilities a backend may grow into. Default-nil so the local
    // environment can adopt this protocol incrementally.
    var files: FileStore? { get }
    var skills: SkillRegistry? { get }
    var runtime: AgentRuntime? { get }
    var models: ModelConfig? { get }
}

extension ExecutionEnvironment {
    var files: FileStore? { nil }
    var skills: SkillRegistry? { nil }
    var runtime: AgentRuntime? { nil }
    var models: ModelConfig? { nil }
}

/// Read/inspect/write of workspace files for a backend. The OpenClaw VM will
/// back this with SFTP/SSH; the local environment with the on-device workspace.
/// Placeholder — not yet implemented.
protocol FileStore: AnyObject {
    func list(_ path: String) async throws -> [String]
    func read(_ path: String) async throws -> Data
    func write(_ data: Data, to path: String) async throws
}

/// The set of skills/tools a backend exposes to the agent. Placeholder for a
/// future where a remote backend can advertise its own toolset.
protocol SkillRegistry: AnyObject {
    func availableSkillNames() -> [String]
}

/// Where agent turns actually execute (on-device vs. on the VM). Placeholder.
protocol AgentRuntime: AnyObject {
    var identifier: String { get }
}

/// Model selection/config scoped to a backend. Placeholder — model selection
/// today lives in `ModelPickerVC` / `iCloudKVSDefaults`.
protocol ModelConfig: AnyObject {
    var selectedModelIdentifier: String? { get }
}
