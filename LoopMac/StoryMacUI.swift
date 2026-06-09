//
//  StoryMacUI.swift
//  LoopMac
//
//  Mac UI for the Stories feature. Mirrors the iOS StoryPlayerVC / inline
//  card, but in AppKit:
//   - `StoryBubbleView` is the inline portrait card painted into the
//     conversation transcript (generating / ready / failed states), matching
//     the ImageBubbleView / PDFBubbleView pattern.
//   - `StoryPlayerWindowController` opens the rendered 1080×1920 HTML in a
//     portrait window with click/arrow tap-to-advance, driving the same
//     `window.StoryBridge` JS API the iOS player uses.
//
//  The cross-platform pieces (StorySkill, StoryGenerationService,
//  StoryGenerator, StoryAttachment, StoryBundledTemplates) are shared with
//  iOS; only the presentation layer differs.
//

import AppKit
import WebKit

// MARK: - Inline card

/// Inline assistant bubble for a generated story on Mac. Three states match
/// the iOS story card:
/// - `.generating` — spinner over a portrait placeholder + "Creating story…"
/// - `.ready` — gradient poster with the title + a play glyph; click to open
///   the full-screen player.
/// - `.failed` — error text + a Try again button that re-renders the same id.
final class StoryBubbleView: NSView {
    private(set) var attachment: StoryAttachment

    private let onOpen: (StoryAttachment) -> Void
    private let onRetry: (StoryAttachment) -> Void

    private let card = NSView()
    private let poster = NSView()
    private let posterGradient = CAGradientLayer()
    private let glyph = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Try again", target: nil, action: nil)

    init(attachment: StoryAttachment,
         onOpen: @escaping (StoryAttachment) -> Void,
         onRetry: @escaping (StoryAttachment) -> Void) {
        self.attachment = attachment
        self.onOpen = onOpen
        self.onRetry = onRetry
        super.init(frame: .zero)
        configure()
        update(attachment: attachment)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        addSubview(card)

        // Portrait poster (9:16) — gradient backdrop with a centered glyph.
        poster.translatesAutoresizingMaskIntoConstraints = false
        poster.wantsLayer = true
        poster.layer?.cornerRadius = 10
        poster.layer?.masksToBounds = true
        posterGradient.colors = [
            NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.85, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.85, green: 0.30, blue: 0.55, alpha: 1).cgColor,
        ]
        posterGradient.startPoint = CGPoint(x: 0, y: 0)
        posterGradient.endPoint = CGPoint(x: 1, y: 1)
        poster.layer?.addSublayer(posterGradient)
        card.addSubview(poster)

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = .white
        glyph.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Play story")
        poster.addSubview(glyph)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .darkAqua)
        poster.addSubview(spinner)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.wraps = true
        card.addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(subtitleLabel)

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = NSFont.systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3
        errorLabel.cell?.wraps = true
        errorLabel.isHidden = true
        card.addSubview(errorLabel)

        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.isHidden = true
        card.addSubview(retryButton)

        // 132×235 poster ≈ 9:16; the whole card hugs that width.
        let posterW: CGFloat = 132
        let posterH: CGFloat = 235
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            poster.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            poster.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            poster.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            poster.widthAnchor.constraint(equalToConstant: posterW),
            poster.heightAnchor.constraint(equalToConstant: posterH),

            glyph.centerXAnchor.constraint(equalTo: poster.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: poster.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 44),
            glyph.heightAnchor.constraint(equalToConstant: 44),

            spinner.centerXAnchor.constraint(equalTo: poster.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: poster.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: poster.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: poster.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: poster.bottomAnchor, constant: 8),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            errorLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            errorLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 4),

            retryButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            retryButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 8),

            card.bottomAnchor.constraint(greaterThanOrEqualTo: subtitleLabel.bottomAnchor, constant: 12),
            card.bottomAnchor.constraint(greaterThanOrEqualTo: retryButton.bottomAnchor, constant: 12),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(cardTapped))
        poster.addGestureRecognizer(click)
    }

    override func layout() {
        super.layout()
        posterGradient.frame = poster.bounds
    }

    func update(attachment: StoryAttachment) {
        self.attachment = attachment
        titleLabel.stringValue = attachment.title.isEmpty ? "Story" : attachment.title

        switch attachment.status {
        case .generating:
            spinner.startAnimation(nil)
            glyph.isHidden = true
            subtitleLabel.stringValue = "Creating story…"
            errorLabel.isHidden = true
            retryButton.isHidden = true
        case .ready:
            spinner.stopAnimation(nil)
            glyph.isHidden = false
            subtitleLabel.stringValue = "Tap to play"
            errorLabel.isHidden = true
            retryButton.isHidden = true
        case .failed:
            spinner.stopAnimation(nil)
            glyph.isHidden = true
            subtitleLabel.stringValue = "Couldn't create story"
            errorLabel.stringValue = attachment.failureReason ?? "Unknown error."
            errorLabel.isHidden = false
            retryButton.isHidden = false
        }
    }

    @objc private func cardTapped() {
        guard attachment.status == .ready else { return }
        onOpen(attachment)
    }

    @objc private func retryTapped() { onRetry(attachment) }
}

// MARK: - Full-screen player

/// Hosts the rendered story HTML in a portrait window. Click the right 70% to
/// advance, the left 30% to go back; arrow keys + space also work. Drives the
/// same `window.StoryBridge` API as the iOS player.
final class StoryPlayerWindowController: NSWindowController {
    private let fileURL: URL
    private let webView: WKWebView
    private let contentView: StoryPlayerContentView

    init(attachment: StoryAttachment) {
        // Stories render at 1080×1920; show a half-ish-scale portrait window.
        let size = NSSize(width: 405, height: 720)
        self.fileURL = attachment.fileURL ?? URL(fileURLWithPath: "/dev/null")

        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        // 1080pt content scaled to the window width.
        web.pageZoom = size.width / 1080.0
        self.webView = web

        let content = StoryPlayerContentView(frame: NSRect(origin: .zero, size: size))
        content.webView = web
        web.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.topAnchor.constraint(equalTo: content.topAnchor),
            web.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        self.contentView = content

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = attachment.title.isEmpty ? "Story" : attachment.title
        // The controller owns the window; without this AppKit would over-
        // release it on close and crash under ARC.
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.contentView = content
        window.center()
        window.contentAspectRatio = NSSize(width: 9, height: 16)

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(contentView)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension StoryPlayerWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Retained by ConversationWindowController; drop the reference there so
        // the player + WKWebView deallocate. Posting is simplest given the
        // controller is stored weakly-by-intent on the conversation window.
        NotificationCenter.default.post(name: .storyPlayerDidClose, object: self)
    }
}

extension Notification.Name {
    static let storyPlayerDidClose = Notification.Name("LoopMacStoryPlayerDidClose")
}

/// First-responder content view that turns clicks + arrow keys into
/// StoryBridge navigation. Left 30% = back, right 70% = forward.
final class StoryPlayerContentView: NSView {
    weak var webView: WKWebView?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if x < bounds.width * 0.3 {
            retreat()
        } else {
            advance()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123:            // left arrow
            retreat()
        case 124, 49:        // right arrow, space
            advance()
        case 53:             // esc
            window?.performClose(nil)
        default:
            super.keyDown(with: event)
        }
    }

    private func advance() {
        webView?.evaluateJavaScript("window.StoryBridge && window.StoryBridge.advance()", completionHandler: nil)
    }

    private func retreat() {
        webView?.evaluateJavaScript("window.StoryBridge && window.StoryBridge.retreat()", completionHandler: nil)
    }
}
