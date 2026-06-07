//
//  TopBannerScrollView.swift
//  Loop
//
//  Horizontally scrollable banner container that hosts the music mini-player.
//  Sits below the sub-agent status bar in the chat view. When the music
//  player is visible, this banner expands; when hidden, it collapses to
//  zero height. The scroll view allows horizontal scrolling if the content
//  is wider than the screen (e.g. future additional banner items).
//

#if os(iOS)

import UIKit

protocol TopBannerScrollViewDelegate: AnyObject {
    func topBannerHeightDidChange()
}

final class TopBannerScrollView: UIView {

    weak var bannerDelegate: TopBannerScrollViewDelegate?

    // MARK: - Subviews

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    /// The music mini-player.
    let musicMiniPlayer = MusicMiniPlayerView()

    /// Height constraint toggled to collapse the entire banner when the
    /// music player is hidden.
    private var heightConstraint: NSLayoutConstraint!

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Setup

    private func setup() {
        backgroundColor = .clear
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.clipsToBounds = false
        addSubview(scrollView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .horizontal
        contentStack.spacing = 8
        contentStack.alignment = .center
        contentStack.distribution = .fill
        scrollView.addSubview(contentStack)

        // Configure music mini-player
        musicMiniPlayer.translatesAutoresizingMaskIntoConstraints = false
        musicMiniPlayer.delegate = self
        contentStack.addArrangedSubview(musicMiniPlayer)

        // Music player width fills available space in minimized, expands in expanded
        let musicWidth = musicMiniPlayer.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        musicWidth.priority = .defaultHigh
        musicWidth.isActive = true

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    // MARK: - Layout refresh

    /// Recalculates the banner height based on the music player state.
    func refreshLayout(animated: Bool = true) {
        let musicVisible = musicMiniPlayer.displayState != .hidden

        let targetHeight: CGFloat
        if musicMiniPlayer.displayState == .expanded {
            targetHeight = musicMiniPlayer.currentHeight + 8
        } else if musicVisible {
            targetHeight = 48
        } else {
            targetHeight = 0
        }

        guard heightConstraint.constant != targetHeight else { return }

        let work = {
            self.heightConstraint.constant = targetHeight
            self.superview?.layoutIfNeeded()
        }

        if animated {
            UIView.animate(withDuration: 0.25, animations: work) { _ in
                self.bannerDelegate?.topBannerHeightDidChange()
            }
        } else {
            work()
            bannerDelegate?.topBannerHeightDidChange()
        }
    }

    /// Conversation scope pass-through (unused here but keeps API consistent).
    var conversationId: String? {
        didSet { /* Music player is global, not conversation-scoped */ }
    }
}

// MARK: - MusicMiniPlayerDelegate

extension TopBannerScrollView: MusicMiniPlayerDelegate {
    func musicMiniPlayerVisibilityChanged(_ visible: Bool) {
        refreshLayout(animated: true)
    }

    func musicMiniPlayerDidChangeState(expanded: Bool) {
        refreshLayout(animated: true)
    }
}

#endif
