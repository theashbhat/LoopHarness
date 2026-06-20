//
//  SkillDispatcher.swift
//  Loop
//
//  Built from LoopIOS/Specs/7_background_scheduler_spec.md.
//
//  Headless function-call dispatcher used by BackgroundScheduler when a
//  scheduled job runs outside the chat UI. Mirrors the if-chain that
//  MessagingVC uses to route a function call to the right skill, minus the
//  UI side effects (shimmer label, table reload, etc).
//
//  Most skills are visible from the shared `LoopIOS/` target so the dispatcher
//  can reference them directly. Mac-only skills (MacAppSkill, TerminalSkill)
//  call `SkillDispatcher.shared.register(...)` from
//  `applicationDidFinishLaunching` so the dispatcher can route to them by
//  name without `LoopIOS/` ever importing AppKit.
//

import Foundation

final class SkillDispatcher {

    static let shared = SkillDispatcher()

    typealias Handler = (FunctionCallStruct, @escaping (MessageStruct) -> Void) -> Void

    /// Runtime-registered handlers (Mac-only skills, plus anything else that
    /// can't be referenced from `LoopIOS/` directly). Bundled iOS skills are
    /// matched in `dispatch(_:completion:)` before this list is consulted.
    private var registered: [(handles: (String) -> Bool, handle: Handler)] = []
    private let lock = NSLock()

    private init() {}

    func register(handles: @escaping (String) -> Bool,
                  handle: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        registered.append((handles: handles, handle: handle))
    }

    /// Route a function call. The completion is invoked with the function's
    /// result message (role: "function") exactly once, on whichever queue the
    /// underlying skill resolves on (typically the main queue — same as the
    /// chat-UI path).
    ///
    /// The call runs through `ToolCallGuard` first. If the guard detects a
    /// duplicate / looping call it short-circuits with a synthetic error and
    /// the real skill never executes — saving API quota and preventing the
    /// model from burning tokens re-fetching data it already has.
    func dispatch(_ call: FunctionCallStruct,
                  completion: @escaping (MessageStruct) -> Void) {

        // --- Anti-loop guard (layers 1–3) ---
        let verdict = ToolCallGuard.shared.evaluate(call: call)
        switch verdict {
        case .block(var result, _):
            if result.callId == nil { result.callId = call.callId }
            if result.name == nil   { result.name   = call.name }
            completion(result)
            return
        case .allow:
            break
        }

        // Wrap the downstream completion so we can record the result for
        // the guard's result-diff layer before handing it back to the caller.
        let guardedCompletion: (MessageStruct) -> Void = { result in
            ToolCallGuard.shared.recordResult(
                call: call,
                resultContent: result.content
            )
            completion(result)
        }

        // Built-in skills first — direct references keep this branchless and
        // avoid the runtime-registration overhead for the common case.
        if NotionSkill.shared.handles(functionName: call.name) {
            NotionSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if SlackSkill.shared.handles(functionName: call.name) {
            SlackSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if SchedulerSkill.shared.handles(functionName: call.name) {
            // Scheduling from inside a scheduled-task run is disallowed at
            // the schema level (BackgroundScheduler filters those tools out),
            // but defense in depth — if the model somehow emits one anyway,
            // synthesize a refusal so we don't infinite-loop.
            if BackgroundScheduler.shared.isRunningHeadless {
                completion(MessageStruct(
                    role: "function",
                    content: "{\"status\":\"blocked\",\"message\":\"Scheduling tools are unavailable inside a scheduled task run.\"}",
                    name: call.name
                ))
                return
            }
            SchedulerSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if ExaSkill.shared.handles(functionName: call.name) {
            ExaSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if SerpImageSearchSkill.shared.handles(functionName: call.name) {
            SerpImageSearchSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if URLFetchSkill.shared.handles(functionName: call.name) {
            URLFetchSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if GitSkill.shared.handles(functionName: call.name) {
            GitSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if GitHubSkill.shared.handles(functionName: call.name) {
            GitHubSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if SelfImprovementSkill.shared.handles(functionName: call.name) {
            SelfImprovementSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if FileSystemSkill.shared.handles(functionName: call.name) {
            FileSystemSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if SpecBuilderSkill.shared.handles(functionName: call.name) {
            SpecBuilderSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if LocationSkill.shared.handles(functionName: call.name) {
            LocationSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if MapsSkill.shared.handles(functionName: call.name) {
            MapsSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if GeocodingSkill.shared.handles(functionName: call.name) {
            GeocodingSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if ImageSkill.shared.handles(functionName: call.name) {
            ImageSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if PDFSkill.shared.handles(functionName: call.name) {
            PDFSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if ObsidianSkill.shared.handles(functionName: call.name) {
            ObsidianSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if CalendarSkill.shared.handles(functionName: call.name) {
            CalendarSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if MusicSkill.shared.handles(functionName: call.name) {
            MusicSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if SkillBuilderSkill.shared.handles(functionName: call.name) {
            SkillBuilderSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if IntegrationSkill.shared.handles(functionName: call.name) {
            IntegrationSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if NavigationSkill.shared.handles(functionName: call.name) {
            NavigationSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if CursorSkill.shared.handles(functionName: call.name) {
            CursorSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if DevinSkill.shared.handles(functionName: call.name) {
            DevinSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if TwitterSkill.shared.handles(functionName: call.name) {
            TwitterSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if SSHSkill.shared.handles(functionName: call.name) {
            SSHSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if VMCronSkill.shared.handles(functionName: call.name) {
            // Like SchedulerSkill, scheduling from inside a headless scheduled
            // run is disallowed so a task can't spawn more scheduled work.
            if BackgroundScheduler.shared.isRunningHeadless {
                completion(MessageStruct(
                    role: "function",
                    content: "{\"status\":\"blocked\",\"message\":\"VM-agent tools are unavailable inside a scheduled task run.\"}",
                    name: call.name
                ))
                return
            }
            VMCronSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if MuniRealtimeSkill.shared.handles(functionName: call.name) {
            MuniRealtimeSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if CardSkill.shared.handles(functionName: call.name) {
            CardSkill.shared.handle(functionCall: call, completion: completion); return
        }
        if GoogleDriveSkill.shared.handles(functionName: call.name) {
            GoogleDriveSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if GoogleGmailSkill.shared.handles(functionName: call.name) {
            GoogleGmailSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if GoogleCalendarSkill.shared.handles(functionName: call.name) {
            GoogleCalendarSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if AgentMailSkill.shared.handles(functionName: call.name) {
            AgentMailSkill.shared.handle(functionCall: call, completion: completion); return
        }
        #if canImport(HealthKit) && os(iOS)
        if HealthSkill.shared.handles(functionName: call.name) {
            HealthSkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        #endif
        #if os(iOS)
        if StorySkill.shared.handles(functionName: call.name) {
            StorySkill.shared.handle(functionCall: call, completion: guardedCompletion); return
        }
        if BrowseSkill.shared.handles(functionName: call.name) {
            BrowseSkill.shared.handle(functionCall: call, completion: completion); return
        }
        #endif

        // Runtime-registered skills (Mac-only). Checked under the lock so a
        // concurrent register() can't tear the iteration.
        lock.lock()
        let snapshot = registered
        lock.unlock()
        for entry in snapshot where entry.handles(call.name) {
            entry.handle(call, guardedCompletion)
            return
        }

        // Dynamic (user-authored JS) skills last — they're hot-loaded so the
        // registry is the source of truth for what's currently available.
        if DynamicSkillRegistry.shared.handles(functionName: call.name) {
            DynamicSkillRegistry.shared.handle(functionCall: call, completion: guardedCompletion)
            return
        }

        // Remote MCP tools installed via Settings → Skills. Names are
        // namespaced `<server>__<tool>` so they can't collide with anything
        // checked above.
        if MCPRegistry.shared.handles(functionName: call.name) {
            MCPRegistry.shared.handle(functionCall: call, completion: guardedCompletion)
            return
        }

        // Unknown — synthesize a structured error the model can read.
        completion(MessageStruct(
            role: "function",
            content: "{\"status\":\"error\",\"error\":\"Unknown tool \(call.name)\"}",
            name: call.name
        ))
    }
}
