//
//  ConversationWindowController.swift
//  LoopMac
//
//  Conversation window — shows the active SimpleConversation as a flat list
//  of bubbles. Opens automatically the first time the user sends a message
//  via the recorder; manually toggleable via the menu bar.
//

import AppKit
import PDFKit
import MapKit

final class ConversationWindowController: NSWindowController, ConversationPresenter, NSToolbarDelegate, TabBarViewDelegate {
    /// Open tabs in display order. Index 0 is the leftmost cell; the active
    /// tab is the only one whose state drives the recorder bar, avatar, and
    /// chat-bubble stack at any given moment. Background tabs keep running
    /// their coordinator so a turn that started before the user switched tabs
    /// still completes — its assistant message lands in the store, ready to
    /// be re-rendered the moment the user switches back.
    private(set) var tabs: [ConversationTab] = []
    private(set) var activeTabIndex: Int = 0

    var activeTab: ConversationTab? {
        guard tabs.indices.contains(activeTabIndex) else { return nil }
        return tabs[activeTabIndex]
    }
    var activeCoordinator: VoiceLoopCoordinator? { activeTab?.coordinator }

    /// Recorder bar reference so we can rebind which coordinator it drives
    /// when the user switches tabs. Weak — AppDelegate owns the recorder.
    private weak var recorder: RecorderWindowController?

    /// In-memory sidecar mapping message id → `OnboardingCardKind`. The
    /// `SimpleConversation` store doesn't serialize the card enum, so this
    /// dictionary is where the live chips for currently-posted onboarding
    /// bubbles live. Looked up in `rebuild(messages:)` so the chip row
    /// re-renders after every redraw. Cleared when onboarding completes;
    /// keys for `.answered` bubbles stay around so the bubble doesn't
    /// flicker back to chips on the next rebuild.
    private var onboardingCards: [String: OnboardingCardKind] = [:]

    private let tabBarView = TabBarView()
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let thinkingLabel = NSTextField(labelWithString: "")
    private let avatarView = AvatarView()
    /// Tappable "N sub-agents running" pill that sits between the avatar and
    /// the scroll view. Hides itself when no agents are alive.
    private let subAgentStatusBar = SubAgentMacStatusBar()
    private var hasShown = false

    /// Left-hand conversation list. Owned here, hosted inside the window's
    /// NSSplitViewController so the standard toolbar `.toggleSidebar` button
    /// works without custom plumbing.
    private let sidebarVC = ConversationsSidebarViewController()
    private weak var splitVC: NSSplitViewController?
    private static let composeToolbarIdentifier = NSToolbarItem.Identifier("loop.toolbar.compose")

    /// Messages from the last `rebuild(messages:)` call. Kept so the
    /// "Branch conversation from here" context menu can map a row view
    /// back to the corresponding slice of messages.
    private var lastRebuiltMessages: [SimpleMessage] = []

    /// Live state for any image the user has generated this session, keyed by
    /// attachment id. The persisted store carries the placeholder message
    /// (id = "image-<attachmentId>") but not the attachment itself, so this
    /// map is what `rebuild(messages:)` consults when it sees an image-prefixed
    /// id. Updated in place by the ImageSkillHost callbacks so a single bubble
    /// can flip from .generating → .ready/.failed without churn.
    private var imageAttachments: [String: ImageAttachment] = [:]
    /// Bubble views currently in the stack, keyed by attachment id, so the
    /// finish callback can mutate the existing row in place rather than
    /// inserting a new one.
    private var imageBubbles: [String: ImageBubbleView] = [:]
    private static let imageMessageIdPrefix = "image-"

    /// Live registry of PDF attachments + their bubbles, parallel to the
    /// image plumbing above. The placeholder message lives in the store
    /// under id `pdf-<attachmentId>`; the in-memory `pdfAttachments` map
    /// carries the live state so a tab switch or window reload can
    /// re-render the bubble in whatever state it last reached.
    private var pdfBubbles: [String: PDFBubbleView] = [:]
    private(set) var pdfAttachments: [String: PDFAttachment] = [:]
    private static let pdfMessageIdPrefix = "pdf-"

    /// The markdown editor currently slid up over the chat pane, if any, plus
    /// the top constraint we animate to drive the vertical slide.
    private var markdownEditorVC: MarkdownEditorViewController?
    private var markdownEditorTop: NSLayoutConstraint?

    init(initialCoordinator: VoiceLoopCoordinator, recorder: RecorderWindowController) {
        self.recorder = recorder

        // Wider default than the old single-pane design so the sidebar has a
        // comfortable home; min width keeps the chat readable when collapsed.
        let rect = NSRect(x: 0, y: 0, width: 780, height: 640)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.title = "Loop"
        window.minSize = NSSize(width: 520, height: 400)
        // Transparent titlebar lets the sidebar's visual-effect material run
        // edge-to-edge. The window itself stays opaque so the chat pane on
        // the right keeps its solid windowBackgroundColor fill — the sidebar
        // NSVisualEffectView in configureSplitView opts into `.behindWindow`
        // blending independently, so its frosted material still works.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = true
        window.backgroundColor = NSColor.windowBackgroundColor
        window.isReleasedWhenClosed = false
        // Follow the user across Spaces: when a send/response orders the
        // window front from the recorder bar (which joins all Spaces), bring
        // the chat to the active desktop instead of yanking the user back to
        // whichever desktop the window was last parked on.
        window.collectionBehavior = [.moveToActiveSpace]

        super.init(window: window)
        configureContent()
        configureSplitView()
        configureToolbar()
        wireSidebar()

        // SlackSkill needs a UI host so write tools can present a
        // confirmation alert before chat.postMessage fires. Mac chat is
        // single-window so we own this slot for the process lifetime.
        SlackSkill.shared.host = self
        GitHubSkill.shared.host = self
        TwitterSkill.shared.host = self

        // Bootstrap the first tab around whatever conversation the initial
        // coordinator just attached to (`loadLastConversation()` ran in its
        // own init). Wrapping it in a TabConversationPresenter is what gives
        // us the "background coordinators don't paint to the visible UI"
        // semantics for free — once a second tab arrives, the inactive
        // coordinator's presenter calls become no-ops, but its chat callback
        // still persists to its own conversation.
        let conv = SimpleConversationManager.shared.currentConversation
            ?? SimpleConversationManager.shared.loadLastConversation()
            ?? SimpleConversationManager.shared.createConversation(
                title: "Mac Chat \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))")
        let firstTab = ConversationTab(conversation: conv, coordinator: initialCoordinator)
        let firstPresenter = TabConversationPresenter(window: self, tab: firstTab)
        firstTab.presenter = firstPresenter
        initialCoordinator.conversationPresenter = firstPresenter
        initialCoordinator.isActive = true
        tabs = [firstTab]
        activeTabIndex = 0
        tabBarView.delegate = self
        refreshTabBar()
        reloadFromStore()

        // Hook the shared onboarding coordinator. On Mac we skip the iOS
        // action-button step (no Action Button hardware to bind). The
        // coordinator no-ops if `OnboardingState.isComplete` so existing
        // users see nothing change. Posted prompts land in the active tab's
        // conversation, with chips rendered via `onboardingCards` sidecar.
        OnboardingCoordinator.shared.skipActionButtonStep = true
        // On Mac the panel opens blank — wait for the user's first message,
        // then drop the greeting in as a reply. Without this the "Nice to
        // meet you" pops above the user's opener which reads awkwardly,
        // especially when the user just types "hi" to see what the harness
        // does.
        OnboardingCoordinator.shared.deferGreetingUntilFirstMessage = true
        OnboardingCoordinator.shared.host = self
        DispatchQueue.main.async {
            OnboardingCoordinator.shared.resumeIfNeeded()
        }

        // Reload the bubble stack when a sub-agent posts its completion
        // summary into the active conversation so the user sees it appear
        // without having to refocus or click around. Devin and Cursor post
        // back through separate notification names but use the same userInfo
        // shape (conversationId + messageId), so one handler covers all three.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(subAgentDidPostMessage(_:)),
            name: .subAgentDidPostMessage,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(subAgentDidPostMessage(_:)),
            name: .devinAgentDidPostMessage,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(subAgentDidPostMessage(_:)),
            name: .cursorAgentDidPostMessage,
            object: nil
        )
        // Each coordinator broadcasts its state transitions; refresh the tab
        // bar so the "running" dot can appear/disappear on background tabs.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(voiceLoopStateDidChange),
            name: .voiceLoopStateDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func subAgentDidPostMessage(_ note: Notification) {
        guard let conversationId = note.userInfo?["conversationId"] as? String,
              let current = SimpleConversationManager.shared.currentConversation,
              current.id == conversationId else {
            return
        }
        DispatchQueue.main.async { [weak self] in self?.reloadFromStore() }
    }

    /// The chat-content view, built once in `configureContent` and then
    /// re-parented into the split view's right pane in `configureSplitView`.
    private var chatContentView: NSView?

    private func configureContent() {
        // Soft material backdrop for the chat pane. Window is opaque (so the
        // sidebar's auto-applied translucent material doesn't bleed through to
        // the desktop), which means behind-window blending no longer has the
        // wallpaper to sample — we use within-window blending so the popover
        // material renders consistently against the opaque window background.
        let content = NSVisualEffectView()
        content.material = .popover
        content.blendingMode = .withinWindow
        content.state = .active
        content.wantsLayer = true

        tabBarView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabBarView)

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(avatarView)

        subAgentStatusBar.translatesAutoresizingMaskIntoConstraints = false
        subAgentStatusBar.delegate = self
        content.addSubview(subAgentStatusBar)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        content.addSubview(scrollView)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.distribution = .fill

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        scrollView.documentView = documentView

        thinkingLabel.translatesAutoresizingMaskIntoConstraints = false
        thinkingLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        thinkingLabel.textColor = .tertiaryLabelColor
        thinkingLabel.stringValue = Self.recordHintText
        content.addSubview(thinkingLabel)

        NSLayoutConstraint.activate([
            // Tab bar — pinned 36pt below the raw content top so it sits
            // immediately below the unifiedCompact toolbar. Collapses to
            // zero intrinsic height while there's only one tab, so the
            // avatar visually sits exactly where it did before tabs landed.
            tabBarView.topAnchor.constraint(equalTo: content.topAnchor, constant: 36),
            tabBarView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabBarView.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            // Avatar centered horizontally, sitting just below the tab bar
            // (or right under the hidden titlebar when the bar is collapsed
            // to zero height). Its intrinsic content size pins the dimensions.
            avatarView.topAnchor.constraint(equalTo: tabBarView.bottomAnchor, constant: 4),
            avatarView.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            // Sub-agent status bar sits between the avatar and the scroll
            // view. It self-collapses to zero height when no agents are
            // alive, so the layout still feels right when nothing is
            // running.
            subAgentStatusBar.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 8),
            subAgentStatusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            subAgentStatusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            // Scroll view starts below the sub-agent bar.
            scrollView.topAnchor.constraint(equalTo: subAgentStatusBar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: thinkingLabel.topAnchor, constant: -4),

            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            thinkingLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            thinkingLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])

        // Stash for `configureSplitView` to mount inside the right pane.
        // Don't attach to the window directly any more — the split view
        // controller will become the window's contentViewController.
        self.chatContentView = content
    }

    // MARK: - Split view + toolbar
    //
    // Standard macOS chat-app layout: NSSplitViewController with a sidebar
    // item on the left and the chat content on the right. Using the
    // controller (vs raw NSSplitView) is what lets `.toggleSidebar` in the
    // toolbar work without custom plumbing.

    private func configureSplitView() {
        guard let window = window, let chatContent = chatContentView else { return }

        let chatVC = ChatContentHostViewController(rootView: chatContent)

        let split = NSSplitViewController()
        split.splitView.dividerStyle = .thin

        // Use NSVisualEffectView with the standard `.sidebar` material so the
        // sidebar matches the system appearance (Mail/Notes/Finder/Messages
        // all use this). `.behindWindow` lets AppKit sample the desktop for
        // the frosted-glass look even though the chat pane stays opaque.
        let sidebarBackground = NSVisualEffectView()
        sidebarBackground.material = .sidebar
        sidebarBackground.blendingMode = .behindWindow
        sidebarBackground.state = .followsWindowActiveState

        let sidebarHostVC = NSViewController()
        sidebarHostVC.view = sidebarBackground

        sidebarVC.view.translatesAutoresizingMaskIntoConstraints = false
        sidebarBackground.addSubview(sidebarVC.view)

        NSLayoutConstraint.activate([
            sidebarVC.view.topAnchor.constraint(equalTo: sidebarBackground.topAnchor),
            sidebarVC.view.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor),
            sidebarVC.view.trailingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor),
            sidebarVC.view.bottomAnchor.constraint(equalTo: sidebarBackground.bottomAnchor),
        ])

        clearBackgrounds(in: sidebarVC.view)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHostVC)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 250)
        split.addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: chatVC)
        contentItem.minimumThickness = 320
        split.addSplitViewItem(contentItem)

        window.contentViewController = split
        self.splitVC = split
    }

    private func clearBackgrounds(in view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
        }

        if let table = view as? NSTableView {
            table.backgroundColor = .clear
            table.enclosingScrollView?.drawsBackground = false
        }

        if let collection = view as? NSCollectionView {
            collection.backgroundColors = [.clear]
            collection.enclosingScrollView?.drawsBackground = false
        }

        view.subviews.forEach { clearBackgrounds(in: $0) }
    }
    
    private func configureToolbar() {
        guard let window = window else { return }
        let toolbar = NSToolbar(identifier: "loop.toolbar.conversation")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
    }

    private func wireSidebar() {
        // Selecting a conversation in the sidebar swaps the active tab's
        // live thread. The coordinator handles cancellation of any in-flight
        // turn; we just refresh our own view + sidebar selection afterwards.
        sidebarVC.onPicked = { [weak self] conv in
            guard let self = self else { return }
            // Switching threads while the editor is up would leave it
            // floating over an unrelated conversation — flush + close it.
            self.dismissMarkdownEditor()
            guard let tab = self.activeTab else { return }
            // CRITICAL: update the tab's conversation BEFORE telling the
            // coordinator to switch. The coordinator's switchToConversation
            // chains into presenter.showAndReload → reloadFromStore, which
            // reads `activeTab?.conversation` to decide which messages to
            // render. If we hadn't pointed the tab at the new conversation
            // first, the chat panel would rebuild against the *previous*
            // conversation — which is exactly the "I clicked the 1:41 PM
            // row but the 1:52 PM messages loaded" symptom from the bug
            // report.
            tab.conversation = conv
            tab.coordinator.switchToConversation(conv)
            SimpleConversationManager.shared.currentConversation = conv
            self.sidebarVC.setActiveConversationId(conv.id)
            self.refreshTabBar()
            // Match the tab-switch flow: drop into the recorder text input
            // so the user can immediately type without a second gesture.
            self.recorder?.focusTextInput()
        }

        // Right-click in the sidebar → "Open in New Tab" routes here. If the
        // conversation is already loaded into one of our tabs, just switch to
        // it; otherwise spin up a new tab around it.
        sidebarVC.onOpenInNewTab = { [weak self] conv in
            self?.openConversationInTab(conv)
        }

        sidebarVC.onOpenMarkdown = { [weak self] url in
            self?.presentMarkdownEditor(for: url)
        }
    }

    // MARK: - Tabs

    /// Cap on the number of concurrently open tabs. The ⌘1…⌘9 shortcut
    /// scheme only addresses nine, and turning the chat surface into a tab
    /// manager beyond that would be more chaos than utility — match Safari's
    /// limit and let the user close before opening more.
    private static let maxTabs = 9

    /// CMD+T (and the toolbar compose button): create a fresh conversation
    /// and bring up its tab. No-op once we've hit the per-window tab cap.
    @objc func openNewTab() {
        guard tabs.count < Self.maxTabs else {
            NSSound.beep()
            return
        }
        dismissMarkdownEditor()

        let manager = SimpleConversationManager.shared
        // Snapshot the active tab's conversation so we can put it back: the
        // new coordinator's init runs `loadLastConversation()`, which has a
        // side effect of clobbering `manager.currentConversation`. If a tool
        // call (e.g. image generation) lands in the window between this line
        // and `activate(tabAt:)` below, we want it routed to the tab the
        // user was actually looking at, not the half-built new one.
        let priorCurrent = manager.currentConversation

        let title = "Mac Chat \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
        let conv = manager.createConversation(title: title)

        let coordinator = VoiceLoopCoordinator()
        if let restore = priorCurrent { manager.currentConversation = restore }

        let tab = ConversationTab(conversation: conv, coordinator: coordinator)
        let presenter = TabConversationPresenter(window: self, tab: tab)
        tab.presenter = presenter
        coordinator.conversationPresenter = presenter
        coordinator.switchToConversation(conv)
        coordinator.isActive = false

        tabs.append(tab)
        activate(tabAt: tabs.count - 1)
        // activate() handles both surfacing the window (if it was hidden
        // after a CMD+W on an empty last tab) and giving the recorder text
        // field first responder — no extra calls needed here.
    }

    /// CMD+N: "new conversation" with empty-reuse. If the most-recently-
    /// updated conversation in the store has no user/assistant messages,
    /// open *that* one rather than minting a fresh empty conversation —
    /// keeps the sidebar from accumulating identical "Mac Chat …" rows when
    /// the user reflexively hits CMD+N a few times without ever sending a
    /// message. Falls back to `openNewTab()` (which creates a brand-new
    /// conversation) when the most-recent one has actual content.
    @objc func openNewOrReuseEmpty() {
        let manager = SimpleConversationManager.shared
        // Pull from the cached list rather than `loadLastConversation()` —
        // the latter clobbers `manager.currentConversation` as a side effect,
        // which would race with the tab manager's view of "what conversation
        // is foreground."
        if let mostRecent = manager.getAllConversations().first,
           isConversationEmpty(mostRecent) {
            openConversationInTab(mostRecent)
            return
        }
        openNewTab()
    }

    /// True when the conversation has no user/assistant messages — function
    /// calls and other internal entries don't count, since the user wouldn't
    /// recognize them as "real" content worth preserving.
    private func isConversationEmpty(_ conv: SimpleConversation) -> Bool {
        return conv.messages.allSatisfy { $0.role != "user" && $0.role != "assistant" }
    }

    /// CMD+W: close the active tab, kill its coordinator's in-flight work,
    /// and leave the underlying conversation in the store so the user can
    /// re-open it from the sidebar later. If we just closed the last tab,
    /// fall back to opening a fresh one — the window should never be left
    /// with zero tabs (which would also leave the recorder bar unbound).
    @objc func closeActiveTab() {
        guard tabs.indices.contains(activeTabIndex) else { return }
        closeTab(at: activeTabIndex)
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]

        // Special case: closing the LAST tab when it's empty. Tearing it
        // down and immediately spawning another empty conversation is the
        // "CMD+W did nothing visually but swapped my underlying chat" trap
        // the user called out. Treat this as "hide the window" instead —
        // leave the tab alive so the recorder bar stays wired up and the
        // user can re-surface the same conversation later.
        if tabs.count == 1, tabIsEmpty(tab) {
            window?.orderOut(nil)
            return
        }

        // Drop the in-flight turn cleanly (cancels chat tokens, scrubs the
        // mid-turn user message from the store, stops TTS). The conversation
        // itself stays in the store — the spec wants the row to keep showing
        // in the sidebar after a close.
        tab.coordinator.cancelCurrentTurn()
        tab.coordinator.isActive = false
        tab.coordinator.conversationPresenter = nil
        tabs.remove(at: index)

        if tabs.isEmpty {
            // Non-empty last tab walking us to zero: matches Safari/Chrome —
            // open a fresh tab so the recorder bar stays bound to a live
            // coordinator and the user lands on a clean slate.
            openNewTab()
            return
        }

        // Reselect: prefer the tab that occupied this slot's position; if
        // the closed tab was at the trailing edge, fall back one to the
        // left so we never end up with an out-of-range active index.
        let next = min(index, tabs.count - 1)
        activate(tabAt: next)
    }

    /// "No user-visible content" check used by the empty-last-tab path. We
    /// look at the persisted store (not the in-memory snapshot) so a tab
    /// that just finished a turn — but whose snapshot is still pre-message —
    /// still counts as non-empty.
    private func tabIsEmpty(_ tab: ConversationTab) -> Bool {
        let messages = SimpleConversationManager.shared.getMessages(for: tab.conversation)
        return messages.allSatisfy { $0.role != "user" && $0.role != "assistant" }
    }

    /// CMD+N: switch to the Nth tab (1-indexed in the keyboard shortcut,
    /// 0-indexed in the array). No-op if out of range — keeps the shortcut
    /// safe to bind for all nine slots even when fewer tabs are open.
    func switchToTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        guard index != activeTabIndex else { return }
        activate(tabAt: index)
    }

    /// Sidebar right-click handler: bring the named conversation into a tab.
    /// If it's already loaded into one, just switch to that tab; otherwise
    /// open a fresh tab pointing at it (and reuse the active tab's coordinator
    /// if that tab is empty + idle, so right-click → open doesn't pile up
    /// useless empty tabs).
    func openConversationInTab(_ conv: SimpleConversation) {
        if let existing = tabs.firstIndex(where: { $0.conversation.id == conv.id }) {
            switchToTab(at: existing)
            return
        }
        guard tabs.count < Self.maxTabs else {
            NSSound.beep()
            return
        }
        dismissMarkdownEditor()
        // Same save/restore as openNewTab — VoiceLoopCoordinator()'s init
        // grabs `manager.currentConversation` for itself, which would point
        // image-gen / sub-agent callbacks at the wrong tab between here and
        // `activate`.
        let manager = SimpleConversationManager.shared
        let priorCurrent = manager.currentConversation
        let coordinator = VoiceLoopCoordinator()
        if let restore = priorCurrent { manager.currentConversation = restore }
        let tab = ConversationTab(conversation: conv, coordinator: coordinator)
        let presenter = TabConversationPresenter(window: self, tab: tab)
        tab.presenter = presenter
        coordinator.conversationPresenter = presenter
        coordinator.switchToConversation(conv)
        coordinator.isActive = false
        tabs.append(tab)
        activate(tabAt: tabs.count - 1)
    }

    /// Shared activation path: flips the active flags on each coordinator,
    /// repoints the recorder bar, and re-renders the chat content for the
    /// newly-active tab.
    private func activate(tabAt index: Int) {
        guard tabs.indices.contains(index) else { return }
        dismissMarkdownEditor()

        // Flip activeness flags. Marking the previous tab inactive stops its
        // TTS (see VoiceLoopCoordinator.isActive didSet) but lets any
        // in-flight chat callback keep running — it'll persist to the right
        // conversation on completion.
        for (i, tab) in tabs.enumerated() {
            tab.coordinator.isActive = (i == index)
        }
        activeTabIndex = index

        let active = tabs[index]
        // Hydrate the tab's snapshot from the store so its title + message
        // list reflect any writes that landed while this tab was offscreen
        // (background turns, iCloud syncs, sub-agent posts). Without this,
        // the snapshot the tab was opened with would silently drive the
        // header / recovery paths.
        if let refreshed = SimpleConversationManager.shared.getConversation(by: active.conversation.id) {
            active.conversation = refreshed
        }
        SimpleConversationManager.shared.currentConversation = active.conversation

        // Make sure the coordinator's internal pointer matches the tab's
        // conversation. If the previous active tab's coordinator was the
        // most-recent submitter, the store-update path may have nudged its
        // `.conversation` field in subtle ways — re-pinning here keeps the
        // next `sendUserText` aimed at the right thread. switchToConversation
        // is a no-op when ids already match.
        active.coordinator.switchToConversation(active.conversation)
        recorder?.setActiveCoordinator(active.coordinator)

        // Refresh visuals. The chat stack rebuilds from the store so any
        // background-tab message that landed while this tab was offscreen
        // shows up the moment the user lands on it.
        reloadFromStore()
        sidebarVC.setActiveConversationId(active.conversation.id)
        // Re-scope the sub-agent pill to this tab's conversation so only
        // agents spawned from this thread show up here. Tabs that started
        // sub-agents on other conversations re-appear when the user lands
        // back on those tabs. If the inspector window happens to be open we
        // retarget it too so the list the user is staring at flips alongside
        // the pill rather than going stale.
        subAgentStatusBar.conversationId = active.conversation.id
        if SubAgentInspectorWindowController.shared.window?.isVisible == true {
            SubAgentInspectorWindowController.shared.presentInFront(scopedTo: active.conversation.id)
        }
        refreshTabBar()
        // Sync the avatar to whatever state the new tab is in — if we just
        // switched into a tab whose coordinator is thinking, the avatar
        // should immediately read as thinking rather than idle.
        avatarStateChanged(active.coordinator.state)
        // Restore the bottom-hint text for the active tab. Without this the
        // label would keep showing the previous tab's "Thinking…" (sticky)
        // or fall back to the record hint even when the active tab is
        // mid-turn.
        setThinking(active.isThinking, label: active.thinkingLabel)
        // If the window was hidden (e.g., a previous CMD+W on an empty last
        // tab), bring it forward first — otherwise the user activates a
        // tab they can't actually see. Surface BEFORE the recorder grab so
        // makeKey on the chat window doesn't steal focus from the text
        // field a few lines later.
        if window?.isVisible == false { showAndReload() }
        // Every tab activation (CMD+N, tab-cell click, right-click "Open in
        // New Tab", post-close re-activation) drops the user straight into
        // the recorder's text field so they can start typing without a
        // second gesture. Mirrors the CMD+T flow.
        recorder?.focusTextInput()
    }

    private func refreshTabBar() {
        tabBarView.reconfigure(tabs: tabs, activeIndex: activeTabIndex)
    }

    @objc private func voiceLoopStateDidChange() {
        // Any coordinator's state moved — refresh the tab bar so the
        // "running" dot stays in sync with what each tab is actually doing.
        DispatchQueue.main.async { [weak self] in self?.refreshTabBar() }
    }

    // MARK: - TabBarViewDelegate

    func tabBar(_ bar: TabBarView, didSelectTabAt index: Int) {
        switchToTab(at: index)
    }

    func tabBar(_ bar: TabBarView, didCloseTabAt index: Int) {
        closeTab(at: index)
    }

    // MARK: - Markdown editor overlay
    //
    // The editor slides up vertically over the chat pane (the split view's
    // right content view), leaving the sidebar untouched. Driven by a single
    // top constraint animated from "fully below the visible area" to 0.

    func presentMarkdownEditor(for url: URL) {
        guard let host = chatContentView else { return }

        // Replace any editor already up (saving its edits first).
        if markdownEditorVC != nil {
            tearDownMarkdownEditor(animated: false)
        }

        let editor = MarkdownEditorViewController(fileURL: url)
        editor.onClose = { [weak self] in self?.dismissMarkdownEditor() }

        // `self` is an NSWindowController, not a view controller, so there's
        // no containment to hook into — we retain the editor via
        // `markdownEditorVC` and let it manage its own first responder. The
        // first `.view` access drives loadView/viewDidLoad.
        let ev = editor.view
        ev.translatesAutoresizingMaskIntoConstraints = false
        ev.wantsLayer = true
        ev.layer?.shadowColor = NSColor.black.cgColor
        ev.layer?.shadowOpacity = 0.18
        ev.layer?.shadowRadius = 12
        ev.layer?.shadowOffset = CGSize(width: 0, height: 4)
        host.addSubview(ev)

        // Rest the editor against the safe-area top, not the raw view top —
        // the window uses fullSizeContentView + a transparent titlebar, so
        // pinning to `host.topAnchor` would slide the editor's header up
        // behind the toolbar (clipping its title and the Save/Done buttons).
        // The safe-area guide already excludes the toolbar band, so its
        // height is exactly the visible chat area below the toolbar.
        let safeArea = host.safeAreaLayoutGuide
        let startOffset = max(host.bounds.height, 1)
        let top = ev.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: startOffset)
        NSLayoutConstraint.activate([
            ev.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            ev.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ev.heightAnchor.constraint(equalTo: safeArea.heightAnchor),
            top,
        ])

        markdownEditorVC = editor
        markdownEditorTop = top

        host.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.34
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            top.animator().constant = 0
            host.layoutSubtreeIfNeeded()
        }
    }

    private func dismissMarkdownEditor() {
        guard let host = chatContentView,
              let editor = markdownEditorVC,
              let top = markdownEditorTop else { return }
        // Always flush unsaved edits, regardless of how we got here (Done,
        // Esc, conversation switch).
        editor.autosaveIfNeeded()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            top.animator().constant = max(host.bounds.height, 1)
            host.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self, weak editor] in
            guard let editor = editor else { return }
            editor.view.removeFromSuperview()
            if self?.markdownEditorVC === editor {
                self?.markdownEditorVC = nil
                self?.markdownEditorTop = nil
            }
        })
    }

    /// Synchronous teardown used when replacing one editor with another —
    /// no slide-out, just save + remove.
    private func tearDownMarkdownEditor(animated: Bool) {
        guard let editor = markdownEditorVC else { return }
        editor.autosaveIfNeeded()
        editor.view.removeFromSuperview()
        markdownEditorVC = nil
        markdownEditorTop = nil
    }

    @objc private func toolbarComposeClicked() {
        // Compose now opens a new tab rather than swapping the current tab's
        // conversation — that way the user's in-flight work doesn't vanish
        // when they want to jot a separate thought. Matches CMD+T.
        openNewTab()
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.toggleSidebar, .flexibleSpace, Self.composeToolbarIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.toggleSidebar, .flexibleSpace, .space, Self.composeToolbarIdentifier]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.composeToolbarIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "New Conversation"
            item.paletteLabel = "New Conversation"
            item.toolTip = "Start a new conversation"
            item.image = NSImage(systemSymbolName: "square.and.pencil",
                                 accessibilityDescription: "New Conversation")
            item.target = self
            item.action = #selector(toolbarComposeClicked)
            return item
        default:
            // .toggleSidebar and .flexibleSpace are system items — returning
            // nil lets AppKit create the standard version.
            return nil
        }
    }

    func reloadFromStore() {
        let manager = SimpleConversationManager.shared
        // Anchor on the active tab's conversation rather than the manager's
        // global pointer — with multiple tabs alive, "current" follows the
        // foreground tab but the store also fields writes from background
        // tabs that we shouldn't accidentally re-render here.
        let conv: SimpleConversation? = activeTab?.conversation
            ?? manager.currentConversation
            ?? manager.loadLastConversation()
        guard let conv = conv else {
            sidebarVC.reload()
            sidebarVC.setActiveConversationId(nil)
            rebuild(messages: [])
            return
        }
        // Pull fresh metadata for the active tab from the store so the tab
        // cell's title reflects any title rename that happened elsewhere.
        if let refreshed = manager.getConversation(by: conv.id),
           let active = activeTab,
           active.conversation.id == refreshed.id {
            active.conversation = refreshed
            manager.currentConversation = refreshed
        }
        let messages = manager.getMessages(for: conv)
        rebuild(messages: messages)
        // Keep the sidebar in lock-step: pull fresh metadata so the row's
        // snippet + relative-time label reflect the just-appended message,
        // and highlight whichever conversation is now live.
        sidebarVC.reload()
        sidebarVC.setActiveConversationId(conv.id)
        refreshTabBar()
    }

    private func rebuild(messages: [SimpleMessage]) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        // Forget the bubble views — they're being torn down. The attachment
        // map survives so we can re-render their state below.
        imageBubbles.removeAll()
        pdfBubbles.removeAll()
        lastRebuiltMessages = messages
        let manager = SimpleConversationManager.shared
        for (messageIndex, message) in messages.enumerated() {
            // Map embed and share_file results ride on a function-role
            // message (the tool result whose only surface is the rendered
            // visual). Surface them before the role switch so they don't
            // get dropped by the "skip non-user/assistant" default below.
            if message.role == "function" {
                let m = manager.messageStruct(from: message)
                if let mapAttachment = m.mapAttachment {
                    stack.addArrangedSubview(makeMapRow(bubbleView: MapBubbleView(attachment: mapAttachment)))
                } else if let fileAttachment = m.fileAttachment {
                    // role="assistant" routes the existing bubble factory
                    // to the assistant-side alignment (leading edge,
                    // borderless caption) instead of the user-upload look.
                    // Pass an empty caption — `m.content` here is the
                    // LLM-only confirmation ("Shared X with the user…")
                    // and shouldn't appear under the card for the human.
                    stack.addArrangedSubview(makeAttachmentBubble(attachment: fileAttachment,
                                                                   text: "",
                                                                   role: "assistant"))
                }
                continue
            }
            switch message.role {
            case "user", "assistant":
                let viewCountBefore = stack.arrangedSubviews.count

                // image-prefixed assistant rows are placeholder messages from
                // a generate_image call. The attachment itself isn't in the
                // store; pull the live state from imageAttachments and render
                // an image bubble. If the attachment is gone (cold relaunch
                // before persistence ships), render an "expired" placeholder
                // so the row isn't an empty bubble.
                if message.role == "assistant",
                   message.id.hasPrefix(Self.imageMessageIdPrefix) {
                    let attachmentId = String(message.id.dropFirst(Self.imageMessageIdPrefix.count))
                    let attachment = imageAttachments[attachmentId]
                        ?? ImageAttachment(id: attachmentId,
                                           prompt: message.content,
                                           status: .failed,
                                           failureReason: "Image is no longer available — generate it again to retry.")
                    let bubble = ImageBubbleView(attachment: attachment) { [weak self] att in
                        self?.retryImage(attachment: att)
                    }
                    imageBubbles[attachmentId] = bubble
                    stack.addArrangedSubview(makeImageRow(bubbleView: bubble))
                } else if message.role == "assistant",
                   message.id.hasPrefix(Self.pdfMessageIdPrefix) {
                    // pdf-prefixed assistant rows mirror the image branch: the
                    // placeholder message in the store has no real content; the
                    // live attachment lives in `pdfAttachments`. If we don't
                    // have it (cold relaunch before the render completed), the
                    // bubble surfaces the same "no longer available" recovery.
                    let attachmentId = String(message.id.dropFirst(Self.pdfMessageIdPrefix.count))
                    let attachment = pdfAttachments[attachmentId]
                        ?? PDFAttachment(id: attachmentId,
                                         title: message.content.isEmpty ? "Untitled PDF" : message.content,
                                         template: "report",
                                         document: "",
                                         status: .failed,
                                         failureReason: "PDF is no longer available — ask Loop to regenerate it.")
                    let bubble = PDFBubbleView(attachment: attachment,
                                               onPreview: { [weak self] att in self?.previewPDF(attachment: att) },
                                               onShare:   { [weak self] att, sender in self?.sharePDF(attachment: att, from: sender) },
                                               onRetry:   { [weak self] att in self?.retryPDF(attachment: att) })
                    pdfBubbles[attachmentId] = bubble
                    stack.addArrangedSubview(makePDFRow(bubbleView: bubble))
                } else {
                    // Going through messageStruct gives us the decoded
                    // FileAttachment (if any) without re-parsing JSON here.
                    let m = manager.messageStruct(from: message)
                    // Onboarding bubble: chip row hangs off the assistant prompt.
                    // The card itself isn't persisted (the kind enum has
                    // associated values that don't round-trip through the store),
                    // so the live card lives in `onboardingCards` keyed by id.
                    if message.role == "assistant",
                       let card = onboardingCards[message.id] {
                        stack.addArrangedSubview(
                            MacOnboardingChipBubble.makeBubble(text: message.content,
                                                              card: card,
                                                              delegate: self))
                    } else if let attachment = m.fileAttachment {
                        stack.addArrangedSubview(makeAttachmentBubble(attachment: attachment,
                                                                       text: m.content,
                                                                       role: message.role))
                    } else if let mapAttachment = m.mapAttachment {
                        stack.addArrangedSubview(makeMapRow(bubbleView: MapBubbleView(attachment: mapAttachment)))
                    } else {
                        stack.addArrangedSubview(makeBubble(role: message.role, text: message.content, model: m.role == "assistant" ? m.model : nil))
                    }
                }

                // Attach a right-click context menu to the row that was
                // just added so the user can branch the conversation.
                if stack.arrangedSubviews.count > viewCountBefore,
                   let rowView = stack.arrangedSubviews.last {
                    let menu = NSMenu()
                    let item = NSMenuItem(title: "Branch conversation from here",
                                          action: #selector(branchFromContextMenu(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.tag = messageIndex
                    item.image = NSImage(systemSymbolName: "arrow.triangle.branch",
                                         accessibilityDescription: nil)
                    menu.addItem(item)
                    rowView.menu = menu
                }
            default:
                continue
            }
        }
        scrollToBottom()
    }

    private func retryImage(attachment: ImageAttachment) {
        // Reuse the same id so the existing placeholder message + bubble get
        // updated in place rather than a second one being inserted. Re-stamp
        // the conversationId so a retry triggered from a background tab
        // still routes back to that same tab when it completes — without
        // this, the second submit would carry a nil id and the host would
        // fall back to "current tab" again, recreating the original bug.
        ImageGenerationService.shared.retry(
            attachmentId: attachment.id,
            prompt: attachment.prompt,
            conversationId: attachment.conversationId
        )
    }

    // MARK: - PDF bubble actions

    private func previewPDF(attachment: PDFAttachment) {
        guard let url = attachment.fileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        // NSWorkspace.open hands the PDF to Preview.app (or whichever
        // handler the user has set). Quick Look would also work via
        // QLPreviewPanel but it requires a controller-style data source —
        // hand-off to Preview is one line and matches what the user
        // expects from a file in chat.
        NSWorkspace.shared.open(url)
    }

    private func sharePDF(attachment: PDFAttachment, from sender: NSView) {
        guard let url = attachment.fileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func retryPDF(attachment: PDFAttachment) {
        PDFGenerationService.shared.retry(
            attachmentId: attachment.id,
            title: attachment.title,
            document: attachment.document,
            template: attachment.template,
            conversationId: attachment.conversationId
        )
    }

    // MARK: - Branch conversation

    @objc private func branchFromContextMenu(_ sender: NSMenuItem) {
        let messageIndex = sender.tag
        guard messageIndex >= 0, messageIndex < lastRebuiltMessages.count else { return }

        let manager = SimpleConversationManager.shared
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        let branchedConversation = manager.createConversation(title: "Branch \(timestamp)")

        for i in 0...messageIndex {
            let simpleMessage = lastRebuiltMessages[i]
            // Skip system messages — the new conversation gets its own.
            if simpleMessage.role == "system" { continue }
            let msg = manager.messageStruct(from: simpleMessage)
            manager.addMessage(msg, to: branchedConversation)
        }

        if let fresh = manager.getConversation(by: branchedConversation.id) {
            openConversationInTab(fresh)
        }
    }

    func showAndReload() {
        guard let window = window else { return }
        if !hasShown {
            hasShown = true
            window.center()
        }
        // Bring the window back even if it was minimized to the dock — a
        // response from the assistant should always be visible.
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        // `orderFrontRegardless` bypasses the "must be the active app" check.
        // The send path can come from the recorder bar (a non-activating
        // panel), in which case `NSApp.activate` doesn't fully promote Loop
        // and a plain `makeKeyAndOrderFront` would leave this window stuck
        // behind whichever app the user was actually working in. Forcing it
        // front first, then making it key, is the only reliable order.
        window.orderFrontRegardless()
        window.makeKey()
        reloadFromStore()
    }

    /// Make sure the window is visible/forward without re-reloading from
    /// disk — used during an in-flight turn where we already have the
    /// freshest state in memory.
    ///
    /// Two paths an in-flight thinking-state change can take here:
    ///  - Window not on screen yet → show it (first response after a
    ///    new tab, or after a CMD+W on an empty last tab).
    ///  - Window already on screen → leave the user's window stacking
    ///    alone. Specifically, if the user has the terminal window
    ///    foregrounded to watch a session run, we DO NOT want a
    ///    thinking-state notification yanking the chat above it. The
    ///    chat already has the message; ordering can wait until the
    ///    user clicks back.
    private func surfaceForResponse() {
        guard let window = window else { return }
        if !hasShown {
            hasShown = true
            window.center()
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isVisible {
            showWindow(nil)
            window.orderFront(nil)
            return
        }
        // Window's already visible somewhere in the stack — don't yank
        // it on top of whatever else the user is focused on (terminal
        // session, scheduled-tasks pane, etc).
    }

    func appendUserMessage(_ text: String) {
        stack.addArrangedSubview(makeBubble(role: "user", text: text, model: nil))
        scrollToBottom()
    }

    func appendUserAttachment(_ attachment: FileAttachment, text: String?) {
        stack.addArrangedSubview(makeAttachmentBubble(attachment: attachment,
                                                       text: text ?? "",
                                                       role: "user"))
        scrollToBottom()
    }

    func appendAssistantMessage(_ text: String, model: String?) {
        stack.addArrangedSubview(makeBubble(role: "assistant", text: text, model: model))
        scrollToBottom()
        // Speaking starts immediately after the assistant text lands, so
        // this is the right moment to make sure the window is on screen.
        surfaceForResponse()
    }

    func setThinking(_ thinking: Bool, label: String?) {
        if thinking {
            thinkingLabel.stringValue = label ?? ""
            thinkingLabel.textColor = .secondaryLabelColor
            surfaceForResponse()
        } else {
            // Idle state — fall back to the keyboard hint so the bottom bar
            // always tells the user how to start a turn.
            thinkingLabel.stringValue = Self.recordHintText
            thinkingLabel.textColor = .tertiaryLabelColor
        }
    }

    private static let recordHintText = "Hold down fn + ctrl to speak"

    func avatarStateChanged(_ state: VoiceLoopCoordinator.State) {
        // .transcribing has no dedicated avatar mode — it's a brief in-between
        // state, and visually it reads the same as thinking (we've stopped
        // listening and we're waiting on the network). Lumping them keeps the
        // transition from listening → thinking smooth.
        switch state {
        case .idle:         avatarView.mode = .idle
        case .recording:    avatarView.mode = .listening
        case .transcribing: avatarView.mode = .thinking
        case .thinking:     avatarView.mode = .thinking
        case .speaking:     avatarView.mode = .speaking
        }
    }

    func avatarAmplitudeChanged(_ amplitude: Float) {
        avatarView.amplitude = amplitude
    }

    func avatarPulse() {
        avatarView.pulse()
    }

    private func makeBubble(role: String, text: String, model: String?) -> NSView {
        let isUser = role == "user"
        // AdaptiveBubbleView for user turns so the systemBlue fill
        // re-resolves on appearance change; assistant turns stay a plain
        // NSView since they have no background at all.
        let bubble: NSView = isUser ? AdaptiveBubbleView() : NSView()
        bubble.wantsLayer = true
        bubble.translatesAutoresizingMaskIntoConstraints = false
        if isUser, let userBubble = bubble as? AdaptiveBubbleView {
            userBubble.layer?.cornerRadius = 14
            userBubble.layer?.cornerCurve = .continuous
            userBubble.fillColor = .systemBlue
        }

        // User bubbles stay a plain NSTextField — the user's own input
        // shouldn't be re-interpreted as markdown. Assistant bubbles use a
        // link-aware NSTextView so clicking a markdown file link routes into
        // the editor (and other links keep opening in the system handler).
        // When the assistant message contains a markdown table, the single
        // text view is replaced by a vertical NSStackView of prose text
        // views and grid views, one per parsed segment.
        let contentView: NSView
        if isUser {
            let label = NSTextField(wrappingLabelWithString: "")
            label.isSelectable = true
            label.allowsEditingTextAttributes = true
            label.font = NSFont.systemFont(ofSize: 14)
            label.textColor = .white
            label.stringValue = text
            contentView = label
        } else if MarkdownSegmenter.containsRichContent(in: text) {
            contentView = makeAssistantRichContentView(text: text, maxWidth: 380 - 24)
        } else {
            let tv = ChatLinkTextView.makeBubbleTextView(maxTextWidth: 380 - 24)
            tv.delegate = self
            tv.textStorage?.setAttributedString(Self.markdownAttributedString(from: text))
            contentView = tv
        }
        contentView.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            contentView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
            contentView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            contentView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
        ])

        // Wrap the bubble plus its optional model-attribution caption into a
        // vertical column. The column gets right/left-aligned in `row` below.
        let column = NSStackView()
        column.translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical
        column.alignment = isUser ? .trailing : .leading
        column.spacing = 2
        column.addArrangedSubview(bubble)

        if !isUser, let model = model, !model.isEmpty {
            let modelLabel = NSTextField(labelWithString: model)
            modelLabel.font = .systemFont(ofSize: 10)
            modelLabel.textColor = .tertiaryLabelColor
            modelLabel.translatesAutoresizingMaskIntoConstraints = false
            // Wrap in a container so we can match the bubble's internal 12pt
            // leading inset — otherwise the caption would sit flush with the
            // column's edge while the bubble text starts 12pt in, and the
            // two reads as misaligned.
            let modelRow = NSView()
            modelRow.translatesAutoresizingMaskIntoConstraints = false
            modelRow.addSubview(modelLabel)
            NSLayoutConstraint.activate([
                modelLabel.topAnchor.constraint(equalTo: modelRow.topAnchor),
                modelLabel.bottomAnchor.constraint(equalTo: modelRow.bottomAnchor),
                modelLabel.leadingAnchor.constraint(equalTo: modelRow.leadingAnchor, constant: 12),
                modelLabel.trailingAnchor.constraint(lessThanOrEqualTo: modelRow.trailingAnchor),
            ])
            column.addArrangedSubview(modelRow)
            column.setCustomSpacing(2, after: bubble)
        }

        // Wrap in a row so we can right-align user bubbles.
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .top
        if isUser {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
            row.addArrangedSubview(column)
        } else {
            row.addArrangedSubview(column)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
        }
        bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        return row
    }

    /// Render a user-uploaded attachment as a bubble, with any accompanying
    /// text underneath. Image / PDF kinds get an inline thumbnail (click →
    /// open in Preview); markdown / source / text / generic kinds route to
    /// `makeFilePreviewCardBubble` for the icon+snippet card path.
    private func makeAttachmentBubble(attachment: FileAttachment, text: String, role: String) -> NSView {
        if attachment.kind != .image && attachment.kind != .pdf {
            return makeFilePreviewCardBubble(attachment: attachment, text: text, role: role)
        }
        let isUser = role == "user"

        let bubble = NSView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.wantsLayer = true

        // Image / PDF preview at the top of the bubble.
        let preview = ClickableImageView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 10
        preview.layer?.masksToBounds = true
        preview.layer?.borderWidth = 1
        preview.layer?.borderColor = NSColor.separatorColor.cgColor
        preview.fileURL = attachment.fileURL  // click → Reveal in Finder / open
        bubble.addSubview(preview)

        // Side dimension — images are square, PDFs are wider+shorter.
        let side: CGFloat = 240
        let pdfHeight: CGFloat = 150

        var constraints: [NSLayoutConstraint] = [
            preview.topAnchor.constraint(equalTo: bubble.topAnchor),
            preview.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            preview.widthAnchor.constraint(equalToConstant: side),
        ]
        constraints.append(
            preview.heightAnchor.constraint(equalToConstant: attachment.kind == .pdf ? pdfHeight : side)
        )

        if text.isEmpty {
            constraints.append(preview.bottomAnchor.constraint(equalTo: bubble.bottomAnchor))
        } else {
            // Caption text below the preview. Uses the same styling as a user
            // bubble so it visually pairs with the file.
            let captionWrap = AdaptiveBubbleView()
            captionWrap.translatesAutoresizingMaskIntoConstraints = false
            captionWrap.wantsLayer = true
            captionWrap.layer?.cornerRadius = 14
            captionWrap.layer?.cornerCurve = .continuous
            captionWrap.fillColor = isUser ? .systemBlue : .controlBackgroundColor

            let caption = NSTextField(wrappingLabelWithString: text)
            caption.translatesAutoresizingMaskIntoConstraints = false
            caption.font = NSFont.systemFont(ofSize: 14)
            caption.textColor = isUser ? .white : .labelColor
            caption.isSelectable = true
            captionWrap.addSubview(caption)

            bubble.addSubview(captionWrap)

            constraints += [
                captionWrap.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 6),
                captionWrap.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
                captionWrap.leadingAnchor.constraint(greaterThanOrEqualTo: bubble.leadingAnchor),
                captionWrap.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),

                caption.topAnchor.constraint(equalTo: captionWrap.topAnchor, constant: 8),
                caption.bottomAnchor.constraint(equalTo: captionWrap.bottomAnchor, constant: -8),
                caption.leadingAnchor.constraint(equalTo: captionWrap.leadingAnchor, constant: 12),
                caption.trailingAnchor.constraint(equalTo: captionWrap.trailingAnchor, constant: -12),
            ]
        }

        NSLayoutConstraint.activate(constraints)

        // Load the preview off the main thread so big images don't hitch the
        // scroll animation. PDFs render page 1 as a thumbnail.
        let url = attachment.fileURL
        let kind = attachment.kind
        let pdfSize = CGSize(width: side, height: pdfHeight)
        DispatchQueue.global(qos: .userInitiated).async { [weak preview] in
            let image: NSImage?
            switch kind {
            case .image:
                image = (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
            case .pdf:
                image = ConversationWindowController.renderPDFThumbnail(at: url, size: pdfSize)
            case .markdown, .text, .generic:
                // Unreachable — the guard at the top of makeAttachmentBubble
                // routes these kinds to the card path. Compiler requires the
                // case for exhaustiveness on the non-frozen `Kind` enum.
                image = nil
            }
            DispatchQueue.main.async {
                preview?.image = image
            }
        }

        // Right-align user bubbles in a containing row, matching makeBubble.
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .top
        if isUser {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
            row.addArrangedSubview(bubble)
        } else {
            row.addArrangedSubview(bubble)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
        }
        bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        return row
    }

    /// Card variant of the attachment bubble used for markdown / source /
    /// plain-text / generic kinds. Renders icon + filename (+ language
    /// badge for source) + subtitle + snippet of the file contents. Click
    /// behavior mirrors message-link handling: markdown opens in the
    /// in-app editor, everything else opens in the system handler.
    private func makeFilePreviewCardBubble(attachment: FileAttachment, text: String, role: String) -> NSView {
        let isUser = role == "user"

        let bubble = NSView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.wantsLayer = true

        let card = MacFilePreviewCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.configure(for: attachment)
        card.onClick = { [weak self] url in
            // Markdown gets the slide-up in-app editor for parity with link
            // taps inside assistant replies. The other kinds (source, text,
            // generic) hand off to the system handler — Preview, Xcode,
            // Finder, whatever owns the UTI.
            if attachment.kind == .markdown,
               MarkdownEditorViewController.isMarkdownFile(url),
               FileManager.default.fileExists(atPath: url.path) {
                self?.presentMarkdownEditor(for: url)
                return
            }
            NSWorkspace.shared.open(url)
        }
        bubble.addSubview(card)

        let cardWidth: CGFloat = 240

        var constraints: [NSLayoutConstraint] = [
            card.topAnchor.constraint(equalTo: bubble.topAnchor),
            card.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            card.widthAnchor.constraint(equalToConstant: cardWidth),
        ]

        if text.isEmpty {
            constraints.append(card.bottomAnchor.constraint(equalTo: bubble.bottomAnchor))
        } else {
            let captionWrap = AdaptiveBubbleView()
            captionWrap.translatesAutoresizingMaskIntoConstraints = false
            captionWrap.wantsLayer = true
            captionWrap.layer?.cornerRadius = 14
            captionWrap.layer?.cornerCurve = .continuous
            captionWrap.fillColor = isUser ? .systemBlue : .controlBackgroundColor

            let caption = NSTextField(wrappingLabelWithString: text)
            caption.translatesAutoresizingMaskIntoConstraints = false
            caption.font = NSFont.systemFont(ofSize: 14)
            caption.textColor = isUser ? .white : .labelColor
            caption.isSelectable = true
            captionWrap.addSubview(caption)
            bubble.addSubview(captionWrap)

            constraints += [
                captionWrap.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 6),
                captionWrap.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
                captionWrap.leadingAnchor.constraint(greaterThanOrEqualTo: bubble.leadingAnchor),
                captionWrap.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),

                caption.topAnchor.constraint(equalTo: captionWrap.topAnchor, constant: 8),
                caption.bottomAnchor.constraint(equalTo: captionWrap.bottomAnchor, constant: -8),
                caption.leadingAnchor.constraint(equalTo: captionWrap.leadingAnchor, constant: 12),
                caption.trailingAnchor.constraint(equalTo: captionWrap.trailingAnchor, constant: -12),
            ]
        }

        NSLayoutConstraint.activate(constraints)

        // Right-align user bubbles in a containing row, matching makeBubble.
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .top
        if isUser {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
            row.addArrangedSubview(bubble)
        } else {
            row.addArrangedSubview(bubble)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
        }
        bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        return row
    }

    fileprivate static func renderPDFThumbnail(at url: URL, size: CGSize) -> NSImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let pageRect = page.bounds(for: .mediaBox)
        let scale = min(size.width / pageRect.width, size.height / pageRect.height)
        let target = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        let image = NSImage(size: target)
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: target))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: target.height)
        ctx.scaleBy(x: scale, y: -scale)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        return image
    }

    /// Lightweight markdown → NSAttributedString renderer for assistant
    /// replies. Handles the subset that actually shows up in our model
    /// output: ATX headings, **bold**, *italic* / _italic_, `inline code`,
    /// [text](url) links, and bare URLs. This mirrors the iOS path in
    /// MessagingCell so both clients style replies the same way.
    static func markdownAttributedString(from text: String) -> NSAttributedString {
        let bodyFont = NSFont.systemFont(ofSize: 14)
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let attributed = NSMutableAttributedString(string: text, attributes: baseAttrs)

        // Fenced code blocks: ```lang\n…\n```. Strip the fence markers and
        // style the interior as a monospaced block with a tinted background.
        // Processed first so later passes (headers, bold, links) never touch
        // source code inside a fence.
        let fencedPattern = "(?m)^[ \\t]*(`{3,}|~{3,})[^\\n]*\\n([\\s\\S]*?)^[ \\t]*\\1[ \\t]*$"
        if let fencedRegex = try? NSRegularExpression(pattern: fencedPattern, options: [.anchorsMatchLines]) {
            let matches = fencedRegex.matches(in: attributed.string, options: [],
                                              range: NSRange(location: 0, length: attributed.length))
            let codeFont = NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize - 1, weight: .regular)
            let codeBg = NSColor.labelColor.withAlphaComponent(0.06)
            for match in matches.reversed() {
                let codeRange = match.range(at: 2)
                guard codeRange.location != NSNotFound else { continue }
                let codeText = (attributed.string as NSString).substring(with: codeRange)
                let replacement = NSMutableAttributedString(string: codeText, attributes: [
                    .font: codeFont,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: codeBg,
                ])
                attributed.replaceCharacters(in: match.range, with: replacement)
            }
        }

        func boldFont(matching font: NSFont) -> NSFont {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.bold)
            return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }
        func italicFont(matching font: NSFont) -> NSFont {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }

        // Headings: # / ## / ###. Bigger + bold, decreasing by level.
        if let headerRegex = try? NSRegularExpression(pattern: "^(#{1,6})\\s*(.*?)$", options: [.anchorsMatchLines]) {
            let headerMatches = headerRegex.matches(in: attributed.string, options: [], range: NSRange(location: 0, length: attributed.length))
            for match in headerMatches.reversed() {
                let level = match.range(at: 1).length
                let contentRange = match.range(at: 2)
                guard contentRange.location != NSNotFound else { continue }
                let headerText = (attributed.string as NSString).substring(with: contentRange)
                let size = max(13, 20 - CGFloat(level - 1) * 2)
                let headerFont = NSFont.boldSystemFont(ofSize: size)
                let header = NSAttributedString(string: headerText, attributes: [
                    .font: headerFont,
                    .foregroundColor: NSColor.labelColor,
                ])
                attributed.replaceCharacters(in: match.range, with: header)
            }
        }

        // Bold: **text**
        if let boldRegex = try? NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*", options: []) {
            let matches = boldRegex.matches(in: attributed.string, options: [], range: NSRange(location: 0, length: attributed.length))
            for match in matches.reversed() {
                let innerRange = match.range(at: 1)
                guard innerRange.location != NSNotFound else { continue }
                let inner = attributed.attributedSubstring(from: innerRange).mutableCopy() as! NSMutableAttributedString
                inner.enumerateAttribute(.font, in: NSRange(location: 0, length: inner.length)) { value, range, _ in
                    let current = (value as? NSFont) ?? bodyFont
                    inner.addAttribute(.font, value: boldFont(matching: current), range: range)
                }
                attributed.replaceCharacters(in: match.range, with: inner)
            }
        }

        // Italic: *text* or _text_ — avoid matching the leftovers of bold
        // markers by requiring non-asterisk content inside.
        if let italicRegex = try? NSRegularExpression(pattern: "(?<![\\*_])([\\*_])(?!\\1)([^\\*_\\n]+?)\\1(?![\\*_])", options: []) {
            let matches = italicRegex.matches(in: attributed.string, options: [], range: NSRange(location: 0, length: attributed.length))
            for match in matches.reversed() {
                let innerRange = match.range(at: 2)
                guard innerRange.location != NSNotFound else { continue }
                let inner = attributed.attributedSubstring(from: innerRange).mutableCopy() as! NSMutableAttributedString
                inner.enumerateAttribute(.font, in: NSRange(location: 0, length: inner.length)) { value, range, _ in
                    let current = (value as? NSFont) ?? bodyFont
                    inner.addAttribute(.font, value: italicFont(matching: current), range: range)
                }
                attributed.replaceCharacters(in: match.range, with: inner)
            }
        }

        // Inline code: `text`. Skip ranges already inside a fenced code block.
        if let codeRegex = try? NSRegularExpression(pattern: "`([^`\\n]+)`", options: []) {
            let matches = codeRegex.matches(in: attributed.string, options: [], range: NSRange(location: 0, length: attributed.length))
            for match in matches.reversed() {
                let innerRange = match.range(at: 1)
                guard innerRange.location != NSNotFound else { continue }
                if attributed.attribute(.backgroundColor, at: match.range.location, effectiveRange: nil) != nil { continue }
                let codeText = (attributed.string as NSString).substring(with: innerRange)
                let codeFont = NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize - 0.5, weight: .regular)
                let code = NSAttributedString(string: codeText, attributes: [
                    .font: codeFont,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.labelColor.withAlphaComponent(0.12),
                ])
                attributed.replaceCharacters(in: match.range, with: code)
            }
        }

        // Markdown links: [text](url)
        if let linkRegex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#, options: []) {
            let matches = linkRegex.matches(in: attributed.string, options: [], range: NSRange(location: 0, length: attributed.length))
            for match in matches.reversed() {
                guard match.numberOfRanges == 3 else { continue }
                let textRange = match.range(at: 1)
                let urlRange = match.range(at: 2)
                let urlString = (attributed.string as NSString).substring(with: urlRange)
                guard let url = URL(string: urlString) else { continue }
                let inner = attributed.attributedSubstring(from: textRange).mutableCopy() as! NSMutableAttributedString
                let innerRange = NSRange(location: 0, length: inner.length)
                inner.addAttribute(.link, value: url, range: innerRange)
                inner.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: innerRange)
                inner.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: innerRange)
                attributed.replaceCharacters(in: match.range, with: inner)
            }
        }

        // Filesystem paths → tappable file name. Vault-relative paths
        // become obsidian:// links, others become file://. Runs before
        // the NSDataDetector pass so a path never gets reinterpreted as
        // a generic URL.
        if let pathRegex = try? NSRegularExpression(pattern: FilePathLinkifier.pattern, options: []) {
            let matches = pathRegex.matches(in: attributed.string, options: [],
                                            range: NSRange(location: 0, length: attributed.length))
            for match in matches.reversed() {
                if attributed.attribute(.link, at: match.range.location, effectiveRange: nil) != nil { continue }
                let raw = (attributed.string as NSString).substring(with: match.range)
                guard let resolved = FilePathLinkifier.resolve(raw) else { continue }
                let replacement = NSMutableAttributedString(string: resolved.displayName, attributes: [
                    .font: bodyFont,
                    .foregroundColor: NSColor.systemBlue,
                ])
                let r = NSRange(location: 0, length: replacement.length)
                replacement.addAttribute(.link, value: resolved.url, range: r)
                replacement.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                attributed.replaceCharacters(in: match.range, with: replacement)
            }
        }

        // Bare URLs picked up by NSDataDetector — skip ranges that already
        // carry a .link from the markdown pass above.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let matches = detector.matches(in: attributed.string, options: [], range: NSRange(location: 0, length: attributed.length))
            for match in matches {
                guard let url = match.url else { continue }
                if attributed.attribute(.link, at: match.range.location, effectiveRange: nil) != nil { continue }
                attributed.addAttribute(.link, value: url, range: match.range)
                attributed.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: match.range)
                attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            }
        }

        return attributed
    }

    // MARK: - Markdown table rendering

    /// Builds the assistant bubble's content when the response contains a
    /// GFM table: a vertical NSStackView with one subview per parsed
    /// segment (ChatLinkTextView for prose, a custom grid view for each
    /// table). The bubble's outer geometry (insets, max width) stays the
    /// same as the plain-text path so layout doesn't shift.
    private func makeAssistantRichContentView(text: String, maxWidth: CGFloat) -> NSView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.distribution = .gravityAreas
        // When a bubble contains a table, force it to the bubble's max
        // content width. Without this the NSStackView would hug to the
        // intrinsic size of the prose, which in turn shrinks the table
        // grid into an unreadable thumbnail.
        stack.widthAnchor.constraint(equalToConstant: maxWidth).isActive = true

        for segment in MarkdownSegmenter.segments(from: text) {
            switch segment {
            case .text(let prose):
                let tv = ChatLinkTextView.makeBubbleTextView(maxTextWidth: maxWidth)
                tv.delegate = self
                tv.textStorage?.setAttributedString(Self.markdownAttributedString(from: prose))
                stack.addArrangedSubview(tv)
                tv.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            case .table(let table):
                let gridView = makeMarkdownTableView(table)
                stack.addArrangedSubview(gridView)
                gridView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            case .codeBlock(let block):
                let codeView = makeCodeBlockView(block)
                stack.addArrangedSubview(codeView)
                codeView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        return stack
    }

    /// Builds a rounded container with monospaced code text, a subtle
    /// background, and an optional language label in the top-right corner.
    private func makeCodeBlockView(_ block: MarkdownCodeBlock) -> NSView {
        let container = AdaptiveTableLayerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.adaptiveCornerRadius = 8
        container.adaptiveBackground = NSColor.labelColor.withAlphaComponent(0.06)
        container.adaptiveBorder = nil
        container.adaptiveBorderWidth = 0

        let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let tv = ChatLinkTextView.makeBubbleTextView(maxTextWidth: .greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.textStorage?.setAttributedString(
            CodeSyntaxHighlighter.highlight(block.code, language: block.language, font: codeFont)
        )
        container.addSubview(tv)
        tv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: container.topAnchor),
            tv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        if let lang = block.language, !lang.isEmpty {
            let label = NSTextField(labelWithString: lang)
            label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            ])
        }

        return container
    }

    /// Lay out a single markdown table as a vertical NSStackView of
    /// horizontal row stacks, with header tinting, alternating body row
    /// fills, and hairline dividers between rows and columns. Columns
    /// are equal-width via `.fillEqually` — a robust fallback when we
    /// can't size to content (which on macOS we can't, since the bubble
    /// width is fixed before the table content is measured).
    private func makeMarkdownTableView(_ table: MarkdownTable) -> NSView {
        let container = AdaptiveTableLayerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.adaptiveCornerRadius = 6
        container.adaptiveBorder = NSColor.separatorColor
        container.adaptiveBorderWidth = 0.5
        container.adaptiveBackground = NSColor.controlBackgroundColor

        let vstack = NSStackView()
        vstack.translatesAutoresizingMaskIntoConstraints = false
        vstack.orientation = .vertical
        vstack.alignment = .leading
        vstack.spacing = 0
        vstack.distribution = .fill
        container.addSubview(vstack)
        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: container.topAnchor),
            vstack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            vstack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        // NSStackView (vertical) has no `.fill` orthogonal alignment, so
        // rows hug their content unless we explicitly pin their width to
        // the stack. Without this, the table collapses to the natural
        // width of its shortest column.
        func addRow(_ view: NSView) {
            vstack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: vstack.widthAnchor).isActive = true
        }

        addRow(makeMarkdownTableRow(cells: table.headers,
                                     alignments: table.alignments,
                                     isHeader: true,
                                     altBackground: false))

        for (i, row) in table.rows.enumerated() {
            addRow(makeMarkdownTableHairline())
            addRow(makeMarkdownTableRow(cells: row,
                                         alignments: table.alignments,
                                         isHeader: false,
                                         altBackground: !i.isMultiple(of: 2)))
        }
        return container
    }

    private func makeMarkdownTableHairline() -> NSView {
        let v = AdaptiveTableLayerView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.adaptiveBackground = NSColor.separatorColor
        v.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return v
    }

    private func makeMarkdownTableRow(cells: [String],
                                       alignments: [MarkdownColumnAlignment],
                                       isHeader: Bool,
                                       altBackground: Bool) -> NSView {
        let row = AdaptiveTableLayerView()
        row.translatesAutoresizingMaskIntoConstraints = false
        if isHeader {
            // Slightly stronger tint than the body so the header is
            // distinct from alternating rows in both light and dark mode.
            row.adaptiveBackground = NSColor.unemphasizedSelectedContentBackgroundColor
        } else if altBackground {
            row.adaptiveBackground = NSColor.unemphasizedSelectedContentBackgroundColor
                .withAlphaComponent(0.5)
        } else {
            row.adaptiveBackground = nil
        }

        let hstack = NSStackView()
        hstack.translatesAutoresizingMaskIntoConstraints = false
        hstack.orientation = .horizontal
        hstack.alignment = .top
        hstack.distribution = .fillEqually
        hstack.spacing = 0
        row.addSubview(hstack)
        NSLayoutConstraint.activate([
            hstack.topAnchor.constraint(equalTo: row.topAnchor),
            hstack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            hstack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            hstack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])

        // Column dividers go *inside* each non-leading cell rather than as
        // arranged subviews of `hstack`. `.fillEqually` requires every
        // arranged subview to share width — a 0.5pt divider in the line-up
        // either gets forced wide (breaking the divider) or wins its own
        // explicit width (breaking the equal-column invariant), and the
        // result is the broken-looking row we hit before.
        for (i, cellText) in cells.enumerated() {
            let alignment = i < alignments.count ? alignments[i] : .left
            let cell = makeMarkdownTableCell(text: cellText,
                                              alignment: alignment,
                                              isHeader: isHeader,
                                              leadingDivider: i > 0)
            hstack.addArrangedSubview(cell)
        }
        return row
    }

    private func makeMarkdownTableCell(text: String,
                                        alignment: MarkdownColumnAlignment,
                                        isHeader: Bool,
                                        leadingDivider: Bool) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // NSTextField wrapping label keeps text selectable and lets inline
        // marks (bold/italic/links) render via the shared markdown helper.
        let field = NSTextField(wrappingLabelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isSelectable = true
        field.drawsBackground = false
        field.isBordered = false
        field.allowsEditingTextAttributes = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        // NSTextField defaults to a high horizontal content-hugging
        // priority — it actively resists stretching past its natural
        // width. That fights `.fillEqually` and produces uneven columns,
        // so drop both hugging and compression resistance to let the
        // equal-width invariant win.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let attributed = NSMutableAttributedString(
            attributedString: Self.markdownAttributedString(from: text))
        if isHeader {
            attributed.enumerateAttribute(.font,
                                          in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                let base = (value as? NSFont) ?? NSFont.systemFont(ofSize: 13)
                let descriptor = base.fontDescriptor.withSymbolicTraits(.bold)
                let bold = NSFont(descriptor: descriptor, size: base.pointSize) ?? base
                attributed.addAttribute(.font, value: bold, range: range)
            }
        }
        let paragraph = NSMutableParagraphStyle()
        switch alignment {
        case .left:   paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right:  paragraph.alignment = .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        attributed.addAttribute(.paragraphStyle,
                                value: paragraph,
                                range: NSRange(location: 0, length: attributed.length))
        field.attributedStringValue = attributed

        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
        ])

        if leadingDivider {
            let line = AdaptiveTableLayerView()
            line.translatesAutoresizingMaskIntoConstraints = false
            line.adaptiveBackground = NSColor.separatorColor
            container.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                line.topAnchor.constraint(equalTo: container.topAnchor),
                line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                line.widthAnchor.constraint(equalToConstant: 0.5),
            ])
        }

        return container
    }

    /// Same row layout as `makeImageRow`, used for the generated PDF card
    /// so it sits on the assistant side of the transcript. Wider cap
    /// because the PDF card is horizontal (thumbnail + title block).
    private func makePDFRow(bubbleView: PDFBubbleView) -> NSView {
        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .top
        row.addArrangedSubview(bubbleView)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        bubbleView.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        return row
    }

    /// Wrap an image bubble in the same left-aligned row layout
    /// `makeBubble(role:"assistant", …)` uses, so generated images sit on
    /// the assistant side of the conversation alongside text replies.
    private func makeImageRow(bubbleView: ImageBubbleView) -> NSView {
        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .top
        row.addArrangedSubview(bubbleView)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        // Cap at the same width as the text + file-attachment bubbles for
        // visual consistency.
        bubbleView.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        return row
    }

    /// Wrap a map bubble in the same left-aligned row layout as image/PDF
    /// bubbles. Maps sit on the assistant side alongside text replies.
    private func makeMapRow(bubbleView: MapBubbleView) -> NSView {
        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .top
        row.addArrangedSubview(bubbleView)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        bubbleView.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        return row
    }

    private func scrollToBottom() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let documentView = self.scrollView.documentView else { return }
            // Force a synchronous layout pass — bubbles are added by stack
            // view at the same runloop turn, so `bounds.height` would read as
            // the pre-bubble height otherwise and we'd "scroll to bottom" to
            // the wrong y-coordinate.
            documentView.layoutSubtreeIfNeeded()
            let bottom = NSPoint(x: 0, y: max(0, documentView.bounds.height - self.scrollView.contentView.bounds.height))
            self.scrollView.contentView.scroll(to: bottom)
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }
}

// MARK: - ImageSkillHost

extension ConversationWindowController: ImageSkillHost {
    /// Insert (or, on retry, refresh) a bubble for a generation that just
    /// kicked off. The placeholder message is also added to the persistent
    /// store so it shows up after a window reload — its id encodes the
    /// attachment id (`image-<uuid>`), and the live attachment lives in
    /// `imageAttachments` until persistence catches up.
    func imageSkillDidStartGenerating(_ attachment: ImageAttachment) {
        imageAttachments[attachment.id] = attachment

        // Retry case: the bubble already exists, just flip its state. Only
        // surface the window if the retry is for the visible tab — pulling
        // a background tab's window forward would yank the user out of
        // whatever they were doing in the foreground tab.
        if let existing = imageBubbles[attachment.id] {
            existing.update(attachment: attachment)
            if isAttachmentForActiveTab(attachment) { surfaceForResponse() }
            return
        }

        // First-time placeholder. Persist a marker message so the originating
        // tab's `rebuild(messages:)` can re-render the image row on the next
        // tab switch / window reload. Prefer the stamped conversationId from
        // ImageSkill; fall back to currentConversation only for legacy
        // callers that didn't stamp.
        if let conversation = resolveAttachmentConversation(attachment) {
            let marker = MessageStruct(
                id: "\(Self.imageMessageIdPrefix)\(attachment.id)",
                role: "assistant",
                content: attachment.prompt,
                model: "gpt-image-2"
            )
            SimpleConversationManager.shared.addMessage(marker, to: conversation)
        }

        // Only paint a live bubble if this generation belongs to the visible
        // tab. Otherwise the persisted marker + entry in `imageAttachments`
        // is what the eventual rebuild reads from — switching to that tab
        // brings the row into view with its current state.
        guard isAttachmentForActiveTab(attachment) else { return }

        let bubble = ImageBubbleView(attachment: attachment) { [weak self] att in
            self?.retryImage(attachment: att)
        }
        imageBubbles[attachment.id] = bubble
        stack.addArrangedSubview(makeImageRow(bubbleView: bubble))
        scrollToBottom()
        surfaceForResponse()
    }

    /// True when this attachment was started inside the currently-foreground
    /// tab. Attachments without a stamped conversationId fall back to "yes"
    /// for backward compatibility — single-tab iOS callers never stamp.
    private func isAttachmentForActiveTab(_ attachment: ImageAttachment) -> Bool {
        guard let stamped = attachment.conversationId else { return true }
        return stamped == activeTab?.conversation.id
    }

    /// Pick the SimpleConversation this image belongs to. Stamped id wins
    /// (multi-tab Mac); legacy callers fall through to whatever is current.
    private func resolveAttachmentConversation(_ attachment: ImageAttachment) -> SimpleConversation? {
        if let id = attachment.conversationId,
           let conv = SimpleConversationManager.shared.getConversation(by: id) {
            return conv
        }
        return SimpleConversationManager.shared.currentConversation
    }

    /// Generation finished (or failed). Mutate the existing bubble in place
    /// so the row's identity — and the user's scroll position — stays put.
    func imageSkillDidFinishGenerating(_ attachment: ImageAttachment) {
        imageAttachments[attachment.id] = attachment
        if let bubble = imageBubbles[attachment.id] {
            bubble.update(attachment: attachment)
        }
        // Bubble might have been recycled by a reload while the network was
        // in flight — `imageAttachments` still has the latest state, so the
        // next reload will pick it up.
    }
}

/// Inline assistant bubble for a generated image. Three states:
/// - `.generating` — gray placeholder + spinner + the truncated prompt.
/// - `.ready` — the saved PNG drawn at the bubble's max width, click to open
///   in Preview.
/// - `.failed` — error text + "Try again" button that re-submits with the
///   same id so this same bubble gets refreshed.
final class ImageBubbleView: NSView {
    private(set) var attachment: ImageAttachment
    private let onRetry: (ImageAttachment) -> Void

    private let promptLabel = NSTextField(labelWithString: "")
    private let canvas = ClickableImageView()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Try again", target: nil, action: nil)

    init(attachment: ImageAttachment, onRetry: @escaping (ImageAttachment) -> Void) {
        self.attachment = attachment
        self.onRetry = onRetry
        super.init(frame: .zero)
        configure()
        update(attachment: attachment)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        promptLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        promptLabel.textColor = .secondaryLabelColor
        promptLabel.maximumNumberOfLines = 2
        promptLabel.lineBreakMode = .byTruncatingTail
        promptLabel.cell?.wraps = true
        addSubview(promptLabel)

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.imageScaling = .scaleProportionallyUpOrDown
        canvas.wantsLayer = true
        canvas.layer?.cornerRadius = 12
        canvas.layer?.masksToBounds = true
        canvas.layer?.borderWidth = 1
        canvas.layer?.borderColor = NSColor.separatorColor.cgColor
        canvas.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        addSubview(canvas)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 3
        statusLabel.cell?.wraps = true
        addSubview(statusLabel)

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.isHidden = true
        addSubview(retryButton)

        let side: CGFloat = 240
        NSLayoutConstraint.activate([
            promptLabel.topAnchor.constraint(equalTo: topAnchor),
            promptLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            promptLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

            canvas.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 6),
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.widthAnchor.constraint(equalToConstant: side),
            canvas.heightAnchor.constraint(equalToConstant: side),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: canvas.centerYAnchor, constant: -10),

            statusLabel.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -12),

            retryButton.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
        ])
    }

    func update(attachment: ImageAttachment) {
        self.attachment = attachment
        canvas.fileURL = attachment.fileURL
        promptLabel.stringValue = attachment.prompt

        switch attachment.status {
        case .generating:
            spinner.startAnimation(nil)
            statusLabel.stringValue = "Generating image…"
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.isHidden = false
            retryButton.isHidden = true
            canvas.image = nil
            canvas.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        case .ready:
            spinner.stopAnimation(nil)
            statusLabel.isHidden = true
            retryButton.isHidden = true
            canvas.layer?.backgroundColor = NSColor.clear.cgColor
            // Load asynchronously so a 1024×1024 PNG decode doesn't hitch the
            // run loop on the main thread.
            if let url = attachment.fileURL {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let image = (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
                    DispatchQueue.main.async {
                        guard let self = self,
                              self.attachment.id == attachment.id else { return }
                        self.canvas.image = image
                    }
                }
            }
        case .failed:
            spinner.stopAnimation(nil)
            statusLabel.stringValue = attachment.failureReason ?? "Generation failed."
            statusLabel.textColor = .systemRed
            statusLabel.isHidden = false
            retryButton.isHidden = false
            canvas.image = nil
            canvas.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
    }

    @objc private func retryTapped() {
        onRetry(attachment)
    }
}

/// Standard flipped-coordinate document view so newly added bubbles append
/// at the bottom rather than at the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// NSView that re-resolves its NSColor → CGColor whenever the system
/// appearance changes. Used for the user-bubble fill so the chosen
/// `systemBlue` always reflects the current light/dark variant rather
/// than the one in effect when the bubble was created.
final class AdaptiveBubbleView: NSView {
    var fillColor: NSColor? {
        didSet { applyFill() }
    }

    private func applyFill() {
        wantsLayer = true
        layer?.backgroundColor = fillColor?.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }
}

/// A layer-backed NSView with adaptive background / border colors. Like
/// `AdaptiveBubbleView` but more general: any of background, border
/// color, border width, and corner radius can be set, and every NSColor
/// → CGColor re-resolves whenever the system appearance flips. Used for
/// each piece of a markdown-table view (container, rows, hairlines,
/// cell-leading dividers) so a table built in dark mode reads correctly
/// after a switch to light mode and vice versa.
final class AdaptiveTableLayerView: NSView {
    var adaptiveBackground: NSColor? { didSet { applyColors() } }
    var adaptiveBorder: NSColor? { didSet { applyColors() } }
    var adaptiveBorderWidth: CGFloat = 0 { didSet { applyColors() } }
    var adaptiveCornerRadius: CGFloat = 0 { didSet { applyColors() } }

    private func applyColors() {
        wantsLayer = true
        layer?.backgroundColor = adaptiveBackground?.cgColor
        layer?.borderColor = adaptiveBorder?.cgColor
        layer?.borderWidth = adaptiveBorderWidth
        layer?.cornerRadius = adaptiveCornerRadius
        layer?.masksToBounds = adaptiveCornerRadius > 0
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
}

/// NSImageView that opens its associated file in the default macOS app on
/// click. Used by the user-attachment bubble so the user can pull up the
/// image/PDF full-size via Preview.app.
final class ClickableImageView: NSImageView {
    var fileURL: URL?

    override func mouseDown(with event: NSEvent) {
        guard let url = fileURL else {
            super.mouseDown(with: event)
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// Mac counterpart of `FilePreviewCardView`: a click-to-open card showing
/// icon + filename + (optional) language badge + subtitle + content
/// snippet, used for markdown / source / text / generic attachments. Pinned
/// to 240pt wide; height grows to fit the snippet.
final class MacFilePreviewCardView: NSView {

    var onClick: ((URL) -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let snippetView = NSTextView()
    private var fileURL: URL?

    init() {
        super.init(frame: .zero)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .secondaryLabelColor
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Badge sits in its own container so we can give it padding + a
        // background tint without subclassing NSTextField. The container's
        // intrinsic size tracks the label's content.
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.cornerRadius = 3
        badgeContainer.layer?.backgroundColor = NSColor.tertiaryLabelColor
            .withAlphaComponent(0.18).cgColor
        badgeContainer.setContentHuggingPriority(.required, for: .horizontal)
        badgeContainer.setContentCompressionResistancePriority(.required, for: .horizontal)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.alignment = .center
        badgeContainer.addSubview(badgeLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.maximumNumberOfLines = 1

        // NSTextView so we can use an NSAttributedString from
        // MarkdownSourceHighlighter directly. Disabled-but-not-selectable
        // gives us "read-only" while still letting the wrapping container
        // own the click — clicking inside the text view does not route to
        // mouseDown on `self`, so we forward it explicitly below.
        snippetView.translatesAutoresizingMaskIntoConstraints = false
        snippetView.isEditable = false
        snippetView.isSelectable = false
        snippetView.drawsBackground = false
        snippetView.textContainerInset = .zero
        snippetView.textContainer?.lineFragmentPadding = 0
        snippetView.textContainer?.maximumNumberOfLines = 8
        snippetView.textContainer?.lineBreakMode = .byTruncatingTail

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(badgeContainer)
        addSubview(subtitleLabel)
        addSubview(snippetView)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.leadingAnchor, constant: -6),

            badgeContainer.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            badgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            badgeLabel.topAnchor.constraint(equalTo: badgeContainer.topAnchor, constant: 1),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeContainer.bottomAnchor, constant: -1),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -5),

            subtitleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            snippetView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            snippetView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            snippetView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            snippetView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
        ])

        // Two competing bottom constraints — the snippet drives the height
        // when it's visible; otherwise the subtitle (chip-like generic
        // card) pulls the bottom up. Priorities pick the right one.
        let bottomEqualSnippet = bottomAnchor.constraint(equalTo: snippetView.bottomAnchor, constant: 12)
        bottomEqualSnippet.priority = .defaultHigh
        bottomEqualSnippet.isActive = true
        let bottomEqualSubtitle = bottomAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12)
        bottomEqualSubtitle.priority = .defaultLow
        bottomEqualSubtitle.isActive = true
    }

    func configure(for attachment: FileAttachment) {
        fileURL = attachment.fileURL
        titleLabel.stringValue = attachment.fileName

        let sizeText: String?
        if let bytes = (try? attachment.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
            sizeText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        } else {
            sizeText = nil
        }

        switch attachment.kind {
        case .markdown:
            iconView.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            badgeLabel.stringValue = "MD"
            badgeContainer.isHidden = false
            subtitleLabel.stringValue = Self.subtitle("Markdown", size: sizeText)
            applyMarkdownSnippet(attachment.extractedText ?? "")
        case .text:
            iconView.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
            if let lang = attachment.languageTag {
                badgeLabel.stringValue = lang.uppercased()
                badgeContainer.isHidden = false
                subtitleLabel.stringValue = Self.subtitle(lang.capitalized, size: sizeText)
            } else {
                badgeContainer.isHidden = true
                subtitleLabel.stringValue = Self.subtitle("Text", size: sizeText)
            }
            applyCodeSnippet(attachment.extractedText ?? "")
        case .generic:
            iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            badgeContainer.isHidden = true
            let mimeLabel: String
            if attachment.mimeType == "application/octet-stream" {
                let ext = attachment.fileURL.pathExtension
                mimeLabel = ext.isEmpty ? "File" : ext.uppercased()
            } else {
                mimeLabel = attachment.mimeType
            }
            subtitleLabel.stringValue = Self.subtitle(mimeLabel, size: sizeText)
            snippetView.string = ""
            snippetView.isHidden = true
        case .image, .pdf:
            iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            badgeContainer.isHidden = true
            subtitleLabel.stringValue = Self.subtitle(attachment.mimeType, size: sizeText)
            snippetView.isHidden = true
        }
    }

    private func applyMarkdownSnippet(_ text: String) {
        if text.isEmpty {
            snippetView.string = ""
            snippetView.isHidden = true
            return
        }
        let snippet = Self.firstLines(text, count: 6)
        guard let storage = snippetView.textStorage else {
            snippetView.string = snippet
            snippetView.isHidden = false
            return
        }
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(string: snippet))
        storage.endEditing()
        MarkdownSourceHighlighter.highlight(storage, baseSize: 11)
        snippetView.isHidden = false
    }

    private func applyCodeSnippet(_ text: String) {
        if text.isEmpty {
            snippetView.string = ""
            snippetView.isHidden = true
            return
        }
        let snippet = Self.firstLines(text, count: 8)
        let attributed = NSAttributedString(string: snippet, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
        snippetView.textStorage?.setAttributedString(attributed)
        snippetView.isHidden = false
    }

    private static func firstLines(_ text: String, count: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(count)
        return lines.joined(separator: "\n")
    }

    private static func subtitle(_ label: String, size: String?) -> String {
        guard let size = size else { return label }
        return "\(label) · \(size)"
    }

    override func mouseDown(with event: NSEvent) {
        guard let url = fileURL else {
            super.mouseDown(with: event)
            return
        }
        onClick?(url)
    }

    /// Re-derive the border colour through `cgColor` whenever the effective
    /// appearance flips (light/dark), since CGColor on CALayer is static.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        badgeContainer.layer?.backgroundColor = NSColor.tertiaryLabelColor
            .withAlphaComponent(0.18).cgColor
    }
}

// MARK: - Sub-agent inspector hook

extension ConversationWindowController: SubAgentMacStatusBarDelegate {
    /// Clicking the sub-agent pill opens (or fronts) the shared inspector
    /// window. Lives outside the main window so the user can move it to a
    /// second monitor and watch a long-running agent without losing the
    /// conversation.
    func subAgentStatusBarClicked() {
        // Scope the inspector to the visible tab's conversation so it shows
        // only the agents that belong to this thread — same filter the pill
        // uses. The inspector retains the scope until another pill click
        // hands it a different id (or `nil` for unscoped fallback).
        let scope = tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex].conversation.id : nil
        SubAgentInspectorWindowController.shared.presentInFront(scopedTo: scope)
    }
}

// MARK: - Onboarding host

extension ConversationWindowController: OnboardingCoordinatorHost, MacOnboardingChipDelegate {

    /// Coordinator → host: append a scripted assistant/user bubble into the
    /// active tab's conversation. Surfaces the chat window so the user sees
    /// the prompt — they may be focused on the recorder bar with the chat
    /// minimized. The card kind goes into the `onboardingCards` sidecar
    /// (keyed by message id) so the chip row re-renders after any future
    /// `rebuild(messages:)` pass — the store doesn't serialize the card
    /// enum itself.
    func onboardingPostMessage(_ message: MessageStruct) {
        guard let conv = tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex].conversation : nil else { return }
        if let card = message.onboardingCard {
            onboardingCards[message.id] = card
        }
        // Reveal beat for mid-flow assistant turns — mirrors iOS, where every
        // assistant turn after the first greeting sits behind a brief
        // "thinking" label so the scripted prompts feel reactive instead of
        // teleported in. The first greeting (empty stack) and user echoes
        // both post immediately — no thinking required there.
        let isAssistantWithCard = message.role == "assistant" && message.onboardingCard != nil
        if isAssistantWithCard && !stack.arrangedSubviews.isEmpty {
            thinkingLabel.stringValue = "Thinking…"
            thinkingLabel.textColor = .secondaryLabelColor
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.onboardingThinkingDelay) { [weak self] in
                guard let self = self else { return }
                self.thinkingLabel.stringValue = Self.recordHintText
                self.thinkingLabel.textColor = .tertiaryLabelColor
                self.appendOnboardingMessageImmediately(message, to: conv)
            }
            return
        }
        appendOnboardingMessageImmediately(message, to: conv)
    }

    /// Shared append + scroll path used by both the immediate post (user
    /// echoes, first greeting) and the post-thinking reveal (later assistant
    /// turns). Two-stage scroll: the immediate `scrollToBottom` covers most
    /// posts, the deferred 0.25s pass catches the case where the wrapping
    /// chip stack lays out asynchronously and the initial scroll math used a
    /// height that didn't yet include the chip row.
    private func appendOnboardingMessageImmediately(_ message: MessageStruct, to conv: SimpleConversation) {
        SimpleConversationManager.shared.addMessage(message, to: conv)
        if message.role == "assistant", let card = message.onboardingCard {
            stack.addArrangedSubview(
                MacOnboardingChipBubble.makeBubble(text: message.content,
                                                  card: card,
                                                  delegate: self))
            surfaceForOnboarding()
        } else if message.role == "user" {
            appendUserMessage(message.content)
            surfaceForOnboarding()
        } else if message.role == "assistant" {
            appendAssistantMessage(message.content, model: nil)
        }
        scrollToBottom()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.scrollToBottom()
        }
    }

    /// Shimmer-to-message reveal pause for Mac onboarding — kept in sync
    /// with the iOS constant so both platforms read the same beat.
    private static let onboardingThinkingDelay: TimeInterval = 0.8

    /// Coordinator → host: flip a previously-posted bubble's chip row to
    /// `.answered` so it collapses. We have to rebuild here (vs. mutating
    /// the live view) because the bubble's chip row was constructed inside
    /// `MacOnboardingChipBubble.makeBubble` and isn't reachable by id.
    /// One rebuild per answer is cheap enough; the alternative would be to
    /// hold weak refs to every bubble's chip container.
    func onboardingMarkAnswered(messageId: String) {
        onboardingCards[messageId] = .answered
        reloadFromStore()
    }

    /// Coordinator → host: prefill the recorder bar's text field so the user
    /// can edit-and-send the suggested default (e.g. "Loop" on the name
    /// step). Bubbles up to the recorder via the public prefill method.
    func onboardingPrefillMessageBox(_ text: String) {
        recorder?.prefillInputText(text)
    }

    /// Coordinator → host: bring the recorder bar forward and focus its
    /// text field. Called after the greeting so the user can immediately
    /// type their name without first clicking the bar.
    func onboardingFocusMessageBox() {
        recorder?.focusInputField()
    }

    /// Coordinator → host: open the named integration's connect flow. Mac
    /// has its own IntegrationsWindowController for this.
    func onboardingRequestIntegration(_ kind: OnboardingIntegrationKind) {
        IntegrationsWindowController.shared.show()
    }

    /// Coordinator → host: onboarding finished. Nothing platform-specific to
    /// tear down — the next chat turn will go through the normal LLM path
    /// because `OnboardingCoordinator.shared.handleUserText` early-returns
    /// once `OnboardingState.isComplete`.
    func onboardingDidComplete() {
        // No-op.
    }

    /// Like `surfaceForResponse()` but without the activate-other-app dance,
    /// because onboarding prompts post BEFORE the user has interacted (and
    /// shouldn't yank focus from a non-Loop app the user might be in). Just
    /// make sure the chat window is visible if it isn't already.
    private func surfaceForOnboarding() {
        guard let window = window else { return }
        if !hasShown {
            hasShown = true
            window.center()
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isVisible {
            showWindow(nil)
        }
    }

    // MARK: MacOnboardingChipDelegate

    /// Chip tap → coordinator. The chip view doesn't know about the
    /// coordinator directly; the window controller is the bridge so the
    /// view stays focused on rendering.
    func macOnboardingChipDidFire(_ event: OnboardingCardEvent) {
        OnboardingCoordinator.shared.handleCardEvent(event)
    }
}

// MARK: - Chat content host
//
// Lightweight NSViewController that simply hosts the existing chat content
// view (NSVisualEffectView with the avatar / scroll / thinking-label
// hierarchy). Needed because NSSplitViewItem wants a view controller.

private final class ChatContentHostViewController: NSViewController {
    private let rootView: NSView
    init(rootView: NSView) {
        self.rootView = rootView
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { self.view = rootView }
}

// MARK: - Link-aware assistant bubble text view
//
// NSTextField can't hand us link clicks for a non-editable label, so
// assistant bubbles use this NSTextView instead. It's configured to behave
// like a wrapping label that hugs its content (so the bubble still shrinks
// to the text, capped at the same max width) while routing link clicks
// through the delegate.

final class ChatLinkTextView: NSTextView {

    static func makeBubbleTextView(maxTextWidth: CGFloat) -> ChatLinkTextView {
        let tv = ChatLinkTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        // Fixed container width + no width-tracking => the text wraps at the
        // bubble cap and `usedRect` reports the natural (hugging) size.
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = NSSize(width: maxTextWidth,
                                        height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.setContentHuggingPriority(.required, for: .horizontal)
        tv.setContentHuggingPriority(.required, for: .vertical)
        tv.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.linkTextAttributes = [
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        return tv
    }

    override var intrinsicContentSize: NSSize {
        guard let layoutManager = layoutManager, let container = textContainer else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).size
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }
}

// MARK: - Assistant bubble link routing

extension ConversationWindowController: NSTextViewDelegate {
    /// A markdown file link opens in the slide-up editor; everything else
    /// (http, obsidian://, non-markdown files) falls back to the system
    /// handler by returning false so NSTextView does its default thing.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        switch link {
        case let u as URL:    url = u
        case let s as String: url = URL(string: s)
        default:              url = nil
        }
        guard let url = url, url.isFileURL,
              MarkdownEditorViewController.isMarkdownFile(url),
              FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        presentMarkdownEditor(for: url)
        return true
    }
}

// MARK: - Tab-scoped presenter

/// Conversation-presenter wrapper that only forwards UI updates while its tab
/// owns the foreground. Background tabs' coordinators keep running their chat
/// loops (and persist to their own conversation), but they don't get to paint
/// bubbles, drive the avatar, or surface the window — that belongs to the
/// active tab. The moment the user switches into the background tab, the
/// window's `reloadFromStore()` re-renders everything that landed while it
/// was offscreen.
final class TabConversationPresenter: ConversationPresenter {
    weak var window: ConversationWindowController?
    weak var tab: ConversationTab?

    init(window: ConversationWindowController, tab: ConversationTab) {
        self.window = window
        self.tab = tab
    }

    /// True only when our tab is the foreground one. Without `tab` (e.g.
    /// the tab was closed but a stale callback is still in flight) we
    /// suppress — there's nothing meaningful to paint to.
    private var isForeground: Bool {
        guard let window = window, let tab = tab else { return false }
        return window.activeTab === tab
    }

    func showAndReload() {
        guard isForeground else { return }
        window?.showAndReload()
    }

    func appendUserMessage(_ text: String) {
        guard isForeground else { return }
        window?.appendUserMessage(text)
    }

    func appendUserAttachment(_ attachment: FileAttachment, text: String?) {
        guard isForeground else { return }
        window?.appendUserAttachment(attachment, text: text)
    }

    func appendAssistantMessage(_ text: String, model: String?) {
        guard isForeground else { return }
        window?.appendAssistantMessage(text, model: model)
    }

    func setThinking(_ thinking: Bool, label: String?) {
        // Record the state on the tab so a tab swap can restore the right
        // bottom-hint text — without this, a background tab's "Thinking…"
        // would either persist after switching away (sticky) or be lost
        // entirely when we land back on the tab still doing work.
        tab?.isThinking = thinking
        tab?.thinkingLabel = label
        guard isForeground else { return }
        window?.setThinking(thinking, label: label)
    }

    func avatarStateChanged(_ state: VoiceLoopCoordinator.State) {
        guard isForeground else { return }
        window?.avatarStateChanged(state)
    }

    func avatarAmplitudeChanged(_ amplitude: Float) {
        guard isForeground else { return }
        window?.avatarAmplitudeChanged(amplitude)
    }

    func avatarPulse() {
        guard isForeground else { return }
        window?.avatarPulse()
    }
}

// MARK: - GitHubSkillHost

extension ConversationWindowController: GitHubSkillHost {
    /// Present a sheet-modal NSAlert for any GitHub write tool. Same shape as
    /// the iOS UIAlertController on MessagingVC.
    func githubSkill(requestConfirmation title: String,
                     detail: String,
                     destructive: Bool,
                     completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let confirm = alert.addButton(withTitle: "Confirm")
        if destructive { confirm.hasDestructiveAction = true }
        alert.addButton(withTitle: "Cancel")
        if let window = self.window {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}

// MARK: - SlackSkillHost

extension ConversationWindowController: SlackSkillHost {
    /// Present a modal NSAlert with the proposed Slack message so the user
    /// can review and approve before chat.postMessage fires. The user's tap
    /// IS the confirmation checkpoint — no second ask in chat is needed.
    func slackSkill(requestSendConfirmation channelLabel: String,
                    text: String,
                    completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Send Slack message to \(channelLabel)?"
        alert.informativeText = text
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        // Anchor to our own window so the alert blocks the conversation
        // surface that originated the send, not the whole app.
        if let window = self.window {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}

// MARK: - PDFSkillHost

extension ConversationWindowController: PDFSkillHost {

    /// Insert (or, on retry, refresh) a PDF card for a render that just
    /// kicked off. Mirrors `imageSkillDidStartGenerating` — placeholder
    /// message goes into the persistent store under id `pdf-<id>` so a
    /// subsequent tab switch or window reload re-renders it.
    func pdfSkillDidStartGenerating(_ attachment: PDFAttachment) {
        pdfAttachments[attachment.id] = attachment

        if let existing = pdfBubbles[attachment.id] {
            existing.update(attachment: attachment)
            if isPDFAttachmentForActiveTab(attachment) { surfaceForResponse() }
            return
        }

        if let conversation = resolvePDFAttachmentConversation(attachment) {
            let marker = MessageStruct(
                id: "\(Self.pdfMessageIdPrefix)\(attachment.id)",
                role: "assistant",
                content: attachment.title,
                model: "loop-pdf"
            )
            SimpleConversationManager.shared.addMessage(marker, to: conversation)
        }

        guard isPDFAttachmentForActiveTab(attachment) else { return }

        let bubble = PDFBubbleView(attachment: attachment,
                                   onPreview: { [weak self] att in self?.previewPDF(attachment: att) },
                                   onShare:   { [weak self] att, sender in self?.sharePDF(attachment: att, from: sender) },
                                   onRetry:   { [weak self] att in self?.retryPDF(attachment: att) })
        pdfBubbles[attachment.id] = bubble
        stack.addArrangedSubview(makePDFRow(bubbleView: bubble))
        scrollToBottom()
        surfaceForResponse()
    }

    func pdfSkillDidFinishGenerating(_ attachment: PDFAttachment) {
        pdfAttachments[attachment.id] = attachment
        if let bubble = pdfBubbles[attachment.id] {
            bubble.update(attachment: attachment)
        }
    }

    private func isPDFAttachmentForActiveTab(_ attachment: PDFAttachment) -> Bool {
        guard let stamped = attachment.conversationId else { return true }
        return stamped == activeTab?.conversation.id
    }

    private func resolvePDFAttachmentConversation(_ attachment: PDFAttachment) -> SimpleConversation? {
        if let id = attachment.conversationId,
           let conv = SimpleConversationManager.shared.getConversation(by: id) {
            return conv
        }
        return SimpleConversationManager.shared.currentConversation
    }
}

/// Inline assistant bubble for a generated PDF on Mac. Three states match
/// the iOS PDF card:
/// - `.generating` — spinner over a placeholder thumbnail + "Generating…"
/// - `.ready` — page-1 thumbnail + title + page count + Preview / Share.
/// - `.failed` — error text + Try again button that re-renders with the
///   same id so this bubble gets refreshed.
final class PDFBubbleView: NSView {
    private(set) var attachment: PDFAttachment

    private let onPreview: (PDFAttachment) -> Void
    private let onShare: (PDFAttachment, NSView) -> Void
    private let onRetry: (PDFAttachment) -> Void

    private let card = NSView()
    private let thumbnail = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let errorLabel = NSTextField(labelWithString: "")
    private let previewButton = NSButton(title: "Preview", target: nil, action: nil)
    private let shareButton = NSButton(title: "Share", target: nil, action: nil)
    private let retryButton = NSButton(title: "Try again", target: nil, action: nil)

    init(attachment: PDFAttachment,
         onPreview: @escaping (PDFAttachment) -> Void,
         onShare: @escaping (PDFAttachment, NSView) -> Void,
         onRetry: @escaping (PDFAttachment) -> Void) {
        self.attachment = attachment
        self.onPreview = onPreview
        self.onShare = onShare
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
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        addSubview(card)

        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 6
        thumbnail.layer?.borderWidth = 0.5
        thumbnail.layer?.borderColor = NSColor.separatorColor.cgColor
        thumbnail.layer?.backgroundColor = NSColor.white.cgColor
        card.addSubview(thumbnail)

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

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        card.addSubview(spinner)

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = NSFont.systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3
        errorLabel.cell?.wraps = true
        errorLabel.isHidden = true
        card.addSubview(errorLabel)

        previewButton.bezelStyle = .rounded
        previewButton.controlSize = .small
        previewButton.target = self
        previewButton.action = #selector(previewTapped)
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(previewButton)

        shareButton.bezelStyle = .rounded
        shareButton.controlSize = .small
        shareButton.target = self
        shareButton.action = #selector(shareTapped)
        shareButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(shareButton)

        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.isHidden = true
        card.addSubview(retryButton)

        let thumbW: CGFloat = 80
        let thumbH: CGFloat = 104   // Letter aspect at width=80
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            thumbnail.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            thumbnail.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            thumbnail.widthAnchor.constraint(equalToConstant: thumbW),
            thumbnail.heightAnchor.constraint(equalToConstant: thumbH),

            titleLabel.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: thumbnail.topAnchor, constant: 2),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            spinner.centerXAnchor.constraint(equalTo: thumbnail.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: thumbnail.centerYAnchor),

            errorLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            errorLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 4),

            previewButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            previewButton.topAnchor.constraint(greaterThanOrEqualTo: subtitleLabel.bottomAnchor, constant: 10),
            previewButton.topAnchor.constraint(greaterThanOrEqualTo: errorLabel.bottomAnchor, constant: 10),

            shareButton.leadingAnchor.constraint(equalTo: previewButton.trailingAnchor, constant: 8),
            shareButton.centerYAnchor.constraint(equalTo: previewButton.centerYAnchor),

            retryButton.leadingAnchor.constraint(equalTo: previewButton.trailingAnchor, constant: 8),
            retryButton.centerYAnchor.constraint(equalTo: previewButton.centerYAnchor),

            card.bottomAnchor.constraint(greaterThanOrEqualTo: thumbnail.bottomAnchor, constant: 12),
            card.bottomAnchor.constraint(greaterThanOrEqualTo: previewButton.bottomAnchor, constant: 12),
        ])
    }

    func update(attachment: PDFAttachment) {
        self.attachment = attachment
        titleLabel.stringValue = attachment.title

        switch attachment.status {
        case .generating:
            spinner.startAnimation(nil)
            thumbnail.image = nil
            thumbnail.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            subtitleLabel.stringValue = "Generating PDF…"
            errorLabel.isHidden = true
            previewButton.isHidden = true
            shareButton.isHidden = true
            retryButton.isHidden = true
        case .ready:
            spinner.stopAnimation(nil)
            thumbnail.layer?.backgroundColor = NSColor.white.cgColor
            if let url = attachment.thumbnailURL,
               let data = try? Data(contentsOf: url),
               let image = NSImage(data: data) {
                thumbnail.image = image
            } else {
                thumbnail.image = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: "PDF")
                thumbnail.contentTintColor = .secondaryLabelColor
            }
            let pages = attachment.pageCount ?? 0
            let pageWord = pages == 1 ? "page" : "pages"
            let templateLabel = attachment.template.capitalized
            subtitleLabel.stringValue = pages > 0
                ? "\(pages) \(pageWord) · \(templateLabel)"
                : templateLabel
            errorLabel.isHidden = true
            previewButton.isHidden = false
            shareButton.isHidden = false
            retryButton.isHidden = true
        case .failed:
            spinner.stopAnimation(nil)
            thumbnail.image = NSImage(systemSymbolName: "doc.badge.ellipsis", accessibilityDescription: "PDF failed")
            thumbnail.contentTintColor = .systemRed
            thumbnail.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            subtitleLabel.stringValue = "Couldn't generate PDF"
            errorLabel.stringValue = attachment.failureReason ?? "Unknown error."
            errorLabel.isHidden = false
            previewButton.isHidden = true
            shareButton.isHidden = true
            retryButton.isHidden = false
        }
    }

    @objc private func previewTapped() { onPreview(attachment) }
    @objc private func shareTapped() { onShare(attachment, shareButton) }
    @objc private func retryTapped() { onRetry(attachment) }
}

/// Inline assistant bubble for a map embed on Mac. Wraps an MKMapView with
/// one pin per place; each pin's callout has an info button that hands the
/// place to Apple Maps via `MKMapItem.openInMaps`.
final class MapBubbleView: NSView {
    private let attachment: MapAttachment
    private let titleLabel = NSTextField(labelWithString: "")
    private let mapView = MKMapView()

    init(attachment: MapAttachment) {
        self.attachment = attachment
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let hasTitle = (attachment.title?.isEmpty == false)
        if hasTitle {
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            titleLabel.stringValue = attachment.title ?? ""
            titleLabel.maximumNumberOfLines = 2
            titleLabel.lineBreakMode = .byTruncatingTail
            addSubview(titleLabel)
        }

        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.wantsLayer = true
        mapView.layer?.cornerRadius = 12
        mapView.layer?.borderWidth = 1
        mapView.layer?.borderColor = NSColor.separatorColor.cgColor
        mapView.layer?.masksToBounds = true
        mapView.delegate = MapBubbleViewDelegate.shared
        mapView.register(MKMarkerAnnotationView.self,
                         forAnnotationViewWithReuseIdentifier: MapBubbleView.pinReuseId)
        addSubview(mapView)

        let annotations: [MapPlaceAnnotation] = attachment.places.map {
            MapPlaceAnnotation(place: $0)
        }
        mapView.addAnnotations(annotations)
        mapView.showAnnotations(annotations, animated: false)

        if hasTitle {
            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                titleLabel.topAnchor.constraint(equalTo: topAnchor),

                mapView.leadingAnchor.constraint(equalTo: leadingAnchor),
                mapView.trailingAnchor.constraint(equalTo: trailingAnchor),
                mapView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
                mapView.bottomAnchor.constraint(equalTo: bottomAnchor),
                mapView.heightAnchor.constraint(equalToConstant: 240),
            ])
        } else {
            NSLayoutConstraint.activate([
                mapView.leadingAnchor.constraint(equalTo: leadingAnchor),
                mapView.trailingAnchor.constraint(equalTo: trailingAnchor),
                mapView.topAnchor.constraint(equalTo: topAnchor),
                mapView.bottomAnchor.constraint(equalTo: bottomAnchor),
                mapView.heightAnchor.constraint(equalToConstant: 240),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    static let pinReuseId = "MapBubbleViewPin"
}

/// MKPointAnnotation that carries the underlying `MapPlace`, used by both
/// iOS and macOS map renderers. Declared at file scope so the Mac bubble
/// can share the iOS-side implementation's shape.
final class MapPlaceAnnotation: MKPointAnnotation {
    let place: MapPlace
    init(place: MapPlace) {
        self.place = place
        super.init()
        self.coordinate = CLLocationCoordinate2D(latitude: place.latitude,
                                                 longitude: place.longitude)
        self.title = place.name
        self.subtitle = place.address
    }
}

/// Shared MKMapViewDelegate for every MapBubbleView in the Mac window —
/// stateless (the annotation carries the place data), so a single instance
/// is safe and avoids retain cycles back into the bubble view.
private final class MapBubbleViewDelegate: NSObject, MKMapViewDelegate {
    static let shared = MapBubbleViewDelegate()

    func mapView(_ mapView: MKMapView,
                 viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard annotation is MapPlaceAnnotation else { return nil }
        let v = mapView.dequeueReusableAnnotationView(
            withIdentifier: MapBubbleView.pinReuseId,
            for: annotation) as? MKMarkerAnnotationView
        v?.canShowCallout = true
        v?.animatesWhenAdded = false
        let button = NSButton(title: "Open in Maps", target: self,
                              action: #selector(openInMaps(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        v?.rightCalloutAccessoryView = button
        // Stash the place on the button so the action handler can read it
        // without a back-reference to the annotation view.
        objc_setAssociatedObject(button,
                                 &MapBubbleViewDelegate.placeAssocKey,
                                 (annotation as? MapPlaceAnnotation)?.place,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return v
    }

    @objc private func openInMaps(_ sender: NSButton) {
        guard let place = objc_getAssociatedObject(
                sender,
                &MapBubbleViewDelegate.placeAssocKey) as? MapPlace else { return }
        let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(
            latitude: place.latitude, longitude: place.longitude))
        let item = MKMapItem(placemark: placemark)
        item.name = place.name
        item.openInMaps(launchOptions: [
            MKLaunchOptionsMapTypeKey: NSNumber(value: MKMapType.standard.rawValue)
        ])
    }

    private static var placeAssocKey: UInt8 = 0
}

// MARK: - TwitterSkillHost

extension ConversationWindowController: TwitterSkillHost {
    func twitterSkill(requestPostConfirmation text: String,
                      completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Post this tweet?"
        alert.informativeText = text
        alert.addButton(withTitle: "Post")
        alert.addButton(withTitle: "Cancel")
        if let window = self.window {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}
