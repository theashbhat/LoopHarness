//
//  OnboardingCardView.swift
//  Loop (iOS)
//
//  The interactive card rendered inside a MessagingCell during onboarding.
//  Two layouts:
//   - `.suggestions(options:)` — compact horizontally-wrapping chip row under
//     the bubble text. Tapping a chip fires `.choiceSelected(...)`. The user
//     can also free-type into the bottom messageBox to answer.
//   - `.actionButtonWalkthrough` — the rich hero + numbered Settings steps
//     facsimile, plus an inline [Open Settings] / [Skip for now] chip row at
//     the bottom. Kept inline because the steps are reference material the
//     user needs while configuring iOS Settings.
//
//  Designed to live below an assistant message's prose. Once the user
//  replies, the cell swaps the card kind to `.answered`, the cell tears
//  down this view and the bubble keeps just its text — the chip row goes
//  away cleanly without removing the prompt from the transcript.
//

import UIKit

/// Tap callbacks bubble through here so MessagingVC can forward them to
/// `OnboardingCoordinator.handleCardEvent(_:)`.
protocol OnboardingCardDelegate: AnyObject {
    func onboardingCardDidFire(_ event: OnboardingCardEvent)
}

final class OnboardingCardView: UIView {

    weak var delegate: OnboardingCardDelegate?

    /// Current card kind. Set via `apply(_:delegate:)`; nil means the view is
    /// dormant (recycled cell that no longer needs a card).
    private(set) var currentKind: OnboardingCardKind?

    /// All subviews live inside this stack so resetting the card is one
    /// `removeArrangedSubview` loop instead of bespoke teardown per kind.
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear

        stack.axis = .vertical
        // `.fill` so the ChipFlowView gets the full width of the card area —
        // it self-sizes height to its laid-out chips but needs the parent
        // to dictate width. `.leading` collapsed it to zero-width and chips
        // all rendered at origin (0,0) on top of each other.
        stack.alignment = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset() {
        currentKind = nil
        for sub in stack.arrangedSubviews {
            stack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
    }

    func apply(_ kind: OnboardingCardKind, delegate: OnboardingCardDelegate?) {
        reset()
        self.currentKind = kind
        self.delegate = delegate

        switch kind {
        case .suggestions(let options):
            stack.addArrangedSubview(buildChipRow(options))
        case .actionButtonWalkthrough:
            stack.addArrangedSubview(buildActionButtonWalkthrough())
        case .answered:
            // No subviews — the bubble shows only its prose. We still leave
            // the empty stack in place so the cell's constraints stay valid.
            break
        }
    }

    // MARK: - Chip row

    /// Builds chip rows by chunking chips into horizontal `UIStackView`s
    /// based on a width estimate, then nesting them inside a vertical stack.
    /// Plain auto-layout the whole way down — avoids the layoutSubviews
    /// timing problems of the prior `ChipFlowView` (which set frames manually
    /// from a layoutSubviews pass that fired before bounds were known).
    private func buildChipRow(_ options: [OnboardingChoiceOption]) -> UIView {
        let outer = UIStackView()
        outer.axis = .vertical
        outer.spacing = 8
        outer.alignment = .leading

        // Width budget per row: screen width minus the cell's horizontal
        // padding (20pt each side). On iPad we may have more headroom but
        // capping here yields tighter rows on phones, which is the priority.
        let rowWidthBudget = UIScreen.main.bounds.width - 64
        let chipSpacing: CGFloat = 8

        var rows: [[UIView]] = [[]]
        var rowWidth: CGFloat = 0
        for option in options {
            let chip = makeChip(label: option.label) { [weak self] in
                self?.delegate?.onboardingCardDidFire(
                    .choiceSelected(optionId: option.id, label: option.label))
            }
            let size = chip.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            let withSpacing = (rows[rows.count - 1].isEmpty ? size.width : rowWidth + chipSpacing + size.width)
            if !rows[rows.count - 1].isEmpty && withSpacing > rowWidthBudget {
                rows.append([chip])
                rowWidth = size.width
            } else {
                rows[rows.count - 1].append(chip)
                rowWidth = withSpacing
            }
        }

        for chipsInRow in rows where !chipsInRow.isEmpty {
            let row = UIStackView(arrangedSubviews: chipsInRow)
            row.axis = .horizontal
            row.spacing = chipSpacing
            row.alignment = .center
            outer.addArrangedSubview(row)
        }
        return outer
    }

    /// One pill-shaped tappable chip. Sized to its content via UIStackView
    /// auto-sizing — no manual frame work.
    private func makeChip(label: String, action: @escaping () -> Void) -> UIView {
        let button = OnboardingChipButton(action: action)
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        // A custom mid-tone that has enough contrast against both the white
        // chat background (light mode) and the black chat background (dark
        // mode). `.gray()` was nearly invisible in dark mode against pure
        // black; `secondarySystemFill` reads as a soft pill in both.
        config.baseBackgroundColor = .secondarySystemFill
        config.baseForegroundColor = .label
        var attrs = AttributeContainer()
        attrs.font = .systemFont(ofSize: 14, weight: .medium)
        config.attributedTitle = AttributedString(label, attributes: attrs)
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
        // UIButton.Configuration allows multi-line titles by default, which
        // makes `systemLayoutSizeFitting(.layoutFittingCompressedSize)` (used
        // by buildChipRow's wrap planner) return the narrower wrapped width
        // — so labels like "Stay on Kimi K2.6" ended up rendered on two lines
        // inside their own pill. The line-break mode must be set on the
        // configuration itself: with the Configuration API the button rebuilds
        // its `titleLabel` from the config, so setting `titleLabel.numberOfLines`
        // afterward gets overridden. Pinning the config to single-line tail
        // truncation forces the intrinsic width to the full single-line text,
        // so chips stay pill-shaped and the row planner sees the real width.
        config.titleLineBreakMode = .byTruncatingTail
        button.configuration = config
        return button
    }

    // MARK: - Action button walkthrough

    private func buildActionButtonWalkthrough() -> UIView {
        let hero = makeHeroTile(image: UIImage(named: "ActionButtonGlyph"),
                                background: .systemBlue,
                                size: 60,
                                cornerRadius: 14)
        let heroRow = UIStackView(arrangedSubviews: [UIView(), hero, UIView()])
        heroRow.axis = .horizontal
        heroRow.alignment = .center
        heroRow.distribution = .equalCentering

        // The Action Button row + Choose a Shortcut pill are visual mocks of
        // the Settings UI, but users naturally try to tap them — so they
        // now route through the same `.actionButtonOpenSettings` event the
        // "Open Settings" chip fires. Step 4 ("swipe back to Loop") and
        // step 2's carousel mock aren't really tap targets in the real
        // Settings flow, so they stay non-interactive.
        let openSettings: () -> Void = { [weak self] in
            self?.delegate?.onboardingCardDidFire(.actionButtonOpenSettings)
        }
        let stepsCard = makeStepsCard([
            (1, "Open Settings, then tap Action Button. You may need to swipe back to the root if on a different page in settings",
                makeMockSettingsRow(image: UIImage(named: "ActionButtonGlyph"),
                                    title: "Action Button",
                                    tileColor: .systemBlue,
                                    onTap: openSettings)),
            (2, "Swipe the carousel to the Shortcut option.",
                makeMockShortcutChip()),
            (3, "Tap Choose a Shortcut, then pick Loop → Start Dictation.",
                makeMockChooseShortcutPill(onTap: openSettings)),
            (4, "Swipe back to Loop when you're done.", nil),
        ])

        // Action chips, centered below the walkthrough. Plain UIStackView with
        // spacer views on either side instead of ChipFlowView — at two chips
        // we don't need wrapping, and the spacers give us a clean centered row.
        let openChip = makeChip(label: "Open Settings") { [weak self] in
            self?.delegate?.onboardingCardDidFire(.actionButtonOpenSettings)
        }
        let skipChip = makeChip(label: "Skip for now") { [weak self] in
            self?.delegate?.onboardingCardDidFire(.actionButtonSkip)
        }
        let chipRow = UIStackView(arrangedSubviews: [UIView(), openChip, skipChip, UIView()])
        chipRow.axis = .horizontal
        chipRow.alignment = .center
        chipRow.spacing = 8
        chipRow.distribution = .equalCentering

        let inner = UIStackView(arrangedSubviews: [heroRow, stepsCard, chipRow])
        inner.axis = .vertical
        inner.alignment = .fill
        inner.spacing = 14

        // Wrap the walkthrough in a container card so the steps, hero, and
        // chips read as one grouped unit instead of bare elements floating in
        // the chat. The inner stepsCard keeps its own (lighter) background, so
        // we use `.tertiarySystemGroupedBackground` on the outer card — gives
        // a soft tonal layering in both light and dark mode.
        let card = UIView()
        card.backgroundColor = .tertiarySystemGroupedBackground
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        return card
    }

    // MARK: - Walkthrough building blocks (ported from OnboardingViewController)

    private func makeHeroTile(image: UIImage?, background: UIColor, size: CGFloat, cornerRadius: CGFloat) -> UIView {
        let tile = UIView()
        tile.backgroundColor = background
        tile.layer.cornerRadius = cornerRadius
        tile.layer.cornerCurve = .continuous
        tile.layer.shadowColor = background.cgColor
        tile.layer.shadowOpacity = 0.28
        tile.layer.shadowRadius = 14
        tile.layer.shadowOffset = CGSize(width: 0, height: 8)
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: size),
            tile.heightAnchor.constraint(equalToConstant: size),
        ])
        let glyph = UIImageView(image: image?.withRenderingMode(.alwaysTemplate))
        glyph.tintColor = .white
        glyph.contentMode = .scaleAspectFit
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: size * 0.55),
            glyph.heightAnchor.constraint(equalToConstant: size * 0.55),
        ])
        return tile
    }

    private func makeStepsCard(_ steps: [(Int, String, UIView?)]) -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        for (idx, step) in steps.enumerated() {
            stack.addArrangedSubview(makeStepRow(number: step.0, text: step.1, preview: step.2))
            if idx < steps.count - 1 {
                stack.addArrangedSubview(makeRowSeparator(leftInset: 14 + 24 + 12))
            }
        }
        return card
    }

    private func makeStepRow(number: Int, text: String, preview: UIView?) -> UIView {
        let badge = UILabel()
        badge.text = "\(number)"
        badge.font = .systemFont(ofSize: 12, weight: .bold)
        badge.textColor = .white
        badge.textAlignment = .center
        badge.backgroundColor = .systemBlue
        badge.layer.cornerRadius = 12
        badge.layer.masksToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
        ])

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14)
        label.textColor = .label
        label.numberOfLines = 0

        let textRow = UIStackView(arrangedSubviews: [badge, label])
        textRow.axis = .horizontal
        textRow.alignment = .top
        textRow.spacing = 12

        let column: UIStackView
        if let preview {
            let previewIndent = UIStackView(arrangedSubviews: [preview])
            previewIndent.axis = .horizontal
            previewIndent.isLayoutMarginsRelativeArrangement = true
            previewIndent.layoutMargins = UIEdgeInsets(top: 0, left: 36, bottom: 0, right: 0)
            column = UIStackView(arrangedSubviews: [textRow, previewIndent])
            column.axis = .vertical
            column.alignment = .fill
            column.spacing = 8
        } else {
            column = UIStackView(arrangedSubviews: [textRow])
            column.axis = .vertical
        }

        let wrap = UIView()
        column.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -10),
            column.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -14),
        ])
        return wrap
    }

    private func makeRowSeparator(leftInset: CGFloat) -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        let wrap = UIView()
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: leftInset),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
        ])
        return wrap
    }

    private func makeMockSettingsRow(image: UIImage?,
                                     title: String,
                                     tileColor: UIColor,
                                     onTap: (() -> Void)? = nil) -> UIView {
        let tile = UIView()
        tile.backgroundColor = tileColor
        tile.layer.cornerRadius = 6
        tile.layer.cornerCurve = .continuous
        tile.layer.masksToBounds = true
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 24),
            tile.heightAnchor.constraint(equalToConstant: 24),
        ])
        let glyph = UIImageView(image: image?.withRenderingMode(.alwaysTemplate))
        glyph.tintColor = .white
        glyph.contentMode = .scaleAspectFit
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 15),
            glyph.heightAnchor.constraint(equalToConstant: 15),
        ])
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 13)
        label.textColor = .label
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [tile, label, UIView(), chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        row.backgroundColor = .systemBackground
        row.layer.cornerRadius = 10
        row.layer.cornerCurve = .continuous
        if let onTap = onTap {
            row.isUserInteractionEnabled = true
            row.addGestureRecognizer(ClosureTapRecognizer(action: onTap))
        }
        return row
    }

    private func makeMockShortcutChip() -> UIView {
        let pill = UIView()
        pill.backgroundColor = .systemIndigo
        pill.layer.cornerRadius = 13
        pill.layer.cornerCurve = .continuous
        pill.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pill.widthAnchor.constraint(equalToConstant: 26),
            pill.heightAnchor.constraint(equalToConstant: 44),
        ])
        let icon = UIImageView(image: UIImage(systemName: "square.stack.3d.up.fill"))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        let left = UIImageView(image: UIImage(systemName: "chevron.left"))
        left.tintColor = .quaternaryLabel
        left.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        let right = UIImageView(image: UIImage(systemName: "chevron.right"))
        right.tintColor = .quaternaryLabel
        right.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        let caption = UILabel()
        caption.text = "Shortcut"
        caption.font = .systemFont(ofSize: 12, weight: .semibold)
        caption.textColor = .secondaryLabel
        let row = UIStackView(arrangedSubviews: [left, pill, right, caption, UIView()])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 7
        row.setCustomSpacing(10, after: right)
        return row
    }

    private func makeMockChooseShortcutPill(onTap: (() -> Void)? = nil) -> UIView {
        let plus = UIImageView(image: UIImage(systemName: "plus.circle.fill"))
        plus.tintColor = .systemBlue
        plus.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let label = UILabel()
        label.text = "Choose a Shortcut"
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .systemBlue
        let pill = UIStackView(arrangedSubviews: [plus, label])
        pill.axis = .horizontal
        pill.spacing = 6
        pill.alignment = .center
        pill.isLayoutMarginsRelativeArrangement = true
        pill.layoutMargins = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 14)
        pill.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        pill.layer.cornerRadius = 13
        pill.layer.cornerCurve = .continuous
        if let onTap = onTap {
            pill.isUserInteractionEnabled = true
            pill.addGestureRecognizer(ClosureTapRecognizer(action: onTap))
        }
        let wrap = UIStackView(arrangedSubviews: [pill, UIView()])
        wrap.axis = .horizontal
        return wrap
    }
}

/// UITapGestureRecognizer that owns a closure target. Lets the mock-Settings
/// rows in the action-button walkthrough opt in to tap handling without each
/// caller needing its own target/selector pair. Held strongly by the view
/// it's attached to, so the closure outlives the local that constructed it.
private final class ClosureTapRecognizer: UITapGestureRecognizer {
    private let actionClosure: () -> Void
    init(action: @escaping () -> Void) {
        self.actionClosure = action
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(invoke))
    }
    @objc private func invoke() { actionClosure() }
}

/// Small UIButton subclass that owns its tap closure — saves boilerplate vs.
/// the target/selector dance per button.
private final class OnboardingChipButton: UIButton {
    private let actionClosure: () -> Void

    init(action: @escaping () -> Void) {
        self.actionClosure = action
        super.init(frame: .zero)
        addTarget(self, action: #selector(invoke), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { actionClosure() }
}

