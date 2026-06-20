//
//  LoopMacApp.swift
//  LoopMac
//
//  AppKit app delegate. The Mac app keeps two visible surfaces:
//   - A floating recorder bar pinned bottom-center of the screen (always visible
//     so you can see capture state while typing in another app).
//   - A normal window showing the active conversation, opened on first send.
//
//  Conversations live in CoreData + CloudKit (ConversationStore), so anything
//  the user says here syncs to the iPhone app and vice versa.
//

import AppKit
import UserNotifications
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Sparkle updater. `startingUpdater: true` plus `SUEnableAutomaticChecks`
    /// in Info.plist means it checks the appcast on launch + on the scheduled
    /// interval, downloads the EdDSA-signed update in the background, and
    /// prompts to install. Also backs the "Check for Updates…" menu item.
    /// Held strongly for the app lifetime so the background scheduler keeps
    /// running.
    private var updaterController: SPUStandardUpdaterController?
    private var recorderController: RecorderWindowController?
    /// Internal so other module-level controllers (e.g. the Scheduled Tasks
    /// window's "Open Last" path) can route through the tab manager rather
    /// than poking `SimpleConversationManager.currentConversation` directly.
    var conversationController: ConversationWindowController?
    private var hotKeyMonitor: HotKeyMonitor?
    private var coordinator: VoiceLoopCoordinator?
    private var onboardingController: OnboardingWindowController?
    /// Floating pill that sits just above the recorder bar whenever the
    /// active conversation has an in-app terminal session attached. Lives
    /// on the AppDelegate so it can listen to tab/conversation changes for
    /// the entire app lifetime.
    private var terminalPillController: TerminalPillWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Boot the earcon player early so its AVAudioEngine is warm by the
        // time the first state transition fires, and play the welcome cue
        // (A4 → E5) — the startup earcon.
        EarconPlayer.shared.play(.welcome)

        // Touch the conversation store so the iCloud Documents path resolves
        // and the NSMetadataQuery starts watching messages/ for iPhone writes.
        _ = ConversationFileStore.shared

        // Own notification handling so scheduler-fired notifications can route
        // taps through to ConversationWindowController. Has to be set before
        // BackgroundScheduler.bootstrap() in case any pending notification
        // arrives during launch.
        UNUserNotificationCenter.current().delegate = self

        // BackgroundScheduler subsumes the old CronSkill. On Mac, bootstrap()
        // migrates legacy crons and starts the DispatchSourceTimer loop that
        // fires jobs at their scheduled hh:mm.
        BackgroundScheduler.shared.bootstrap()

        // Add Mac-only tools to the agent harness: open URLs, launch apps,
        // list installed apps. Done before the coordinator builds its system
        // prompt so the very first message advertises these capabilities.
        AgentHarness.shared.registerSkill(
            tools: MacAppSkill.tools,
            systemPromptFragment: MacAppSkill.systemPromptFragment
        )
        // Register with the headless SkillDispatcher too so scheduled-task
        // runs can fire `open_url` / `open_mac_app` ("open Slack at 9am").
        SkillDispatcher.shared.register(
            handles: { MacAppSkill.shared.handles(functionName: $0) },
            handle: { call, completion in
                MacAppSkill.shared.handle(functionCall: call, completion: completion)
            }
        )

        // Terminal control: run shell commands / start Claude Code sessions
        // in a visible Ghostty (or Terminal.app) window the user can take over.
        AgentHarness.shared.registerSkill(
            tools: TerminalSkill.tools,
            systemPromptFragment: TerminalSkill.systemPromptFragment
        )
        SkillDispatcher.shared.register(
            handles: { TerminalSkill.shared.handles(functionName: $0) },
            handle: { call, completion in
                TerminalSkill.shared.handle(functionCall: call, completion: completion)
            }
        )

        // Image generation. ImageSkill itself is target-agnostic — the iOS
        // build registers it via the global `tools` constant; on Mac we wire
        // it explicitly here, alongside the host plumbing below, so the model
        // is allowed to call generate_image and the result actually paints
        // a bubble in the conversation window.
        AgentHarness.shared.registerSkill(
            tools: ImageSkill.tools,
            systemPromptFragment: ImageSkill.systemPromptFragment
        )

        // PDF generation — same registration shape as ImageSkill. PDFSkill
        // is target-agnostic; the actual WKWebView render happens in
        // PDFGenerationService and posts back via the conversation window
        // as PDFSkillHost (wired below alongside the ImageSkill host).
        AgentHarness.shared.registerSkill(
            tools: PDFSkill.tools,
            systemPromptFragment: PDFSkill.systemPromptFragment
        )

        let initialCoordinator = VoiceLoopCoordinator()
        self.coordinator = initialCoordinator

        let recorder = RecorderWindowController(coordinator: initialCoordinator)
        recorder.showWindow(nil)
        self.recorderController = recorder

        // Floating terminal pill sits above the recorder bar; visible only
        // when the active conversation has a session attached. We give it
        // a weak reference to the recorder so it can anchor its position.
        let pill = TerminalPillWindowController(recorder: recorder)
        self.terminalPillController = pill
        // Initial refresh after the first tab is bootstrapped (which the
        // ConversationWindowController init does synchronously below). A
        // microtask is enough to let SimpleConversationManager catch up.
        DispatchQueue.main.async { pill.refresh() }

        // Conversation window owns the tab manager; it wraps the initial
        // coordinator's presenter internally so we don't assign it here.
        let conversation = ConversationWindowController(
            initialCoordinator: initialCoordinator,
            recorder: recorder
        )
        self.conversationController = conversation
        // ImageGenerationService publishes start/finish callbacks through its
        // weak host; make the conversation window the receiver so generated
        // images render inline.
        ImageGenerationService.shared.host = conversation
        // Same host for PDFGenerationService — the conversation window
        // implements PDFSkillHost and renders the PDF cell when the render
        // completes.
        PDFGenerationService.shared.host = conversation
        // And StoryGenerationService — the conversation window implements
        // StorySkillHost and renders the story card (then the full-screen
        // player on tap) when the HTML render completes.
        StoryGenerationService.shared.host = conversation

        let monitor = HotKeyMonitor()
        // All hotkey closures route through `recorder.coordinator`, which the
        // conversation window keeps pointed at the active tab — so fn+ctrl
        // always drives whichever tab the user is currently looking at.
        monitor.onHoldBegan = { [weak recorder] in
            // Surface the bar even if Loop is in the background — pressing
            // ctrl+fn from another app needs to give the user feedback
            // immediately.
            recorder?.showBar()
            recorder?.flashHotKeyActive(true)
            recorder?.coordinator.startRecording()
        }
        monitor.onHoldEnded = { [weak recorder] in
            recorder?.flashHotKeyActive(false)
            recorder?.coordinator.finishRecording()
            // Leave the user parked on the text input once they stop holding,
            // so they can keep talking to Loop by typing while transcription
            // / thinking / speaking finishes. (If finishRecording bailed via
            // the <1s minimum, onEmptyTranscript also focuses — the double
            // call is harmless and either path keeps the field selected.)
            recorder?.focusTextInput()
        }
        monitor.onTap = { [weak recorder] in
            // A tap is a "stop and switch to text" gesture: if Loop is in
            // the middle of speaking, cut the audio first, then bring up
            // the bar in text-input mode so the user can type a follow-up.
            recorder?.coordinator.stopSpeakingIfNeeded()
            recorder?.focusTextInput()
        }
        monitor.start()
        self.hotKeyMonitor = monitor

        // Start Sparkle before the menu is built so the "Check for Updates…"
        // item can target it. Kicks off the first background update check on
        // launch (subject to SUScheduledCheckInterval) per Info.plist config.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Build the app menu so cmd-Q etc. work — required for any regular
        // (.regular activation policy) AppKit app.
        installAppMenu()

        // Register for remote ConversationStore changes (iPhone wrote
        // something via CloudKit) so the conversation window refreshes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteConversationChanged),
            name: .conversationStoreDidChange,
            object: nil
        )

        // IntegrationSkill asks us to surface the Integrations window (or
        // the system Privacy pane). The skill is target-agnostic and posts
        // a notification rather than importing AppKit.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIntegrationSettingsRequest(_:)),
            name: .integrationSkillRequestedSettings,
            object: nil
        )

        // NavigationSkill follows the same pattern — observes here and
        // routes the panel id to the matching Mac WindowController. Panels
        // without a Mac equivalent (workspace files, conversations, agent
        // immersive view) fall through to no-ops with a debug log. The
        // skill itself is already in the shared `tools` array + AgentHarness
        // systemPrompt, so no registerSkill call is needed here.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNavigationOpenPanel(_:)),
            name: .navigationSkillOpenPanel,
            object: nil
        )

        // Catch URL hand-offs from the share extension (and any future
        // URL-scheme integrations).
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Drain anything the share extension already wrote to the App Group
        // inbox while the app wasn't running. URL handoff covers the live
        // case; this fallback covers cold-start / first-launch scenarios.
        drainSharedInbox()

        // Foreground re-entry pickup so a share dropped while we were
        // backgrounded still surfaces immediately.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        // First-run onboarding (LoopIOS/Specs/3_mac_onboarding_spec.md). Hold
        // the recorder bar offscreen via `isSuppressed` until the user
        // finishes the flow, then hand control back. The hotkey monitor and
        // coordinator are already wired above so step 4 (first ⌃+fn message)
        // works the moment the user reaches it.
        if !MacOnboardingState.isComplete {
            presentOnboarding()
        }
    }

    private func presentOnboarding() {
        guard let coordinator = coordinator,
              let recorder = recorderController else { return }
        let onboarding = OnboardingWindowController(coordinator: coordinator, recorder: recorder)
        onboarding.onCompleted = { [weak self] in
            self?.onboardingController = nil
        }
        self.onboardingController = onboarding
        onboarding.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Recorder bar is the persistent surface — we don't quit when a
        // conversation window is closed.
        return false
    }

    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Mirror the welcome cue in reverse (E5 → A4) at shutdown. Rather than
        // block the main thread on a semaphore (which would wait on
        // AVAudioEngine's lower-QoS render thread and trip the Thread
        // Performance Checker's hang-risk warning), defer termination until the
        // buffer finishes, with a safety timeout so we always quit.
        if isTerminating { return .terminateNow }
        isTerminating = true

        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        EarconPlayer.shared.play(.goodbye) {
            DispatchQueue.main.async { reply() }
        }
        // Guard against the completion never firing (engine stopped, etc.).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { reply() }

        return .terminateLater
    }

    @objc private func remoteConversationChanged() {
        conversationController?.reloadFromStore()
    }

    /// IntegrationSkill posts this when the model calls
    /// `open_integration_settings`. `userInfo["target"]` decides whether we
    /// show the in-app Integrations window (default) or jump to the system
    /// Privacy & Security → Calendars pane.
    @objc private func handleIntegrationSettingsRequest(_ note: Notification) {
        let target = (note.userInfo?["target"] as? String) ?? "in_app"
        DispatchQueue.main.async {
            if target == "calendar_privacy" {
                // Same deep-link URL the IntegrationsListViewController uses
                // when the user clicks a denied Calendar row.
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            IntegrationsWindowController.shared.show()
        }
    }

    /// NavigationSkill posts this when the model calls `open_panel`. Maps the
    /// stable panel id to whichever WindowController Mac has for that
    /// surface. Panels without a Mac equivalent (workspace, conversations,
    /// immersive agent view) raise the conversation window instead so the
    /// user lands somewhere reasonable rather than nothing happening.
    @objc private func handleNavigationOpenPanel(_ note: Notification) {
        let panel = (note.userInfo?["panel"] as? String) ?? ""
        DispatchQueue.main.async { [weak self] in
            switch panel {
            case "integrations":
                IntegrationsWindowController.shared.show()
            case "keys", "settings":
                // No standalone Settings root on Mac — Keys is the main
                // settings window; `settings` resolves there too.
                SettingsWindowController.shared.showKeys()
            case "subagents":
                SubagentsWindowController.shared.show()
            case "scheduled":
                ScheduledTasksWindowController.shared.show()
            case "microphone":
                MicrophoneSettingsWindowController.shared.show()
            case "files", "workspace", "conversations", "skills", "agent", "model":
                // Mac doesn't have these as discrete windows. Surface the
                // conversation window so the user has somewhere to go.
                self?.conversationController?.showAndReload()
            default:
                break
            }
        }
    }

    // MARK: - Share-extension hand-off

    @objc private func appBecameActive() {
        // Foreground fallback: catches shares that landed while the app was
        // backgrounded but didn't successfully wake us via the URL hop.
        drainSharedInbox()
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor,
                                      withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString)
        else { return }

        // We currently only respond to commandintel://share?file=<filename>.
        // Other schemes (e.g. future commandintel://mic) can branch here too.
        if url.scheme == "commandintel" && url.host == "share" {
            handleShareHandoff(url)
        }
    }

    /// Pull the named file out of the App Group inbox, copy it into the
    /// workspace via AttachmentStore, and stage it on the recorder bar so
    /// the user is one prompt + Enter away from sending it.
    private func handleShareHandoff(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let filename = components.queryItems?.first(where: { $0.name == "file" })?.value,
              let inboxURL = SharedInbox.urlForFilename(filename),
              FileManager.default.fileExists(atPath: inboxURL.path)
        else {
            drainSharedInbox()
            return
        }
        do {
            let attachment = try AttachmentStore.shared.saveFromFileURL(inboxURL)
            SharedInbox.remove(inboxURL)
            stageOnRecorder(attachment)
        } catch {
            print("Share handoff copy failed: \(error.localizedDescription)")
        }
    }

    private func drainSharedInbox() {
        SharedInbox.drain { url in
            do {
                let attachment = try AttachmentStore.shared.saveFromFileURL(url)
                stageOnRecorder(attachment)
                return true
            } catch {
                print("Share inbox drain failed for \(url.lastPathComponent): \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Hand the attachment to the recorder bar and surface it so the user
    /// can immediately add a prompt. RecorderWindowController already has
    /// the drag-drop pipeline (`handleDroppedFile`) we want to reuse — wrap
    /// it here so the share path doesn't need a parallel implementation.
    private func stageOnRecorder(_ attachment: FileAttachment) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.recorderController?.stageSharedAttachment(attachment)
        }
    }

    private func installAppMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Loop", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        // Manual update trigger. Targets the Sparkle controller, which also
        // validates the item (greys it out while a check is already running).
        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = updaterController
        appMenu.addItem(checkForUpdatesItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Loop", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Loop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // Tab menu: new (⌘T), close (⌘W), and ⌘1…⌘9 to switch tabs. Lives
        // before Voice/Model so the standard "File → New Tab" muscle memory
        // works (no File menu yet — Tab is the closest analog).
        let tabMenuItem = NSMenuItem()
        mainMenu.addItem(tabMenuItem)
        tabMenuItem.submenu = buildTabMenu()

        // Voice menu: pick TTS provider + Aura voice. Mirrors the iOS speaker
        // menu but slimmed down — Aura, OpenAI HTTP, on-device.
        let voiceMenuItem = NSMenuItem()
        mainMenu.addItem(voiceMenuItem)
        voiceMenuItem.submenu = buildVoiceMenu()

        // Model menu: pick which language model handles the next turn. Two
        // options today (GPT-5.5, Apple Foundation); offline auto-routes to
        // Apple regardless of pick (see AgentHarness.chat).
        let modelMenuItem = NSMenuItem()
        mainMenu.addItem(modelMenuItem)
        modelMenuItem.submenu = AppDelegate.buildModelMenu()
        NotificationCenter.default.addObserver(forName: .modelSelectionChanged, object: nil, queue: .main) { [weak modelMenuItem] _ in
            modelMenuItem?.submenu = AppDelegate.buildModelMenu()
        }

        // Settings menu — currently just "Keys…" but kept as its own top-level
        // menu so future panes (sync, defaults, etc.) drop in beside it.
        let settingsMenuItem = NSMenuItem()
        mainMenu.addItem(settingsMenuItem)
        let settingsMenu = NSMenu(title: "Settings")
        let keysItem = NSMenuItem(
            title: "Keys…",
            action: #selector(openKeysSettings(_:)),
            keyEquivalent: ","
        )
        keysItem.keyEquivalentModifierMask = [.command]
        keysItem.target = self
        settingsMenu.addItem(keysItem)

        let integrationsItem = NSMenuItem(
            title: "Integrations…",
            action: #selector(openIntegrationsSettings(_:)),
            keyEquivalent: ""
        )
        integrationsItem.target = self
        settingsMenu.addItem(integrationsItem)

        let microphoneItem = NSMenuItem(
            title: "Microphone…",
            action: #selector(openMicrophoneSettings(_:)),
            keyEquivalent: ""
        )
        microphoneItem.target = self
        settingsMenu.addItem(microphoneItem)

        let scheduledItem = NSMenuItem(
            title: "Scheduled…",
            action: #selector(openScheduledTasks(_:)),
            keyEquivalent: ""
        )
        scheduledItem.target = self
        settingsMenu.addItem(scheduledItem)

        let subagentsItem = NSMenuItem(
            title: "Subagents…",
            action: #selector(openSubagents(_:)),
            keyEquivalent: ""
        )
        subagentsItem.target = self
        settingsMenu.addItem(subagentsItem)

        settingsMenu.addItem(NSMenuItem.separator())

        let replayOnboardingItem = NSMenuItem(
            title: "Replay Onboarding…",
            action: #selector(replayOnboarding(_:)),
            keyEquivalent: ""
        )
        replayOnboardingItem.target = self
        settingsMenu.addItem(replayOnboardingItem)

        let viewSourceItem = NSMenuItem(
            title: "View Source Code…",
            action: #selector(openSourceRepo(_:)),
            keyEquivalent: ""
        )
        viewSourceItem.target = self
        settingsMenu.addItem(viewSourceItem)

        settingsMenuItem.submenu = settingsMenu

        NSApplication.shared.mainMenu = mainMenu

        // Rebuild the voice menu when the user picks something so the
        // checkmarks update in place.
        NotificationCenter.default.addObserver(forName: .ttsSettingsChanged, object: nil, queue: .main) { [weak voiceMenuItem] _ in
            voiceMenuItem?.submenu = AppDelegate.buildVoiceMenu()
        }
    }

    fileprivate func buildVoiceMenu() -> NSMenu { AppDelegate.buildVoiceMenu() }

    /// Static so the change observer can call it without holding a strong
    /// reference to the AppDelegate.
    fileprivate static func buildVoiceMenu() -> NSMenu {
        let menu = NSMenu(title: "Voice")
        let active = TTSSettings.shared.provider

        for provider in MacTTSProvider.allCases {
            let item = NSMenuItem(
                title: provider.displayName,
                action: #selector(AppDelegate.selectTTSProvider(_:)),
                keyEquivalent: ""
            )
            item.representedObject = provider.rawValue
            item.state = (provider == active) ? .on : .off
            menu.addItem(item)
        }

        // Aura voice picker only makes sense when Aura is the active provider.
        if active == .aura2 {
            menu.addItem(NSMenuItem.separator())
            let header = NSMenuItem(title: "Aura Voice", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let activeVoice = TTSSettings.shared.auraVoice
            for voice in TTSSettings.auraVoices {
                let item = NSMenuItem(
                    title: voice.label,
                    action: #selector(AppDelegate.selectAuraVoice(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = voice.id
                item.state = (voice.id == activeVoice) ? .on : .off
                menu.addItem(item)
            }
        }

        // ElevenLabs voice picker shown for either ElevenLabs model. Picks are
        // stored per-provider so v3 / Flash don't clobber each other.
        if active == .elevenLabsV3 || active == .elevenLabsFlashV25 {
            menu.addItem(NSMenuItem.separator())
            let header = NSMenuItem(title: "ElevenLabs Voice", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let activeVoice = TTSSettings.shared.elevenLabsVoice(for: active)
            for voice in TTSSettings.elevenLabsVoices {
                let item = NSMenuItem(
                    title: voice.label,
                    action: #selector(AppDelegate.selectElevenLabsVoice(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = voice.id
                item.state = (voice.id == activeVoice) ? .on : .off
                menu.addItem(item)
            }
        }

        // OpenAI voice picker only when gpt-4o-mini-tts is the active provider.
        if active == .openAIMiniTTS {
            menu.addItem(NSMenuItem.separator())
            let header = NSMenuItem(title: "OpenAI Voice", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let activeVoice = TTSSettings.shared.openAIVoice
            for voice in TTSSettings.openAIVoices {
                let item = NSMenuItem(
                    title: voice.label,
                    action: #selector(AppDelegate.selectOpenAIVoice(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = voice.id
                item.state = (voice.id == activeVoice) ? .on : .off
                menu.addItem(item)
            }
        }

        return menu
    }

    /// Builds the "Model" top-level menu listing every `ModelSelection` case
    /// with a checkmark next to the active one. Static so the change observer
    /// can rebuild it without holding a strong reference to the AppDelegate.
    fileprivate static func buildModelMenu() -> NSMenu {
        let menu = NSMenu(title: "Model")
        let active = ModelSelectionStore.current

        func modelItem(_ model: ModelSelection) -> NSMenuItem {
            let item = NSMenuItem(
                title: model.displayName,
                action: #selector(AppDelegate.selectModel(_:)),
                keyEquivalent: ""
            )
            item.representedObject = model.rawValue
            item.state = (model == active) ? .on : .off
            return item
        }

        // One section per provider, in `ModelProvider` order (Apple, OpenAI,
        // Anthropic). Single-model providers (Apple) render as a flat item;
        // multi-model providers get a submenu, with the checkmark mirrored
        // onto the parent so the active provider shows without opening it.
        for provider in ModelProvider.allCases {
            let models = ModelSelection.models(for: provider)
            guard !models.isEmpty else { continue }

            if models.count == 1 {
                menu.addItem(modelItem(models[0]))
            } else {
                let submenu = NSMenu(title: provider.displayName)
                models.forEach { submenu.addItem(modelItem($0)) }
                let parent = NSMenuItem(title: provider.displayName,
                                        action: nil, keyEquivalent: "")
                parent.submenu = submenu
                parent.state = (active.provider == provider) ? .on : .off
                menu.addItem(parent)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let footer = NSMenuItem(
            title: "Offline auto-uses Apple Foundation",
            action: nil,
            keyEquivalent: ""
        )
        footer.isEnabled = false
        menu.addItem(footer)
        return menu
    }

    // MARK: - Tab menu

    /// "Tab" top-level menu: New Tab (⌘T), Close Tab (⌘W), and ⌘1…⌘9 to jump
    /// directly to a slot. All actions are routed through the conversation
    /// window's tab manager — the items are no-ops if it isn't loaded yet
    /// (e.g. fired before applicationDidFinishLaunching completes).
    fileprivate func buildTabMenu() -> NSMenu {
        let menu = NSMenu(title: "Tab")

        // ⌘N: "New Conversation" with empty-reuse — see
        // ConversationWindowController.openNewOrReuseEmpty for the dedupe
        // rationale.
        let newConversation = NSMenuItem(title: "New Conversation",
                                         action: #selector(newConversationAction(_:)),
                                         keyEquivalent: "n")
        newConversation.keyEquivalentModifierMask = [.command]
        newConversation.target = self
        menu.addItem(newConversation)

        let newTab = NSMenuItem(title: "New Tab",
                                action: #selector(newTabAction(_:)),
                                keyEquivalent: "t")
        newTab.keyEquivalentModifierMask = [.command]
        newTab.target = self
        menu.addItem(newTab)

        let closeTab = NSMenuItem(title: "Close Tab",
                                  action: #selector(closeTabAction(_:)),
                                  keyEquivalent: "w")
        closeTab.keyEquivalentModifierMask = [.command]
        closeTab.target = self
        menu.addItem(closeTab)

        menu.addItem(NSMenuItem.separator())

        // ⌘1 … ⌘9. Each fires `selectTabAction` with its 0-based index in
        // `representedObject`; the validator below greys out slots that
        // don't have a tab yet.
        for i in 1...9 {
            let item = NSMenuItem(title: "Show Tab \(i)",
                                  action: #selector(selectTabAction(_:)),
                                  keyEquivalent: "\(i)")
            item.keyEquivalentModifierMask = [.command]
            item.representedObject = i - 1
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc fileprivate func newTabAction(_ sender: Any?) {
        conversationController?.openNewTab()
    }

    @objc fileprivate func newConversationAction(_ sender: Any?) {
        conversationController?.openNewOrReuseEmpty()
    }

    @objc fileprivate func closeTabAction(_ sender: Any?) {
        // Fall back to NSWindow's default close when the conversation window
        // isn't around (or its tab manager has no tabs) — that way ⌘W still
        // works on the recorder / settings / scheduled-tasks windows.
        if let conversation = conversationController, !conversation.tabs.isEmpty {
            conversation.closeActiveTab()
            return
        }
        NSApp.keyWindow?.performClose(nil)
    }

    @objc fileprivate func selectTabAction(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        conversationController?.switchToTab(at: index)
    }

    /// Menu validation: grey out ⌘N slots that don't have a tab yet so the
    /// menu accurately reflects what's available. AppKit calls this for any
    /// menu item whose target points at us — we keep it cheap by routing
    /// the rest through `super`'s default (which returns true).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectTabAction(_:)):
            guard let idx = menuItem.representedObject as? Int,
                  let conversation = conversationController else { return false }
            return idx < conversation.tabs.count
        case #selector(closeTabAction(_:)):
            // Always enabled — falls back to the standard close when no tab
            // manager exists, so it should never read as greyed out.
            return true
        default:
            return true
        }
    }

    @objc fileprivate func selectModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let model = ModelSelection(rawValue: raw) else { return }
        ModelSelectionStore.current = model
    }

    @objc fileprivate func selectTTSProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = MacTTSProvider(rawValue: raw) else { return }
        TTSSettings.shared.provider = provider
    }

    @objc fileprivate func selectAuraVoice(_ sender: NSMenuItem) {
        guard let voiceId = sender.representedObject as? String else { return }
        TTSSettings.shared.auraVoice = voiceId
    }

    @objc fileprivate func selectElevenLabsVoice(_ sender: NSMenuItem) {
        guard let voiceId = sender.representedObject as? String else { return }
        let provider = TTSSettings.shared.provider
        guard provider == .elevenLabsV3 || provider == .elevenLabsFlashV25 else { return }
        TTSSettings.shared.setElevenLabsVoice(voiceId, for: provider)
    }

    @objc fileprivate func selectOpenAIVoice(_ sender: NSMenuItem) {
        guard let voiceId = sender.representedObject as? String else { return }
        TTSSettings.shared.openAIVoice = voiceId
    }

    @objc fileprivate func openKeysSettings(_ sender: Any?) {
        SettingsWindowController.shared.showKeys()
    }

    @objc fileprivate func openIntegrationsSettings(_ sender: Any?) {
        IntegrationsWindowController.shared.show()
    }

    @objc fileprivate func openMicrophoneSettings(_ sender: Any?) {
        MicrophoneSettingsWindowController.shared.show()
    }

    @objc fileprivate func openScheduledTasks(_ sender: Any?) {
        ScheduledTasksWindowController.shared.show()
    }

    @objc fileprivate func openSubagents(_ sender: Any?) {
        SubagentsWindowController.shared.show()
    }

    /// Settings → Replay Onboarding…
    /// Asks first (a stray click would otherwise yank the user back to the
    /// welcome page), then resets the flags and re-runs the same flow the
    /// app uses on a fresh install.
    @objc fileprivate func replayOnboarding(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Replay onboarding?"
        alert.informativeText = "You'll see the welcome flow again from the start."
        alert.addButton(withTitle: "Replay")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        MacOnboardingState.isComplete = false
        MacOnboardingState.lastStep = 0
        // The Mac welcome window only covers the platform-specific steps
        // (welcome / accessibility / launch-at-login / "send your first
        // message"). The model pick, key paste, integrations, TTS and name
        // prompts live in the shared conversational coordinator. Without
        // resetting it here, `handleUserText` would see `isComplete == true`
        // from the prior run, return false on the user's first message, and
        // route them straight to the LLM — skipping every chat-side setup
        // step. Mirrors what iOS does in SettingsVC.replayOnboarding().
        OnboardingState.isComplete = false
        OnboardingState.lastStep = 0
        OnboardingCoordinator.shared.resetForReplay()
        OnboardingCoordinator.shared.resumeIfNeeded()
        // Drop any existing onboarding window before opening a fresh one so
        // we don't end up with two stacked welcome panes if the user clicks
        // the menu item twice.
        onboardingController?.close()
        onboardingController = nil
        presentOnboarding()
    }

    @objc fileprivate func openSourceRepo(_ sender: Any?) {
        if let url = URL(string: "https://github.com/getathelas/LoopHarness") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate (scheduler tap routing)

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Surface scheduler banners even while Loop is the foreground app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        if BackgroundScheduler.isSchedulerNotification(userInfo),
           let jobId = userInfo["job_id"] as? String {
            BackgroundScheduler.shared.notificationDidFire(jobId: jobId)
        }
        completionHandler([.banner, .sound, .list])
    }

    /// Notification tap on Mac.
    /// - prefetched: switch the conversation window to the stored transcript.
    /// - fallback:   open a fresh conversation and run the payload's prompt
    ///               through `VoiceLoopCoordinator.sendUserText`.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo
        guard BackgroundScheduler.isSchedulerNotification(userInfo) else { return }

        if let jobId = userInfo["job_id"] as? String {
            BackgroundScheduler.shared.notificationDidFire(jobId: jobId)
        }

        switch BackgroundScheduler.shared.handleTap(userInfo: userInfo) {
        case .openConversation(let conversationId):
            DispatchQueue.main.async { [weak self] in
                guard let conv = SimpleConversationManager.shared.getConversation(by: conversationId) else { return }
                // Route through the tab manager so the conversation either
                // jumps to its existing tab or pops up in a fresh one.
                self?.conversationController?.openConversationInTab(conv)
                self?.conversationController?.showAndReload()
            }

        case .runJobLive(let job, _):
            switch job.payload {
            case .prompt(let user, _):
                DispatchQueue.main.async { [weak self] in
                    let f = DateFormatter(); f.dateFormat = "MMM d"
                    let title = "\(job.title) — \(f.string(from: Date()))"
                    let conv = SimpleConversationManager.shared.createConversation(title: title)
                    self?.conversationController?.openConversationInTab(conv)
                    self?.conversationController?.showAndReload()
                    // sendUserText goes through whichever coordinator is now
                    // active — `openConversationInTab` just made the new
                    // conversation's coordinator the active one.
                    self?.conversationController?.activeCoordinator?.sendUserText(user)
                }
            case .skill:
                // No live-run mapping for raw skill calls; user can press
                // "Run now" in Scheduled Tasks to retry on demand.
                break
            }

        case .unknown:
            break
        }
    }
}

