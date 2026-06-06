//
//  OnboardingCoordinator.swift
//  Loop (iOS)
//
//  Drives the conversational onboarding flow that sits inside MessagingVC's
//  chat. Instead of a separate modal wizard, Loop "speaks first" through
//  scripted messages that carry interactive cards (text fields, choice
//  buttons, key paste, action-button walkthrough). The user answers via the
//  cards; the coordinator advances through the script.
//
//  Persistence: `OnboardingState.lastStep` is written *before* each prompt is
//  posted, so killing the app mid-flow resumes at the same card on relaunch.
//

import Foundation

/// Implemented by `MessagingVC`. Lets the coordinator post messages into the
/// chat and signal completion without depending on UIKit internals.
protocol OnboardingCoordinatorHost: AnyObject {
    /// Append a message (assistant or user) to the conversation and reload
    /// the table. Onboarding messages carry an `onboardingCard` and are
    /// excluded from TTS / LLM context by the host.
    func onboardingPostMessage(_ message: MessageStruct)

    /// Swap the existing message's `onboardingCard` to `.answered` so its
    /// chip row collapses away while the prose stays in the transcript.
    /// Called after the user replies (chip tap or free text).
    func onboardingMarkAnswered(messageId: String)

    /// Prefill the bottom messageBox with this text and place the cursor at
    /// the end so the user can edit-and-send. Used for the name step so
    /// "Loop" is one tap away.
    func onboardingPrefillMessageBox(_ text: String)

    /// Make the message bar the first responder (raise the keyboard on iOS,
    /// focus the recorder text field on Mac) so the user can start typing
    /// immediately after a scripted prompt. Coordinator calls this after the
    /// greeting so the open question lands with a cursor ready.
    func onboardingFocusMessageBox()

    /// Open the existing IntegrationsVC connect flow for the named
    /// provider. Today this presents the modal — the user goes through
    /// IntegrationsVC's per-provider flow and dismisses when done.
    func onboardingRequestIntegration(_ kind: OnboardingIntegrationKind)

    /// Onboarding finished (either completed normally or the user skipped
    /// the last step). The host hides any onboarding-only chrome and lets
    /// the regular chat take over.
    func onboardingDidComplete()

    /// Lock/unlock the chat surface during onboarding. While the scripted flow
    /// runs, the user answers through the cards, so the host disables the text
    /// input and the nav-bar controls (settings, speaker, new chat, sidebar)
    /// plus the attachment button. `input` follows the current step — only the
    /// `.keyPaste` and `.done` steps allow typing — while `chrome` is false for
    /// the whole flow and flips true once onboarding completes.
    func onboardingSetInteractionEnabled(input: Bool, chrome: Bool)
}

extension OnboardingCoordinatorHost {
    /// Default no-op so hosts that don't gate their UI during onboarding
    /// (e.g. the Mac panel) compile without implementing this.
    func onboardingSetInteractionEnabled(input: Bool, chrome: Bool) {}
}

/// Events that interactive cards bubble up to the coordinator. The chip /
/// walkthrough cards report user actions through this single enum; the
/// coordinator's per-step switch decides what each event means in context.
enum OnboardingCardEvent: Equatable {
    /// User tapped a suggestion chip. `optionId` matches the chip's
    /// `OnboardingChoiceOption.id` and `label` carries the visible text
    /// (used directly as the user's echo bubble).
    case choiceSelected(optionId: String, label: String)
    /// User tapped "Open Settings" on the action-button walkthrough card.
    case actionButtonOpenSettings
    /// User tapped "Skip for now" on the action-button walkthrough card.
    case actionButtonSkip
}

final class OnboardingCoordinator {

    static let shared = OnboardingCoordinator()

    /// Order matches the script flow. Raw values persist via `OnboardingState.lastStep`,
    /// so don't renumber existing cases — append new ones if the script grows.
    enum StepID: Int {
        case greeting = 0
        case askName
        case modelChoice
        case keyPaste
        case integrationsOffer
        case ttsOffer
        case actionButton
        case done
    }

    weak var host: OnboardingCoordinatorHost?

    /// Set to `true` on platforms that have no Action Button (Mac, Vision).
    /// Causes the script to skip from `.ttsOffer` straight to `.done` instead
    /// of routing through the action-button walkthrough. The Mac host sets
    /// this at app launch, before the chat opens. Default `false` (iOS).
    var skipActionButtonStep: Bool = false

    /// When true, `resumeIfNeeded()` seeds first-launch state but does NOT
    /// auto-post the greeting — instead, `handleUserText` posts the user's
    /// first typed message as a bubble and then fires the greeting in
    /// response. The Mac panel host enables this so the conversation opens
    /// blank (the user types first, the harness greets them back); iOS leaves
    /// it false so the chat surface opens with the script already mid-flight.
    var deferGreetingUntilFirstMessage: Bool = false

    /// Internal latch flipped on by `resumeIfNeeded()` when
    /// `deferGreetingUntilFirstMessage` is honored. Drives the one-shot
    /// "user opener → greeting" reroute in `handleUserText`, then resets so
    /// subsequent typed inputs flow through the regular state machine.
    private var awaitingFirstUserInput: Bool = false

    /// Opaque chip identifiers. Kept here (not in `OnboardingCardKind`)
    /// because their meaning is only relevant inside this coordinator's
    /// switch. Labels are separate so we can tune copy without breaking the
    /// id-based switch logic.
    private enum ChipId {
        static let useDefaultName    = "name.default"
        static let stayOnCurrent     = "model.stay"
        static let modelApple        = "model.apple"
        static let modelClaude       = "model.claude"
        static let modelOpenAI       = "model.openai"
        static let modelFireworks    = "model.fireworks"
        static let skipKey           = "key.skip"
        static let connectNotion     = "integration.notion"
        static let connectGitHub     = "integration.github"
        static let connectSlack      = "integration.slack"
        static let skipIntegrations  = "integration.skip"
        static let voiceSystem       = "tts.system"
        static let voiceDeepgram     = "tts.deepgram"
        static let voiceElevenLabs   = "tts.elevenlabs"
        static let voiceOpenAI       = "tts.openai"
        static let skipTTS           = "tts.skip"
        static let startChatting     = "done.start"
    }

    private(set) var currentStep: StepID = .greeting

    /// Captured between modelChoice → keyPaste so the paste step knows which
    /// provider's key it's collecting. Reset when we advance past keyPaste.
    private var pendingKeyProvider: KeyStore.Key?

    /// When the user picks a cloud TTS provider (Deepgram / ElevenLabs /
    /// OpenAI) that doesn't have a saved key yet, we route through the same
    /// `.keyPaste` step the model flow uses — but we need to remember (a)
    /// which voice provider to enable once the key lands, and (b) which
    /// step to return to afterwards (`.actionButton` for the TTS path,
    /// `.integrationsOffer` for the model path). Both are cleared by
    /// `clearKeyPasteState()` when keyPaste resolves either way.
    private var pendingVoiceProviderRaw: String?
    private var pendingKeyReturnStep: StepID = .integrationsOffer

    /// Id of the most recently posted assistant onboarding bubble. The host
    /// uses this to swap its `onboardingCard` to `.answered` after the user
    /// replies, collapsing the chip row while keeping the prompt visible.
    private var lastPostedMessageId: String?

    /// True while we're posting a scripted message — prevents `handleUserText`
    /// from re-entering during the same run loop tick if the host fires text
    /// callbacks synchronously.
    private var isAdvancing = false

    private init() {}

    // MARK: - Public entry points

    /// Called by MessagingVC after `viewDidLoad`. If onboarding hasn't been
    /// completed, post the prompt for `lastStep` (or `.greeting` if fresh).
    /// Idempotent — a second call inside the same session no-ops because
    /// the messages are already in the chat.
    /// Reset the in-memory "we've already shown the script this session" flag
    /// so a subsequent `resumeIfNeeded()` re-runs the flow from scratch.
    /// Used by Settings → Replay Onboarding so the user gets the new
    /// conversational flow without relaunching the app.
    func resetForReplay() {
        hasResumed = false
        currentStep = .greeting
        pendingKeyProvider = nil
        awaitingFirstUserInput = false
    }

    func resumeIfNeeded() {
        guard !OnboardingState.isComplete else { return }
        if hasResumed { return }
        hasResumed = true

        let resumed = StepID(rawValue: OnboardingState.lastStep) ?? .greeting
        currentStep = resumed

        // First launch: seed the self-docs and pick a sensible starting
        // model. If the user already has a hosted-provider key (TestFlight,
        // Secrets.xcconfig, iCloud-KVS sync), let `ModelSelectionStore`'s
        // default logic pick that provider — pinning Apple would hide a
        // working key and make the greeting inaccurate. Pin Apple only when
        // no hosted key exists.
        if resumed == .greeting {
            AppSignals.emit("onboarding_started")
            if !ModelProvider.hasAnyProviderKey {
                pinAppleFoundationModel()
            }
            AgentHarness.shared.seedSelfDocsIfMissing()
            if deferGreetingUntilFirstMessage {
                // Host wants the greeting to land as a *reply* to the user's
                // opener, so hold the post. `handleUserText` will fire it
                // after echoing the user's bubble.
                awaitingFirstUserInput = true
                return
            }
        }
        post(currentStep)
    }
    private var hasResumed = false

    /// User typed something into the messageBox during onboarding. Drives the
    /// same state machine the chips do — every step has a "what does typed
    /// text mean here?" interpretation. Returns true if we consumed the text
    /// (host should suppress the normal LLM call); false once onboarding is
    /// done so real messages flow through to the model.
    @discardableResult
    func handleUserText(_ text: String) -> Bool {
        guard !OnboardingState.isComplete else { return false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        // Deferred-greeting path (Mac panel): the user's first typed input
        // becomes the conversation opener. Echo it as a plain user bubble,
        // then fire the greeting as if the harness were replying. Reset the
        // latch so subsequent inputs flow through the regular state machine.
        if awaitingFirstUserInput {
            awaitingFirstUserInput = false
            echoUser(trimmed)
            post(.greeting)
            return true
        }

        let lower = trimmed.lowercased()

        switch currentStep {

        case .greeting, .modelChoice:
            // Step 1 is now model setup, not name. Free text is interpreted
            // as a model pick (fuzzy keyword match) — anything else just
            // re-shows the chip row. "stay" / "skip" / a word that matches
            // the current model's display name all keep the active model.
            let current = ModelSelectionStore.current
            let currentProvider = current.provider
            let currentName = current.displayName.lowercased()
            if lower == "stay" || lower == "skip" || lower.contains(currentName) {
                commitAnswer(echo: "Stay on \(current.displayName)")
                advance(to: .integrationsOffer)
            } else if lower.contains("apple") || lower.contains("on-device") {
                guard ModelProvider.isAppleFoundationAvailable else {
                    echoUser(trimmed); break
                }
                let echo = currentProvider == .apple ? "Stay on Apple" : "Use Apple"
                commitAnswer(echo: echo)
                pinAppleFoundationModel()
                advance(to: .integrationsOffer)
            } else if lower.contains("claude") || lower.contains("anthropic") {
                let verb = KeyStore.shared.source(for: .anthropic) != .missing ? "Use" : "Add"
                commitAnswer(echo: "\(verb) Claude")
                pendingKeyProvider = .anthropic
                selectModel(for: .anthropic)
                advanceAfterModelPick(.anthropic)
            } else if lower.contains("openai") || lower.contains("gpt") {
                let verb = KeyStore.shared.source(for: .openAI) != .missing ? "Use" : "Add"
                commitAnswer(echo: "\(verb) OpenAI")
                pendingKeyProvider = .openAI
                selectModel(for: .openAI)
                advanceAfterModelPick(.openAI)
            } else if lower.contains("fireworks") || lower.contains("kimi") {
                let verb = KeyStore.shared.source(for: .fireworks) != .missing ? "Use" : "Add"
                commitAnswer(echo: "\(verb) Fireworks")
                pendingKeyProvider = .fireworks
                selectModel(for: .fireworks)
                advanceAfterModelPick(.fireworks)
            } else {
                echoUser(trimmed)
            }

        case .askName:
            // Deprecated step — onboarding no longer asks the user to name the
            // assistant. Kept in the enum so persisted `lastStep` raw values
            // stay stable; if a user resumes mid-update at this step, just
            // finish onboarding rather than re-prompting for a name.
            advance(to: .done)

        case .keyPaste:
            if lower == "skip" {
                commitAnswer(echo: "Skip for now")
                let returnStep = pendingKeyReturnStep
                // TTS-driven paste was skipped → keep voice off rather than
                // enabling a provider we can't authenticate.
                if pendingVoiceProviderRaw != nil {
                    iCloudKVSDefaults.shared.set(true, forKey: "audioMuted")
                }
                clearKeyPasteState()
                advance(to: returnStep)
                return true
            }
            guard let key = pendingKeyProvider else {
                clearKeyPasteState()
                advance(to: .integrationsOffer)
                return true
            }
            _ = KeyStore.shared.setValue(trimmed, for: key)
            // After the key lands, finish whichever flow brought us here:
            // TTS-mode applies the chosen voice provider; model-mode pins
            // the matching LLM. `clearKeyPasteState` resets both so a
            // subsequent keyPaste visit defaults back to the model path.
            let returnStep = pendingKeyReturnStep
            if let voiceRaw = pendingVoiceProviderRaw {
                selectVoiceProvider(voiceRaw)
            } else {
                selectModel(for: key)
            }
            // Don't echo the secret. Show a masked confirmation instead.
            commitAnswer(echo: "Key saved · \(key.displayName)")
            clearKeyPasteState()
            advance(to: returnStep)

        case .integrationsOffer:
            if lower.contains("notion") {
                commitAnswer(echo: "Connect Notion")
                host?.onboardingRequestIntegration(.notion)
                advance(to: .ttsOffer)
            } else if lower.contains("github") {
                commitAnswer(echo: "Connect GitHub")
                host?.onboardingRequestIntegration(.github)
                advance(to: .ttsOffer)
            } else if lower.contains("slack") {
                commitAnswer(echo: "Connect Slack")
                host?.onboardingRequestIntegration(.slack)
                advance(to: .ttsOffer)
            } else if lower == "skip" || lower == "none" || lower == "no" || lower.contains("later") {
                commitAnswer(echo: "Skip integrations")
                advance(to: .ttsOffer)
            } else {
                echoUser(trimmed)
            }

        case .ttsOffer:
            if lower == "skip" || lower == "no" || lower.contains("later") {
                commitAnswer(echo: "Skip")
                // Match the chip-skip path so a typed dismissal also leaves
                // voice playback off until the user toggles it themselves.
                iCloudKVSDefaults.shared.set(true, forKey: "audioMuted")
                advance(to: .actionButton)
            } else if lower.contains("native") || lower.contains("ios") || lower.contains("apple") || lower.contains("system") {
                commitAnswer(echo: "Native iOS")
                selectVoiceProvider("system")
                advance(to: .actionButton)
            } else if lower.contains("deepgram") || lower.contains("aura") {
                chooseVoice(label: "Deepgram", providerRaw: "aura2", key: .deepgram)
            } else if lower.contains("eleven") {
                chooseVoice(label: "ElevenLabs", providerRaw: "elevenLabsV3", key: .elevenLabs)
            } else if lower.contains("openai") || lower.contains("open ai") {
                chooseVoice(label: "OpenAI", providerRaw: "openAIMiniTTS", key: .openAI)
            } else {
                commitAnswer(echo: trimmed)
                advance(to: .actionButton)
            }

        case .actionButton:
            if lower == "skip" || lower.contains("later") || lower.contains("done") {
                OnboardingState.actionButtonSkipped = true
                commitAnswer(echo: "Skip for now")
                advance(to: .done)
            } else {
                echoUser(trimmed)
            }

        case .done:
            // Any text ends onboarding and the real chat takes over.
            complete()
            return false
        }
        return true
    }

    /// Chip tap handler — every chip is `.choiceSelected(optionId:label:)`,
    /// plus the two action-button-specific events from the walkthrough card.
    func handleCardEvent(_ event: OnboardingCardEvent) {
        guard !OnboardingState.isComplete else { return }

        switch event {

        case .choiceSelected(let id, let label):
            handleChoice(id: id, label: label)

        case .actionButtonOpenSettings:
            // The host opens Settings; the card stays visible so when the
            // user returns they can also tap Skip if they backed out.
            break

        case .actionButtonSkip:
            OnboardingState.actionButtonSkipped = true
            commitAnswer(echo: "Skip for now")
            advance(to: .done)
        }
    }

    private func handleChoice(id: String, label: String) {
        switch (currentStep, id) {

        // Model picks fire from .greeting now (the first step). .modelChoice
        // is kept in the same row only so a user mid-flow at the old `1`
        // raw value resumes onto the same logic.
        case (.greeting, ChipId.stayOnCurrent),
             (.modelChoice, ChipId.stayOnCurrent):
            // "Stay on <current>" — keep whatever the harness is already
            // running (Apple if no key, Fireworks Kimi if a Fireworks key is
            // bundled, etc.). No model write, no key paste.
            commitAnswer(echo: label)
            advance(to: .integrationsOffer)

        case (.greeting, ChipId.modelApple),
             (.modelChoice, ChipId.modelApple):
            commitAnswer(echo: label)
            pinAppleFoundationModel()
            advance(to: .integrationsOffer)

        case (.greeting, ChipId.modelClaude),
             (.modelChoice, ChipId.modelClaude):
            commitAnswer(echo: label)
            pendingKeyProvider = .anthropic
            // Switch to Claude now so the post-onboarding chat lands on
            // Claude even if the user pastes the key seconds later. If they
            // skip the key, they'll still be on Claude — Settings ▸ Keys
            // lets them add it later.
            selectModel(for: .anthropic)
            advanceAfterModelPick(.anthropic)

        case (.greeting, ChipId.modelOpenAI),
             (.modelChoice, ChipId.modelOpenAI):
            commitAnswer(echo: label)
            pendingKeyProvider = .openAI
            selectModel(for: .openAI)
            advanceAfterModelPick(.openAI)

        case (.greeting, ChipId.modelFireworks),
             (.modelChoice, ChipId.modelFireworks):
            commitAnswer(echo: label)
            pendingKeyProvider = .fireworks
            selectModel(for: .fireworks)
            advanceAfterModelPick(.fireworks)

        case (.keyPaste, ChipId.skipKey):
            commitAnswer(echo: label)
            let returnStep = pendingKeyReturnStep
            if pendingVoiceProviderRaw != nil {
                // Skipping the key for a TTS voice — leave audio muted so
                // the assistant doesn't try to use a provider it can't auth.
                iCloudKVSDefaults.shared.set(true, forKey: "audioMuted")
            }
            clearKeyPasteState()
            advance(to: returnStep)

        case (.integrationsOffer, ChipId.connectNotion):
            commitAnswer(echo: label)
            host?.onboardingRequestIntegration(.notion)
            advance(to: .ttsOffer)

        case (.integrationsOffer, ChipId.connectGitHub):
            commitAnswer(echo: label)
            host?.onboardingRequestIntegration(.github)
            advance(to: .ttsOffer)

        case (.integrationsOffer, ChipId.connectSlack):
            commitAnswer(echo: label)
            host?.onboardingRequestIntegration(.slack)
            advance(to: .ttsOffer)

        case (.integrationsOffer, ChipId.skipIntegrations):
            commitAnswer(echo: label)
            advance(to: .ttsOffer)

        case (.ttsOffer, ChipId.voiceSystem):
            commitAnswer(echo: label)
            selectVoiceProvider("system")
            advance(to: .actionButton)

        case (.ttsOffer, ChipId.voiceDeepgram):
            chooseVoice(label: label, providerRaw: "aura2", key: .deepgram)

        case (.ttsOffer, ChipId.voiceElevenLabs):
            chooseVoice(label: label, providerRaw: "elevenLabsV3", key: .elevenLabs)

        case (.ttsOffer, ChipId.voiceOpenAI):
            chooseVoice(label: label, providerRaw: "openAIMiniTTS", key: .openAI)

        case (.ttsOffer, ChipId.skipTTS):
            commitAnswer(echo: label)
            // Skip means "no voice for now" — keep the speaker muted so the
            // assistant stays text-only until the user flips it on from the
            // speaker menu in the nav bar.
            iCloudKVSDefaults.shared.set(true, forKey: "audioMuted")
            advance(to: .actionButton)

        case (.done, ChipId.startChatting):
            complete()

        default:
            // Stale tap from a previously-answered card that the table view
            // re-rendered with chips by mistake. Ignore.
            break
        }
    }

    /// SceneDelegate forwards Action Button presses here. While on the
    /// `.actionButton` step, treat the press as proof the user bound the
    /// shortcut and advance. Returns true if the press was consumed by
    /// onboarding (host can still fall through to start voice transcription —
    /// the binding press doubles as the user's first real voice message).
    @discardableResult
    func handleActionButtonPressed() -> Bool {
        OnboardingState.actionButtonBound = true
        guard !OnboardingState.isComplete, currentStep == .actionButton else { return false }
        commitAnswer(echo: "Pressed Action Button")
        // The press proved the binding works — that's the last onboarding
        // step, so hand straight off to the sign-off.
        advance(to: .done)
        return true
    }

    /// Route past `.keyPaste` when the user already has a key saved for the
    /// chosen provider. Saves a step in the common "I picked Loop on my
    /// phone first, now on Mac" path. Falls through to the regular paste
    /// step when no key exists yet.
    private func advanceAfterModelPick(_ key: KeyStore.Key) {
        if KeyStore.shared.source(for: key) != .missing {
            advance(to: .integrationsOffer)
        } else {
            advance(to: .keyPaste)
        }
    }

    // MARK: - State machine

    private func advance(to step: StepID) {
        // Platforms without an Action Button skip that whole step and go
        // straight to the sign-off. The Mac and Vision hosts set
        // `skipActionButtonStep = true`; iOS leaves it false so the
        // walkthrough still appears (and routes to `.done` itself when the
        // user skips it). Done here (not at each call site) so all the
        // existing `advance(to: .actionButton)` paths route through one place.
        let actualStep: StepID = (step == .actionButton && skipActionButtonStep) ? .done : step
        currentStep = actualStep
        post(actualStep)
        // `.done` is the final step — there's no chip and no follow-up
        // prompt, so finishing here means onboarding is over and the user's
        // next typed message should hit the real LLM. Calling `complete()`
        // immediately after the post flips `OnboardingState.isComplete`
        // before `handleUserText` runs again.
        //
        // Note: this branch only fires when callers explicitly request
        // `.done` — `.actionButton` is rerouted to `.askName` above on
        // platforms that skip the action button, so the name prompt always
        // runs before we land here.
        if actualStep == .done {
            complete()
        }
    }

    private func complete() {
        OnboardingState.isComplete = true
        AppSignals.emit("onboarding_completed")
        // Onboarding is over — hand the full chat surface back to the user.
        host?.onboardingSetInteractionEnabled(input: true, chrome: true)
        host?.onboardingDidComplete()
    }

    /// Post the assistant prompt + card for the given step. Writes
    /// `lastStep` first so a crash between write and post still resumes here.
    /// Captures the new message's id in `lastPostedMessageId` so a later
    /// `commitAnswer(...)` can flip its chips to `.answered`.
    private func post(_ step: StepID) {
        isAdvancing = true
        defer { isAdvancing = false }
        OnboardingState.lastStep = step.rawValue

        let message = makeMessage(for: step)
        lastPostedMessageId = message.id
        host?.onboardingPostMessage(message)

        // Lock the chat chrome for the duration of the scripted flow. Only the
        // key-paste step needs the keyboard (to paste a provider key); `.done`
        // unlocks the input pre-emptively so there's no flicker before
        // `complete()` runs. Nav-bar chrome stays locked until completion.
        host?.onboardingSetInteractionEnabled(
            input: step == .keyPaste || step == .done,
            chrome: false)
    }

    /// Mark the last posted bubble as answered (chips collapse) AND append
    /// the user's echo bubble. Use this for every "user just replied to the
    /// current step" path so the transition is consistent.
    private func commitAnswer(echo text: String) {
        if let id = lastPostedMessageId {
            host?.onboardingMarkAnswered(messageId: id)
            lastPostedMessageId = nil
        }
        echoUser(text)
    }

    /// Plain user echo bubble. Carries `.answered` as a sentinel so the
    /// LLM-context filter still excludes it (`onboardingCard != nil`).
    private func echoUser(_ text: String) {
        var msg = MessageStruct(role: "user", content: text)
        msg.onboardingCard = .answered
        host?.onboardingPostMessage(msg)
    }

    // MARK: - Script

    private func makeMessage(for step: StepID) -> MessageStruct {
        switch step {
        case .greeting, .modelChoice:
            // Step 1 is model setup, not name. Name now comes last (see
            // `.askName` below) so the user picks a working LLM before we
            // ask anything personal. `.modelChoice` shares the same content
            // so a mid-flow user resuming at the old raw value (=1) still
            // sees the right card.
            //
            // Surface "Use X" instead of "Add X" when a key for that
            // provider already exists (typed in via Settings, synced via
            // iCloud-KVS, or bundled). Tapping "Use" skips the key-paste
            // step entirely.
            let current = ModelSelectionStore.current
            let currentProvider = current.provider
            let claudeLabel = KeyStore.shared.source(for: .anthropic) != .missing
                ? "Use Claude" : "Add Claude"
            let openAILabel = KeyStore.shared.source(for: .openAI) != .missing
                ? "Use OpenAI" : "Add OpenAI"
            let fireworksLabel = KeyStore.shared.source(for: .fireworks) != .missing
                ? "Use Fireworks" : "Add Fireworks"
            let greetingText: String
            if ModelProvider.hasAnyProviderKey {
                greetingText = "Nice to meet you! **Let's get set up with this Harness.**\n\nI'm running inference with \(current.displayName). Want to try something else? Tap or type below to plug in a key."
            } else {
                greetingText = "Nice to meet you! **Let's get set up with this Harness.**\n\nI'm running inference with Apple's on-device model right now (free, private, but limited). Want something **more capable**? Plug in a key."
            }

            // First chip always says "Stay on <current model>" and keeps the
            // active selection — the other chips switch to a different
            // provider, and we drop the duplicate for whichever provider is
            // already current.
            var chips: [OnboardingChoiceOption] = [
                .init(id: ChipId.stayOnCurrent, label: "Stay on \(current.displayName)")
            ]
            if currentProvider != .apple && ModelProvider.isAppleFoundationAvailable {
                chips.append(.init(id: ChipId.modelApple, label: "Use Apple"))
            }
            if currentProvider != .anthropic {
                chips.append(.init(id: ChipId.modelClaude, label: claudeLabel))
            }
            if currentProvider != .openAI {
                chips.append(.init(id: ChipId.modelOpenAI, label: openAILabel))
            }
            if currentProvider != .fireworks {
                chips.append(.init(id: ChipId.modelFireworks, label: fireworksLabel))
            }

            return assistantMessage(
                text: greetingText,
                card: .suggestions(options: chips))

        case .askName:
            // Deprecated step (see the `.askName` handler). Mirror the `.done`
            // sign-off so a resumed render never shows the old name prompt.
            return assistantMessage(
                text: "Awesome. We're all set! I'm excited to be at your service. **How can I be helpful?**",
                card: .answered)

        case .keyPaste:
            let provider = pendingKeyProvider ?? .anthropic
            // Slight copy tweak when the paste was triggered from the voice
            // step — makes it clear *why* we're asking for a key in the
            // middle of picking a voice. Model-mode keeps the original copy.
            let lead: String
            if pendingVoiceProviderRaw != nil {
                lead = "To use that voice, paste your \(provider.displayName) key into the **input field below** or **tap the settings gear above** to add it directly to your **private key store**."
            } else {
                lead = "Paste your \(provider.displayName) key into the **input field below** or **tap the settings gear above** to add it directly to your **private key store**."
            }
            return assistantMessage(
                text: "\(lead) Your keys are stored in your **keychain** and inference calls are made **directly to providers** from this device.",
                card: .suggestions(options: [
                    .init(id: ChipId.skipKey, label: "Skip for now"),
                ]))

        case .integrationsOffer:
            return assistantMessage(
                text: "Want to **connect any tools**? You can also add more later from Settings.",
                card: .suggestions(options: [
                    .init(id: ChipId.connectNotion,    label: "Notion"),
                    .init(id: ChipId.connectGitHub,    label: "GitHub"),
                    .init(id: ChipId.connectSlack,     label: "Slack"),
                    .init(id: ChipId.skipIntegrations, label: "Skip"),
                ]))

        case .ttsOffer:
            return assistantMessage(
                text: "**Pick a voice** for replies. You can change it anytime from the speaker menu.",
                card: .suggestions(options: [
                    .init(id: ChipId.voiceSystem,     label: "Native iOS"),
                    .init(id: ChipId.voiceDeepgram,   label: "Deepgram"),
                    .init(id: ChipId.voiceElevenLabs, label: "ElevenLabs"),
                    .init(id: ChipId.voiceOpenAI,    label: "OpenAI"),
                    .init(id: ChipId.skipTTS,         label: "Skip"),
                ]))

        case .actionButton:
            return assistantMessage(
                text: "One last thing — bind your iPhone's **Action Button** so you can talk to me from anywhere.",
                card: .actionButtonWalkthrough)

        case .done:
            // Terminal message. We no longer ask the user to name the
            // assistant, so this is the single sign-off that hands the
            // conversation over to the real chat. No chip — the message bar
            // is the obvious next step.
            return assistantMessage(
                text: "Awesome. We're all set! I'm excited to be at your service. **How can I be helpful?**",
                card: .answered)
        }
    }

    private func assistantMessage(text: String, card: OnboardingCardKind) -> MessageStruct {
        var msg = MessageStruct(role: "assistant", content: text)
        msg.onboardingCard = card
        return msg
    }

    // MARK: - TTS selection side effects

    /// Persist a voice-provider choice from the TTS onboarding step. Writes
    /// the same `ttsProvider` iCloud key the speaker menu in `MessagingVC`
    /// reads from, and clears `audioMuted` so the assistant actually speaks.
    /// `rawValue` is one of the cases in `TTSProvider` ("system", "aura2",
    /// "elevenLabsV3", "openAIMiniTTS") — passed as a string to keep this
    /// helper independent of the enum's definition in MessagingVC.
    private func selectVoiceProvider(_ rawValue: String) {
        iCloudKVSDefaults.shared.set(rawValue, forKey: "ttsProvider")
        iCloudKVSDefaults.shared.set(false, forKey: "audioMuted")
    }

    /// True when a non-empty key is saved for `key`. Used by the TTS step to
    /// decide whether the user can use a cloud voice immediately or needs to
    /// paste a key first.
    private func hasKey(_ key: KeyStore.Key) -> Bool {
        guard let v = KeyStore.shared.value(for: key) else { return false }
        return !v.isEmpty
    }

    /// Apply a cloud TTS choice. If the matching key is already saved, jump
    /// straight to `.actionButton`. Otherwise route through `.keyPaste`
    /// stashing the voice provider so it gets enabled after the key lands.
    /// Either way, `label` is echoed as the user's reply bubble.
    private func chooseVoice(label: String, providerRaw: String, key: KeyStore.Key) {
        commitAnswer(echo: label)
        if hasKey(key) {
            selectVoiceProvider(providerRaw)
            advance(to: .actionButton)
        } else {
            pendingKeyProvider = key
            pendingVoiceProviderRaw = providerRaw
            pendingKeyReturnStep = .actionButton
            advance(to: .keyPaste)
        }
    }

    /// Reset the state the `.keyPaste` step uses to remember why it's open.
    /// Called when keyPaste resolves either way (key saved, or skipped) so
    /// the next visit defaults back to the model-paste flow rather than
    /// carrying TTS state into an unrelated path.
    private func clearKeyPasteState() {
        pendingKeyProvider = nil
        pendingVoiceProviderRaw = nil
        pendingKeyReturnStep = .integrationsOffer
    }

    // MARK: - Name extraction

    /// Tighten the LLM's reply down to a single short token suitable for a
    /// name field. Strips quotes, takes the first line, caps the length, and
    /// falls back to the user's original input if the model returned junk.
    static func sanitizeExtractedName(_ raw: String, fallback: String) -> String {
        let trimmedLine = raw
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stripped = trimmedLine
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“”‘’!?"))
            .trimmingCharacters(in: .whitespaces)
        // Guardrails: empty, suspiciously long (model rambled), or a refusal
        // ("I cannot…") all fall back to the raw input.
        if stripped.isEmpty || stripped.count > 40 || stripped.lowercased().hasPrefix("i ") {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return stripped
    }

    // MARK: - Model selection side effects

    /// Pin Apple Foundation Model so the user can chat immediately, even on
    /// dev builds that ship with a bundled Fireworks key. Routes through
    /// `ModelSelectionStore.current` (not raw `iCloudKVSDefaults.set`) so
    /// the `modelSelectionChanged` notification fires for any listeners.
    private func pinAppleFoundationModel() {
        ModelSelectionStore.current = .appleFoundation
    }

    /// Set the flagship model for the given provider as the active selection
    /// so the next message routes through it. Called when the user picks a
    /// provider chip (Claude/OpenAI/Fireworks) AND again when they actually
    /// paste a key — both writes are idempotent. Mirrors what ModelPickerVC
    /// does.
    private func selectModel(for key: KeyStore.Key) {
        let selection: ModelSelection?
        switch key {
        case .anthropic: selection = .claudeSonnet46
        case .openAI:    selection = .gpt55
        case .fireworks: selection = .fireworksKimiK26
        default:         selection = nil
        }
        if let s = selection {
            ModelSelectionStore.current = s
        }
    }
}
