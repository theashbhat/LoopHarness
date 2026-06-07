//
//  MusicMiniPlayerView.swift
//  Loop
//
//  Compact music mini-player that lives in the top banner scroll view.
//  Two states: minimized pill (track + play/pause) and expanded card
//  (full controls, scrubber, album art). Driven by MusicController state.
//

#if os(iOS)

import UIKit
import MusicKit
import MediaPlayer

// MARK: - MusicMiniPlayerDelegate

protocol MusicMiniPlayerDelegate: AnyObject {
    /// Called when the player visibility changes (show/hide) so the parent
    /// banner can re-layout.
    func musicMiniPlayerVisibilityChanged(_ visible: Bool)
    /// Called when the player expands/collapses so the parent can adjust.
    func musicMiniPlayerDidChangeState(expanded: Bool)
}

// MARK: - MusicMiniPlayerView

final class MusicMiniPlayerView: UIView {

    weak var delegate: MusicMiniPlayerDelegate?

    enum DisplayState {
        case hidden
        case minimized
        case expanded
    }

    private(set) var displayState: DisplayState = .hidden

    // MARK: - Minimized pill subviews

    private let pillContainer = UIView()
    private let pillArtwork = UIImageView()
    private let pillTitleLabel = UILabel()
    private let pillArtistLabel = UILabel()
    private let pillPlayPauseButton = UIButton(type: .system)

    // MARK: - Expanded card subviews

    private let cardContainer = UIView()
    private let cardArtwork = UIImageView()
    private let cardTitleLabel = UILabel()
    private let cardArtistLabel = UILabel()
    private let cardPlayPauseButton = UIButton(type: .system)
    private let cardSkipButton = UIButton(type: .system)
    private let cardCollapseButton = UIButton(type: .system)
    private let cardProgressView = UIProgressView(progressViewStyle: .default)
    private let cardDismissButton = UIButton(type: .system)

    // MARK: - State tracking

    private var pollTimer: Timer?
    private var lastActiveTime: Date?
    private let autoDismissInterval: TimeInterval = 300 // 5 minutes
    private var isUserDismissed = false

    // MARK: - Constraints

    private var pillHeightConstraint: NSLayoutConstraint?
    private var cardHeightConstraint: NSLayoutConstraint?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        setupGestures()
        observeNotifications()
        startPolling()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
        setupGestures()
        observeNotifications()
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .clear
        clipsToBounds = false

        setupPill()
        setupCard()

        // Start hidden
        pillContainer.isHidden = true
        cardContainer.isHidden = true
        pillContainer.alpha = 0
        cardContainer.alpha = 0
    }

    private func setupPill() {
        pillContainer.translatesAutoresizingMaskIntoConstraints = false
        pillContainer.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
        pillContainer.layer.cornerRadius = 18
        pillContainer.layer.borderWidth = 0.5
        pillContainer.layer.borderColor = UIColor.separator.cgColor
        pillContainer.layer.shadowColor = UIColor.black.cgColor
        pillContainer.layer.shadowOpacity = 0.08
        pillContainer.layer.shadowOffset = CGSize(width: 0, height: 2)
        pillContainer.layer.shadowRadius = 6
        addSubview(pillContainer)

        pillArtwork.translatesAutoresizingMaskIntoConstraints = false
        pillArtwork.contentMode = .scaleAspectFill
        pillArtwork.clipsToBounds = true
        pillArtwork.layer.cornerRadius = 4
        pillArtwork.backgroundColor = .systemGray5
        pillArtwork.image = UIImage(systemName: "music.note")
        pillArtwork.tintColor = .secondaryLabel
        pillContainer.addSubview(pillArtwork)

        pillTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        pillTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        pillTitleLabel.textColor = .label
        pillTitleLabel.lineBreakMode = .byTruncatingTail
        pillContainer.addSubview(pillTitleLabel)

        pillArtistLabel.translatesAutoresizingMaskIntoConstraints = false
        pillArtistLabel.font = .systemFont(ofSize: 10, weight: .regular)
        pillArtistLabel.textColor = .secondaryLabel
        pillArtistLabel.lineBreakMode = .byTruncatingTail
        pillContainer.addSubview(pillArtistLabel)

        pillPlayPauseButton.translatesAutoresizingMaskIntoConstraints = false
        pillPlayPauseButton.tintColor = .label
        pillPlayPauseButton.setImage(UIImage(systemName: "pause.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)), for: .normal)
        pillPlayPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        pillContainer.addSubview(pillPlayPauseButton)

        pillHeightConstraint = pillContainer.heightAnchor.constraint(equalToConstant: 36)

        NSLayoutConstraint.activate([
            pillContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            pillContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            pillContainer.topAnchor.constraint(equalTo: topAnchor),
            pillHeightConstraint!,

            pillArtwork.leadingAnchor.constraint(equalTo: pillContainer.leadingAnchor, constant: 8),
            pillArtwork.centerYAnchor.constraint(equalTo: pillContainer.centerYAnchor),
            pillArtwork.widthAnchor.constraint(equalToConstant: 24),
            pillArtwork.heightAnchor.constraint(equalToConstant: 24),

            pillTitleLabel.leadingAnchor.constraint(equalTo: pillArtwork.trailingAnchor, constant: 8),
            pillTitleLabel.topAnchor.constraint(equalTo: pillContainer.topAnchor, constant: 5),
            pillTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pillPlayPauseButton.leadingAnchor, constant: -8),

            pillArtistLabel.leadingAnchor.constraint(equalTo: pillArtwork.trailingAnchor, constant: 8),
            pillArtistLabel.topAnchor.constraint(equalTo: pillTitleLabel.bottomAnchor, constant: 1),
            pillArtistLabel.trailingAnchor.constraint(lessThanOrEqualTo: pillPlayPauseButton.leadingAnchor, constant: -8),

            pillPlayPauseButton.trailingAnchor.constraint(equalTo: pillContainer.trailingAnchor, constant: -10),
            pillPlayPauseButton.centerYAnchor.constraint(equalTo: pillContainer.centerYAnchor),
            pillPlayPauseButton.widthAnchor.constraint(equalToConstant: 28),
            pillPlayPauseButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func setupCard() {
        cardContainer.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.96)
        cardContainer.layer.cornerRadius = 16
        cardContainer.layer.borderWidth = 0.5
        cardContainer.layer.borderColor = UIColor.separator.cgColor
        cardContainer.layer.shadowColor = UIColor.black.cgColor
        cardContainer.layer.shadowOpacity = 0.12
        cardContainer.layer.shadowOffset = CGSize(width: 0, height: 4)
        cardContainer.layer.shadowRadius = 12
        addSubview(cardContainer)

        cardArtwork.translatesAutoresizingMaskIntoConstraints = false
        cardArtwork.contentMode = .scaleAspectFill
        cardArtwork.clipsToBounds = true
        cardArtwork.layer.cornerRadius = 8
        cardArtwork.backgroundColor = .systemGray5
        cardArtwork.image = UIImage(systemName: "music.note")
        cardArtwork.tintColor = .secondaryLabel
        cardArtwork.isUserInteractionEnabled = true
        let artTap = UITapGestureRecognizer(target: self, action: #selector(openInAppleMusic))
        cardArtwork.addGestureRecognizer(artTap)
        cardContainer.addSubview(cardArtwork)

        cardTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        cardTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        cardTitleLabel.textColor = .label
        cardTitleLabel.lineBreakMode = .byTruncatingTail
        cardTitleLabel.isUserInteractionEnabled = true
        let titleTap = UITapGestureRecognizer(target: self, action: #selector(openInAppleMusic))
        cardTitleLabel.addGestureRecognizer(titleTap)
        cardContainer.addSubview(cardTitleLabel)

        cardArtistLabel.translatesAutoresizingMaskIntoConstraints = false
        cardArtistLabel.font = .systemFont(ofSize: 12, weight: .regular)
        cardArtistLabel.textColor = .secondaryLabel
        cardArtistLabel.lineBreakMode = .byTruncatingTail
        cardContainer.addSubview(cardArtistLabel)

        cardProgressView.translatesAutoresizingMaskIntoConstraints = false
        cardProgressView.progressTintColor = .systemPink
        cardProgressView.trackTintColor = .systemGray5
        cardContainer.addSubview(cardProgressView)

        cardPlayPauseButton.translatesAutoresizingMaskIntoConstraints = false
        cardPlayPauseButton.tintColor = .label
        cardPlayPauseButton.setImage(UIImage(systemName: "pause.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)), for: .normal)
        cardPlayPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        cardContainer.addSubview(cardPlayPauseButton)

        cardSkipButton.translatesAutoresizingMaskIntoConstraints = false
        cardSkipButton.tintColor = .label
        cardSkipButton.setImage(UIImage(systemName: "forward.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        cardSkipButton.addTarget(self, action: #selector(skipTrack), for: .touchUpInside)
        cardContainer.addSubview(cardSkipButton)

        cardCollapseButton.translatesAutoresizingMaskIntoConstraints = false
        cardCollapseButton.tintColor = .secondaryLabel
        cardCollapseButton.setImage(UIImage(systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)), for: .normal)
        cardCollapseButton.addTarget(self, action: #selector(collapseToMinimized), for: .touchUpInside)
        cardContainer.addSubview(cardCollapseButton)

        cardDismissButton.translatesAutoresizingMaskIntoConstraints = false
        cardDismissButton.tintColor = .tertiaryLabel
        cardDismissButton.setImage(UIImage(systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)), for: .normal)
        cardDismissButton.addTarget(self, action: #selector(dismissPlayer), for: .touchUpInside)
        cardContainer.addSubview(cardDismissButton)

        cardHeightConstraint = cardContainer.heightAnchor.constraint(equalToConstant: 160)

        NSLayoutConstraint.activate([
            cardContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardContainer.topAnchor.constraint(equalTo: topAnchor),
            cardHeightConstraint!,

            cardCollapseButton.topAnchor.constraint(equalTo: cardContainer.topAnchor, constant: 8),
            cardCollapseButton.centerXAnchor.constraint(equalTo: cardContainer.centerXAnchor),

            cardDismissButton.topAnchor.constraint(equalTo: cardContainer.topAnchor, constant: 8),
            cardDismissButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -12),

            cardArtwork.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: 16),
            cardArtwork.topAnchor.constraint(equalTo: cardCollapseButton.bottomAnchor, constant: 8),
            cardArtwork.widthAnchor.constraint(equalToConstant: 72),
            cardArtwork.heightAnchor.constraint(equalToConstant: 72),

            cardTitleLabel.leadingAnchor.constraint(equalTo: cardArtwork.trailingAnchor, constant: 12),
            cardTitleLabel.topAnchor.constraint(equalTo: cardArtwork.topAnchor, constant: 4),
            cardTitleLabel.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -16),

            cardArtistLabel.leadingAnchor.constraint(equalTo: cardArtwork.trailingAnchor, constant: 12),
            cardArtistLabel.topAnchor.constraint(equalTo: cardTitleLabel.bottomAnchor, constant: 4),
            cardArtistLabel.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -16),

            cardProgressView.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: 16),
            cardProgressView.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -16),
            cardProgressView.topAnchor.constraint(equalTo: cardArtwork.bottomAnchor, constant: 12),

            cardPlayPauseButton.centerXAnchor.constraint(equalTo: cardContainer.centerXAnchor),
            cardPlayPauseButton.topAnchor.constraint(equalTo: cardProgressView.bottomAnchor, constant: 8),
            cardPlayPauseButton.widthAnchor.constraint(equalToConstant: 44),
            cardPlayPauseButton.heightAnchor.constraint(equalToConstant: 44),

            cardSkipButton.leadingAnchor.constraint(equalTo: cardPlayPauseButton.trailingAnchor, constant: 24),
            cardSkipButton.centerYAnchor.constraint(equalTo: cardPlayPauseButton.centerYAnchor),
            cardSkipButton.widthAnchor.constraint(equalToConstant: 36),
            cardSkipButton.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func setupGestures() {
        // Tap pill to expand
        let pillTap = UITapGestureRecognizer(target: self, action: #selector(expandFromPill))
        pillContainer.addGestureRecognizer(pillTap)
        pillContainer.isUserInteractionEnabled = true

        // Swipe down on card to collapse
        let cardSwipeDown = UISwipeGestureRecognizer(target: self, action: #selector(collapseToMinimized))
        cardSwipeDown.direction = .down
        cardContainer.addGestureRecognizer(cardSwipeDown)

        // Swipe left/right on pill to dismiss
        let pillSwipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(dismissPlayer))
        pillSwipeLeft.direction = .left
        pillContainer.addGestureRecognizer(pillSwipeLeft)

        let pillSwipeRight = UISwipeGestureRecognizer(target: self, action: #selector(dismissPlayer))
        pillSwipeRight.direction = .right
        pillContainer.addGestureRecognizer(pillSwipeRight)
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(voiceStateChanged),
            name: .voiceLoopStateDidChange,
            object: nil
        )
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollMusicState()
            }
        }
    }

    @MainActor
    private func pollMusicState() {
        let controller = MusicController.shared
        let player = ApplicationMusicPlayer.shared
        let playbackStatus = player.state.playbackStatus

        let isPlaying = playbackStatus == .playing
        let isPaused = playbackStatus == .paused

        if isPlaying {
            lastActiveTime = Date()
            isUserDismissed = false
        }

        // Determine visibility
        let shouldShow: Bool
        if isUserDismissed {
            shouldShow = false
        } else if isPlaying {
            shouldShow = true
        } else if isPaused, let lastActive = lastActiveTime {
            shouldShow = Date().timeIntervalSince(lastActive) < autoDismissInterval
        } else if controller.nowPlaying != nil && isPaused {
            // Paused but within window
            if lastActiveTime == nil { lastActiveTime = Date() }
            shouldShow = true
        } else {
            shouldShow = false
        }

        if shouldShow && displayState == .hidden {
            transitionTo(.minimized, animated: true)
        } else if !shouldShow && displayState != .hidden {
            transitionTo(.hidden, animated: true)
        }

        // Update content
        if displayState != .hidden {
            updateContent(controller: controller, isPlaying: isPlaying)
        }
    }

    // MARK: - Content Updates

    @MainActor
    private func updateContent(controller: MusicController, isPlaying: Bool) {
        let np = controller.nowPlaying

        let title = np?.title ?? "Not Playing"
        let artist = np?.artist ?? ""

        // Pill
        pillTitleLabel.text = title
        pillArtistLabel.text = artist

        // Card
        cardTitleLabel.text = title
        cardArtistLabel.text = artist

        // Play/pause icon
        let iconName = isPlaying ? "pause.fill" : "play.fill"
        pillPlayPauseButton.setImage(UIImage(systemName: iconName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)), for: .normal)
        cardPlayPauseButton.setImage(UIImage(systemName: iconName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)), for: .normal)

        // Progress
        let player = ApplicationMusicPlayer.shared
        let currentTime = player.playbackTime
        let duration = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? TimeInterval ?? 0
        if duration > 0 {
            cardProgressView.progress = Float(currentTime / duration)
        } else {
            cardProgressView.progress = 0
        }

        // Artwork — use MusicKit's current entry artwork if available
        loadArtwork()
    }

    private func loadArtwork() {
        let player = ApplicationMusicPlayer.shared
        guard let entry = player.queue.currentEntry else { return }

        Task { @MainActor in
            let artworkURL: URL?
            switch entry.item {
            case .song(let song):
                artworkURL = song.artwork?.url(width: 120, height: 120)
            default:
                artworkURL = nil
            }

            guard let url = artworkURL else { return }
            // Load artwork data off main thread, then apply
            let loadedImage = await Task.detached {
                guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
                return UIImage(data: data)
            }.value
            if let image = loadedImage {
                self.pillArtwork.image = image
                self.cardArtwork.image = image
            }
        }
    }

    // MARK: - State Transitions

    func transitionTo(_ state: DisplayState, animated: Bool) {
        guard state != displayState else { return }
        let oldState = displayState
        displayState = state

        let work: () -> Void
        switch state {
        case .hidden:
            work = {
                self.pillContainer.alpha = 0
                self.cardContainer.alpha = 0
            }
        case .minimized:
            pillContainer.isHidden = false
            work = {
                self.pillContainer.alpha = 1
                self.cardContainer.alpha = 0
            }
        case .expanded:
            cardContainer.isHidden = false
            work = {
                self.pillContainer.alpha = 0
                self.cardContainer.alpha = 1
            }
        }

        let completion: (Bool) -> Void = { _ in
            switch state {
            case .hidden:
                self.pillContainer.isHidden = true
                self.cardContainer.isHidden = true
            case .minimized:
                self.cardContainer.isHidden = true
            case .expanded:
                self.pillContainer.isHidden = true
            }

            let wasVisible = oldState != .hidden
            let isVisible = state != .hidden
            if wasVisible != isVisible {
                self.delegate?.musicMiniPlayerVisibilityChanged(isVisible)
            }
            self.delegate?.musicMiniPlayerDidChangeState(expanded: state == .expanded)
        }

        if animated {
            UIView.animate(withDuration: 0.3, delay: 0,
                           usingSpringWithDamping: 0.85,
                           initialSpringVelocity: 0.5,
                           options: [.curveEaseInOut],
                           animations: work,
                           completion: completion)
        } else {
            work()
            completion(true)
        }
    }

    // MARK: - Intrinsic sizing

    var currentHeight: CGFloat {
        switch displayState {
        case .hidden: return 0
        case .minimized: return 44
        case .expanded: return 168
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: currentHeight)
    }

    // MARK: - Actions

    @objc private func togglePlayPause() {
        Task { @MainActor in
            let player = ApplicationMusicPlayer.shared
            if player.state.playbackStatus == .playing {
                MusicController.shared.pause(reason: .userExplicit)
            } else {
                try? await MusicController.shared.userResume()
            }
        }
    }

    @objc private func skipTrack() {
        Task { @MainActor in
            try? await MusicController.shared.skip()
        }
    }

    @objc private func expandFromPill() {
        transitionTo(.expanded, animated: true)
    }

    @objc private func collapseToMinimized() {
        transitionTo(.minimized, animated: true)
    }

    @objc private func dismissPlayer() {
        isUserDismissed = true
        transitionTo(.hidden, animated: true)
    }

    @objc private func openInAppleMusic() {
        // Deep-link to currently playing track in Apple Music
        if let url = URL(string: "music://") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Voice state auto-minimize

    @objc private func voiceStateChanged() {
        let state = VoiceLoopCoordinator.shared.state
        if state == .recording && displayState == .expanded {
            transitionTo(.minimized, animated: true)
        }
    }

    // MARK: - Public API

    /// Call when the user explicitly stopped music via agent command
    func handleMusicStopped() {
        lastActiveTime = nil
        isUserDismissed = false
        transitionTo(.hidden, animated: true)
    }

    /// Reset user dismiss flag (e.g. when new music starts playing)
    func resetDismiss() {
        isUserDismissed = false
    }
}

#endif
