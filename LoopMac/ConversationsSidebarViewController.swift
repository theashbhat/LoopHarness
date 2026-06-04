//
//  ConversationsSidebarViewController.swift
//  LoopMac
//
//  Left-hand conversation list shown in the Loop window's split view.
//  Modeled on ChatGPT's macOS sidebar: a single chronological list of
//  conversations, click to switch, compose button in the toolbar (not here).
//
//  Stays in sync with the store by observing `.conversationStoreDidChange`,
//  which the file-backed `ConversationFileStore` posts when iCloud delivers
//  a remote write — so an iPhone-side new message lights up the matching
//  row's relative-time label without a manual reload.
//

import AppKit
import Quartz

final class ConversationsSidebarViewController: NSViewController,
                                                NSTableViewDataSource,
                                                NSTableViewDelegate,
                                                NSOutlineViewDataSource,
                                                NSOutlineViewDelegate,
                                                QLPreviewPanelDataSource,
                                                QLPreviewPanelDelegate {

    // MARK: - Callbacks

    /// Fired when the user picks a different conversation. The host window
    /// is responsible for routing through `VoiceLoopCoordinator.switchToConversation(_:)`.
    var onPicked: ((SimpleConversation) -> Void)?

    /// Fired when the user right-clicks a conversation row and picks
    /// "Open in New Tab". The host opens (or switches to) a tab pointing
    /// at the conversation — see ConversationWindowController.openConversationInTab.
    var onOpenInNewTab: ((SimpleConversation) -> Void)?

    /// Fired when the user opens a markdown file from the Files tab. The host
    /// window slides the editor up over the chat area; non-markdown files
    /// still go through QuickLook below.
    var onOpenMarkdown: ((URL) -> Void)?

    // MARK: - State

    private var conversations: [SimpleConversation] = []
    /// Id of the conversation the host considers "active" so we can paint a
    /// stronger selection on the right row. Updated externally via
    /// `setActiveConversationId`.
    private var activeId: String?

    /// What the sidebar is currently showing. Both scroll views are kept
    /// around and toggled via `isHidden` so re-entering a tab doesn't have to
    /// rebuild the tree / table from scratch.
    private enum Mode {
        case conversations
        case files
    }
    private var mode: Mode = .conversations

    // MARK: - Views

    private let segmentedControl = NSSegmentedControl(labels: ["Conversations", "Files"],
                                                       trackingMode: .selectOne,
                                                       target: nil,
                                                       action: nil)
    private let tableView = ContextMenuTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No conversations yet.\nStart talking to Loop and one will appear here.")
    /// Small spinner that runs while `ConversationFileStore`
    /// is pulling updates from iCloud (initial bootstrap or remote-change
    /// diff). Matches the Mail/Notes idiom of an in-header sync indicator.
    private let syncSpinner = NSProgressIndicator()
    private let syncLabel = NSTextField(labelWithString: "Syncing…")

    // MARK: - Files mode

    private let filesOutlineView = SpacebarPreviewOutlineView()
    private let filesScrollView = NSScrollView()
    /// Holds the URL the QuickLook panel is previewing. Owned here so the
    /// QLPreviewPanelDataSource methods (which can't capture state) can read
    /// it back out.
    private var previewURL: URL?

    override func loadView() {
        // Transparent root — the parent split-view host is an
        // NSVisualEffectView with `.sidebar` material that paints the
        // frosted system sidebar appearance behind us. Painting our own
        // fill here would clobber that vibrancy.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 500))

        // Segmented control replaces the static title — gives the user a way
        // to flip between conversations and the workspace file tree without
        // leaving the sidebar.
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.segmentStyle = .roundRect
        segmentedControl.selectedSegment = 0
        segmentedControl.target = self
        segmentedControl.action = #selector(segmentedControlChanged)
        root.addSubview(segmentedControl)

        // Sync indicators sit under the segmented control. We start them
        // hidden; the notification observer below flips them on/off based on
        // `SimpleConversationManager.shared.router.isSyncing`.
        syncSpinner.translatesAutoresizingMaskIntoConstraints = false
        syncSpinner.style = .spinning
        syncSpinner.controlSize = .small
        syncSpinner.isDisplayedWhenStopped = false
        syncSpinner.isIndeterminate = true
        root.addSubview(syncSpinner)

        syncLabel.translatesAutoresizingMaskIntoConstraints = false
        syncLabel.font = .systemFont(ofSize: 11)
        syncLabel.textColor = .tertiaryLabelColor
        syncLabel.isHidden = true
        root.addSubview(syncLabel)

        // Table.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Conversation"))
        column.minWidth = 160
        column.resizingMask = .autoresizingMask

        tableView.style = .sourceList
        tableView.headerView = nil
        tableView.addTableColumn(column)
        tableView.rowHeight = 52
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = false
        // `.sourceList` selection style was deprecated in macOS 12 — setting
        // tableView.style = .sourceList (above) is now the only thing needed
        // to get the pill-style selection.
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.onMakeContextMenu = { [weak self] row in
            self?.makeConversationContextMenu(forRow: row)
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        root.addSubview(scrollView)

        // Files outline + scroll. Same visual frame as the conversations
        // scroll view; we toggle `isHidden` on segment change. Single-column
        // outline with the indent the system gives it by default — depth
        // visualization is handled by NSOutlineView itself.
        let fileColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("File"))
        fileColumn.minWidth = 160
        fileColumn.resizingMask = .autoresizingMask
        filesOutlineView.addTableColumn(fileColumn)
        filesOutlineView.outlineTableColumn = fileColumn
        filesOutlineView.headerView = nil
        filesOutlineView.rowHeight = 22
        filesOutlineView.style = .sourceList
        filesOutlineView.usesAlternatingRowBackgroundColors = false
        filesOutlineView.dataSource = self
        filesOutlineView.delegate = self
        filesOutlineView.target = self
        filesOutlineView.doubleAction = #selector(fileDoubleClicked)
        filesOutlineView.action = #selector(fileSingleClicked)
        filesOutlineView.indentationPerLevel = 16
        filesOutlineView.autoresizesOutlineColumn = false
        // Spacebar → Quick Look the selected file, matching Finder. The
        // subclass routes the key event to us so we can run the same iCloud
        // download + panel surface flow as a double-click.
        filesOutlineView.onSpacebar = { [weak self] in self?.spacebarPressedInFilesOutline() }
        filesOutlineView.onMakeContextMenu = { [weak self] row in self?.contextMenu(forRow: row) }

        filesScrollView.translatesAutoresizingMaskIntoConstraints = false
        filesScrollView.documentView = filesOutlineView
        filesScrollView.hasVerticalScroller = true
        filesScrollView.drawsBackground = false
        filesScrollView.borderType = .noBorder
        filesScrollView.isHidden = true
        root.addSubview(filesScrollView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.isHidden = true
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            segmentedControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            segmentedControl.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            segmentedControl.trailingAnchor.constraint(lessThanOrEqualTo: syncSpinner.leadingAnchor, constant: -8),

            // Trailing sync cluster: label sits to the left of the spinner so
            // the spinner is the rightmost visual anchor (mirrors Mail).
            syncSpinner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            syncSpinner.centerYAnchor.constraint(equalTo: segmentedControl.centerYAnchor),
            syncSpinner.widthAnchor.constraint(equalToConstant: 14),
            syncSpinner.heightAnchor.constraint(equalToConstant: 14),

            syncLabel.trailingAnchor.constraint(equalTo: syncSpinner.leadingAnchor, constant: -6),
            syncLabel.centerYAnchor.constraint(equalTo: segmentedControl.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            filesScrollView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            filesScrollView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            filesScrollView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            filesScrollView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
        ])

        self.view = root

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: .conversationStoreDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(syncStateChanged),
            name: .conversationStoreSyncStateChanged, object: nil
        )
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
        // Mirror current sync state immediately — the notification may have
        // fired before the view was loaded.
        applySyncState()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public

    /// Called by the host window when the active conversation changes so the
    /// sidebar can highlight the matching row. Reloads if the row exists.
    func setActiveConversationId(_ id: String?) {
        activeId = id
        guard let id = id, let row = conversations.firstIndex(where: { $0.id == id }) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func reload() {
        // Route through the manager so OpenClaw-backed conversations appear
        // alongside local ones. For local-only users the OpenClaw store is
        // empty, so the merged result is identical to before.
        conversations = SimpleConversationManager.shared.getAllConversations()
        tableView.reloadData()
        updateEmptyLabel()
        // Re-apply selection after reloadData clears it.
        setActiveConversationId(activeId)
    }

    /// Empty-state copy depends on sync state: if we're still pulling from
    /// iCloud the list isn't truly empty, it's just not loaded yet.
    private func updateEmptyLabel() {
        if conversations.isEmpty {
            emptyLabel.isHidden = false
            emptyLabel.stringValue = SimpleConversationManager.shared.router.isSyncing
                ? "⏳ Loading conversations…"
                : "No conversations yet.\nStart talking to Loop and one will appear here."
        } else {
            emptyLabel.isHidden = true
        }
    }

    private func applySyncState() {
        let syncing = SimpleConversationManager.shared.router.isSyncing
        if syncing {
            syncSpinner.startAnimation(nil)
        } else {
            syncSpinner.stopAnimation(nil)
        }
        syncLabel.isHidden = !syncing
        // Empty-state copy depends on sync state too.
        updateEmptyLabel()
    }

    // MARK: - Notifications

    @objc private func storeChanged() {
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    @objc private func syncStateChanged() {
        DispatchQueue.main.async { [weak self] in self?.applySyncState() }
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { conversations.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ConversationRow")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ConversationRowCell
            ?? ConversationRowCell()
        cell.identifier = id
        let conv = conversations[row]
        cell.configure(
            title: conv.title,
            snippet: conv.messages.last?.content ?? "",
            updatedAt: conv.updatedAt
        )
        return cell
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < conversations.count else { return }
        let conv = conversations[row]
        activeId = conv.id
        onPicked?(conv)
    }

    /// Right-click context menu on a conversation row. Currently a single
    /// "Open in New Tab" entry — the host opens (or switches to) a tab
    /// pointing at this conversation.
    private func makeConversationContextMenu(forRow row: Int) -> NSMenu? {
        guard row >= 0, row < conversations.count else { return nil }
        let conv = conversations[row]
        let menu = NSMenu()
        let item = NSMenuItem(title: "Open in New Tab",
                              action: #selector(openInNewTabFromMenu(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = conv.id
        menu.addItem(item)
        return menu
    }

    @objc private func openInNewTabFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let conv = conversations.first(where: { $0.id == id }) else { return }
        onOpenInNewTab?(conv)
    }

    // MARK: - Segmented control

    @objc private func segmentedControlChanged() {
        mode = segmentedControl.selectedSegment == 0 ? .conversations : .files
        let showingFiles = (mode == .files)
        scrollView.isHidden = showingFiles
        filesScrollView.isHidden = !showingFiles
        if showingFiles {
            filesOutlineView.reloadData()
            updateFilesEmptyState()
        } else {
            updateEmptyLabel()
        }
    }

    /// The conversations-empty label is reused for the "Workspace is empty"
    /// message while in files mode; the copy is just different.
    private func updateFilesEmptyState() {
        let hasContents = (FileManager.default
            .enumerator(at: Workspace.shared.rootURL,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])?
            .nextObject() as? URL) != nil
        if hasContents {
            emptyLabel.isHidden = true
        } else {
            emptyLabel.isHidden = false
            emptyLabel.stringValue = "Workspace is empty.\nFiles you create with Loop will show up here."
        }
    }

    // MARK: - NSOutlineView (files)
    //
    // The outline uses URLs directly as items: AppKit allows any
    // `AnyHashable`-conforming value, and a URL gives stable identity across
    // reloads without us owning a parallel tree. `nil` represents the
    // synthetic root (Workspace.shared.rootURL) so the workspace folder
    // doesn't show up as its own row.

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let dir = (item as? URL) ?? Workspace.shared.rootURL
        return children(of: dir).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let dir = (item as? URL) ?? Workspace.shared.rootURL
        return children(of: dir)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let url = item as? URL else { return false }
        return isDirectory(url)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let url = item as? URL else { return nil }
        let id = NSUserInterfaceItemIdentifier("FileRow")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? FileRowCell ?? FileRowCell()
        cell.identifier = id
        cell.configure(url: url, isDirectory: isDirectory(url))
        return cell
    }

    /// Listing helper used by both the data source and expansion checks.
    /// Results aren't cached — the listings are small and we want directory
    /// edits made elsewhere (Finder, the agent) to be reflected when the
    /// user re-enters Files mode.
    private func children(of dir: URL) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let contents = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles])
        else { return [] }
        return contents.sorted { a, b in
            let aDir = isDirectory(a)
            let bDir = isDirectory(b)
            if aDir != bDir { return aDir }
            return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    @objc private func fileSingleClicked() {
        // No-op — single click just selects. Folder expansion uses the
        // disclosure triangle; file open requires a double-click so users
        // can browse without surprise QuickLook pop-ups.
    }

    @objc private func fileDoubleClicked() {
        let row = filesOutlineView.clickedRow
        guard row >= 0, let url = filesOutlineView.item(atRow: row) as? URL else { return }
        if isDirectory(url) {
            if filesOutlineView.isItemExpanded(url) {
                filesOutlineView.collapseItem(url)
            } else {
                filesOutlineView.expandItem(url)
            }
        } else if MarkdownEditorViewController.isMarkdownFile(url) {
            onOpenMarkdown?(url)
        } else {
            presentPreview(for: url)
        }
    }

    /// Spacebar pressed while the files outline has focus. Open Quick Look
    /// for the selected file (Finder-parity). If the panel is already up,
    /// close it — that's the second-press toggle users expect.
    private func spacebarPressedInFilesOutline() {
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let row = filesOutlineView.selectedRow
        guard row >= 0, let url = filesOutlineView.item(atRow: row) as? URL else { return }
        if isDirectory(url) { return }
        if MarkdownEditorViewController.isMarkdownFile(url) {
            onOpenMarkdown?(url)
            return
        }
        presentPreview(for: url)
    }

    // MARK: - Context menu

    /// Build the right-click menu for a workspace item. Files and folders
    /// both get "Copy" — it puts the item on the general pasteboard as a
    /// file URL, which is exactly what Finder's Copy does, so a ⌘V in
    /// Finder (or dropping into Mail, etc.) duplicates the real file.
    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard let url = filesOutlineView.item(atRow: row) as? URL else { return nil }
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy",
                              action: #selector(copyItemFromMenu(_:)),
                              keyEquivalent: "")
        copy.target = self
        copy.representedObject = url
        menu.addItem(copy)
        return menu
    }

    @objc private func copyItemFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        // Materialize iCloud-evicted items first so a paste gets the real
        // bytes rather than a 0-byte placeholder — same best-effort,
        // time-boxed download the QuickLook path uses.
        DispatchQueue.global(qos: .userInitiated).async {
            try? Workspace.shared.ensureDownloaded(url)
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([url as NSURL])
            }
        }
    }

    // MARK: - QuickLook preview

    private func presentPreview(for url: URL) {
        previewURL = url
        // iCloud-evicted files need to be pulled down before the preview
        // panel can show anything. Best-effort, time-boxed — if it fails,
        // QuickLook will show its own "couldn't open" state.
        DispatchQueue.global(qos: .userInitiated).async {
            try? Workspace.shared.ensureDownloaded(url)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.previewURL == url else { return }
                // The QL panel walks the responder chain looking for a
                // controller that accepts it; making ourselves first
                // responder guarantees the chain starts here so our
                // `acceptsPreviewPanelControl` is the one consulted.
                self.view.window?.makeFirstResponder(self)
                if let panel = QLPreviewPanel.shared() {
                    panel.updateController()
                    panel.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return previewURL != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        return (previewURL ?? Workspace.shared.rootURL) as NSURL
    }
}

// MARK: - File row cell

/// One row in the workspace outline. Icon + name; the outline view applies
/// the disclosure triangle and indentation automatically.
private final class FileRowCell: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.drawsBackground = false
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(url: URL, isDirectory: Bool) {
        nameLabel.stringValue = url.lastPathComponent
        // NSWorkspace gives us the system icon — matches what Finder shows for
        // the same file, so the user can scan for documents by appearance.
        iconView.image = NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Right-click-aware conversations table

/// NSTableView subclass that hands the right-click event back to its host so
/// the host can build a contextual menu for the clicked row. Mirrors the
/// SpacebarPreviewOutlineView pattern used for the files outline below.
final class ContextMenuTableView: NSTableView {
    /// Set by the host VC. Asked to build the contextual menu for the row
    /// under a right-click; return nil for "no menu here".
    var onMakeContextMenu: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        // Select the row first so the highlight matches the item the menu
        // is acting on — Finder/Mail-style affordance.
        if selectedRow != row {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return onMakeContextMenu?(row)
    }
}

// MARK: - Spacebar-aware outline view

/// NSOutlineView subclass that hands the spacebar back to its host so we can
/// drive Quick Look the way Finder does. AppKit doesn't otherwise route the
/// space key anywhere useful here (the outline doesn't have a default action
/// for it), so without this override pressing space would just bounce the
/// system beep.
final class SpacebarPreviewOutlineView: NSOutlineView {
    /// Set by the host VC. Invoked on every space-key press while this view
    /// is the first responder.
    var onSpacebar: (() -> Void)?

    /// Set by the host VC. Asked to build the contextual menu for the row
    /// under a right-click; return nil for "no menu here".
    var onMakeContextMenu: ((Int) -> NSMenu?)?

    /// Right-click → select the row under the cursor (Finder parity) and let
    /// the host build the menu for it. Selecting first means the highlight
    /// matches the item the menu acts on.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        if selectedRow != row {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return onMakeContextMenu?(row)
    }

    override func keyDown(with event: NSEvent) {
        // `charactersIgnoringModifiers == " "` and keyCode 49 both match
        // spacebar; characters is the friendlier path and is what HIToolbox
        // recommends.
        if event.charactersIgnoringModifiers == " " {
            onSpacebar?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Row cell
//
// Three pieces of text per row: title (1 line, semibold), snippet of the last
// message (1 line, secondary color), and a compact relative-time label on the
// trailing edge (e.g. "5m", "2h", "Mon", "Mar 4"). Mirrors the visual rhythm
// of ChatGPT's sidebar and the iOS Side Drawer.

private final class ConversationRowCell: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.drawsBackground = false
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)

        snippetLabel.translatesAutoresizingMaskIntoConstraints = false
        snippetLabel.font = .systemFont(ofSize: 11)
        snippetLabel.textColor = .secondaryLabelColor
        snippetLabel.drawsBackground = false
        snippetLabel.isBezeled = false
        snippetLabel.isEditable = false
        snippetLabel.lineBreakMode = .byTruncatingTail
        snippetLabel.maximumNumberOfLines = 1
        addSubview(snippetLabel)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .systemFont(ofSize: 10)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.drawsBackground = false
        timeLabel.isBezeled = false
        timeLabel.isEditable = false
        timeLabel.alignment = .right
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(timeLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -8),

            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            timeLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            snippetLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            snippetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            snippetLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    func configure(title: String, snippet: String, updatedAt: Date) {
        titleLabel.stringValue = title.isEmpty ? "Untitled" : title
        let trimmedSnippet = snippet
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        snippetLabel.stringValue = trimmedSnippet.isEmpty ? "No messages yet" : trimmedSnippet
        timeLabel.stringValue = Self.relativeTimeString(for: updatedAt)
    }

    /// Compact relative-time formatter matching the visual rhythm of
    /// ChatGPT / Messages: under a minute → "now", same day → "5m"/"3h",
    /// yesterday → "Yesterday", same week → weekday name, older → "Mar 4".
    private static func relativeTimeString(for date: Date) -> String {
        let cal = Calendar.current
        let now = Date()
        let secs = now.timeIntervalSince(date)
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if cal.isDate(date, inSameDayAs: now) { return "\(Int(secs / 3600))h" }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
           cal.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        // Within last 6 days → weekday short name. Anything older → "Mar 4".
        let daysDiff = cal.dateComponents([.day], from: date, to: now).day ?? 0
        let df = DateFormatter()
        if daysDiff < 7 {
            df.dateFormat = "EEE"
        } else {
            df.dateFormat = "MMM d"
        }
        return df.string(from: date)
    }
}
