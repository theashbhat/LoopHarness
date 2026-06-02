import Foundation

/// Thin shim that routes every chat through `AgentHarness`, where the
/// system message (SOUL/USER/MEMORY/TOOLS) and online/offline dispatch
/// are owned. Default `tools` to `nil` so AgentHarness falls back to its
/// own `toolSchemas` — that property is seeded from the static `tools`
/// list at startup AND extended at runtime via `registerSkill(...)` (used
/// by LoopMac to add Mac-only tools like `open_url` / `open_mac_app`).
/// Hard-coding the static list here would silently drop those.
class Cloud {
    static let connection = Cloud()

    func chat(messages: [MessageStruct], tools: [[String: Any]]? = nil, onPartial: ((String) -> Void)? = nil, completion: @escaping(MessageStruct?, Error?) -> Void) {
        AgentHarness.shared.chat(messages: messages, tools: tools, onPartial: onPartial, completion: completion)
    }
}
