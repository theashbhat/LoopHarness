//
//  MarkdownShareToolbar.swift
//  Loop
//
//  A minimal, reusable toolbar pinned to the bottom of markdown preview
//  surfaces. Contains a single Share action that triggers the native share
//  sheet with the raw markdown source text. Styled to match the existing
//  Loop visual language — subtle separator, system background, SF Symbol
//  icon.
//

import UIKit

final class MarkdownShareToolbar: UIView {

    // MARK: - Public

    /// Invoked when the user taps the Share button. The host is responsible
    /// for presenting `UIActivityViewController` with the appropriate text.
    var onShare: (() -> Void)?

    /// The frame of the share button in this view's coordinate space, for
    /// anchoring the activity popover on iPad.
    var shareButtonFrame: CGRect { shareButton.frame }

    // MARK: - Subviews

    private let separator = UIView()
    private let shareButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "square.and.arrow.up")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 16, weight: .medium)
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        let b = UIButton(configuration: config)
        b.accessibilityLabel = "Share"
        return b
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Setup

    private func setup() {
        backgroundColor = .systemBackground

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = .separator
        addSubview(separator)

        shareButton.translatesAutoresizingMaskIntoConstraints = false
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        addSubview(shareButton)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            shareButton.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            shareButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            shareButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        // Intrinsic height comes from the button; no explicit height needed.
    }

    @objc private func shareTapped() { onShare?() }
}
