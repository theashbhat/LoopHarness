//
//  StoryDemoVC.swift
//  Loop
//
//  Demo view controller that showcases the Stories feature end-to-end:
//  data in → HTML story out → rendered in the app. Shows a scrollable list
//  of sample story cards (inline thumbnails) that tap to open the full-screen
//  story player.
//

#if os(iOS)

import UIKit

final class StoryDemoVC: UIViewController {

    // MARK: - Sample data

    private struct SampleStory {
        let title: String
        let template: StoryAttachment.Template
        let data: [String: Any]
    }

    private let samples: [SampleStory] = [
        SampleStory(
            title: "Morning Hike",
            template: .activitySummary,
            data: [
                "icon": "🥾",
                "title": "Morning Hike",
                "subtitle": "Mt. Tamalpais Trail",
                "metrics": [
                    ["emoji": "📏", "label": "Distance", "value": "12.4", "unit": "mi"],
                    ["emoji": "⛰️", "label": "Elevation", "value": "2,340", "unit": "ft"],
                    ["emoji": "👟", "label": "Steps", "value": "15,280", "unit": ""],
                    ["emoji": "🔥", "label": "Calories", "value": "890", "unit": "kcal"],
                ],
                "goal": [
                    "current": 12.4,
                    "target": 10.0,
                    "label": "distance goal",
                    "caption": "You exceeded your 10-mile goal by 24%! 🎉",
                ] as [String: Any],
                "timeline": [
                    ["time": "6:30 AM", "text": "Started at Pantoll trailhead"],
                    ["time": "7:15 AM", "text": "Reached West Point Inn viewpoint"],
                    ["time": "8:00 AM", "text": "Summit! Clear views of the Bay"],
                    ["time": "8:45 AM", "text": "Descended via Dipsea Trail"],
                    ["time": "9:30 AM", "text": "Back at trailhead — 3h total"],
                ],
            ]
        ),
        SampleStory(
            title: "Daily Recap",
            template: .dailyRecap,
            data: [
                "emoji": "📊",
                "title": "Your Tuesday",
                "subtitle": "June 3, 2025",
                "stats": [
                    ["emoji": "✉️", "value": "47", "label": "Emails"],
                    ["emoji": "📅", "value": "6", "label": "Meetings"],
                    ["emoji": "✅", "value": "12", "label": "Tasks Done"],
                    ["emoji": "💬", "value": "23", "label": "Messages"],
                ],
                "goals": [
                    ["label": "Deep Work", "current": 3.5, "target": 4.0] as [String: Any],
                    ["label": "Exercise", "current": 45, "target": 30] as [String: Any],
                    ["label": "Reading", "current": 15, "target": 30] as [String: Any],
                ],
                "highlights": [
                    ["emoji": "🚀", "text": "Shipped the stories feature prototype"],
                    ["emoji": "🏃", "text": "Personal best on morning run (5K in 22:30)"],
                    ["emoji": "📖", "text": "Started reading 'Designing Data-Intensive Applications'"],
                    ["emoji": "🎵", "text": "Discovered a new playlist for focus work"],
                ],
            ]
        ),
    ]

    // MARK: - State

    private var renderedStories: [(SampleStory, StoryAttachment)] = []
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Stories Demo"
        view.backgroundColor = UIColor.systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(dismissSelf)
        )

        setupScrollView()
        generateStories()
    }

    // MARK: - Setup

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        stackView.axis = .vertical
        stackView.spacing = 24
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 24),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
        ])
    }

    // MARK: - Generation

    private func generateStories() {
        StoryGenerationService.shared.host = self

        for sample in samples {
            let attachment = StoryGenerationService.shared.submit(
                title: sample.title,
                template: sample.template,
                data: sample.data
            )
            renderedStories.append((sample, attachment))
            addStoryCard(for: sample, attachment: attachment)
        }
    }

    private func addStoryCard(for sample: SampleStory, attachment: StoryAttachment) {
        let card = StoryCardView()
        card.configure(title: sample.title, template: sample.template, status: attachment.status)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.onTap = { [weak self] in
            self?.openStory(attachment: attachment)
        }
        stackView.addArrangedSubview(card)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            card.heightAnchor.constraint(equalToConstant: 400),
        ])
    }

    private func openStory(attachment: StoryAttachment) {
        guard attachment.status == .ready else { return }
        let playerVC = StoryPlayerVC()
        playerVC.storyAttachment = attachment
        playerVC.modalPresentationStyle = .fullScreen
        present(playerVC, animated: true)
    }

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }
}

// MARK: - StorySkillHost

extension StoryDemoVC: StorySkillHost {
    func storySkillDidStartGenerating(_ attachment: StoryAttachment) {
        // Could show a loading indicator on the card
    }

    func storySkillDidFinishGenerating(_ attachment: StoryAttachment) {
        // Update the card + store the ready attachment
        for i in 0..<renderedStories.count {
            if renderedStories[i].1.id == attachment.id {
                renderedStories[i].1 = attachment
                if let card = stackView.arrangedSubviews[i] as? StoryCardView {
                    card.configure(
                        title: renderedStories[i].0.title,
                        template: renderedStories[i].0.template,
                        status: attachment.status
                    )
                    if attachment.status == .ready, let url = attachment.fileURL {
                        card.loadPreview(fileURL: url)
                    }
                }
                break
            }
        }
    }
}

// MARK: - Story Card (inline thumbnail)

/// A tappable card that shows a story thumbnail in chat or the demo list.
final class StoryCardView: UIView {

    var onTap: (() -> Void)?

    private let titleLabel = UILabel()
    private let templateBadge = UILabel()
    private let statusLabel = UILabel()
    private let playerView = StoryPlayerView()
    private let overlayGradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = UIColor.secondarySystemBackground
        layer.cornerRadius = 20
        clipsToBounds = true

        // Player view (inline thumbnail)
        playerView.isInlineMode = true
        playerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Bottom overlay
        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.heightAnchor.constraint(equalToConstant: 100),
        ])
        overlayGradient.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.7).cgColor,
        ]
        overlay.layer.addSublayer(overlayGradient)

        // Title
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Template badge
        templateBadge.font = .systemFont(ofSize: 12, weight: .medium)
        templateBadge.textColor = UIColor.white.withAlphaComponent(0.7)
        templateBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(templateBadge)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            templateBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            templateBadge.bottomAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -4),
        ])

        // Status (for loading/error states)
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Tap gesture
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlayGradient.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 100)
    }

    func configure(title: String, template: StoryAttachment.Template, status: StoryAttachment.Status) {
        titleLabel.text = title
        templateBadge.text = template.rawValue.uppercased()

        switch status {
        case .generating:
            statusLabel.text = "Generating…"
            statusLabel.isHidden = false
            playerView.isHidden = true
        case .ready:
            statusLabel.isHidden = true
            playerView.isHidden = false
        case .failed:
            statusLabel.text = "Failed to generate"
            statusLabel.isHidden = false
            playerView.isHidden = true
        }
    }

    func loadPreview(fileURL: URL) {
        playerView.isHidden = false
        statusLabel.isHidden = true
        playerView.loadStory(fileURL: fileURL)
    }

    @objc private func tapped() {
        onTap?()
    }
}

#endif
