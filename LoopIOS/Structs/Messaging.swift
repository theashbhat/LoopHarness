//
//  Messaging.swift
//  Loop
//
//  Created by Ash Bhat on 11/2/24.
//

import Foundation
import CoreLocation

// MARK: - Active-request tracker

/// Lightweight thread-safe set of conversation ids that currently have an
/// in-flight LLM request. The sidebar reads this (via `isActive(for:)`)
/// alongside `SubAgentManager.aggregateLiveCount` to light up the
/// running-indicator dot. Only the chat VC mutates the set.
final class ActiveRequestTracker {
    static let shared = ActiveRequestTracker()
    private var ids: Set<String> = []
    private let lock = NSLock()

    func markActive(_ conversationId: String) {
        lock.lock(); defer { lock.unlock() }
        ids.insert(conversationId)
    }

    func markIdle(_ conversationId: String) {
        lock.lock(); defer { lock.unlock() }
        ids.remove(conversationId)
    }

    func isActive(for conversationId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(conversationId)
    }
}

enum MesssageActions {
    case upload_driver_id
}

/// Lightweight projection of a SimpleConversation for sidebar/list rendering.
/// Lives here (not in SideDrawerViewController.swift) so the macOS target can
/// see it without pulling in UIKit.
struct Conversation {
    let id: String
    let title: String
    let lastMessage: String
    let timestamp: Date
    /// True when at least one agent/sub-agent/tool run is active for this
    /// conversation. Drives the running-indicator dot in the sidebar row.
    var isRunning: Bool = false
    /// Execution backend marker — `.local` or `.openclaw`. Drives the small
    /// backend badge on the conversation row so OpenClaw-backed chats are
    /// distinguishable from local ones. Defaults to `.local`.
    var backend: ConversationBackend = .local
}

struct FunctionCallStruct {
    var name: String
    var arguments: [String: Any]
    /// Provider-issued id for this call. Anthropic returns it as `tool_use.id`;
    /// OpenAI returns it as `tool_calls[].id`. Carried so the matching tool
    /// result can pair back to this call via `MessageStruct.callId`. Nil for
    /// legacy messages that pre-date structured tool blocks.
    var callId: String? = nil
    /// Conversation the call originated from. Stamped by the dispatching
    /// coordinator (Mac per-tab, iOS single-thread) BEFORE handing the
    /// call to a skill, so the skill never has to fall back on the
    /// global `SimpleConversationManager.currentConversation` — that
    /// global tracks the user's active tab and is unsafe to read from
    /// async tool dispatch on multi-tab Mac (user can switch tabs between
    /// the model emitting the tool call and the skill handling it).
    /// Skills that need conversation context (SubAgentSkill,
    /// TerminalSkill) read this first, fall back to the global, and only
    /// then give up.
    var conversationId: String? = nil
}

/// Provider-returned token counts for a single completion.
struct TokenUsage {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int

    /// Percentage of the model's context window consumed by the prompt,
    /// or `nil` when the window size is unknown.
    func contextPercent(windowSize: Int?) -> Int? {
        guard let window = windowSize, window > 0 else { return nil }
        let pct = Int((Double(totalTokens) / Double(window)) * 100)
        return min(pct, 100)
    }
}

struct MessageStruct {
    var id: String = UUID().uuidString
    var role: String
    var content: String
    var model: String = "GPT 5.5 Instant"
    var name: String? = nil
    /// All function calls emitted in this assistant turn. Anthropic and OpenAI
    /// can return multiple `tool_use` / `tool_calls` entries in a single
    /// response — keeping them in one MessageStruct preserves the "one
    /// assistant turn, many calls" shape the providers expect on replay.
    var functions: [FunctionCallStruct] = []
    /// Back-compat shim — most call sites still read `.function` as a single
    /// optional. Reading returns the first call; writing replaces the array
    /// with one entry (or clears it on nil).
    var function: FunctionCallStruct? {
        get { functions.first }
        set {
            if let v = newValue { functions = [v] }
            else { functions = [] }
        }
    }
    /// Set on a `role:"function"` tool-result message — matches the `callId`
    /// of the originating `FunctionCallStruct` so the wire payload can pair
    /// `tool_use` with `tool_result` (Anthropic) or `tool_calls[].id` with
    /// `role:"tool"` (OpenAI).
    var callId: String? = nil
    var actions: [MesssageActions] = []
    var polling_locations: [PollLocationStruct] = []
    /// Attached generated image, if any. Set by ImageSkill via the host
    /// protocol so the cell can render it inline. Mutable so the cell can
    /// flip status from .generating → .ready/.failed without rebuilding the
    /// whole message.
    var imageAttachment: ImageAttachment? = nil
    /// Attached generated PDF, if any. Set by PDFSkill via PDFSkillHost so
    /// the chat cell can render a thumbnail + page count + preview/share
    /// buttons inline. Same .generating → .ready/.failed lifecycle as
    /// `imageAttachment`.
    var pdfAttachment: PDFAttachment? = nil
    /// User-uploaded image or PDF attached to this turn. Kept separate from
    /// `imageAttachment` so the ImageSkill output flow and the user-upload
    /// input flow can coexist on the same message in the future.
    var fileAttachment: FileAttachment? = nil
    /// Map embed with pinned places, set by MapsSkill when the model calls
    /// `show_places_on_map`. Cell renders an inline MKMapView with annotations
    /// that callout to Apple Maps. Synchronous — no `.generating` lifecycle.
    var mapAttachment: MapAttachment? = nil
    /// Set when this message belongs to the conversational onboarding flow.
    /// Drives `MessagingCell` to render an interactive card (text field,
    /// choice buttons, key paste, etc.) under the message body. Onboarding
    /// messages are filtered out of LLM context and suppressed from TTS so
    /// the bootstrap script doesn't bleed into the real conversation.
    var onboardingCard: OnboardingCardKind? = nil
    /// True when this message is a synthetic compaction summary generated by
    /// opportunistic context compaction. Used to identify and replace the
    /// summary on subsequent compaction runs, and to filter it out of the
    /// UI-visible message list.
    var isCompactionSummary: Bool = false
    /// Provider-returned reasoning/thinking content for this assistant turn.
    /// Kimi K2.6 returns `reasoning_content` alongside `tool_calls` when
    /// thinking is enabled; the field must be replayed on subsequent requests
    /// or the API rejects the message with "reasoning_content is missing".
    var reasoningContent: String? = nil
    /// Provider-returned token usage for this assistant turn. Populated by
    /// OpenAIChat / AnthropicChat / FireworksChat from the response's
    /// `usage` object. `nil` for on-device Apple responses and older
    /// persisted messages.
    var tokenUsage: TokenUsage? = nil

    /// Explicit init that still accepts `function:` as a singular optional —
    /// keeps existing call sites compiling now that `function` is a computed
    /// view over the underlying `functions` array.
    init(id: String = UUID().uuidString,
         role: String,
         content: String,
         model: String = "GPT 5.5 Instant",
         name: String? = nil,
         function: FunctionCallStruct? = nil,
         functions: [FunctionCallStruct] = [],
         callId: String? = nil,
         actions: [MesssageActions] = [],
         polling_locations: [PollLocationStruct] = [],
         imageAttachment: ImageAttachment? = nil,
         pdfAttachment: PDFAttachment? = nil,
         fileAttachment: FileAttachment? = nil,
         mapAttachment: MapAttachment? = nil,
         onboardingCard: OnboardingCardKind? = nil,
         reasoningContent: String? = nil,
         tokenUsage: TokenUsage? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.model = model
        self.name = name
        // If a caller passes the singular `function`, prefer it; otherwise
        // use the plural array as-is. Callers don't pass both.
        if let function = function {
            self.functions = [function]
        } else {
            self.functions = functions
        }
        self.callId = callId
        self.actions = actions
        self.polling_locations = polling_locations
        self.imageAttachment = imageAttachment
        self.pdfAttachment = pdfAttachment
        self.fileAttachment = fileAttachment
        self.mapAttachment = mapAttachment
        self.onboardingCard = onboardingCard
        self.reasoningContent = reasoningContent
        self.tokenUsage = tokenUsage
    }

    /// Generic JSON representation of the message. Provider-specific chat
    /// clients (`AnthropicChat`, `OpenAIChat`) build their own per-request
    /// payloads from `MessageStruct` fields directly and ignore the
    /// `attachment`/`attachment_type` keys produced here. Only image / PDF
    /// kinds inline their bytes — text-based kinds (markdown, source) ride
    /// along via `assistantHint` and don't need a base64 payload.
    var dict: [String: Any] {
        var out: [String: Any] = ["role": role, "content": content]
        if let name = name { out["name"] = name }
        if let f = fileAttachment,
           f.status == .ready,
           (f.kind == .image || f.kind == .pdf),
           let data = try? Data(contentsOf: f.fileURL) {
            out["attachment"] = data.base64EncodedString()
            out["attachment_type"] = (f.kind == .pdf) ? "PDF" : "JPEG"
        }
        return out
    }
}

/// User-uploaded file attached to an outgoing message. Persisted in the
/// workspace's `attachments/` folder so the URL survives app restarts and
/// CloudKit sync. Status starts at `.pending` while we're copying the bytes
/// off the picker's security-scoped URL and flips to `.ready` once the file
/// is durable in the workspace.
struct FileAttachment: Codable {
    enum Kind: String, Codable, Equatable {
        case image
        case pdf
        /// `.md` / `.markdown` and friends. Tap opens the in-app markdown
        /// editor rather than QuickLook so the rendered Markdown styling
        /// matches the rest of the app.
        case markdown
        /// Plain text or source code. `languageTag` distinguishes the two:
        /// nil for a generic `.txt` / `.log` / `.csv`, a short identifier
        /// like "swift" / "python" / "json" for a recognized source file.
        case text
        /// Catch-all for everything we can't preview inline (archives,
        /// office docs, unknown MIME types). Renders as an icon+name+size
        /// card; tap hands off to QuickLook which falls back to the system
        /// handler when it can't display the file itself.
        case generic
    }

    enum Status: String, Codable, Equatable {
        case pending
        case ready
        case failed
    }

    let id: String
    /// Absolute URL to the file inside `Workspace.shared.rootURL`. Persisting
    /// the resolved URL keeps the storage iCloud-synced; downstream code can
    /// re-derive a workspace-relative path via `Workspace.shared.relativePath`.
    var fileURL: URL
    let fileName: String
    let kind: Kind
    let mimeType: String
    /// For `.text` kind only: short lowercase language identifier ("swift",
    /// "json", "python"). Drives the language badge in the preview card and
    /// the `assistantHint` label. Nil for plain text / non-source kinds.
    let languageTag: String?
    var status: Status
    var failureReason: String?
    /// For PDFs / markdown / text: text extracted from the document at save
    /// time so the model can read the contents inline. Truncated to a fixed
    /// cap (`extractedTextCharCap`) to keep the chat payload reasonable. Nil
    /// for images (Vision OCR runs but may yield nothing) and `.generic`.
    var extractedText: String?

    init(id: String = UUID().uuidString,
         fileURL: URL,
         fileName: String,
         kind: Kind,
         mimeType: String,
         languageTag: String? = nil,
         status: Status = .ready,
         failureReason: String? = nil,
         extractedText: String? = nil) {
        self.id = id
        self.fileURL = fileURL
        self.fileName = fileName
        self.kind = kind
        self.mimeType = mimeType
        self.languageTag = languageTag
        self.status = status
        self.failureReason = failureReason
        self.extractedText = extractedText
    }

    /// Maximum number of characters from `extractedText` to inline in a
    /// chat message body. Roughly 40KB at one byte per char — enough for
    /// most short-to-medium PDFs without blowing past sensible token limits.
    static let extractedTextCharCap = 40_000

    /// Compact human-and-model-readable tag that gets appended to the chat
    /// message's `content` so the assistant knows a file is attached. The
    /// path uses a `workspace://` prefix so it's unambiguous about where to
    /// look. For PDFs we additionally inline the extracted text between
    /// fenced markers so the model can answer questions about the file
    /// without needing a tool call.
    var assistantHint: String {
        let kindLabel: String
        switch kind {
        case .pdf:      kindLabel = "PDF"
        case .image:    kindLabel = "image"
        case .markdown: kindLabel = "markdown"
        case .text:     kindLabel = languageTag.map { "\($0) source" } ?? "text"
        case .generic:  kindLabel = "file"
        }
        let workspaceRelative = fileURL.lastPathComponent
        let header = "[Attached file: \(fileName) (\(kindLabel)) at workspace://attachments/\(workspaceRelative)]"

        guard let text = extractedText, !text.isEmpty else {
            return header
        }
        let truncated: String
        if text.count > Self.extractedTextCharCap {
            let endIndex = text.index(text.startIndex, offsetBy: Self.extractedTextCharCap)
            truncated = String(text[..<endIndex]) + "\n\n[...truncated, full file in workspace...]"
        } else {
            truncated = text
        }
        return """
        \(header)
        [File content begin]
        \(truncated)
        [File content end]
        """
    }
}

/// Inline PDF attached to an assistant chat message. Created in the
/// .generating state when `generate_pdf` fires, then mutated in place to
/// .ready (with fileURL, thumbnailURL, pageCount) or .failed (with reason)
/// when PDFGenerationService finishes the render. The original `document`
/// is held so retry can re-render without re-asking the model.
struct PDFAttachment {
    enum Status: Equatable {
        case generating
        case ready
        case failed
    }

    let id: String
    let title: String
    let template: String
    /// Source GFM markdown. Carried on the attachment so a retry from the
    /// failed-state UI can re-run the same render without round-tripping
    /// through the model.
    let document: String
    var fileURL: URL?
    var thumbnailURL: URL?
    var pageCount: Int?
    var status: Status
    var failureReason: String?
    /// Conversation the render belongs to (mirrors `ImageAttachment` for
    /// multi-tab Mac routing). Optional for single-tab callers.
    let conversationId: String?

    init(id: String = UUID().uuidString,
         title: String,
         template: String,
         document: String,
         fileURL: URL? = nil,
         thumbnailURL: URL? = nil,
         pageCount: Int? = nil,
         status: Status = .generating,
         failureReason: String? = nil,
         conversationId: String? = nil) {
        self.id = id
        self.title = title
        self.template = template
        self.document = document
        self.fileURL = fileURL
        self.thumbnailURL = thumbnailURL
        self.pageCount = pageCount
        self.status = status
        self.failureReason = failureReason
        self.conversationId = conversationId
    }
}

/// Inline image attached to a chat message. Created in the .generating state
/// when an image-generation tool call kicks off, then mutated in place to
/// .ready (with fileURL) or .failed (with reason) when the call completes.
struct ImageAttachment {
    enum Status: Equatable {
        case generating
        case ready
        case failed
    }

    let id: String
    let prompt: String
    var fileURL: URL?
    var status: Status
    var failureReason: String?
    /// Conversation the generation belongs to. Captured at submit time so the
    /// host can route the bubble to the right tab on multi-tab Mac, even if
    /// the user switches tabs between "tool call fired" and "image ready".
    /// Optional for backward compatibility with callers (iOS / older paths)
    /// that don't supply it — those clients render whatever conversation is
    /// currently visible, which is the right behavior for single-tab UIs.
    let conversationId: String?

    init(id: String = UUID().uuidString,
         prompt: String,
         fileURL: URL? = nil,
         status: Status = .generating,
         failureReason: String? = nil,
         conversationId: String? = nil) {
        self.id = id
        self.prompt = prompt
        self.fileURL = fileURL
        self.status = status
        self.failureReason = failureReason
        self.conversationId = conversationId
    }
}

/// One place rendered as a pin on the inline map embed.
struct MapPlace: Codable, Equatable {
    let name: String
    let latitude: Double
    let longitude: Double
    /// Optional street address — shown under the name in the callout and used
    /// when handing the place off to Apple Maps so the destination sheet has a
    /// human-readable label.
    let address: String?

    init(name: String, latitude: Double, longitude: Double, address: String? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
    }
}

/// Inline map embed attached to a message by MapsSkill. The cell renders an
/// MKMapView fitted to the place set with a callout per pin that deep-links
/// into Apple Maps. Synchronous lifecycle — the model already supplies the
/// coordinates, so there's no `.generating` state like images / PDFs.
struct MapAttachment: Codable, Equatable {
    let id: String
    /// Optional caption shown above the map (e.g. "Coffee near you").
    let title: String?
    let places: [MapPlace]
    var conversationId: String?

    init(id: String = UUID().uuidString,
         title: String? = nil,
         places: [MapPlace],
         conversationId: String? = nil) {
        self.id = id
        self.title = title
        self.places = places
        self.conversationId = conversationId
    }
}

/// Interactive card rendered under an onboarding message in `MessagingCell`.
/// The script (in `OnboardingCoordinator`) drives which card to attach to each
/// turn; the cell switches on the case to build the right UI. Equatable so the
/// table view can diff cells cheaply.
enum OnboardingCardKind: Equatable {
    /// Compact wrapping row of suggestion chips below the message text.
    /// Tapping a chip fires `.choiceSelected(optionId:)`. Used for every
    /// step that's just "pick one" — naming, model choice, integrations,
    /// TTS, etc. The user can also type free text in the message bar to
    /// answer without using the chips.
    case suggestions(options: [OnboardingChoiceOption])
    /// The rich action-button walkthrough: hero tile, mock Settings rows,
    /// "Open Settings" + "Skip" chips. Visuals ported from the old modal.
    /// Stays inline because the numbered Settings facsimile is information
    /// the user needs while they're configuring iOS Settings.
    case actionButtonWalkthrough
    /// Sentinel marking an onboarding bubble whose user has already replied.
    /// Renders nothing (just the prose stays). We swap the card to this
    /// value instead of removing the bubble so scroll position is preserved
    /// and the prompt remains in the transcript.
    case answered
}

/// One option in a `.choices` card. `id` is the opaque identifier the
/// coordinator switches on; `label` is what the user sees.
struct OnboardingChoiceOption: Equatable {
    let id: String
    let label: String
}

/// Integrations offered during onboarding. Maps 1:1 to the existing connect
/// flows in `IntegrationsVC`. Kept narrow on purpose — the long tail of
/// integrations (Obsidian, Devin, etc.) lives in Settings for later.
enum OnboardingIntegrationKind: String, Equatable {
    case notion
    case github
    case slack
}

struct PollLocationStruct {
    var name: String
    var full_address: String
    var polling_hours: String
    var location: CLLocationCoordinate2D
    var startDate: String
    var endDate: String
    
    var stringRepresentation: String {
        return "{address: \(full_address), polling_hours: \(polling_hours), location_lat: \(location.latitude), location_lon: \(location.longitude), startDate: \(startDate), endDate: \(endDate) }"
    }
}


var tools: [[String: Any]] = {
    var all: [[String: Any]] = []
    all += NotionSkill.tools
    all += SlackSkill.tools
    all += SchedulerSkill.tools
    all += ExaSkill.tools
    all += URLFetchSkill.tools
    all += GitSkill.tools
    all += GitHubSkill.tools
    all += SelfImprovementSkill.tools
    all += FileSystemSkill.tools
    all += SpecBuilderSkill.tools
    all += LocationSkill.tools
    all += MapsSkill.tools
    all += ImageSkill.tools
    all += PDFSkill.tools
    all += ObsidianSkill.tools
    all += CalendarSkill.tools
    all += MusicSkill.tools
    all += SkillBuilderSkill.tools
    all += SubAgentSkill.tools
    all += IntegrationSkill.tools
    all += NavigationSkill.tools
    all += CursorSkill.tools
    all += DevinSkill.tools
    all += TwitterSkill.tools
    all += SSHSkill.tools
    all += MuniRealtimeSkill.tools
    #if canImport(HealthKit) && os(iOS)
    all += HealthSkill.tools
    #endif
    // Dynamic, user-authored skills get appended in AgentHarness at every
    // chat turn so newly hot-loaded skills become visible without restart.
    return all
}()
