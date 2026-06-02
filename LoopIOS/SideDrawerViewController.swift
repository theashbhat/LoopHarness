//
//  SideDrawerViewController.swift
//  Loop
//
//  Created by Ash Bhat on 11/2/24.
//

import UIKit
import QuickLook

protocol SideDrawerDelegate: AnyObject {
    func sideDrawerDidClose()
    func sideDrawerDidSelectConversation(_ conversation: Conversation?)
}

class SideDrawerViewController: UIViewController {

    weak var delegate: SideDrawerDelegate?

    // MARK: - UI Components
    private let containerView = UIView()
    private let navigationBar = UINavigationBar()
    private let newNavigationItem = UINavigationItem()
    private let segmentedControl = UISegmentedControl(items: ["Conversations", "Files", "Skills"])

    /// UserDefaults key for the last-selected segment. Restored on setup so the
    /// drawer reopens on whatever tab the user left it on.
    private static let selectedTabDefaultsKey = "SideDrawer.selectedTab"
    private let tableView = UITableView()
    private let overlayView = UIView()

    // MARK: - Mode

    /// What the table is currently showing. The same UITableView is reused
    /// for both modes — the cell types, row heights, and data sources all
    /// branch on this flag rather than swapping the table out.
    private enum Mode {
        case conversations
        case files
        case skills
    }
    private var mode: Mode = .conversations

    /// Optional override applied during `setupUI()` before the persisted tab
    /// would otherwise be restored. NavigationSkill sets this when the model
    /// asks to open the drawer focused on a specific tab.
    var pendingInitialTab: String?

    /// Map a segmented-control index to a mode. Centralised so the restore
    /// path and the value-changed handler can't drift apart.
    private func mode(forSegmentIndex index: Int) -> Mode {
        switch index {
        case 1:  return .files
        case 2:  return .skills
        default: return .conversations
        }
    }

    /// Inverse of `mode(forSegmentIndex:)` for the tab-string API used by
    /// NavigationSkill. Returns `nil` for unknown strings so callers can
    /// silently fall back to the restored selection.
    private static func segmentIndex(forTab tab: String) -> Int? {
        switch tab.lowercased() {
        case "conversations", "history": return 0
        case "files", "workspace":       return 1
        case "skills":                   return 2
        default:                         return nil
        }
    }

    /// Switch the drawer to the given tab. Safe to call before or after the
    /// view has loaded — if called pre-load it just stashes the request in
    /// `pendingInitialTab`; if called post-load it updates the segmented
    /// control and rebuilds rows immediately.
    func selectTab(_ tab: String) {
        guard let index = Self.segmentIndex(forTab: tab) else { return }
        if isViewLoaded {
            segmentedControl.selectedSegmentIndex = index
            UserDefaults.standard.set(index, forKey: Self.selectedTabDefaultsKey)
            mode = mode(forSegmentIndex: index)
            rebuildRows(for: mode)
            tableView.reloadData()
        } else {
            pendingInitialTab = tab
        }
    }

    // MARK: - Async load state

    /// Loading state for the Files/Skills tabs when they're sourced from a
    /// remote VM over SSH (the local workspace is read synchronously and never
    /// needs this). Drives a spinner / retry row in place of the list.
    private enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    // MARK: - File tree state

    /// Expanded folders, keyed by a stable string so the same set works for both
    /// the local tree (file URL path) and a remote tree (workspace-relative
    /// path). The flat row list is rebuilt from this set on every toggle so the
    /// order always reflects the live directory contents.
    private var expandedFolders: Set<String> = []
    private var fileRows: [FileRow] = []
    /// Remote-folder listings in flight (keyed by relative path) so we don't
    /// issue duplicate SSH listings while one is pending.
    private var pendingRemoteListings: Set<String> = []
    private var fileLoadState: LoadState = .idle

    /// One row in the flattened file tree. `depth` drives the visual indent.
    /// The source is either an on-device file URL or a workspace-relative path
    /// on the active remote VM.
    private struct FileRow {
        enum Source: Equatable {
            case local(URL)
            case remote(relativePath: String)
        }
        let source: Source
        let name: String
        let isDirectory: Bool
        let depth: Int

        /// Stable key for `expandedFolders` membership.
        var expandKey: String {
            switch source {
            case .local(let url):  return "local:" + url.path
            case .remote(let rel): return "remote:" + rel
            }
        }
    }

    // MARK: - Skills state

    /// One row in the Skills tab. `isDynamic` distinguishes user-authored JS
    /// skills (loaded from disk, removable) from the bundled built-ins; `remote`
    /// is set for skills read from the active VM's `<workspace>/skills`.
    private struct SkillRow {
        let title: String
        let subtitle: String
        let isDynamic: Bool
        /// OpenAI-style function schemas this skill exposes. Bundled built-ins
        /// carry their catalog `tools`; dynamic/remote skills carry a single
        /// synthesized schema from their manifest. The detail sheet renders
        /// each tool's parameters with descriptions.
        let tools: [[String: Any]]
        /// Present only for user-authored local skills — carries the source and
        /// on-disk metadata for the detail sheet. nil otherwise.
        let dynamic: DynamicSkillRegistry.LoadedSkill?
        /// Present only for skills read from the active remote VM.
        let remote: RemoteSkill?
    }
    private var skillRows: [SkillRow] = []
    private var skillLoadState: LoadState = .idle

    /// Holds the URL we're previewing so QLPreviewController can ask for it
    /// via the data source protocol (which can't capture state in a closure).
    private var previewURL: URL?
    
    // MARK: - Animation Properties
    private var drawerWidth: CGFloat {
        // Use view width for full overlay, or a percentage if preferred
        // Fallback to screen width if view bounds not available yet
        let width = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        return width * 0.85 // 85% of screen width for full overlay feel
    }
    private var isOpen = false
    var panGestureRecognizer: UIPanGestureRecognizer!
    private var tapGestureRecognizer: UITapGestureRecognizer!
    
    // MARK: - Pan Gesture Properties
    private var initialDrawerPosition: CGFloat = 0
    private var currentDrawerPosition: CGFloat = 0
    private var panStartTime: CFTimeInterval = 0
    private var closeCompletion: (() -> Void)?
    
    // MARK: - Edge Pan Properties
    private var isEdgePanTracking = false
    private var edgePanStartPosition: CGFloat = 0
    
    // MARK: - Constraints
    private var containerLeadingConstraint: NSLayoutConstraint!
    private var overlayAlphaConstraint: NSLayoutConstraint!
    
    // MARK: - Data
    private var conversations: [Conversation] = []
    private let conversationManager = SimpleConversationManager.shared
    private var currentConversationId: String?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Ensure drawer view is on top and covers everything
        view.backgroundColor = .clear
        view.isOpaque = false
        
        setupUI()
        setupGestures()
        setupConstraints()
        loadConversations()
        observeChanges()
        
        // Don't automatically open drawer - let the parent decide when to open
        // This prevents flashing when used for edge pan tracking
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Setup Methods
    
    private func setupUI() {
        view.backgroundColor = .clear
        
        // Extend edges under status bar and navigation bar
        if #available(iOS 11.0, *) {
            // Allow content to extend under safe areas
        }
        edgesForExtendedLayout = .all
        
        // Setup overlay
        overlayView.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        overlayView.alpha = 0
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayView)
        
        // Setup container. `secondarySystemBackground` is the standard iOS
        // dark-gray (~#1C1C1E in dark mode, off-white in light mode) used for
        // grouped sheets / sidebars — it gives clean contrast against the
        // chat surface behind it, which is pure systemBackground. The old
        // `systemBackground` here made the drawer indistinguishable from
        // the chat in dark mode.
        containerView.backgroundColor = UIColor.secondarySystemBackground
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.shadowColor = UIColor.black.cgColor
        containerView.layer.shadowOffset = CGSize(width: 2, height: 0)
        containerView.layer.shadowRadius = 10
        containerView.layer.shadowOpacity = 0.5
        view.addSubview(containerView)

        // Hairline at the trailing edge so even when the shadow is washed
        // out (low ambient brightness, OLED black), there's a crisp visual
        // delimiter between the drawer and the chat behind it.
        let trailingHairline = UIView()
        trailingHairline.translatesAutoresizingMaskIntoConstraints = false
        trailingHairline.backgroundColor = UIColor.separator
        containerView.addSubview(trailingHairline)
        NSLayoutConstraint.activate([
            trailingHairline.topAnchor.constraint(equalTo: containerView.topAnchor),
            trailingHairline.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            trailingHairline.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            trailingHairline.widthAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])

        // Setup navigation bar — match the drawer's elevated gray. Use the
        // modern UINavigationBarAppearance so the bar's background reliably
        // tracks `secondarySystemBackground` (the older barTintColor /
        // background-image dance is unreliable on iOS 15+); set the same
        // appearance on standard, compact and scrollEdge so it doesn't flip
        // back to the system default when the table is scrolled.
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        let barAppearance = UINavigationBarAppearance()
        barAppearance.configureWithOpaqueBackground()
        barAppearance.backgroundColor = UIColor.secondarySystemBackground
        barAppearance.shadowColor = .clear
        navigationBar.standardAppearance = barAppearance
        navigationBar.scrollEdgeAppearance = barAppearance
        navigationBar.compactAppearance = barAppearance
        navigationBar.isTranslucent = false
        containerView.addSubview(navigationBar)
        
        // The segmented control replaces a static title here — set the
        // navigation bar's title view so it tracks the bar's vertical
        // centering automatically.
        // Restore the last-selected tab. Clamp to the valid range in case the
        // segment count ever shrinks below a previously stored index.
        let storedIndex = UserDefaults.standard.integer(forKey: Self.selectedTabDefaultsKey)
        // If something requested a specific tab before view-load (NavigationSkill),
        // honor it here so we open on that tab instead of the persisted one.
        // Don't overwrite the persisted preference — this is a one-shot override.
        let resolvedIndex: Int
        if let tab = pendingInitialTab, let forced = Self.segmentIndex(forTab: tab) {
            resolvedIndex = forced
            pendingInitialTab = nil
        } else {
            resolvedIndex = storedIndex
        }
        let restoredIndex = min(max(resolvedIndex, 0), segmentedControl.numberOfSegments - 1)
        segmentedControl.selectedSegmentIndex = restoredIndex
        mode = mode(forSegmentIndex: restoredIndex)
        rebuildRows(for: mode)
        segmentedControl.addTarget(self, action: #selector(segmentedControlChanged), for: .valueChanged)
        navigationBar.setItems([newNavigationItem], animated: false)

        // Pinned into the bar with explicit horizontal insets (rather than set
        // as `titleView`, which centers it at its intrinsic width and lets the
        // labels hug the drawer edges). Constraints are wired in
        // setupConstraints once the bar is in the hierarchy.
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(segmentedControl)

        // Setup table view
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(ConversationCell.self, forCellReuseIdentifier: "ConversationCell")
        tableView.register(FileTreeCell.self, forCellReuseIdentifier: "FileTreeCell")
        tableView.register(SkillCell.self, forCellReuseIdentifier: "SkillCell")
        // Single-row placeholder for the Files/Skills tabs while a remote VM
        // listing is loading or after it failed (spinner / retry).
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "StatusCell")
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(tableView)
    }
    
    private func setupGestures() {
        // Pan gesture for the entire drawer container
        panGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        containerView.addGestureRecognizer(panGestureRecognizer)
        
        // Tap gesture for overlay
        tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(overlayTapped))
        overlayView.addGestureRecognizer(tapGestureRecognizer)
    }
    
    private func setupConstraints() {
        // Overlay constraints - full screen overlay
        NSLayoutConstraint.activate([
            overlayView.topAnchor.constraint(equalTo: view.topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // Container constraints - full vertical overlay
        containerLeadingConstraint = containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: -drawerWidth)
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: view.topAnchor), // Full height from top
            containerLeadingConstraint,
            containerView.widthAnchor.constraint(equalToConstant: drawerWidth),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor) // Full height to bottom
        ])
        
        // Navigation bar constraints - respect safe area at top
        NSLayoutConstraint.activate([
            navigationBar.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor, constant: 0),
            navigationBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])

        // Segmented control: centered in the bar, inset from both edges so the
        // labels don't run into the drawer's sides.
        let segmentSideInset: CGFloat = 16
        NSLayoutConstraint.activate([
            segmentedControl.centerYAnchor.constraint(equalTo: navigationBar.centerYAnchor),
            segmentedControl.leadingAnchor.constraint(equalTo: navigationBar.leadingAnchor, constant: segmentSideInset),
            segmentedControl.trailingAnchor.constraint(equalTo: navigationBar.trailingAnchor, constant: -segmentSideInset)
        ])
        
        // Table view constraints
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: navigationBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
    }
    
    // MARK: - Data Methods

    /// Observe store + agent changes so the conversation list live-updates
    /// while the drawer is open (running indicators, message previews).
    private func observeChanges() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleConversationsChanged),
                       name: .conversationStoreDidChange, object: nil)
        nc.addObserver(self, selector: #selector(handleConversationsChanged),
                       name: .subAgentsDidChange, object: nil)
        nc.addObserver(self, selector: #selector(handleConversationsChanged),
                       name: .devinAgentsDidChange, object: nil)
        nc.addObserver(self, selector: #selector(handleConversationsChanged),
                       name: .cursorAgentsDidChange, object: nil)
        // Joining / leaving / switching an execution backend swaps the source
        // for all three tabs (the active VM's sessions, files, and skills, or
        // the on-device ones), so refresh whatever's on screen.
        nc.addObserver(self, selector: #selector(handleBackendChanged),
                       name: ExecutionBackendStore.didChangeNotification, object: nil)
    }

    @objc private func handleConversationsChanged() {
        guard mode == .conversations else { return }
        loadConversations()
    }

    /// The active execution backend changed. The expanded-folder set and any
    /// cached remote skills refer to the *previous* backend's namespace, so drop
    /// them and rebuild the current tab from the now-active source.
    @objc private func handleBackendChanged() {
        expandedFolders.removeAll()
        pendingRemoteListings.removeAll()
        fileRows = []
        skillRows = []
        fileLoadState = .idle
        skillLoadState = .idle
        switch mode {
        case .conversations: loadConversations()
        case .files:         rebuildFileRows(); tableView.reloadData()
        case .skills:        rebuildSkillRows(); tableView.reloadData()
        }
    }

    private func loadConversations() {
        let conversationEntities = conversationManager.getAllConversations()
        conversations = conversationEntities.map { conversationManager.conversationStruct(from: $0) }
        
        // Update current conversation ID
        currentConversationId = conversationManager.currentConversation?.id
        
        tableView.reloadData()
    }
    
    private func deleteConversation(at indexPath: IndexPath) {
        let conversation = conversations[indexPath.row]
        let wasCurrentConversation = conversation.id == currentConversationId
        
        // Delete from conversation manager
        if let conversationEntity = conversationManager.getConversation(by: conversation.id) {
            conversationManager.deleteConversation(conversationEntity)
        }
        
        // Remove from local array
        conversations.remove(at: indexPath.row)
        
        // Update table view
        tableView.deleteRows(at: [indexPath], with: .fade)
        
        // If we deleted the current conversation, select the previous one
        if wasCurrentConversation {
            selectPreviousConversation()
        }
    }
    
    private func selectPreviousConversation() {
        // Find the conversation that should be selected next
        // Priority: 1) Previous conversation in list, 2) Next conversation in list, 3) Create new conversation
        var conversationToSelect: Conversation?
        
        if let currentId = currentConversationId,
           let currentIndex = conversations.firstIndex(where: { $0.id == currentId }) {
            // Try to select the previous conversation
            if currentIndex > 0 {
                conversationToSelect = conversations[currentIndex - 1]
            } else if !conversations.isEmpty {
                // If we're at the first item, select the next one (which is now at index 0)
                conversationToSelect = conversations[0]
            }
        } else if !conversations.isEmpty {
            // If no current conversation, select the first one
            conversationToSelect = conversations[0]
        }
        
        // Select the conversation
        if let conversation = conversationToSelect {
            delegate?.sideDrawerDidSelectConversation(conversation)
        } else {
            // No conversations left, create a new one
            delegate?.sideDrawerDidSelectConversation(nil)
        }
    }
    
    // MARK: - Animation Methods
    
    func openDrawer() {
        // Refresh conversations when opening drawer
        loadConversations()
        animateToPosition(0, velocity: 0, duration: 0.4)
    }
    
    func prepareForButtonOpening() {
        // Ensure drawer starts in closed position for button opening
        containerLeadingConstraint.constant = -drawerWidth
        overlayView.alpha = 0
        currentDrawerPosition = -drawerWidth
        isOpen = false
        view.layoutIfNeeded()
    }
    
    private func closeDrawer(completion: (() -> Void)? = nil) {
        // Store completion for use in animateToPosition
        self.closeCompletion = completion
        animateToPosition(-drawerWidth, velocity: 0, duration: 0.3)
    }
    
    // MARK: - Gesture Handlers
    
    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)
        
        switch gesture.state {
        case .began:
            // Store initial position and start time
            initialDrawerPosition = containerLeadingConstraint.constant
            currentDrawerPosition = initialDrawerPosition
            panStartTime = CACurrentMediaTime()
            
        case .changed:
            // Calculate new position based on translation
            let newPosition = initialDrawerPosition + translation.x
            
            // Constrain the drawer position
            // Allow dragging left (closing) and right (opening from closed state)
            let minPosition: CGFloat = -drawerWidth
            let maxPosition: CGFloat = 0
            
            currentDrawerPosition = max(minPosition, min(maxPosition, newPosition))
            
            // Apply the position directly to the constraint for real-time tracking
            containerLeadingConstraint.constant = currentDrawerPosition
            
            // Update overlay alpha based on drawer position
            let progress = (currentDrawerPosition - minPosition) / (CGFloat(maxPosition) - minPosition)
            overlayView.alpha = progress
            
            // Force immediate layout update
            view.layoutIfNeeded()
            
        case .ended, .cancelled:
            // Calculate gesture duration for inertia
            let gestureDuration = CACurrentMediaTime() - panStartTime
            
            // Determine final position based on velocity and current position
            let shouldClose: Bool
            
            if abs(velocity.x) > 500 {
                // High velocity - use velocity direction
                shouldClose = velocity.x < 0
            } else {
                // Low velocity - use position threshold
                let dragProgress = abs(currentDrawerPosition) / drawerWidth
                shouldClose = dragProgress > 0.3
            }
            
            if shouldClose {
                // Animate to closed position with inertia
                animateToPosition(-drawerWidth, velocity: velocity.x, duration: gestureDuration)
            } else {
                // Animate to open position with inertia
                animateToPosition(0, velocity: velocity.x, duration: gestureDuration)
            }
            
        default:
            break
        }
    }
    
    private func animateToPosition(_ targetPosition: CGFloat, velocity: CGFloat, duration: CFTimeInterval) {
        // Calculate animation duration based on velocity and distance
        let baseDuration = 0.3
        let velocityFactor = min(abs(velocity) / 1000, 1.0) // Normalize velocity
        let dynamicDuration = baseDuration * (1 - velocityFactor * 0.5) // Faster for higher velocity
        
        // Use spring animation for natural feel
        UIView.animate(
            withDuration: dynamicDuration,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: abs(velocity) / 1000,
            options: [.curveEaseOut, .allowUserInteraction],
            animations: {
                self.containerLeadingConstraint.constant = targetPosition
                self.currentDrawerPosition = targetPosition
                
                // Update overlay alpha
                let progress = (targetPosition - (-self.drawerWidth)) / self.drawerWidth
                self.overlayView.alpha = progress
                
                self.view.layoutIfNeeded()
            },
            completion: { _ in
                // Update open state
                self.isOpen = targetPosition == 0
                
                // Call delegate if closing
                if targetPosition == -self.drawerWidth {
                    self.delegate?.sideDrawerDidClose()
                    self.closeCompletion?()
                    self.closeCompletion = nil
                }
            }
        )
    }
    
    @objc private func overlayTapped() {
        closeDrawer()
    }
    
    @objc private func newChatTapped() {
        delegate?.sideDrawerDidSelectConversation(nil)
        closeDrawer()
    }

    @objc private func segmentedControlChanged() {
        let index = segmentedControl.selectedSegmentIndex
        UserDefaults.standard.set(index, forKey: Self.selectedTabDefaultsKey)
        mode = mode(forSegmentIndex: index)
        rebuildRows(for: mode)
        tableView.reloadData()
    }

    /// Rebuild whichever flat row list backs `mode`. Conversations are loaded
    /// separately (Core Data) so they need no prep here.
    private func rebuildRows(for mode: Mode) {
        switch mode {
        case .conversations: break
        case .files:         rebuildFileRows()
        case .skills:        rebuildSkillRows()
        }
    }

    // MARK: - Skills

    /// Flatten the registered skills into display rows: the bundled built-ins
    /// first (catalog order from `AgentHarness`), then any user-authored
    /// dynamic skills loaded from `Workspace/Skills/`, alphabetised. We kick
    /// the dynamic registry to reload first so skills authored this session
    /// show up without an app relaunch.
    private func rebuildSkillRows() {
        // Joined to a VM: skills come from (and run on) the VM, so show only the
        // VM's skills — the device's bundled catalog isn't what executes there.
        if let store = RemoteWorkspaceStores.shared.activeSkillStore {
            rebuildRemoteSkillRows(store)
            return
        }
        skillLoadState = .idle
        var rows: [SkillRow] = AgentHarness.bundledSkillCatalog.map {
            SkillRow(title: $0.name, subtitle: $0.summary, isDynamic: false,
                     tools: $0.tools, dynamic: nil, remote: nil)
        }
        DynamicSkillRegistry.shared.reload()
        let dynamic = DynamicSkillRegistry.shared.skills.values
            .sorted { $0.name < $1.name }
            .map { skill -> SkillRow in
                // Synthesize an OpenAI-style schema from the manifest so the
                // detail sheet renders dynamic skills through the same
                // per-parameter view as built-ins.
                let schema: [String: Any] = [
                    "type": "function",
                    "function": [
                        "name": skill.name,
                        "description": skill.description,
                        "parameters": skill.parameters,
                    ],
                ]
                return SkillRow(title: skill.name, subtitle: skill.description,
                                isDynamic: true, tools: [schema], dynamic: skill, remote: nil)
            }
        rows.append(contentsOf: dynamic)
        skillRows = rows
    }

    /// Build the Skills rows from the active VM's `<workspace>/skills`. The list
    /// is fetched over SSH on first access; `skillLoadState` drives a spinner /
    /// retry row until it lands.
    private func rebuildRemoteSkillRows(_ store: OpenClawSkillStore) {
        skillRows = skillRows.filter { $0.remote != nil } // keep last good remote rows during reload
        if skillLoadState == .loading { return }
        skillLoadState = .loading
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let skills = try await store.listSkills()
                // A backend switch mid-fetch invalidates this result.
                guard RemoteWorkspaceStores.shared.activeSkillStore === store else { return }
                self.skillRows = skills.map { skill in
                    SkillRow(title: skill.name, subtitle: skill.description,
                             isDynamic: true, tools: [], dynamic: nil, remote: skill)
                }
                self.skillLoadState = .loaded
                if self.mode == .skills { self.tableView.reloadData() }
            } catch {
                guard RemoteWorkspaceStores.shared.activeSkillStore === store else { return }
                self.skillLoadState = .error(error.localizedDescription)
                if self.mode == .skills { self.tableView.reloadData() }
            }
        }
    }

    // MARK: - File tree

    /// Walk the workspace root from scratch, honoring whatever's currently
    /// expanded. Cheap enough for hundreds of files; if it ever needs to scale
    /// past that we can cache per-folder listings keyed by URL.
    private func rebuildFileRows() {
        // Joined to a VM: browse the VM workspace over SSH instead of on-device.
        if let store = RemoteWorkspaceStores.shared.activeFileStore {
            rebuildRemoteFileRows(store)
            return
        }
        fileLoadState = .idle
        fileRows = []
        appendFileRows(in: Workspace.shared.rootURL, depth: 0)
    }

    private func appendFileRows(in dirURL: URL, depth: Int) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let contents = try? fm.contentsOfDirectory(at: dirURL,
                                                          includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles])
        else { return }
        // Folders first, then files; both alphabetical, case-insensitive — the
        // visual rhythm users expect from Files.app.
        let sorted = contents.sorted { a, b in
            let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if aDir != bDir { return aDir }
            return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
        }
        for url in sorted {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let row = FileRow(source: .local(url), name: url.lastPathComponent,
                              isDirectory: isDir, depth: depth)
            fileRows.append(row)
            if isDir, expandedFolders.contains(row.expandKey) {
                appendFileRows(in: url, depth: depth + 1)
            }
        }
    }

    // MARK: Remote file tree

    /// Build the flat row list for the active VM workspace from cached SSH
    /// listings, kicking off a fetch for any folder (root + expanded) not yet
    /// cached. Re-runs when each fetch lands.
    private func rebuildRemoteFileRows(_ store: OpenClawFileStore) {
        fileRows = []
        appendRemoteFileRows(store, relPath: "", depth: 0)
        // The root listing decides the spinner/error/empty state.
        if store.cachedListing("") != nil { fileLoadState = .loaded }
    }

    private func appendRemoteFileRows(_ store: OpenClawFileStore, relPath: String, depth: Int) {
        guard let entries = store.cachedListing(relPath) else {
            fetchRemoteListing(store, relPath: relPath, isRoot: depth == 0)
            return
        }
        for entry in entries {
            let row = FileRow(source: .remote(relativePath: entry.relativePath),
                              name: entry.name, isDirectory: entry.isDirectory, depth: depth)
            fileRows.append(row)
            if entry.isDirectory, expandedFolders.contains(row.expandKey) {
                appendRemoteFileRows(store, relPath: entry.relativePath, depth: depth + 1)
            }
        }
    }

    private func fetchRemoteListing(_ store: OpenClawFileStore, relPath: String, isRoot: Bool) {
        guard !pendingRemoteListings.contains(relPath) else { return }
        pendingRemoteListings.insert(relPath)
        if isRoot && store.cachedListing("") == nil { fileLoadState = .loading }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { self.pendingRemoteListings.remove(relPath) }
            do {
                _ = try await store.list(relPath)
                guard RemoteWorkspaceStores.shared.activeFileStore === store else { return }
                if self.mode == .files {
                    self.rebuildFileRows()
                    self.tableView.reloadData()
                }
            } catch {
                guard RemoteWorkspaceStores.shared.activeFileStore === store else { return }
                if isRoot { self.fileLoadState = .error(error.localizedDescription) }
                if self.mode == .files { self.tableView.reloadData() }
            }
        }
    }

    /// Triggered by tapping a file row. Downloads the file if it's
    /// iCloud-evicted (best-effort, time-boxed), then presents the standard
    /// QuickLook preview controller full-screen with an X close button in
    /// the nav bar.
    private func presentPreview(for url: URL) {
        // Markdown opens in the full editor (read + edit) instead of the
        // read-only QuickLook preview. The editor handles its own
        // iCloud-download + loading spinner.
        if MarkdownEditorViewController.isMarkdownFile(url) {
            let presenter = topMostPresenter() ?? self
            MarkdownEditorViewController.present(for: url, from: presenter)
            return
        }
        previewURL = url
        DispatchQueue.global(qos: .userInitiated).async {
            try? Workspace.shared.ensureDownloaded(url)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.previewURL == url else { return }
                let preview = QLPreviewController()
                preview.dataSource = self
                // Full-screen presentation puts the file front-and-centre;
                // wrapping in a UINavigationController gives us the title
                // bar and a guaranteed slot for the close button (QL's own
                // bar items are positioned by the framework and can't host
                // an X reliably across iOS versions).
                preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
                    barButtonSystemItem: .close,
                    target: self,
                    action: #selector(dismissPreviewController)
                )
                let nav = UINavigationController(rootViewController: preview)
                nav.modalPresentationStyle = .fullScreen
                // The drawer is added as a child of the window or messaging
                // VC; presenting directly from `self` can land on the drawer's
                // own view which is mid-animation. Walk to the topmost
                // presented controller so the preview opens reliably.
                let presenter = self.topMostPresenter() ?? self
                presenter.present(nav, animated: true)
            }
        }
    }

    @objc private func dismissPreviewController() {
        // The presenter is whoever currently owns the preview's nav; ask
        // from the topmost so we close exactly the one we put up.
        topMostPresenter()?.dismiss(animated: true)
    }

    private func topMostPresenter() -> UIViewController? {
        // Start from the key window's root and dive through whatever's
        // already presented. Falls back to the side-drawer's parent if no
        // window is available (shouldn't happen while the drawer is on
        // screen, but it's a safe default).
        let root: UIViewController? = {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
                return keyWindow.rootViewController
            }
            return parent
        }()
        var top = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
    
    // MARK: - Edge Pan Tracking Methods
    
    func startEdgePanTracking() {
        isEdgePanTracking = true
        edgePanStartPosition = -drawerWidth
        currentDrawerPosition = edgePanStartPosition
        
        // Start with drawer completely hidden to avoid flash
        containerLeadingConstraint.constant = -drawerWidth
        overlayView.alpha = 0
        
        // Ensure the view is properly laid out before any animations
        view.layoutIfNeeded()
    }
    
    func updateEdgePanPosition(translation: CGFloat) {
        guard isEdgePanTracking else { return }
        
        // Calculate new position based on translation
        let newPosition = edgePanStartPosition + translation
        
        // Constrain the drawer position
        let minPosition: CGFloat = -drawerWidth
        let maxPosition: CGFloat = 0
        
        currentDrawerPosition = max(minPosition, min(maxPosition, newPosition))
        
        // Apply the position directly to the constraint for real-time tracking
        containerLeadingConstraint.constant = currentDrawerPosition
        
        // Update overlay alpha based on drawer position
        let progress = (currentDrawerPosition - minPosition) / (maxPosition - minPosition)
        overlayView.alpha = progress
        
        // Force immediate layout update
        view.layoutIfNeeded()
    }
    
    func completeEdgePanOpening(velocity: CGFloat, duration: CFTimeInterval) {
        guard isEdgePanTracking else { return }
        isEdgePanTracking = false
        
        // Animate to fully open position with inertia
        animateToPosition(0, velocity: velocity, duration: duration)
    }
    
    func cancelEdgePanOpening() {
        guard isEdgePanTracking else { return }
        isEdgePanTracking = false
        
        // Animate back to closed position
        animateToPosition(-drawerWidth, velocity: 0, duration: 0.3)
    }
}

// MARK: - UITableViewDataSource & UITableViewDelegate

extension SideDrawerViewController: UITableViewDataSource, UITableViewDelegate {

    /// True when the Files tab is remote and has nothing to show yet — the
    /// single status row (spinner / retry) stands in for the list.
    private var filesShowStatusRow: Bool {
        RemoteWorkspaceStores.shared.activeFileStore != nil && fileRows.isEmpty
    }
    private var skillsShowStatusRow: Bool {
        RemoteWorkspaceStores.shared.activeSkillStore != nil && skillRows.isEmpty
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch mode {
        case .conversations: return conversations.count
        case .files:         return filesShowStatusRow ? 1 : fileRows.count
        case .skills:        return skillsShowStatusRow ? 1 : skillRows.count
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch mode {
        case .conversations:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ConversationCell", for: indexPath) as! ConversationCell
            let conversation = conversations[indexPath.row]
            let isCurrent = conversation.id == currentConversationId
            cell.configure(with: conversation, isCurrent: isCurrent)
            return cell
        case .files:
            if filesShowStatusRow { return statusCell(for: fileLoadState, in: tableView, indexPath: indexPath) }
            let cell = tableView.dequeueReusableCell(withIdentifier: "FileTreeCell", for: indexPath) as! FileTreeCell
            let row = fileRows[indexPath.row]
            cell.configure(name: row.name,
                           isDirectory: row.isDirectory,
                           depth: row.depth,
                           isExpanded: expandedFolders.contains(row.expandKey))
            return cell
        case .skills:
            if skillsShowStatusRow { return statusCell(for: skillLoadState, in: tableView, indexPath: indexPath) }
            let cell = tableView.dequeueReusableCell(withIdentifier: "SkillCell", for: indexPath) as! SkillCell
            let row = skillRows[indexPath.row]
            cell.configure(title: row.title, subtitle: row.subtitle, isDynamic: row.isDynamic)
            return cell
        }
    }

    /// Builds the spinner / message / retry row shown in place of an empty
    /// remote Files or Skills list.
    private func statusCell(for state: LoadState, in tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "StatusCell", for: indexPath)
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        cell.accessoryView = nil
        var config = cell.defaultContentConfiguration()
        config.textProperties.color = .secondaryLabel
        config.textProperties.numberOfLines = 0
        switch state {
        case .idle, .loading:
            config.text = "Loading from the VM…"
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        case .loaded:
            config.text = "Nothing here yet."
        case .error(let message):
            config.text = "Couldn't reach the VM. Tap to retry.\n\(message)"
            config.textProperties.color = .systemRed
        }
        cell.contentConfiguration = config
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch mode {
        case .conversations:
            let conversation = conversations[indexPath.row]
            delegate?.sideDrawerDidSelectConversation(conversation)
            closeDrawer()
        case .files:
            if filesShowStatusRow {
                if case .error = fileLoadState { fileLoadState = .idle; rebuildFileRows(); tableView.reloadData() }
                return
            }
            let row = fileRows[indexPath.row]
            if row.isDirectory {
                if expandedFolders.contains(row.expandKey) {
                    expandedFolders.remove(row.expandKey)
                } else {
                    expandedFolders.insert(row.expandKey)
                }
                rebuildFileRows()
                tableView.reloadData()
            } else {
                openFileRow(row)
            }
        case .skills:
            if skillsShowStatusRow {
                if case .error = skillLoadState { skillLoadState = .idle; rebuildSkillRows(); tableView.reloadData() }
                return
            }
            let row = skillRows[indexPath.row]
            presentSkillDetail(for: row)
        }
    }

    /// Open a file row — local files preview/edit as before; remote files load
    /// over SSH (markdown into the editor, everything else into QuickLook).
    private func openFileRow(_ row: FileRow) {
        switch row.source {
        case .local(let url):
            presentPreview(for: url)
        case .remote(let rel):
            presentRemoteFile(relativePath: rel, name: row.name)
        }
    }

    /// Markdown remote files open in the editor (read + edit over SSH); any
    /// other type is fetched to a temp file and shown read-only in QuickLook.
    private func presentRemoteFile(relativePath rel: String, name: String) {
        guard let store = RemoteWorkspaceStores.shared.activeFileStore else { return }
        let presenter = topMostPresenter() ?? self
        if MarkdownEditorViewController.isMarkdownFile(name: name) {
            let source = MarkdownEditorViewController.Source.remote(
                name: name,
                load: { String(decoding: try await store.read(rel), as: UTF8.self) },
                save: { try await store.write(Data($0.utf8), to: rel) })
            MarkdownEditorViewController.present(source: source, from: presenter)
            return
        }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let data = try await store.read(rel)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try data.write(to: tmp, options: .atomic)
                self.previewURL = tmp
                let preview = QLPreviewController()
                preview.dataSource = self
                preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
                    barButtonSystemItem: .close, target: self, action: #selector(self.dismissPreviewController))
                let nav = UINavigationController(rootViewController: preview)
                nav.modalPresentationStyle = .fullScreen
                (self.topMostPresenter() ?? self).present(nav, animated: true)
            } catch {
                self.presentRemoteError(error)
            }
        }
    }

    private func presentRemoteError(_ error: Error) {
        let alert = UIAlertController(title: "Couldn't open file",
                                      message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        (topMostPresenter() ?? self).present(alert, animated: true)
    }

    /// Present a skill's details in a sheet-modal. Built-ins show their name +
    /// summary; user-authored skills additionally surface their parameter
    /// schema, source, and on-disk metadata. Remote (VM) skills open an action
    /// sheet to view, edit `skill.js` / `skill.json`, or delete over SSH.
    private func presentSkillDetail(for row: SkillRow) {
        let detail: SkillDetailViewController
        if let remote = row.remote {
            // Remote VM skills: same descriptive modal as local skills, showing
            // the SKILL.md instructions, with Edit / Delete acting on the VM.
            detail = SkillDetailViewController(
                remoteName: remote.name,
                description: remote.description,
                markdown: remote.markdown,
                onEdit: { [weak self] in self?.editRemoteSkillMarkdown(remote) },
                onDelete: { [weak self] in self?.confirmDeleteRemoteSkill(remote) }
            )
        } else {
            detail = SkillDetailViewController(
                title: row.title,
                summary: row.subtitle,
                isDynamic: row.isDynamic,
                tools: row.tools,
                dynamic: row.dynamic
            )
        }
        let nav = UINavigationController(rootViewController: detail)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        let presenter = topMostPresenter() ?? self
        presenter.present(nav, animated: true)
    }

    private func editRemoteSkillMarkdown(_ skill: RemoteSkill) {
        guard let store = RemoteWorkspaceStores.shared.activeFileStore else { return }
        let rel = skill.markdownRelPath
        let source = MarkdownEditorViewController.Source.remote(
            name: "\(skill.name)/\((rel as NSString).lastPathComponent)",
            load: { String(decoding: try await store.read(rel), as: UTF8.self) },
            save: { try await store.write(Data($0.utf8), to: rel) })
        MarkdownEditorViewController.present(source: source, from: topMostPresenter() ?? self)
    }

    private func confirmDeleteRemoteSkill(_ skill: RemoteSkill) {
        let presenter = topMostPresenter() ?? self
        let alert = UIAlertController(title: "Delete \(skill.name)?",
            message: "This removes the skill folder from the VM. This can't be undone.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self = self, let store = RemoteWorkspaceStores.shared.activeSkillStore else { return }
            Task { @MainActor in
                do {
                    try await store.deleteSkill(folderRelPath: skill.folderRelPath)
                    self.skillLoadState = .idle
                    self.rebuildSkillRows()
                    self.tableView.reloadData()
                } catch {
                    self.presentRemoteError(error)
                }
            }
        })
        presenter.present(alert, animated: true)
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch mode {
        case .conversations: return 80
        case .files:         return filesShowStatusRow ? UITableView.automaticDimension : 44
        case .skills:        return skillsShowStatusRow ? UITableView.automaticDimension : 60
        }
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        // Only the status row uses self-sizing; everything else is fixed.
        switch mode {
        case .conversations: return 80
        case .files:         return filesShowStatusRow ? 88 : 44
        case .skills:        return skillsShowStatusRow ? 88 : 60
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        // Swipe-to-delete only applies to conversations — file destructive
        // actions stay in the Files app where the user already has a familiar
        // confirmation flow.
        guard mode == .conversations else { return nil }
        let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] (action, view, completionHandler) in
            self?.deleteConversation(at: indexPath)
            completionHandler(true)
        }
        deleteAction.backgroundColor = .systemRed
        deleteAction.image = UIImage(systemName: "trash")

        return UISwipeActionsConfiguration(actions: [deleteAction])
    }
}

// MARK: - QLPreviewControllerDataSource

extension SideDrawerViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        return previewURL == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController,
                           previewItemAt index: Int) -> QLPreviewItem {
        // Falling back to the workspace root keeps the data source contract
        // satisfied if `previewURL` somehow nilled out between presentation
        // and the data-source query.
        return (previewURL ?? Workspace.shared.rootURL) as NSURL
    }
}

// MARK: - File tree cell

/// Single row in the workspace file tree. Indent grows with `depth`; folder
/// rows show a chevron that flips on expansion to telegraph the tap action.
private final class FileTreeCell: UITableViewCell {

    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let chevronView = UIImageView()
    private var leadingConstraint: NSLayoutConstraint!

    /// Per-depth indent (points). 18pt felt right against the 20pt cell padding
    /// — enough to read the hierarchy, not so much that deep trees scroll off.
    private static let indentPerDepth: CGFloat = 18
    private static let baseLeading: CGFloat = 20

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        backgroundColor = .clear
        selectionStyle = .default

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .secondaryLabel
        iconView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 15)
        nameLabel.textColor = .label
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameLabel)

        chevronView.contentMode = .scaleAspectFit
        chevronView.tintColor = .tertiaryLabel
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(chevronView)

        leadingConstraint = iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.baseLeading)

        NSLayoutConstraint.activate([
            leadingConstraint,
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -8),

            chevronView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            chevronView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    func configure(name: String, isDirectory: Bool, depth: Int, isExpanded: Bool) {
        nameLabel.text = name
        leadingConstraint.constant = Self.baseLeading + CGFloat(depth) * Self.indentPerDepth
        if isDirectory {
            iconView.image = UIImage(systemName: isExpanded ? "folder.fill" : "folder")
            iconView.tintColor = .systemBlue
            chevronView.image = UIImage(systemName: isExpanded ? "chevron.down" : "chevron.right")
            chevronView.isHidden = false
        } else {
            iconView.image = UIImage(systemName: "doc")
            iconView.tintColor = .secondaryLabel
            chevronView.isHidden = true
        }
    }
}

// MARK: - Skill cell

/// Single row in the Skills tab. Mirrors `FileTreeCell`'s construction style
/// (programmatic UILabel/UIImageView + activated constraints) but shows a
/// two-line title/subtitle and a leading icon that distinguishes bundled
/// built-ins from user-authored dynamic skills.
private final class SkillCell: UITableViewCell {

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        backgroundColor = .clear
        selectionStyle = .none

        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    func configure(title: String, subtitle: String, isDynamic: Bool) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        // Dynamic skills get the "hammer" (authored on device); built-ins get
        // the generic puzzle-piece extension glyph.
        iconView.image = UIImage(systemName: isDynamic ? "hammer.fill" : "puzzlepiece.extension.fill")
        iconView.tintColor = isDynamic ? .systemOrange : .systemBlue
    }
}

// MARK: - Skill detail

/// Sheet-modal showing a single skill's details. Presented when a row in the
/// Skills tab is tapped. The layout is a vertically-scrolling stack of
/// sections: a header (icon + name + type badge), the description, each tool
/// the skill exposes (function name + description + per-parameter docs), and —
/// for user-authored dynamic skills — the source and on-disk metadata. Built
/// programmatically to match the rest of the drawer.
final class SkillDetailViewController: UIViewController {

    private let skillTitle: String
    private let summary: String
    private let isDynamic: Bool
    private let tools: [[String: Any]]
    private let dynamic: DynamicSkillRegistry.LoadedSkill?

    // Remote (VM SKILL.md) skills: there's no JSON tool schema or JS source —
    // instead a markdown instructions body, plus edit/delete affordances.
    private let isRemote: Bool
    private let markdownBody: String?
    private let onEdit: (() -> Void)?
    private let onDelete: (() -> Void)?

    init(title: String,
         summary: String,
         isDynamic: Bool,
         tools: [[String: Any]],
         dynamic: DynamicSkillRegistry.LoadedSkill?) {
        self.skillTitle = title
        self.summary = summary
        self.isDynamic = isDynamic
        self.tools = tools
        self.dynamic = dynamic
        self.isRemote = false
        self.markdownBody = nil
        self.onEdit = nil
        self.onDelete = nil
        super.init(nibName: nil, bundle: nil)
    }

    /// Detail modal for a skill that lives on a remote VM (Claude Code SKILL.md
    /// format). Shows the description and the SKILL.md instructions, with Edit /
    /// Delete actions that operate on the VM.
    init(remoteName: String,
         description: String,
         markdown: String,
         onEdit: @escaping () -> Void,
         onDelete: @escaping () -> Void) {
        self.skillTitle = remoteName
        self.summary = description
        self.isDynamic = false
        self.tools = []
        self.dynamic = nil
        self.isRemote = true
        self.markdownBody = markdown
        self.onEdit = onEdit
        self.onDelete = onDelete
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = skillTitle
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(close)
        )
        // Remote skills can be edited (SKILL.md) on the VM straight from here.
        if onEdit != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .edit, target: self, action: #selector(editTapped))
        }
        buildContent()
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func editTapped() {
        // Dismiss the detail first, then hand off to the editor so it presents
        // from the drawer's presenter rather than stacking on this sheet.
        let edit = onEdit
        dismiss(animated: true) { edit?() }
    }

    @objc private func deleteTapped() {
        let del = onDelete
        dismiss(animated: true) { del?() }
    }

    // MARK: - Layout

    private func buildContent() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32),
        ])

        // Header: large icon, name, and a type badge.
        stack.addArrangedSubview(makeHeader())

        // Description.
        if !summary.isEmpty {
            stack.addArrangedSubview(makeSection(title: "Description",
                                                 body: makeBodyLabel(summary)))
        }

        // Tools the skill exposes, each with its parameters and descriptions.
        // A skill can declare several functions (e.g. Git has clone/pull/
        // status), so we render one card per tool.
        let toolViews = tools.compactMap { makeToolView($0) }
        if !toolViews.isEmpty {
            let header = tools.count > 1 ? "Tools (\(tools.count))" : "Tool"
            let toolsStack = UIStackView(arrangedSubviews: toolViews)
            toolsStack.axis = .vertical
            toolsStack.spacing = 12
            stack.addArrangedSubview(makeSection(title: header, body: toolsStack))
        }

        // Dynamic-only sections: source and on-disk metadata.
        if let dynamic {
            let source = dynamic.source.trimmingCharacters(in: .whitespacesAndNewlines)
            if !source.isEmpty {
                stack.addArrangedSubview(makeSection(title: "Source",
                                                     body: makeCodeView(source)))
            }
            if let meta = metadataText(for: dynamic) {
                stack.addArrangedSubview(makeSection(title: "On disk",
                                                     body: makeBodyLabel(meta)))
            }
        }

        // Remote (SKILL.md) skills: show the markdown instructions body and a
        // destructive delete button.
        if isRemote, let markdown = markdownBody {
            let body = Self.bodyAfterFrontmatter(markdown)
            if !body.isEmpty {
                stack.addArrangedSubview(makeSection(title: "Instructions",
                                                     body: makeCodeView(body)))
            }
            if onDelete != nil {
                let delete = UIButton(type: .system)
                delete.setTitle("Delete skill", for: .normal)
                delete.setTitleColor(.systemRed, for: .normal)
                delete.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
                delete.contentHorizontalAlignment = .leading
                delete.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
                stack.addArrangedSubview(delete)
            }
        }
    }

    /// Strip a leading `---`-delimited YAML frontmatter block, returning just the
    /// markdown instructions. Falls back to the whole text if there's no block.
    private static func bodyAfterFrontmatter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Find the closing delimiter, then return everything after it.
        if let closeIdx = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            return lines[(closeIdx + 1)...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeHeader() -> UIView {
        // Remote VM skills get their own glyph/tint; otherwise the local
        // dynamic (hammer) vs built-in (puzzle piece) distinction.
        let glyph: String
        let tint: UIColor
        let badgeText: String
        if isRemote {
            glyph = "server.rack"; tint = .systemPurple; badgeText = "VM skill"
        } else if isDynamic {
            glyph = "hammer.fill"; tint = .systemOrange; badgeText = "Custom skill"
        } else {
            glyph = "puzzlepiece.extension.fill"; tint = .systemBlue; badgeText = "Built-in"
        }

        let icon = UIImageView()
        icon.contentMode = .scaleAspectFit
        icon.image = UIImage(systemName: glyph)
        icon.tintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34),
        ])

        let name = UILabel()
        name.text = skillTitle
        name.font = .systemFont(ofSize: 22, weight: .bold)
        name.numberOfLines = 0

        let badge = makeBadge(badgeText, tint: tint)

        let textStack = UIStackView(arrangedSubviews: [name, badge])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 8

        let row = UIStackView(arrangedSubviews: [icon, textStack])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 12
        return row
    }

    /// A pill-shaped label used as the skill-type badge.
    private func makeBadge(_ text: String, tint: UIColor) -> UIView {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = tint
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.backgroundColor = tint.withAlphaComponent(0.15)
        container.layer.cornerRadius = 6
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
        ])
        return container
    }

    /// A section is an uppercase header label stacked above its content view.
    private func makeSection(title: String, body: UIView) -> UIView {
        let header = UILabel()
        header.text = title.uppercased()
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [header, body])
        stack.axis = .vertical
        stack.spacing = 8
        return stack
    }

    private func makeBodyLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 15)
        label.textColor = .label
        label.numberOfLines = 0
        return label
    }

    /// Monospaced text in a rounded card — used for parameter JSON and source.
    private func makeCodeView(_ text: String) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .label
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 10
        card.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])
        return card
    }

    // MARK: - Tool rendering

    /// Render one OpenAI-style function schema as a card: the function name
    /// (monospaced), its description, and a row per parameter showing name,
    /// type, a "required" marker, and the parameter's own description.
    /// Returns nil for a schema we can't read.
    private func makeToolView(_ schema: [String: Any]) -> UIView? {
        guard let function = schema["function"] as? [String: Any],
              let name = function["name"] as? String else { return nil }

        let rows = UIStackView()
        rows.axis = .vertical
        rows.spacing = 6

        // Function name.
        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 0
        rows.addArrangedSubview(nameLabel)

        // Function description.
        var hasDescription = false
        if let desc = function["description"] as? String, !desc.isEmpty {
            let descLabel = UILabel()
            descLabel.text = desc
            descLabel.font = .systemFont(ofSize: 13)
            descLabel.textColor = .secondaryLabel
            descLabel.numberOfLines = 0
            rows.addArrangedSubview(descLabel)
            hasDescription = true
        }

        // Parameters. Read each property's schema individually so one
        // malformed entry can't blank out the whole list.
        let params = function["parameters"] as? [String: Any]
        let rawProperties = params?["properties"] as? [String: Any] ?? [:]
        let properties = rawProperties.compactMapValues { $0 as? [String: Any] }
        let required = Set(params?["required"] as? [String] ?? [])
        if properties.isEmpty {
            let none = UILabel()
            none.text = "No parameters"
            none.font = .italicSystemFont(ofSize: 12)
            none.textColor = .tertiaryLabel
            rows.addArrangedSubview(none)
        } else {
            // Required params first, then alphabetical within each group for a
            // stable, predictable order (the schema dict itself is unordered).
            let names = properties.keys.sorted { a, b in
                let ra = required.contains(a), rb = required.contains(b)
                if ra != rb { return ra }
                return a < b
            }
            for (i, key) in names.enumerated() {
                if i > 0 || hasDescription {
                    rows.addArrangedSubview(makeHairline())
                }
                rows.addArrangedSubview(
                    makeParamRow(name: key,
                                 schema: properties[key] ?? [:],
                                 isRequired: required.contains(key)))
            }
        }

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 10
        rows.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            rows.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            rows.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            rows.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])
        return card
    }

    /// One parameter: `name` · type [· required], then its description below.
    private func makeParamRow(name: String,
                              schema: [String: Any],
                              isRequired: Bool) -> UIView {
        var meta: [String] = []
        if let type = schema["type"] as? String { meta.append(type) }
        if isRequired { meta.append("required") }

        // The name + type/required line, with the name emphasised.
        let header = NSMutableAttributedString(
            string: name,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: UIColor.label,
            ])
        if !meta.isEmpty {
            header.append(NSAttributedString(
                string: "  " + meta.joined(separator: " · "),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12),
                    .foregroundColor: isRequired ? UIColor.systemRed : UIColor.tertiaryLabel,
                ]))
        }
        let headerLabel = UILabel()
        headerLabel.attributedText = header
        headerLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [headerLabel])
        stack.axis = .vertical
        stack.spacing = 2

        if let desc = schema["description"] as? String, !desc.isEmpty {
            let descLabel = UILabel()
            descLabel.text = desc
            descLabel.font = .systemFont(ofSize: 13)
            descLabel.textColor = .secondaryLabel
            descLabel.numberOfLines = 0
            stack.addArrangedSubview(descLabel)
        }
        return stack
    }

    private func makeHairline() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale).isActive = true
        return line
    }

    private func metadataText(for skill: DynamicSkillRegistry.LoadedSkill) -> String? {
        var lines: [String] = []
        lines.append("Folder: \(skill.folder.lastPathComponent)")
        if let mtime = skill.scriptMTime ?? skill.manifestMTime {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            lines.append("Updated: \(fmt.string(from: mtime))")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

// MARK: - Conversation Model
// `Conversation` moved to Structs/Messaging.swift so the macOS target (which
// excludes UIKit-only files) can still see it from SimpleConversationManager.

// MARK: - Conversation Cell

class ConversationCell: UITableViewCell {
    
    private let titleLabel = UILabel()
    private let lastMessageLabel = UILabel()
    private let timestampLabel = UILabel()
    private let separatorView = UIView()

    /// Title + backend badge laid out horizontally so the badge collapses when
    /// hidden (local rows look exactly as before).
    private let titleStack = UIStackView()
    /// Small "VM" pill shown only for OpenClaw-backed conversations.
    private let backendBadge = PaddedLabel()

    /// Small colored dot indicating an active agent run for this conversation.
    private let runningDot = UIView()
    private let pulseLayer = CALayer()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        backgroundColor = .clear
        selectionStyle = .none
        
        // Running-indicator dot (hidden by default)
        runningDot.translatesAutoresizingMaskIntoConstraints = false
        runningDot.backgroundColor = .systemGreen
        runningDot.layer.cornerRadius = 4
        runningDot.isHidden = true
        pulseLayer.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.4).cgColor
        pulseLayer.cornerRadius = 4
        runningDot.layer.insertSublayer(pulseLayer, at: 0)
        contentView.addSubview(runningDot)

        // Setup title label
        titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Backend badge ("VM") — hidden for local conversations.
        backendBadge.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
        backendBadge.textColor = .secondaryLabel
        backendBadge.backgroundColor = UIColor.systemGray.withAlphaComponent(0.18)
        backendBadge.textInsets = UIEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)
        backendBadge.layer.cornerRadius = 6
        backendBadge.layer.masksToBounds = true
        backendBadge.setContentHuggingPriority(.required, for: .horizontal)
        backendBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        backendBadge.isHidden = true

        // Title + badge in a horizontal stack so the badge collapses when
        // hidden, leaving the local-row layout unchanged.
        titleStack.axis = .horizontal
        titleStack.spacing = 6
        titleStack.alignment = .center
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(backendBadge)
        contentView.addSubview(titleStack)

        // Setup last message label
        lastMessageLabel.font = UIFont.systemFont(ofSize: 14)
        lastMessageLabel.textColor = .secondaryLabel
        lastMessageLabel.numberOfLines = 2
        lastMessageLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(lastMessageLabel)
        
        // Setup timestamp label
        timestampLabel.font = UIFont.systemFont(ofSize: 12)
        timestampLabel.textColor = .tertiaryLabel
        timestampLabel.textAlignment = .right
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(timestampLabel)
        
        // Setup separator
        separatorView.backgroundColor = UIColor.separator
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separatorView)
        
        // Setup constraints
        NSLayoutConstraint.activate([
            runningDot.widthAnchor.constraint(equalToConstant: 8),
            runningDot.heightAnchor.constraint(equalToConstant: 8),
            runningDot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            runningDot.centerYAnchor.constraint(equalTo: titleStack.centerYAnchor),

            titleStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            titleStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleStack.trailingAnchor.constraint(equalTo: timestampLabel.leadingAnchor, constant: -8),

            timestampLabel.topAnchor.constraint(equalTo: titleStack.topAnchor),
            timestampLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            timestampLabel.widthAnchor.constraint(equalToConstant: 60),

            lastMessageLabel.topAnchor.constraint(equalTo: titleStack.bottomAnchor, constant: 4),
            lastMessageLabel.leadingAnchor.constraint(equalTo: titleStack.leadingAnchor),
            lastMessageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            lastMessageLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            
            separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 0.5)
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pulseLayer.frame = runningDot.bounds
    }
    
    func configure(with conversation: Conversation, isCurrent: Bool = false) {
        titleLabel.text = conversation.title
        lastMessageLabel.text = conversation.lastMessage

        // Backend badge — only remote-backed conversations carry one.
        if conversation.backend == .remote {
            backendBadge.text = "VM"
            backendBadge.isHidden = false
        } else {
            backendBadge.isHidden = true
        }
        
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        timestampLabel.text = formatter.string(from: conversation.timestamp)

        // Running-indicator dot
        runningDot.isHidden = !conversation.isRunning
        if conversation.isRunning {
            startPulse()
        } else {
            stopPulse()
        }
        
        // Highlight current conversation. Bumped from 0.1 → 0.22 so the
        // tint reads against the drawer's `secondarySystemBackground` —
        // 0.1 was calibrated for a black drawer and disappeared once the
        // panel became dark gray.
        if isCurrent {
            backgroundColor = UIColor.systemBlue.withAlphaComponent(0.22)
            titleLabel.textColor = .systemBlue
            titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        } else {
            backgroundColor = .clear
            titleLabel.textColor = .label
            titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        }
    }

    // MARK: - Pulse animation

    private func startPulse() {
        guard pulseLayer.animation(forKey: "pulse") == nil else { return }
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 1.0
        anim.toValue = 1.8
        anim.duration = 1.0
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.6
        opacity.toValue = 0.0
        opacity.duration = 1.0
        opacity.autoreverses = true
        opacity.repeatCount = .infinity
        opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let group = CAAnimationGroup()
        group.animations = [anim, opacity]
        group.duration = 1.0
        group.autoreverses = true
        group.repeatCount = .infinity
        pulseLayer.add(group, forKey: "pulse")
    }

    private func stopPulse() {
        pulseLayer.removeAnimation(forKey: "pulse")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        runningDot.isHidden = true
        backendBadge.isHidden = true
        stopPulse()
    }
}

// MARK: - PaddedLabel

/// A UILabel with configurable text insets — used for the small backend pill
/// on conversation rows so the rounded background has breathing room.
final class PaddedLabel: UILabel {
    var textInsets: UIEdgeInsets = .zero {
        didSet { invalidateIntrinsicContentSize() }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        return CGSize(width: base.width + textInsets.left + textInsets.right,
                      height: base.height + textInsets.top + textInsets.bottom)
    }
}
