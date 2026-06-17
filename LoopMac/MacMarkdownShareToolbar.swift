//
//  MacMarkdownShareToolbar.swift
//  LoopMac
//
//  Bottom toolbar for markdown preview surfaces on macOS. Contains a Share
//  button that triggers NSSharingServicePicker with the raw markdown source.
//  Styled to match the existing Loop visual language.
//

import AppKit

final class MacMarkdownShareToolbar: NSView {

    // MARK: - Public

    var onShare: (() -> Void)?

    /// The bounds/view needed for anchoring NSSharingServicePicker.
    var shareButtonBounds: NSRect { shareButton.bounds }
    var shareButtonView: NSView { shareButton }

    // MARK: - Subviews

    private let separator = NSBox()
    private let shareButton: NSButton = {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.bezelStyle = .recessed
        b.isBordered = false
        b.image = NSImage(systemSymbolName: "square.and.arrow.up",
                          accessibilityDescription: "Share")
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        b.contentTintColor = .labelColor
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        addSubview(separator)

        shareButton.target = self
        shareButton.action = #selector(shareTapped)
        addSubview(shareButton)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            shareButton.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            shareButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shareButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            shareButton.widthAnchor.constraint(equalToConstant: 28),
            shareButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @objc private func shareTapped() { onShare?() }
}
