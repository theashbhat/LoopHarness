//
//  BrowseAttachment.swift
//  Loop
//
//  Defines the browse attachment type for chat messages. Mirrors the
//  StoryAttachment / PDFAttachment pattern: starts at .navigating, updates
//  through .reading as the on-device agent drives the page, and finishes at
//  .done (with a summary + replay bundle) or .failed (with a reason).
//
//  A browse session is STATELESS by design — no cookies, no login persistence.
//  Each session writes a `.browsereplay`-style bundle to the workspace at
//  workspace://browse/<id>/ holding per-step screenshot + DOM-snapshot pairs.
//

import Foundation

/// One captured step of a browse session — the frame the agent saw at that
/// point in the trip. Persisted (minus the heavy PNG/HTML, which live as
/// sibling files) into the replay bundle's manifest.json so the player can
/// reconstruct a scrubbable timeline.
struct BrowseFrame: Codable, Equatable {
    /// Seconds since the session started (monotonic ordering for the scrubber).
    let ts: TimeInterval
    /// The URL the page was showing when this frame was captured.
    let url: String
    /// Human-readable description of the action that produced this frame
    /// (e.g. "navigate", "click .cta", "scroll down", "read").
    let action: String
    /// Filename of the PNG screenshot in the bundle (sibling of manifest.json).
    let screenshot: String
    /// Filename of the HTML DOM snapshot in the bundle.
    let domSnapshot: String
    /// Viewport the frame was captured at, e.g. "390x844".
    let viewport: String
}

/// The replay bundle manifest — the index file written at the root of a
/// `workspace://browse/<id>/` directory.
struct BrowseReplayManifest: Codable {
    let replayId: String
    let url: String
    let instructions: String
    var finalURL: String?
    var summary: String?
    var frames: [BrowseFrame]
}

/// A live/replayable browse session attached to a chat message. The cell
/// renders it as a small preview card (latest screenshot + URL + status pill);
/// tapping opens the full-screen player — a read-only live view while the
/// agent drives, flipping to a scrubbable replay once the session ends.
struct BrowseAttachment: Codable {
    enum Status: String, Codable, Equatable {
        case navigating   // loading / moving between pages
        case reading      // parsing DOM, deciding next action
        case done         // finished — summary + replay ready
        case failed       // errored — see failureReason
    }

    /// Doubles as the `replay_id`.
    let id: String
    /// The URL the session was asked to open.
    let url: String
    /// The natural-language task the agent was given.
    let instructions: String

    var status: Status
    /// Short status detail shown under the pill (e.g. the current URL, or
    /// "Reading hero section").
    var statusDetail: String?
    /// Number of agent steps executed so far.
    var stepCount: Int
    /// Absolute file path to the most recent screenshot PNG — drives the card
    /// thumbnail and the live-preview poster frame.
    var latestThumbnailPath: String?
    /// Absolute path to the replay bundle directory (workspace://browse/<id>/).
    var replayDirPath: String?

    /// Final grounded summary of what the agent observed (filled on .done).
    var summary: String?
    /// The URL the session ended on.
    var finalURL: String?

    var failureReason: String?
    let conversationId: String?

    init(id: String = UUID().uuidString,
         url: String,
         instructions: String,
         status: Status = .navigating,
         statusDetail: String? = nil,
         stepCount: Int = 0,
         latestThumbnailPath: String? = nil,
         replayDirPath: String? = nil,
         summary: String? = nil,
         finalURL: String? = nil,
         failureReason: String? = nil,
         conversationId: String? = nil) {
        self.id = id
        self.url = url
        self.instructions = instructions
        self.status = status
        self.statusDetail = statusDetail
        self.stepCount = stepCount
        self.latestThumbnailPath = latestThumbnailPath
        self.replayDirPath = replayDirPath
        self.summary = summary
        self.finalURL = finalURL
        self.failureReason = failureReason
        self.conversationId = conversationId
    }

    /// The user-facing status pill text — Navigating… / Reading… / Done.
    var pillText: String {
        switch status {
        case .navigating: return "Navigating…"
        case .reading:    return "Reading…"
        case .done:       return "Done"
        case .failed:     return "Failed"
        }
    }

    /// Host display label for the URL (host only, no scheme/path) for the card.
    var displayHost: String {
        if let u = URL(string: url), let host = u.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return url
    }
}
