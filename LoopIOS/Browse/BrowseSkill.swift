//
//  BrowseSkill.swift
//  Loop
//
//  Skill definition for `browse` — drive a real on-device WebKit web view to
//  fetch, render, and navigate JavaScript-heavy pages on the user's behalf.
//  Unlike `fetch_url` / `exa_search` (fast, text-only), `browse` exists for
//  when the UI and visual interface actually matter: "check the Apple homepage
//  and tell me what changed", anything needing JS rendering, clicking through,
//  or seeing the page.
//
//  Visible by default: each session drops a live preview card on the assistant
//  message (like the story skill) and, when it ends, the card flips into a
//  scrubbable replay of the frames the agent saw.
//
//  Blocking-by-design: the handler runs the whole session and returns the
//  grounded { summary, final_url, observations[], replay_id } so the model's
//  reply is anchored in what it actually saw.
//

#if os(iOS)

import UIKit

final class BrowseSkill {
    static let shared = BrowseSkill()
    private init() {}

    static let systemPromptFragment: String = """
You can drive a real on-device web browser with the `browse` tool. It opens a \
WebKit web view, renders the page (JavaScript included), and an internal agent \
loop reads the DOM, scrolls, and clicks through to accomplish a natural-language \
task — capturing a screenshot + DOM snapshot at every step.

When to use `browse` (vs the faster text-only `fetch_url` / `exa_search`):
- The visual interface or live UI matters: "check the Apple homepage and tell me \
  what changed", "what's on the front page of X right now", "see if the hero \
  section changed".
- The page is JavaScript-heavy and `fetch_url` returns empty/garbled text.
- The task needs interaction: clicking through, filling a field, scrolling to \
  load more, navigating between pages.

How to call it:
- `url` (required): the page to open.
- `instructions`: what to look for / do, in natural language (e.g. "see if \
  anything's changed on the hero section, report the headline and main CTA").
- `max_steps` (optional, default 10): how many read/click/scroll steps the \
  internal agent may take.
- `viewport` (optional, e.g. "390x844"): defaults to iPhone-sized.

The tool BLOCKS until the session finishes and returns a grounded summary plus \
a replay id. A live preview card appears in the chat while it runs and becomes a \
scrubbable replay afterward — so after it returns, write a short reply grounded in \
the returned summary; don't restate the whole page. Each session is stateless \
(no cookies, fresh data store every call), so if you need a before/after diff, \
browse the baseline in the same call.
"""

    /// The user-facing tool the primary agent calls.
    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "browse",
                "description": "Drive a real on-device WebKit browser to open, render (JS included), and navigate a web page to accomplish a natural-language task. Use when the visual/live UI matters or the page is JS-heavy — not for plain text (use fetch_url for that). Shows a live preview card and returns a grounded { summary, final_url, observations, replay_id }.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "url": [
                            "type": "string",
                            "description": "The page to open (http/https). Scheme optional — 'apple.com' works.",
                        ],
                        "instructions": [
                            "type": "string",
                            "description": "Natural-language task: what to look for or do, e.g. 'see if the hero section changed and report the headline and CTA'.",
                        ],
                        "max_steps": [
                            "type": "integer",
                            "description": "Max read/click/scroll steps the internal agent may take. Default 10.",
                        ],
                        "viewport": [
                            "type": "string",
                            "description": "Viewport size as WxH, e.g. '390x844'. Defaults to iPhone-sized.",
                        ],
                    ] as [String: Any],
                    "required": ["url"],
                ] as [String: Any],
            ] as [String: Any],
        ]
    ]

    /// The internal tool the browse agent loop drives (one action per step).
    /// Not exposed to the primary agent — only sent on the nested model calls
    /// inside BrowseSession. Registered in ToolRouter.coreToolNames so routing
    /// never strips it from those nested calls.
    static let actionTools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "browse_action",
                "description": "Perform one browsing action on the current page and get the resulting page state back.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["read", "click", "type", "scroll", "wait_for", "query", "eval_js", "finish"],
                            "description": "The action to perform this step.",
                        ],
                        "selector": [
                            "type": "string",
                            "description": "CSS selector for click/type/scroll/wait_for/query/read.",
                        ],
                        "text": [
                            "type": "string",
                            "description": "Text to type (action 'type').",
                        ],
                        "direction": [
                            "type": "string",
                            "enum": ["down", "up"],
                            "description": "Scroll direction (action 'scroll').",
                        ],
                        "js": [
                            "type": "string",
                            "description": "JavaScript body to evaluate (action 'eval_js'). Should `return` a value.",
                        ],
                        "summary": [
                            "type": "string",
                            "description": "Grounded summary answering the task (action 'finish').",
                        ],
                        "observations": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Short bullet observations gathered from the page (action 'finish').",
                        ],
                    ] as [String: Any],
                    "required": ["action"],
                ] as [String: Any],
            ] as [String: Any],
        ]
    ]

    static let toolNames: Set<String> = ["browse"]

    func handles(functionName: String) -> Bool {
        return BrowseSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        guard call.name == "browse" else { return nil }
        if let raw = (call.arguments["url"] as? String), !raw.isEmpty {
            let host = URL(string: raw.contains("://") ? raw : "https://\(raw)")?.host ?? raw
            return "browsing \(host)"
        }
        return "browsing the web"
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        guard functionCall.name == "browse" else {
            completion(MessageStruct(role: "function",
                                     content: "Unknown tool \(functionCall.name).",
                                     name: functionCall.name))
            return
        }

        let raw = (functionCall.arguments["url"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            completion(MessageStruct(role: "function",
                                     content: "I need a `url` to browse.",
                                     name: "browse"))
            return
        }
        let normalized = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: normalized), url.host != nil else {
            completion(MessageStruct(role: "function",
                                     content: "'\(raw)' isn't a valid http/https URL.",
                                     name: "browse"))
            return
        }

        let instructions = (functionCall.arguments["instructions"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "Open the page and report what you see."
        let maxSteps = max(1, min(20, BrowseSkill.intArg(functionCall.arguments["max_steps"]) ?? 10))
        let viewport = BrowseSkill.parseViewport(functionCall.arguments["viewport"] as? String)
        let convId = functionCall.conversationId

        Task { @MainActor in
            let session = await BrowseGenerationService.shared.run(
                url: url,
                instructions: instructions,
                maxSteps: maxSteps,
                viewport: viewport,
                conversationId: convId
            )
            completion(MessageStruct(
                role: "function",
                content: session.toolResultJSON(),
                name: "browse"
            ))
        }
    }

    // MARK: - Helpers

    private static func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func parseViewport(_ s: String?) -> CGSize {
        let fallback = CGSize(width: 390, height: 844) // iPhone-sized default
        guard let s = s?.lowercased() else { return fallback }
        let parts = s.split(separator: "x")
        guard parts.count == 2,
              let w = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              w > 100, h > 100 else { return fallback }
        return CGSize(width: w, height: h)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#endif
