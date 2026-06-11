//
//  RecorderWindowController.swift
//  LoopMac
//
//  Slim floating bar pinned bottom-center of the active screen, matching
//  LoopIOS/Specs/mac_recorder.png. Always visible; the user holds control+fn
//  from anywhere to record.
//

import AppKit

final class RecorderWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    /// The coordinator the recorder bar is currently bound to. Mutable so the
    /// conversation window can swap it when the user switches tabs — each tab
    /// owns its own coordinator, and the recorder always drives whichever
    /// tab is in the foreground.
    private(set) var coordinator: VoiceLoopCoordinator
    // Mini version of the conversation-window orb (9×9 grid at 4pt cells →
    // 36×36 footprint, fits the existing avatar slot). Mirrors the big
    // avatar's mode/amplitude so the two surfaces feel like the same
    // creature.
    private let avatarView = AvatarView(gridW: 9, gridH: 9, pixelSize: 4, baseRadius: 1.5)
    private let textField = NSTextField()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let sendButton = CircleButton(diameter: 36)
    private let waveformContainer = NSView()
    private var waveformBars: [CALayer] = []
    private var textFieldHeightConstraint: NSLayoutConstraint!

    /// While true, every show-the-bar entry point (didBecomeActive observer,
    /// explicit `showBar()` call) is a no-op. The onboarding flow flips this
    /// on for steps 1-3 (welcome / accessibility / launch-at-login) so the
    /// floating bar doesn't compete with the onboarding window for attention.
    /// Step 4 unsuppresses so the user can actually press fn+ctrl and see
    /// the bar respond.
    var isSuppressed: Bool = false {
        didSet {
            if isSuppressed {
                window?.orderOut(nil)
                postVisibilityChange()
            }
        }
    }

    /// File staged for the next send (via drag-and-drop). When non-nil the
    /// `attachmentChip` row appears above the text field and the panel grows
    /// to accommodate it. Cleared on send or when the user hits the chip's
    /// × button.
    private var pendingAttachment: FileAttachment? {
        didSet {
            refreshAttachmentChip()
            adjustWindowHeightToFitText()
            updateSendButtonAppearance()
        }
    }
    private let attachmentChip = NSView()
    private let attachmentChipImage = NSImageView()
    private let attachmentChipLabel = NSTextField(labelWithString: "")
    private let attachmentChipRemove = NSButton()
    /// Height added to the panel when the chip is visible. Read by
    /// `adjustWindowHeightToFitText` so the chip + multi-line text both
    /// contribute to the final panel height.
    private var attachmentChipExtraHeight: CGFloat { pendingAttachment == nil ? 0 : 56 }
    /// Single-line height for the text field at the current font — drives
    /// both the textField's min-height constraint and the panel's collapsed
    /// height calculation in `adjustWindowHeightToFitText`.
    private let singleLineTextHeight: CGFloat = 18
    /// Fill used when the send button is in its "no pending action" state
    /// (idle bar, no typed text). Specified in sRGB rather than via
    /// `NSColor(white:alpha:)` — the latter uses calibrated-white gamma,
    /// which makes `white: 0.5` render visibly closer to white than to
    /// medium grey. 0.4 sRGB is a clear medium grey on both light and
    /// dark popover backdrops, with enough contrast under a white SF Symbol
    /// glyph that the arrow stays readable.
    private static let inactiveSendFill = NSColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1.0)

    /// Custom field editor handed out to the recorder's textField via
    /// `windowWillReturnFieldEditor(_:to:)`. Lives here (not as a per-edit-
    /// session local) because AppKit asks for the field editor every time
    /// the textField becomes first responder — returning the same instance
    /// keeps drag-routing state intact across focus cycles.
    private lazy var recorderFieldEditor: RecorderFieldEditor = {
        let editor = RecorderFieldEditor()
        editor.isFieldEditor = true
        editor.onFileDropped = { [weak self] url in
            self?.handleDroppedFile(url)
        }
        return editor
    }()

    init(coordinator: VoiceLoopCoordinator) {
        self.coordinator = coordinator

        let panel = RecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // No window shadow — the system casts it against the panel's
        // rectangular frame, not the rounded contentView mask, so it
        // leaks out as a faint rectangle behind the rounded bar.
        // Killing the shadow gets us a clean floating chip on both
        // appearances.
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        // Manual show/hide via observers below — `hidesOnDeactivate = true`
        // would also work but it doesn't keep the bar visible while a voice
        // turn is mid-flight (recording / transcribing / thinking / speaking).
        panel.hidesOnDeactivate = false

        super.init(window: panel)

        // Hand out our custom field editor for the textField via
        // `windowWillReturnFieldEditor(_:to:)` below — that's where AppKit
        // collects the editor each time the field becomes first responder.
        panel.delegate = self
        configureContent()
        positionAtBottomCenter()
        wireCoordinator()
        wireVisibilityObservers()
        // Start hidden — the bar surfaces on ctrl+fn or when the user
        // explicitly activates Loop.
        panel.orderOut(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureContent() {
        guard let window = window else { return }
        // Translucent backdrop. `.popover` is the only NSVisualEffectView
        // material in this size class that adapts to light/dark — light
        // mode gets a soft frosted-white bar, dark mode keeps the dim
        // charcoal feel. `.hudWindow` would have stayed dark in both modes.
        let backdrop = RecorderBackdrop()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 28
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        // 1pt hairline outline. `separatorColor` adapts: dark hairline on
        // light mode, light hairline on dark mode. The RecorderBackdrop
        // subclass re-applies this in `viewDidChangeEffectiveAppearance`
        // so the cgColor doesn't go stale when the system flips themes.
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.separatorColor.cgColor
        window.contentView = backdrop
        guard let contentView = window.contentView else { return }

        // Avatar — the AvatarView handles its own per-mode rendering and
        // animation timer; we just place it in the layout.
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(avatarView)

        // Text field for typed input. Configured as a multi-line wrapping
        // field so shift+enter can insert a literal newline and the bar can
        // grow vertically to fit longer prompts.
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = NSFont.systemFont(ofSize: 15)
        // Semantic so it tracks the system appearance — dark text on light
        // mode, light text on dark mode.
        textField.textColor = .labelColor
        textField.backgroundColor = .clear
        textField.isBordered = false
        textField.focusRingType = .none
        textField.delegate = self
        textField.cell?.usesSingleLineMode = false
        textField.cell?.wraps = true
        textField.cell?.isScrollable = false
        textField.maximumNumberOfLines = 0
        textField.lineBreakMode = .byWordWrapping
        textField.placeholderAttributedString = makePlaceholder()
        contentView.addSubview(textField)

        // Send button — `CircleButton` is now a plain NSView with an
        // NSImageView subview, so it cannot drift into a pill the way the
        // NSButton-based version could. It also doubles as the attach button
        // when there's nothing to send (paperclip glyph, click opens a file
        // panel); see `updateSendButtonAppearance` for the swap logic.
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Attach file")
        // Always white glyph: the button is either systemBlue (active) or
        // a medium grey (inactive). White reads on both in either
        // appearance, matching the iOS message-composer affordance.
        sendButton.contentTintColor = .white
        sendButton.fillColor = Self.inactiveSendFill
        // Initial click handler matches the initial glyph (paperclip → file
        // panel). `updateSendButtonAppearance` flips both when the user
        // types or stages an attachment.
        sendButton.onClick = { [weak self] in self?.presentAttachPanel() }
        contentView.addSubview(sendButton)

        // Waveform overlay (hidden until recording)
        waveformContainer.translatesAutoresizingMaskIntoConstraints = false
        waveformContainer.wantsLayer = true
        waveformContainer.isHidden = true
        contentView.addSubview(waveformContainer)

        // Attachment chip — sits along the top edge of the bar when a file
        // has been dropped. Mirrors the iOS chip's visual weight: rounded
        // capsule with a thumbnail, filename, and × button.
        configureAttachmentChip(in: contentView)

        // Drag-drop wiring: RecorderBackdrop is registered for .fileURL types
        // in its init; on a successful drop it forwards the source URL here so
        // we can copy it into the workspace and stage it for the next send.
        if let backdrop = contentView as? RecorderBackdrop {
            backdrop.onFileDropped = { [weak self] url in
                self?.handleDroppedFile(url)
            }
        }

        // Avatar and send button stay pinned to the bottom row so the bar
        // grows upward as the text field accumulates lines. The first line
        // remains in the same screen position the user is used to.
        let firstLineCenterY: CGFloat = 28 // half of the 56pt single-line height

        textFieldHeightConstraint = textField.heightAnchor.constraint(equalToConstant: singleLineTextHeight)

        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            avatarView.centerYAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -firstLineCenterY),
            // intrinsicContentSize on AvatarView already pins width/height
            // (gridW * pixelSize), so no explicit size constraints needed.

            textField.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -12),
            // Pin the text field's last line to the same baseline as the
            // avatar/send button, and grow its top edge upward via an
            // explicit height constraint that's resized in
            // `adjustWindowHeightToFitText`. NSTextField doesn't grow
            // automatically because its wrapping intrinsicContentSize needs
            // a preferredMaxLayoutWidth we don't conveniently have.
            textField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -(firstLineCenterY - 9)),
            textFieldHeightConstraint,

            sendButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            sendButton.centerYAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -firstLineCenterY),
            // Explicit width = height = 36 — relying on intrinsicContentSize
            // alone wasn't enough, NSButton's cell was occasionally stretching
            // the button wider than tall, which combined with `cornerRadius =
            // min(w, h)/2` produced a horizontal pill instead of a circle.
            sendButton.widthAnchor.constraint(equalToConstant: 36),
            sendButton.heightAnchor.constraint(equalToConstant: 36),

            waveformContainer.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
            waveformContainer.trailingAnchor.constraint(equalTo: textField.trailingAnchor),
            waveformContainer.centerYAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -firstLineCenterY),
            waveformContainer.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    // MARK: - Attachment chip

    private func configureAttachmentChip(in contentView: NSView) {
        attachmentChip.translatesAutoresizingMaskIntoConstraints = false
        attachmentChip.wantsLayer = true
        attachmentChip.layer?.cornerRadius = 12
        attachmentChip.layer?.cornerCurve = .continuous
        attachmentChip.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        attachmentChip.isHidden = true
        contentView.addSubview(attachmentChip)

        attachmentChipImage.translatesAutoresizingMaskIntoConstraints = false
        attachmentChipImage.imageScaling = .scaleProportionallyUpOrDown
        attachmentChipImage.wantsLayer = true
        attachmentChipImage.layer?.cornerRadius = 6
        attachmentChipImage.layer?.masksToBounds = true
        attachmentChip.addSubview(attachmentChipImage)

        attachmentChipLabel.translatesAutoresizingMaskIntoConstraints = false
        attachmentChipLabel.font = NSFont.systemFont(ofSize: 12)
        attachmentChipLabel.textColor = .labelColor
        attachmentChipLabel.lineBreakMode = .byTruncatingMiddle
        attachmentChipLabel.maximumNumberOfLines = 1
        attachmentChip.addSubview(attachmentChipLabel)

        attachmentChipRemove.translatesAutoresizingMaskIntoConstraints = false
        attachmentChipRemove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove attachment")
        attachmentChipRemove.contentTintColor = .tertiaryLabelColor
        attachmentChipRemove.isBordered = false
        attachmentChipRemove.bezelStyle = .smallSquare
        attachmentChipRemove.title = ""
        attachmentChipRemove.target = self
        attachmentChipRemove.action = #selector(removeAttachmentTapped)
        attachmentChip.addSubview(attachmentChipRemove)

        NSLayoutConstraint.activate([
            attachmentChip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            attachmentChip.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -10),
            attachmentChip.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            attachmentChip.heightAnchor.constraint(equalToConstant: 40),

            attachmentChipImage.leadingAnchor.constraint(equalTo: attachmentChip.leadingAnchor, constant: 6),
            attachmentChipImage.centerYAnchor.constraint(equalTo: attachmentChip.centerYAnchor),
            attachmentChipImage.widthAnchor.constraint(equalToConstant: 28),
            attachmentChipImage.heightAnchor.constraint(equalToConstant: 28),

            attachmentChipLabel.leadingAnchor.constraint(equalTo: attachmentChipImage.trailingAnchor, constant: 8),
            attachmentChipLabel.centerYAnchor.constraint(equalTo: attachmentChip.centerYAnchor),
            attachmentChipLabel.trailingAnchor.constraint(lessThanOrEqualTo: attachmentChipRemove.leadingAnchor, constant: -8),

            attachmentChipRemove.trailingAnchor.constraint(equalTo: attachmentChip.trailingAnchor, constant: -4),
            attachmentChipRemove.centerYAnchor.constraint(equalTo: attachmentChip.centerYAnchor),
            attachmentChipRemove.widthAnchor.constraint(equalToConstant: 22),
            attachmentChipRemove.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    private func refreshAttachmentChip() {
        guard let attachment = pendingAttachment else {
            attachmentChip.isHidden = true
            attachmentChipImage.image = nil
            attachmentChipLabel.stringValue = ""
            return
        }
        attachmentChip.isHidden = false
        attachmentChipLabel.stringValue = attachment.fileName

        // Placeholder icon while the real thumbnail loads. Mirrors the iOS
        // chip's "generic glyph then real preview" sequence. Image is the
        // only kind that gets swapped for a real bitmap below — every other
        // kind keeps its SF Symbol since the underlying file isn't visually
        // meaningful at chip size.
        let symbolName: String
        switch attachment.kind {
        case .pdf:      symbolName = "doc.richtext"
        case .image:    symbolName = "photo"
        case .markdown: symbolName = "doc.text"
        case .text:     symbolName = "chevron.left.forwardslash.chevron.right"
        case .generic:  symbolName = "doc"
        }
        attachmentChipImage.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)

        if attachment.kind == .image {
            let url = attachment.fileURL
            let id = attachment.id
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let data = try? Data(contentsOf: url),
                      let img = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    guard let self = self, self.pendingAttachment?.id == id else { return }
                    self.attachmentChipImage.image = img
                }
            }
        }
    }

    @objc private func removeAttachmentTapped() {
        pendingAttachment = nil
    }

    private func handleDroppedFile(_ url: URL) {
        do {
            let attachment = try AttachmentStore.shared.saveFromFileURL(url)
            self.pendingAttachment = attachment
            // Bring the bar to focus so the user can immediately type a
            // prompt alongside the file. matches the iOS UX where the
            // input bar's send button just lights up after picking.
            focusTextInput()
        } catch {
            NSSound.beep()
            print("Recorder drop failed: \(error.localizedDescription)")
        }
    }

    /// Public entry point used by the share-extension hand-off in
    /// `AppDelegate.handleShareHandoff`. The attachment is already in the
    /// workspace (AttachmentStore copied it from the App Group inbox) so we
    /// just stage it and surface the bar so the user can add a prompt.
    func stageSharedAttachment(_ attachment: FileAttachment) {
        self.pendingAttachment = attachment
        focusTextInput()
    }

    private func makePlaceholder() -> NSAttributedString {
        // "Type or hold fn control to speak" with the keys shown as small
        // pill-buttons. We use attachments + paragraph styling to mirror the
        // mockup as closely as possible.
        let result = NSMutableAttributedString()
        let baseAttrs: [NSAttributedString.Key: Any] = [
            // secondaryLabelColor reads better on the popover material than
            // tertiary — tertiary sits at ~25% alpha which gets swallowed by
            // the translucent backdrop in dark mode.
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 15),
        ]
        result.append(NSAttributedString(string: "Type or hold ", attributes: baseAttrs))
        result.append(keyPill("fn"))
        result.append(NSAttributedString(string: " ", attributes: baseAttrs))
        result.append(keyPill("control"))
        result.append(NSAttributedString(string: " to speak", attributes: baseAttrs))
        return result
    }

    private func keyPill(_ label: String) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .backgroundColor: NSColor.quaternaryLabelColor,
        ]
        return NSAttributedString(string: " \(label) ", attributes: attrs)
    }

    private func positionAtBottomCenter() {
        guard let window = window else { return }
        // Surface on the screen the cursor is on, not `NSScreen.main`.
        // `NSScreen.main` tracks the *key* window, which — when Loop is in the
        // background and the user triggers ctrl+fn from another app — is
        // whatever window they last focused, frequently on a different monitor
        // (a different "desktop") than where their attention currently is. The
        // cursor is the most reliable proxy for the active display, matching
        // how Spotlight / Raycast pick their screen.
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        let originX = visible.midX - frame.width / 2
        let originY = visible.minY + 36 // 36 pt above dock/menu visible area
        window.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    /// Swap the active coordinator (called by the conversation window when
    /// the user switches tabs). Releases the previous coordinator's recorder
    /// callbacks so a stale background turn can't keep mutating the bar, then
    /// re-wires the new one and refreshes the visible state.
    func setActiveCoordinator(_ next: VoiceLoopCoordinator) {
        guard next !== coordinator else { return }
        // Drop the previous coordinator's recorder hooks so a background turn
        // (e.g. an in-flight chat completion landing later) doesn't fire any
        // amplitude / state callbacks at this bar.
        coordinator.onStateChange = nil
        coordinator.onAmplitude = nil
        coordinator.onPartial = nil
        coordinator.onEmptyTranscript = nil

        coordinator = next
        wireCoordinator()
        // Snap the visible state to the new coordinator so the bar reflects
        // *its* current turn (e.g. if the user switched into a tab that's
        // still thinking, the placeholder should say "thinking…").
        applyState(coordinator.state)
        applyVisibility(for: coordinator.state)
    }

    private func wireCoordinator() {
        coordinator.onStateChange = { [weak self] state in
            self?.applyState(state)
            self?.applyVisibility(for: state)
        }
        coordinator.onAmplitude = { [weak self] amp in
            self?.updateWaveform(amplitude: amp)
            self?.avatarView.amplitude = amp
        }
        coordinator.onPartial = { [weak self] partial in
            self?.showLivePartial(partial)
        }
        coordinator.onEmptyTranscript = { [weak self] in
            // STT returned nothing usable — flip the bar into text-entry mode
            // so the user can type the message instead of re-recording.
            //
            // We async-hop because the coordinator's state setter dispatches
            // its `.idle` onStateChange via DispatchQueue.main.async; our
            // own async-hop queues behind it, so by the time this lands the
            // field has been re-enabled and the placeholder restored. Doing
            // it synchronously would call makeFirstResponder on a still-
            // disabled NSTextField.
            DispatchQueue.main.async {
                self?.textField.stringValue = ""
                self?.focusTextInput()
            }
        }
    }

    /// Visibility rules:
    ///  - The bar appears when the user presses ctrl+fn or clicks into Loop,
    ///    and stays until they click away from it (i.e. somewhere outside
    ///    the bar's frame). This survives a full conversation: even after
    ///    speaking finishes the bar is still there until you dismiss it.
    ///  - During a voice turn (recording/transcribing/thinking/speaking) we
    ///    suppress the click-away dismissal entirely — the user is allowed
    ///    to click anywhere without losing the bar.
    private var clickAwayMonitorGlobal: Any?

    private func wireVisibilityObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func appDidBecomeActive() {
        showBar()
    }

    private func applyVisibility(for state: VoiceLoopCoordinator.State) {
        switch state {
        case .recording, .transcribing, .thinking, .speaking:
            // Definitely keep the bar up during a voice turn.
            showBar()
        case .idle:
            // Stay visible after the turn ends; click-away monitor will
            // hide it when the user dismisses.
            break
        }
    }

    /// Brings the panel up without stealing focus from whichever app the
    /// user is currently typing in. `orderFrontRegardless` works on a
    /// nonactivating panel even when the app isn't frontmost — needed so the
    /// bar surfaces on ctrl+fn when Loop is in the background.
    func showBar() {
        // Onboarding steps 1-3 want the screen to themselves — bail before
        // the panel surfaces.
        if isSuppressed { return }
        guard let window = window else { return }
        if !window.isVisible {
            positionAtBottomCenter()
            window.orderFrontRegardless()
        }
        installClickAwayMonitorIfNeeded()
        postVisibilityChange()
    }

    func hideBar() {
        window?.orderOut(nil)
        removeClickAwayMonitor()
        postVisibilityChange()
    }

    /// Broadcast the bar's current `isVisible` so satellites (the
    /// terminal pill, future floating affordances) can mirror it instead
    /// of staying parked on screen after the bar dismisses. Posted on
    /// every show/hide call — observers de-dupe with their own state.
    private func postVisibilityChange() {
        let visible = window?.isVisible ?? false
        NotificationCenter.default.post(
            name: .recorderBarVisibilityChanged,
            object: nil,
            userInfo: ["visible": visible]
        )
    }

    /// Tap-to-type entry point: surface the bar, activate Loop so keystrokes
    /// route here instead of the previously-frontmost app, make the panel key,
    /// and place the caret in the text field ready to type.
    func focusTextInput() {
        guard let window = window else { return }
        // Activating is necessary because a non-activating panel can't receive
        // keystrokes from another app's foreground context — the user wants
        // to type, so steal focus briefly (mirrors Spotlight / Raycast).
        NSApp.activate(ignoringOtherApps: true)
        positionAtBottomCenter()
        window.orderFrontRegardless()
        window.makeKey()
        // applyState(...) may not have re-enabled the field yet (state setter
        // dispatches async), and makeFirstResponder is a no-op on a disabled
        // NSTextField. Forcing it enabled here makes focusTextInput safe to
        // call from any state transition.
        textField.isEnabled = true
        // Force a layout pass before focusing. makeFirstResponder makes AppKit
        // install a field editor (RecorderFieldEditor) sized to the text
        // field's current frame — and on the very first show no layout has run
        // yet, so the field would come up zero-width and render nothing (no
        // caret, no placeholder) until some later layout. Previously that
        // "later layout" only happened after the first send
        // (adjustWindowHeightToFitText), which is why the field stayed blank
        // until you sent a message. Laying out here gives the field a real
        // frame so the editor surfaces the moment the bar gains focus.
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(textField)
        installClickAwayMonitorIfNeeded()
    }

    private func installClickAwayMonitorIfNeeded() {
        guard clickAwayMonitorGlobal == nil else { return }

        // Global monitor: clicks in OTHER apps. NSEvent gives us a screen-
        // coordinate location via `mouseLocation`, since global events don't
        // belong to any window.
        clickAwayMonitorGlobal = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.handleClickAway(at: NSEvent.mouseLocation)
        }

        // No local monitor: local mouse-down events fire only when Loop is
        // frontmost, which means the click landed on one of Loop's own
        // windows (recorder bar, conversation window, settings, etc.).
        // Any of those means the user is actively using Loop — keep the
        // bar visible. The global monitor above handles dismissal when
        // the user clicks into another app.
    }

    private func removeClickAwayMonitor() {
        if let m = clickAwayMonitorGlobal { NSEvent.removeMonitor(m); clickAwayMonitorGlobal = nil }
    }

    private func handleClickAway(at screenPoint: NSPoint) {
        // Don't dismiss mid-turn — user is allowed to click anywhere while
        // recording/transcribing/thinking/speaking.
        if coordinator.state != .idle { return }
        guard let window = window else { return }
        // If the click landed inside the recorder bar's screen frame, ignore.
        if NSPointInRect(screenPoint, window.frame) { return }
        hideBar()
    }

    private func applyState(_ state: VoiceLoopCoordinator.State) {
        switch state {
        case .idle:
            textField.isEnabled = true
            textField.stringValue = ""
            textField.placeholderAttributedString = makePlaceholder()
            waveformContainer.isHidden = true
            sendButton.fillColor = Self.inactiveSendFill
            avatarView.mode = .idle
            adjustWindowHeightToFitText()
        case .recording:
            textField.isEnabled = false
            // Waveform is the visual indicator while listening; clearing the
            // placeholder avoids "listening…" colliding with the bars in the
            // same horizontal slot. Partial transcription (showLivePartial)
            // will hide the waveform and surface text once speech is detected.
            textField.placeholderAttributedString = NSAttributedString(string: "")
            ensureWaveformBars()
            waveformContainer.isHidden = false
            sendButton.fillColor = .systemBlue
            avatarView.mode = .listening
        case .transcribing:
            // Keep the field enabled in all post-recording states so the user
            // can stay focused on it and start typing their next thought
            // while the assistant works. The placeholder still conveys the
            // current pipeline stage.
            textField.isEnabled = true
            let engineTag: String
            switch VoiceLoopCoordinator.current?.activeSTTEngine {
            case .deepgram: engineTag = " · DG"
            case .apple:    engineTag = " · APL"
            case nil:       engineTag = ""
            }
            textField.placeholderAttributedString = makeStateText("transcribing…\(engineTag)")
            waveformContainer.isHidden = true
            avatarView.mode = .thinking
        case .thinking:
            textField.isEnabled = true
            textField.placeholderAttributedString = makeStateText("thinking…")
            waveformContainer.isHidden = true
            avatarView.mode = .thinking
        case .speaking:
            textField.isEnabled = true
            textField.placeholderAttributedString = makeStateText("speaking…")
            waveformContainer.isHidden = true
            avatarView.mode = .speaking
        }
    }

    private func makeStateText(_ s: String) -> NSAttributedString {
        return NSAttributedString(string: s, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 15),
        ])
    }

    private func showLivePartial(_ partial: String) {
        // Intentionally empty: the waveform is the listening indicator. We
        // used to render Deepgram partials in the placeholder, but they
        // collide with the bars in the same horizontal slot and read as a
        // glitch. The final transcript still flows into the conversation
        // window once the turn ends.
        _ = partial
    }

    func flashHotKeyActive(_ active: Bool) {
        // Hint the user the hotkey is recognized even before audio engine
        // takes over (which has a short setup window). The "off" branch
        // restores the resting hairline, not a clear border — we want the
        // outline always visible, the flash just thickens and tints it.
        guard let layer = window?.contentView?.layer else { return }
        if active {
            layer.borderWidth = 1.5
            layer.borderColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        } else {
            layer.borderWidth = 1
            layer.borderColor = NSColor.separatorColor.cgColor
        }
    }

    // MARK: - Send via type

    /// Prefill the recorder's text field with a suggestion (used by the
    /// onboarding coordinator to one-tap the user's name, etc.). Caret goes
    /// to end so the user can either send-as-is or edit before sending. Also
    /// updates the send button + bar height as if the user had typed.
    func prefillInputText(_ text: String) {
        textField.stringValue = text
        adjustWindowHeightToFitText()
        updateSendButtonAppearance()
        // Bring the panel forward and focus the field so a single press of
        // Return submits.
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textField)
    }

    /// Bring the recorder bar forward and put the cursor in its text field
    /// without changing the current text. Used by the onboarding coordinator
    /// after the greeting so the user can type their name immediately.
    func focusInputField() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textField)
    }

    @objc private func sendTapped() {
        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let stagedAttachment = pendingAttachment
        // Either text or an attachment is enough to send. Empty + empty is
        // still a no-op so a spurious enter on an idle bar doesn't fire.
        guard !text.isEmpty || stagedAttachment != nil else { return }

        textField.stringValue = ""
        if stagedAttachment != nil {
            pendingAttachment = nil
        }
        // Programmatic stringValue changes don't fire controlTextDidChange,
        // so collapse the bar back to its single-line height ourselves.
        adjustWindowHeightToFitText()
        updateSendButtonAppearance()
        // Force-activate Loop before kicking the turn. The recorder is a
        // non-activating panel, so the app may not be the truly-frontmost
        // process — without this, the conversation window's
        // makeKeyAndOrderFront brings it to the top of Loop's own window
        // stack but leaves it stuck behind the previously-frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        if let attachment = stagedAttachment {
            coordinator.sendUserAttachment(attachment, text: text.isEmpty ? nil : text)
        } else {
            coordinator.sendUserText(text)
        }
        // Keep the caret in the input field so the user can keep typing
        // while the model works. Clearing `stringValue` and processing a
        // button-action both end the active field-editor session — AppKit
        // doesn't restore focus automatically, so subsequent keystrokes
        // would fall through to whichever view becomes the window's next
        // first responder (often nothing useful). Hop once so we land after
        // the coordinator's `.thinking` state dispatch, mirroring the same
        // race the empty-transcript handler above is documented to avoid.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let window = self.window else { return }
            self.textField.isEnabled = true
            window.makeFirstResponder(self.textField)
        }
    }

    // MARK: - NSWindowDelegate

    /// Supply our custom field editor for the textField so a file dragged
    /// into the input area gets routed to the attachment-staging path
    /// instead of having its URL inserted as text. Returning `nil` for any
    /// other client uses AppKit's default — preserves whatever field
    /// editors other subviews (if any) might rely on.
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        if let tf = client as? NSTextField, tf === textField {
            return recorderFieldEditor
        }
        return nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape on an empty field dismisses the bar, matching the
            // click-away behavior. If the field has text, fall through to
            // the system default — we don't want to silently delete the
            // user's typing. Only fires in .idle so escape can't bail mid-
            // turn while the assistant is still working.
            let isEmpty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isEmpty && coordinator.state == .idle {
                hideBar()
                return true
            }
            return false
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Shift+Enter inserts a literal newline (multi-line input);
            // plain Enter submits. `insertNewlineIgnoringFieldEditor` is the
            // AppKit-blessed way to add a newline character without ending
            // the field editor session — it also keeps the caret position
            // and undo stack consistent with what the user expects.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            sendTapped()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        // The userInfo dict carries the live field editor (an NSTextView)
        // whose layout manager already knows the wrapped height — far more
        // reliable than NSTextField's intrinsicContentSize, which doesn't
        // re-evaluate mid-edit when newlines are inserted via
        // insertNewlineIgnoringFieldEditor.
        let fieldEditor = obj.userInfo?["NSFieldEditor"] as? NSTextView
        adjustWindowHeightToFitText(fieldEditor: fieldEditor)
        updateSendButtonAppearance(fieldEditor: fieldEditor)
    }

    /// Blue when there's something to send, dim gray otherwise. The
    /// recording state owns the button color on its own (also blue, but for
    /// a different reason), so we only touch it when the coordinator isn't
    /// mid-turn.
    private func updateSendButtonAppearance(fieldEditor: NSTextView? = nil) {
        guard coordinator.state == .idle else { return }
        let text = fieldEditor?.string ?? textField.stringValue
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // A staged attachment is enough to enable the send affordance even
        // when the text field is empty — same rule as the iOS message bar.
        let hasAttachment = pendingAttachment != nil
        let shouldSend = hasText || hasAttachment

        // When there's nothing to send the button doubles as the attach
        // affordance — tap to open a file panel. Mirrors iOS, where the
        // send slot toggles between paperclip and filled-blue arrow.
        if shouldSend {
            sendButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Send")
            sendButton.fillColor = .systemBlue
            sendButton.onClick = { [weak self] in self?.sendTapped() }
        } else {
            sendButton.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Attach file")
            sendButton.fillColor = Self.inactiveSendFill
            sendButton.onClick = { [weak self] in self?.presentAttachPanel() }
        }
    }

    /// Native macOS file picker filtered to images + PDFs. Mirrors the iOS
    /// "Files" branch of the action sheet — drag-drop covers the rest of
    /// the use cases on Mac (Finder, attachments from Mail, etc.).
    @objc private func presentAttachPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // Accept any file — AttachmentStore kinds it on save and enforces
        // the 20 MB ceiling. Restricting to specific UTIs here would block
        // markdown / source / text drops the new card paths handle fine.
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.item]
        } else {
            panel.allowedFileTypes = nil
        }
        panel.prompt = "Attach"
        // Anchor to the recorder window so the panel feels attached to the
        // bar rather than spawning detached at the screen center.
        if let parent = window {
            panel.beginSheetModal(for: parent) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.handleDroppedFile(url)
            }
        } else {
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.handleDroppedFile(url)
            }
        }
    }

    /// Recomputes both the text field's height constraint and the panel's
    /// outer height to fit the current text. Resizes upward (origin Y stays
    /// pinned to the bottom-of-screen position set by `positionAtBottomCenter`).
    /// Clamped to single-line height so an empty field stays at the
    /// original 56pt bar size.
    private func adjustWindowHeightToFitText(fieldEditor: NSTextView? = nil) {
        guard let window = window else { return }
        // Force a layout pass so the text field has its final width before
        // we ask the cell or field editor to measure against it.
        window.contentView?.layoutSubtreeIfNeeded()

        let textHeight: CGFloat
        if let tv = fieldEditor,
           let lm = tv.layoutManager,
           let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            textHeight = ceil(lm.usedRect(for: tc).height)
        } else if let cell = textField.cell, textField.bounds.width > 0 {
            // No active field editor (e.g. after send/clear) — ask the cell
            // to size itself against the current width.
            let bounds = NSRect(x: 0, y: 0, width: textField.bounds.width, height: .greatestFiniteMagnitude)
            textHeight = ceil(cell.cellSize(forBounds: bounds).height)
        } else {
            textHeight = singleLineTextHeight
        }

        let clampedTextHeight = max(singleLineTextHeight, textHeight)
        let baseHeight: CGFloat = 56
        let desiredHeight = baseHeight + max(0, clampedTextHeight - singleLineTextHeight) + attachmentChipExtraHeight

        // Update both at once so the field's frame grows in lockstep with
        // the panel — otherwise the multi-line text gets visually clipped
        // until the next layout pass.
        if abs(textFieldHeightConstraint.constant - clampedTextHeight) > 0.5 {
            textFieldHeightConstraint.constant = clampedTextHeight
        }

        let current = window.frame
        if abs(current.height - desiredHeight) > 0.5 {
            let newFrame = NSRect(
                x: current.origin.x,
                y: current.origin.y, // keep bottom edge pinned
                width: current.width,
                height: desiredHeight
            )
            window.setFrame(newFrame, display: true, animate: false)
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: - Waveform

    private func ensureWaveformBars() {
        guard waveformBars.isEmpty else { return }
        waveformContainer.layoutSubtreeIfNeeded()
        let width = waveformContainer.bounds.width
        let height: CGFloat = 24
        let barWidth: CGFloat = 2
        let spacing: CGFloat = 3
        let total = max(40, Int(width / (barWidth + spacing)))
        for i in 0..<total {
            let bar = CALayer()
            // labelColor resolves to dark-on-light or light-on-dark, so the
            // bars are always visible regardless of system appearance.
            bar.backgroundColor = NSColor.labelColor.withAlphaComponent(0.6).cgColor
            bar.frame = CGRect(
                x: CGFloat(i) * (barWidth + spacing),
                y: height / 2 - 2,
                width: barWidth,
                height: 4
            )
            bar.cornerRadius = 1
            waveformContainer.layer?.addSublayer(bar)
            waveformBars.append(bar)
        }
    }

    private func updateWaveform(amplitude: Float) {
        let baseHeight: CGFloat = 4
        let maxExtra: CGFloat = 16
        for (i, bar) in waveformBars.enumerated() {
            let phase = Float(i) * 0.13 + Float(Date().timeIntervalSinceReferenceDate)
            let wave = (sin(phase) + 1) / 2
            let h = baseHeight + maxExtra * CGFloat(min(1.0, max(0.05, amplitude * (0.4 + wave))))
            bar.frame = CGRect(x: bar.frame.origin.x, y: 12 - h / 2, width: 2, height: h)
            bar.backgroundColor = NSColor.labelColor.withAlphaComponent(0.7 + 0.3 * Double(amplitude)).cgColor
        }
    }

    // Avatar pulse/color was driven manually here when the avatar was a
    // plain white CALayer; AvatarView now owns its own animation loop and
    // per-mode rendering, so this section is gone.
}

extension Notification.Name {
    /// Posted whenever the recorder bar is shown or hidden. UserInfo
    /// carries `visible: Bool`. Used by the terminal pill (and any
    /// future satellite affordance) so they can mirror the bar's on-
    /// screen state without polling.
    static let recorderBarVisibilityChanged = Notification.Name("recorderBarVisibilityChanged")
}

/// Borderless panel that NEVER becomes the active app — clicking it doesn't
/// steal focus from whichever app you're working in. Required so the
/// recorder bar is always there but never disrupts your workflow.
final class RecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// NSVisualEffectView subclass that re-resolves its layer border color on
/// system appearance change. The recorder bar uses a 1pt separatorColor
/// hairline; without this hook, a light↔dark theme flip would leave the
/// border at whatever cgColor was captured at construction time — or, in
/// practice, drop the border entirely because NSVisualEffectView can reset
/// layer properties during the transition.
///
/// Also doubles as the drag-drop target for the file-upload feature: when
/// the user drags an image or PDF onto the bar, `onFileDropped` fires with
/// the source URL so the controller can copy it into the workspace and
/// stage it for the next send.
/// Field editor for the recorder's textField. NSTextView's default drop
/// handling reads file URLs as strings and inserts the path into the
/// field — that's why dragging an image onto the visible textField area
/// used to plant the file path as text instead of staging the attachment.
/// This subclass accepts the same file kinds the RecorderBackdrop does and
/// forwards them to the controller via `onFileDropped`, leaving any non-
/// file drag to fall through to NSTextView's default behavior (so drops of
/// plain text still work normally).
final class RecorderFieldEditor: NSTextView {
    /// Fired on a successful file drop. Controller copies the file into the
    /// workspace and stages it. Runs on the main thread.
    var onFileDropped: ((URL) -> Void)?

    /// Same accepted-kind set as `RecorderBackdrop.isAcceptable(url:)`.
    /// Kept in sync by hand — duplicating four lines is cheaper than
    /// promoting it to a shared helper that both classes import.
    private static let imageExts: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "tif",
    ]

    /// Strip `.fileURL` (and the legacy `NSFilenamesPboardType`) from the
    /// readable-paste types so AppKit's text system can't read a dropped
    /// file URL as a string. Without this override the parent NSTextView
    /// path inserts the URL as text even when we accept the drop ourselves.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        return super.readablePasteboardTypes.filter {
            $0 != .fileURL && $0.rawValue != "NSFilenamesPboardType"
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if firstAcceptableFileURL(in: sender) != nil { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let url = firstAcceptableFileURL(in: sender) {
            onFileDropped?(url)
            return true
        }
        return super.performDragOperation(sender)
    }

    /// Cmd+V routing. If the clipboard holds an image file URL (Finder copy)
    /// or raw image bytes (screenshot, "Copy Image" from Safari/Preview), stage
    /// it as an attachment via the same `onFileDropped` path the drag handler
    /// uses — writing pasteboard image data to a temp file first so the rest
    /// of the pipeline can stay file-URL based. Falls through to the normal
    /// text paste when there's no image content.
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let url = firstAcceptableFileURL(on: pb) {
            onFileDropped?(url)
            return
        }
        if let url = writePastedImageToTempFile(on: pb) {
            onFileDropped?(url)
            return
        }
        super.paste(sender)
    }

    private func firstAcceptableFileURL(in info: NSDraggingInfo) -> URL? {
        return firstAcceptableFileURL(on: info.draggingPasteboard)
    }

    private func firstAcceptableFileURL(on pb: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              let url = urls.first else { return nil }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return url }
        if Self.imageExts.contains(ext) { return url }
        return nil
    }

    /// Pull image bytes off the pasteboard (PNG preferred, TIFF converted) and
    /// write them to a fresh temp file. Returns nil when there's no image
    /// content — the caller should then fall back to plain-text paste.
    private func writePastedImageToTempFile(on pb: NSPasteboard) -> URL? {
        let pngData: Data?
        if let png = pb.data(forType: .png) {
            pngData = png
        } else if let tiff = pb.data(forType: .tiff),
                  let bitmap = NSBitmapImageRep(data: tiff) {
            pngData = bitmap.representation(using: .png, properties: [:])
        } else {
            pngData = nil
        }
        guard let data = pngData else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pasted-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

final class RecorderBackdrop: NSVisualEffectView {
    /// Fired on a successful drop. Caller validates the file kind and stages
    /// it for the next send. The closure runs on the main thread.
    var onFileDropped: ((URL) -> Void)?

    /// Highlight state for the duration of a drag-enter. Resets to nil on
    /// exit or after a drop. Drives the blue border ring drawn by
    /// `viewDidChangeEffectiveAppearance` / `setHighlighted`.
    private var isHighlighted = false {
        didSet { applyHighlight() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyHighlight()
    }

    private func applyHighlight() {
        layer?.borderWidth = isHighlighted ? 2 : 1
        layer?.borderColor = (isHighlighted ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasAcceptableFile(in: sender) else { return [] }
        isHighlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHighlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        guard let url = firstFileURL(in: sender),
              Self.isAcceptable(url: url) else { return false }
        onFileDropped?(url)
        return true
    }

    private func hasAcceptableFile(in info: NSDraggingInfo) -> Bool {
        guard let url = firstFileURL(in: info) else { return false }
        return Self.isAcceptable(url: url)
    }

    private func firstFileURL(in info: NSDraggingInfo) -> URL? {
        // The pasteboard yields an array of NSURL when files are dragged.
        // We accept the first one only — the spec calls for single-file
        // attachment per message.
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            return urls.first
        }
        return nil
    }

    private static func isAcceptable(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        // Match the iOS document-picker contentTypes: images + PDFs.
        if ext == "pdf" { return true }
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "tif"]
        return imageExts.contains(ext)
    }
}

/// Round, fixed-size button drawn as a plain `NSView` with an
/// `NSImageView` subview. The previous NSButton-based implementation kept
/// rendering a horizontally-stretched pill — NSButtonCell draws its own
/// chrome that the view's layer can't suppress, and that chrome was wider
/// than the view's bounds. Dropping NSButton and handling clicks ourselves
/// gives us a clean circle backed only by the layer's cornerRadius.
final class CircleButton: NSView {
    private let diameter: CGFloat
    private let iconView = NSImageView()

    /// Fired on mouse-up inside the button. Replaces the old target/action
    /// pair — the call site assigns `onClick = { ... }`.
    var onClick: (() -> Void)?

    /// Forwards to the inner image view; lets callers keep using
    /// `sendButton.image = ...` like they did with NSButton.
    var image: NSImage? {
        get { iconView.image }
        set { iconView.image = newValue }
    }

    /// Same idea — `contentTintColor` flows through to the image view so
    /// SF Symbols pick up the requested tint.
    var contentTintColor: NSColor? {
        get { iconView.contentTintColor }
        set { iconView.contentTintColor = newValue }
    }

    /// Adaptive layer background. Store the NSColor (rather than calling
    /// `layer.backgroundColor = …` directly) so we can re-resolve its
    /// `cgColor` whenever the system appearance flips between light/dark.
    /// Plain `cgColor` snapshots the *current* appearance and goes stale.
    var fillColor: NSColor? {
        didSet { applyFillColor() }
    }

    private func applyFillColor() {
        layer?.backgroundColor = fillColor?.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFillColor()
    }

    init(diameter: CGFloat) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.masksToBounds = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        // 25% inset on every side keeps the SF Symbol comfortably away from
        // the circular edge. Tweak by changing the constant if the icon
        // ever looks too small or too tight.
        let inset: CGFloat = diameter * 0.25
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            iconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])

        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: diameter, height: diameter)
    }

    override func layout() {
        super.layout()
        // Defensive: even if a parent forces a different frame, keep the
        // background a perfect circle.
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func mouseDown(with event: NSEvent) {
        layer?.opacity = 0.7
    }

    override func mouseUp(with event: NSEvent) {
        layer?.opacity = 1.0
        // Standard button behavior: only fire if the mouse-up happened
        // inside our bounds (drag-out cancels).
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) { onClick?() }
    }
}
