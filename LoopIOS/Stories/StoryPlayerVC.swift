//
//  StoryPlayerVC.swift
//  Loop
//
//  Full-screen story viewer. Presented modally when the user taps a story
//  card in chat. Displays the story at native 1080×1920 resolution scaled
//  to fill the screen, with tap-to-advance navigation and a close button.
//

#if os(iOS)

import UIKit

final class StoryPlayerVC: UIViewController {

    // MARK: - Public

    /// The story attachment to display. Set before presentation.
    var storyAttachment: StoryAttachment?

    /// Alternatively, load from raw HTML string (for demo/preview).
    var rawHTML: String?

    // MARK: - Subviews

    private let playerView = StoryPlayerView()
    private let closeButton = UIButton(type: .system)
    private let progressBar = UIProgressView(progressViewStyle: .bar)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        modalPresentationStyle = .fullScreen

        setupPlayerView()
        setupCloseButton()
        setupProgressBar()
        loadContent()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: - Setup

    private func setupPlayerView() {
        playerView.isInlineMode = false
        playerView.delegate = self
        playerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: view.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupCloseButton() {
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        closeButton.layer.cornerRadius = 18
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func setupProgressBar() {
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.trackTintColor = UIColor.white.withAlphaComponent(0.2)
        progressBar.progressTintColor = .white
        progressBar.progress = 0
        view.addSubview(progressBar)
        NSLayoutConstraint.activate([
            progressBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            progressBar.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -12),
            progressBar.heightAnchor.constraint(equalToConstant: 3),
        ])
    }

    private func loadContent() {
        if let attachment = storyAttachment, let fileURL = attachment.fileURL {
            playerView.loadStory(fileURL: fileURL)
        } else if let html = rawHTML {
            playerView.loadStoryHTML(html)
        }
        playerView.startAutoPlay()
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}

// MARK: - StoryPlayerViewDelegate

extension StoryPlayerVC: StoryPlayerViewDelegate {
    func storyPlayerDidFinish(_ player: StoryPlayerView) {
        // Could auto-dismiss or loop
        progressBar.setProgress(1.0, animated: true)
    }

    func storyPlayerDidRequestFullScreen(_ player: StoryPlayerView) {
        // Already full-screen; no-op.
    }
}

#endif
