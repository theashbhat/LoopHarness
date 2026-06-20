//
//  AgentLargeView.swift
//  Loop
//
//  Immersive "large-mode" view: a floating orb as primary visual focus with a
//  live readout strip underneath. Presented when the user taps the compact
//  nav-bar avatar. Renders three streams of data:
//
//    1. The orb itself — driven by VoiceLoopCoordinator.shared.state, so it
//       lights up cyan while listening, purple while thinking, green while
//       speaking. Matches the nav-bar avatar 1:1 so the expansion feels like a
//       continuation rather than a separate component.
//    2. A status caption directly under the orb — the current shimmer string
//       (Thinking…, "saving note to Notion", etc.).
//    3. A vertical ticker of the most recent activity log entries —
//       tool calls, sub-agent ticks, thoughts. Older entries fade out at the
//       top so the strip feels alive without growing unbounded.
//
//  The view is a plain UIView so the hosting controller stays free to drive
//  pan-to-dismiss / present animation without subclassing baggage.
//

#if os(iOS)

import UIKit

/// Implemented by whoever can drive the existing MessageBox voice pipeline.
/// `AgentLargeView` doesn't own its own STT — it just signals user intent and
/// lets the host (MessagingVC, via its messageBox) actually record + send.
/// This keeps the heavy `MessageBox` (~68KB, owns audio engine + waveform +
/// attachments) out of the expanded view, while still letting the orb be a
/// fully-functional voice surface.
protocol AgentLargeViewVoiceDelegate: AnyObject {
    /// Long-press began — start capturing mic input.
    func agentLargeViewDidBeginVoice()
    /// Long-press ended naturally — send what was captured.
    func agentLargeViewDidEndVoice()
    /// Long-press was interrupted (gesture cancelled, view dismissed) — drop
    /// the recording without sending. Important so a half-captured phrase
    /// doesn't fire off into the model on a stray gesture.
    func agentLargeViewDidCancelVoice()
    /// Current TTS mute state, so the speaker button in the agent view can
    /// render the right icon (speaker.wave vs speaker.slash) without
    /// duplicating the persistence layer.
    func agentLargeViewIsMuted() -> Bool
    /// Flip the TTS mute state and stop any in-flight speech immediately if
    /// the user just muted. Mirrors the nav-bar speaker button so toggling
    /// from either surface lands in the same place.
    func agentLargeViewDidToggleMute()
}

final class AgentLargeView: UIView {

    /// Whoever wants to receive press-and-hold voice events. Set by the host
    /// controller before the view animates in.
    weak var voiceDelegate: AgentLargeViewVoiceDelegate?


    /// Hero orb. Sized to dominate the upper half of the screen — same
    /// component used on the empty-state hero and the nav bar, just larger.
    let avatar = AvatarView(gridW: 25, gridH: 25, pixelSize: 12, baseRadius: 7.5)

    /// One-line status caption directly under the orb. Mirrors the
    /// MessagingVC shimmer text so the user sees the same "Thinking…" copy
    /// whether they're in chat or in large mode.
    private let statusLabel = UILabel()

    /// Small chevron-down above the orb. The whole sheet is drag-to-dismiss
    /// (and tap-the-orb-to-dismiss), so the affordance is just a quiet visual
    /// cue rather than a button — kept tertiary so it doesn't compete with
    /// the orb.
    private let dismissHint = UIImageView()

    /// Top-right speaker toggle. Mirrors the nav-bar speaker button so the
    /// user can flip TTS on/off without leaving the expanded view. State and
    /// behavior are funnelled through `voiceDelegate` so this view stays
    /// ignorant of how mute is persisted (iCloudKVS-backed bool, currently
    /// owned by MessagingVC).
    private let muteButton = UIButton(type: .system)

    /// Press-and-hold capsule sitting above the sub-agent row. The expanded
    /// view is voice-first, so the pill is the dominant input affordance —
    /// hold to record, release to send. No tap behavior on purpose (text
    /// composition still lives on the underlying MessagingVC's message box).
    private let voicePill = UIView()
    private let voicePillIcon = UIImageView()
    private let voicePillLabel = UILabel()
    /// Horizontal stack that holds the icon + label as one visual unit so
    /// the pair stays centered inside the pill regardless of label width.
    /// Without this, fixed leading/trailing constraints leave the icon
    /// hugging the left edge while the label stretches into empty space —
    /// the group reads as left-aligned even though the pill itself is
    /// centered on screen.
    private let voicePillContent = UIStackView()
    /// Tracks whether the press-and-hold gesture is currently active so the
    /// pill's appearance can flip without re-querying gesture state.
    private var isVoicePillHeld = false {
        didSet { applyVoicePillStyle() }
    }
    /// Haptic engine for the press/release edges. Lazy so we don't spin up
    /// CoreHaptics for users who never touch the pill.
    private let pressFeedback = UIImpactFeedbackGenerator(style: .medium)

    /// Vertical ticker of recent activity. We rebuild this from
    /// `AgentActivityLog.shared.entries` on every refresh; cap at
    /// `maxTickerLines` so the layout stays calm.
    private let tickerStack = UIStackView()
    private let tickerContainer = UIView()
    private let tickerMask = CAGradientLayer()

    /// Live sub-agent chips along the bottom. One pill per alive agent with
    /// its title + current step. Hidden when there are no sub-agents.
    private let subAgentScroll = UIScrollView()
    private let subAgentStack = UIStackView()

    /// Backdrop that pulses subtly with the orb's current mode — a radial
    /// vignette in the orb's tint color, super low opacity so the orb still
    /// reads as the focal element. Sits behind everything.
    private let backdrop = CAGradientLayer()

    /// How many ticker rows we keep on screen. Kept low so the strip stays
    /// calm and the orb remains the focal element.
    private let maxTickerLines = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        subscribe()
        refresh(animated: false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
        subscribe()
        refresh(animated: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .systemBackground

        // Ambient backdrop. The colors are dialed in per-mode on `refresh`.
        backdrop.type = .radial
        backdrop.startPoint = CGPoint(x: 0.5, y: 0.35)
        backdrop.endPoint = CGPoint(x: 1.2, y: 1.2)
        backdrop.colors = [
            UIColor.label.withAlphaComponent(0.05).cgColor,
            UIColor.clear.cgColor
        ]
        layer.insertSublayer(backdrop, at: 0)

        avatar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(avatar)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 17, weight: .medium)
        statusLabel.textColor = .label
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.8
        statusLabel.text = "Press and hold to talk"
        addSubview(statusLabel)

        dismissHint.translatesAutoresizingMaskIntoConstraints = false
        let chevronConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        dismissHint.image = UIImage(systemName: "chevron.compact.down", withConfiguration: chevronConfig)
        dismissHint.tintColor = .tertiaryLabel
        dismissHint.contentMode = .scaleAspectFit
        addSubview(dismissHint)

        setupMuteButton()
        setupVoicePill()

        tickerContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tickerContainer)

        tickerStack.translatesAutoresizingMaskIntoConstraints = false
        tickerStack.axis = .vertical
        tickerStack.alignment = .center
        tickerStack.distribution = .equalSpacing
        tickerStack.spacing = 6
        tickerContainer.addSubview(tickerStack)

        // Fade older lines into the background at the top of the ticker.
        // Built once and resized in layoutSubviews.
        tickerMask.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.4).cgColor,
            UIColor.black.cgColor,
            UIColor.black.cgColor
        ]
        tickerMask.locations = [0.0, 0.25, 0.65, 1.0]
        tickerMask.startPoint = CGPoint(x: 0.5, y: 0.0)
        tickerMask.endPoint = CGPoint(x: 0.5, y: 1.0)
        tickerContainer.layer.mask = tickerMask

        subAgentScroll.translatesAutoresizingMaskIntoConstraints = false
        subAgentScroll.showsHorizontalScrollIndicator = false
        subAgentScroll.contentInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        addSubview(subAgentScroll)

        subAgentStack.translatesAutoresizingMaskIntoConstraints = false
        subAgentStack.axis = .horizontal
        subAgentStack.alignment = .center
        subAgentStack.spacing = 8
        subAgentScroll.addSubview(subAgentStack)

        NSLayoutConstraint.activate([
            dismissHint.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 18),
            dismissHint.centerXAnchor.constraint(equalTo: centerXAnchor),
            dismissHint.heightAnchor.constraint(equalToConstant: 18),

            muteButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            muteButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            muteButton.widthAnchor.constraint(equalToConstant: 44),
            muteButton.heightAnchor.constraint(equalToConstant: 44),

            avatar.centerXAnchor.constraint(equalTo: centerXAnchor),
            // The AvatarView draws its 25×25 grid from origin (0,0) at the
            // configured pixelSize, so its content extents are exactly its
            // intrinsicContentSize (300×300 here). Constraining to a smaller
            // box clips the right/bottom edges of the grid and visually
            // shifts the orb up-left — match the intrinsic so it centers.
            avatar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 64),
            avatar.widthAnchor.constraint(equalToConstant: 300),
            avatar.heightAnchor.constraint(equalToConstant: 300),

            statusLabel.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),

            tickerContainer.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            tickerContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            tickerContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            tickerContainer.bottomAnchor.constraint(equalTo: voicePill.topAnchor, constant: -16),

            tickerStack.bottomAnchor.constraint(equalTo: tickerContainer.bottomAnchor),
            tickerStack.leadingAnchor.constraint(equalTo: tickerContainer.leadingAnchor),
            tickerStack.trailingAnchor.constraint(equalTo: tickerContainer.trailingAnchor),
            tickerStack.topAnchor.constraint(greaterThanOrEqualTo: tickerContainer.topAnchor),

            voicePill.centerXAnchor.constraint(equalTo: centerXAnchor),
            voicePill.bottomAnchor.constraint(equalTo: subAgentScroll.topAnchor, constant: -16),
            voicePill.heightAnchor.constraint(equalToConstant: 56),
            voicePill.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            voicePill.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            voicePill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),

            // Center the icon+label group as a unit. The stack hugs its
            // content, so the pill auto-sizes around it; min width of 200
            // (above) sets the floor so short labels don't collapse to a
            // tiny capsule.
            voicePillContent.centerXAnchor.constraint(equalTo: voicePill.centerXAnchor),
            voicePillContent.centerYAnchor.constraint(equalTo: voicePill.centerYAnchor),
            voicePillContent.leadingAnchor.constraint(greaterThanOrEqualTo: voicePill.leadingAnchor, constant: 20),
            voicePillContent.trailingAnchor.constraint(lessThanOrEqualTo: voicePill.trailingAnchor, constant: -20),

            voicePillIcon.widthAnchor.constraint(equalToConstant: 22),
            voicePillIcon.heightAnchor.constraint(equalToConstant: 22),

            subAgentScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            subAgentScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            subAgentScroll.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -24),
            subAgentScroll.heightAnchor.constraint(equalToConstant: 34),

            subAgentStack.topAnchor.constraint(equalTo: subAgentScroll.topAnchor),
            subAgentStack.bottomAnchor.constraint(equalTo: subAgentScroll.bottomAnchor),
            subAgentStack.leadingAnchor.constraint(equalTo: subAgentScroll.leadingAnchor),
            subAgentStack.trailingAnchor.constraint(equalTo: subAgentScroll.trailingAnchor),
            subAgentStack.heightAnchor.constraint(equalTo: subAgentScroll.heightAnchor),
        ])
    }

    /// Build the press-and-hold capsule. Kept in its own helper so the main
    /// `setupViews` reads as a layout outline rather than a wall of style.
    private func setupVoicePill() {
        voicePill.translatesAutoresizingMaskIntoConstraints = false
        voicePill.layer.cornerRadius = 28
        voicePill.layer.borderWidth = 1
        voicePill.layer.borderColor = UIColor.separator.cgColor
        voicePill.isUserInteractionEnabled = true
        addSubview(voicePill)

        voicePillIcon.contentMode = .scaleAspectFit
        voicePillIcon.setContentHuggingPriority(.required, for: .horizontal)
        voicePillIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        let micConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        voicePillIcon.image = UIImage(systemName: "mic.fill", withConfiguration: micConfig)

        voicePillLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        voicePillLabel.textAlignment = .left
        voicePillLabel.setContentHuggingPriority(.required, for: .horizontal)

        voicePillContent.translatesAutoresizingMaskIntoConstraints = false
        voicePillContent.axis = .horizontal
        voicePillContent.alignment = .center
        voicePillContent.spacing = 10
        voicePillContent.isUserInteractionEnabled = false
        voicePillContent.addArrangedSubview(voicePillIcon)
        voicePillContent.addArrangedSubview(voicePillLabel)
        voicePill.addSubview(voicePillContent)

        // Long-press fires immediately on touch-down so the gesture feels
        // like a button hold, not a delayed activation. The system default
        // (0.5s) is far too slow for a press-to-talk affordance.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleVoicePressGesture(_:)))
        press.minimumPressDuration = 0.05
        press.allowableMovement = 60
        voicePill.addGestureRecognizer(press)

        applyVoicePillStyle()
    }

    /// Top-right speaker toggle. Visual style matches the nav-bar mute
    /// button (medium-weight SF Symbol, secondaryLabel tint) so jumping
    /// between the chat and the expanded view doesn't shift the user's
    /// expectation of what "the speaker button" looks like.
    private func setupMuteButton() {
        muteButton.translatesAutoresizingMaskIntoConstraints = false
        muteButton.tintColor = .secondaryLabel
        muteButton.addTarget(self, action: #selector(handleMuteTapped), for: .touchUpInside)
        addSubview(muteButton)
        applyMuteButtonStyle()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        tickerMask.frame = tickerContainer.bounds
    }

    /// Toggle everything except the backdrop and the orb. Used by the present
    /// transition to hold the labels/pill/ticker back until the orb has flown
    /// into place — otherwise the chrome lands at full opacity before the orb
    /// arrives, which reads as the labels "showing up early." The orb itself
    /// is driven separately by `AvatarPopAnimator`.
    func setChromeHidden(_ hidden: Bool, animated: Bool) {
        let chrome: [UIView] = [
            statusLabel, dismissHint, muteButton,
            voicePill, tickerContainer, subAgentScroll,
        ]
        let apply = { chrome.forEach { $0.alpha = hidden ? 0 : 1 } }
        if animated {
            UIView.animate(withDuration: 0.25, animations: apply)
        } else {
            apply()
        }
    }

    // MARK: - Voice pill

    /// Pump the current voice coordinator state + held flag into the pill's
    /// visual style. Called any time the held flag flips or the underlying
    /// recording state changes — keeps the pill in sync without each call
    /// site having to know every visual rule.
    private func applyVoicePillStyle() {
        let state = VoiceLoopCoordinator.shared.state
        let isRecording = state == .recording
        let tint: UIColor
        let label: String
        let textColor: UIColor
        let icon: String
        switch (isVoicePillHeld, isRecording, state) {
        case (true, true, _), (true, _, _):
            // User is actively holding — show "Recording…" even if the
            // coordinator hasn't flipped to .recording yet (mic permission
            // may still be resolving).
            tint = .systemRed
            icon = "waveform"
            label = "Recording…"
            textColor = .white
        case (_, _, .thinking), (_, _, .transcribing):
            tint = .secondarySystemBackground
            icon = "ellipsis"
            label = "Working…"
            textColor = .label
        case (_, _, .speaking):
            tint = .secondarySystemBackground
            icon = "speaker.wave.2.fill"
            label = "Hold to interject"
            textColor = .label
        default:
            tint = .secondarySystemBackground
            icon = "mic.fill"
            label = "Hold to talk"
            textColor = .label
        }
        voicePill.backgroundColor = tint
        voicePillLabel.text = label
        voicePillLabel.textColor = textColor
        voicePillIcon.tintColor = textColor
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        voicePillIcon.image = UIImage(systemName: icon, withConfiguration: config)
    }

    // MARK: - Mute button

    /// Refresh the speaker icon from the delegate's current mute state.
    /// Called on init, on stateDidChange, and right after the user taps it.
    private func applyMuteButtonStyle() {
        let muted = voiceDelegate?.agentLargeViewIsMuted() ?? false
        let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        let name = muted ? "speaker.slash" : "speaker.wave.2"
        muteButton.setImage(UIImage(systemName: name, withConfiguration: cfg), for: .normal)
        muteButton.accessibilityLabel = muted ? "Turn on voice playback" : "Turn off voice playback"
    }

    @objc private func handleMuteTapped() {
        voiceDelegate?.agentLargeViewDidToggleMute()
        applyMuteButtonStyle()
    }

    /// Forward the press-and-hold lifecycle to the voice delegate. `.began`
    /// fires immediately because we set `minimumPressDuration = 0.05`, so it
    /// reads as a touch-down for users. `.ended` is the natural release —
    /// send. `.cancelled` covers gesture interruptions (e.g. the system
    /// reclaiming touches for a notification or the view being dismissed
    /// mid-press) — drop without sending so a half-captured phrase doesn't
    /// fire off.
    @objc private func handleVoicePressGesture(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            isVoicePillHeld = true
            pressFeedback.prepare()
            pressFeedback.impactOccurred()
            voiceDelegate?.agentLargeViewDidBeginVoice()
        case .ended:
            isVoicePillHeld = false
            pressFeedback.impactOccurred(intensity: 0.6)
            voiceDelegate?.agentLargeViewDidEndVoice()
        case .cancelled, .failed:
            isVoicePillHeld = false
            voiceDelegate?.agentLargeViewDidCancelVoice()
        default:
            break
        }
    }

    // MARK: - Observation

    private func subscribe() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityDidChange),
            name: .agentActivityDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityDidChange),
            name: .subAgentsDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateDidChange),
            name: .voiceLoopStateDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(amplitudeDidChange),
            name: .voiceLoopAmplitudeDidChange, object: nil)
    }

    @objc private func activityDidChange() {
        DispatchQueue.main.async { [weak self] in self?.refresh(animated: true) }
    }

    @objc private func stateDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.applyVoiceState()
        }
    }

    @objc private func amplitudeDidChange() {
        avatar.amplitude = VoiceLoopCoordinator.shared.latestAmplitude
    }

    // MARK: - Refresh

    /// Pulls the latest state from the coordinator and the activity log and
    /// rebuilds the visible UI. Idempotent — cheap enough to call on every
    /// notification.
    func refresh(animated: Bool) {
        applyVoiceState()
        applyMuteButtonStyle()
        rebuildTicker(animated: animated)
        rebuildSubAgentChips()
    }

    /// Map VoiceLoopCoordinator's state onto avatar mode + caption + backdrop
    /// tint. Kept tiny so the orb's color is the single point of truth — the
    /// caption and backdrop just echo it.
    private func applyVoiceState() {
        let state = VoiceLoopCoordinator.shared.state
        let mode: AvatarView.Mode
        let caption: String
        let tint: UIColor
        switch state {
        case .idle:
            mode = .idle
            // Default to a hint that matches the pill's affordance. The
            // most-recent activity entry would also be reasonable here, but
            // it bleeds stale tool-call copy ("reading X.md") into the idle
            // state long after the round-trip finished — confusing when the
            // user just opened the expanded view fresh.
            caption = "Press and hold to talk"
            tint = UIColor.label
        case .recording:
            mode = .listening
            caption = "Listening…"
            tint = .systemCyan
        case .transcribing:
            mode = .thinking
            caption = "Transcribing…"
            tint = .systemPurple
        case .thinking:
            mode = .thinking
            // Drive the caption off the currently-active tool set, not the
            // entries log. The log is append-only — scanning it for "the last
            // toolCall" sticks on the first call of a parallel batch even
            // after that tool finishes and another is still running. The
            // active set increments per dispatch and decrements per result,
            // so the caption tracks real in-flight work.
            let log = AgentActivityLog.shared
            switch log.activeCallCount {
            case 0:
                caption = "Thinking…"
            case 1:
                caption = log.mostRecentActiveSummary ?? "Thinking…"
            default:
                let recent = log.mostRecentActiveSummary ?? ""
                caption = recent.isEmpty
                    ? "running \(log.activeCallCount) tools"
                    : "running \(log.activeCallCount) tools\n\(recent)"
            }
            tint = .systemPurple
        case .speaking:
            mode = .speaking
            caption = "Speaking…"
            tint = .systemGreen
        }
        avatar.mode = mode
        statusLabel.text = caption
        backdrop.colors = [
            tint.withAlphaComponent(0.18).cgColor,
            UIColor.clear.cgColor
        ]
        applyVoicePillStyle()
    }

    /// Pulls the last `maxTickerLines` entries off the activity log and
    /// renders them oldest-on-top. Older lines render dimmer + smaller — the
    /// fade-out mask then carries them off the top edge.
    private func rebuildTicker(animated: Bool) {
        let recent = Array(AgentActivityLog.shared.entries.suffix(maxTickerLines))
        // Reuse rows if the count matches; otherwise rebuild the stack so we
        // don't try to animate stale labels.
        if tickerStack.arrangedSubviews.count != recent.count {
            tickerStack.arrangedSubviews.forEach {
                tickerStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            for _ in 0..<recent.count {
                let row = makeTickerRow()
                tickerStack.addArrangedSubview(row)
            }
        }
        for (i, entry) in recent.enumerated() {
            guard let row = tickerStack.arrangedSubviews[i] as? UIStackView,
                  let dot = row.arrangedSubviews.first,
                  let label = row.arrangedSubviews.last as? UILabel else { continue }
            // Newer entries (higher index) feel more present.
            let freshness = Double(i + 1) / Double(max(1, recent.count))
            let alpha = CGFloat(0.35 + 0.65 * freshness)
            label.alpha = alpha
            dot.alpha = alpha
            label.text = entry.summary
            label.textColor = .secondaryLabel
            dot.backgroundColor = color(for: entry.kind)
        }
        if animated {
            UIView.animate(withDuration: 0.2) { self.tickerStack.layoutIfNeeded() }
        }
    }

    /// One ticker row — a small colored dot on the left, the summary on the
    /// right. Centered as a unit so the strip feels like a single column.
    private func makeTickerRow() -> UIStackView {
        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer.cornerRadius = 2.5
        dot.widthAnchor.constraint(equalToConstant: 5).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 5).isActive = true

        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.textAlignment = .left

        let row = UIStackView(arrangedSubviews: [dot, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func color(for kind: AgentActivityLog.Kind) -> UIColor {
        switch kind {
        case .status:     return .systemGray
        case .toolCall:   return .systemBlue
        case .toolResult: return .systemTeal
        case .thought:    return .systemPurple
        case .subAgent:   return .systemOrange
        }
    }

    /// Show one chip per alive sub-agent. The chip is intentionally minimal —
    /// title + current step. Tapping a chip opens the existing inspector if
    /// the host wires `onSubAgentTap`.
    private func rebuildSubAgentChips() {
        let live = SubAgentManager.shared.liveAgents
        subAgentScroll.isHidden = live.isEmpty
        subAgentStack.arrangedSubviews.forEach {
            subAgentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for agent in live {
            let chip = makeSubAgentChip(for: agent)
            subAgentStack.addArrangedSubview(chip)
        }
    }

    private func makeSubAgentChip(for agent: SubAgent) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor.tertiarySystemBackground
        container.layer.cornerRadius = 14
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.separator.cgColor

        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer.cornerRadius = 3
        dot.backgroundColor = agent.state == .active ? .systemGreen : .systemYellow

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .label
        let title = agent.displayTitle
        let step = agent.currentStep
        let trimmed = step.isEmpty ? title : "\(title.prefix(28)) · \(step)"
        label.text = String(trimmed.prefix(60))

        container.addSubview(dot)
        container.addSubview(label)
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 28),
            dot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }
}

#endif
