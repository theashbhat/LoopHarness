//
//  FeedCardStackView.swift
//  Loop
//
//  Swipeable stack of feed cards shown on the empty new-chat screen. The top
//  card is draggable in either direction; flinging it cycles it to the back of
//  the deck, so the user can swipe through cards endlessly. Tap opens the
//  card's detail; long-press shows a menu to delete. Cards behind peek out,
//  scaled down, and rise into place as the top card flies off.
//
//  This is the only surface that browses cards now — there is no Feed tab in
//  the side drawer. Each rendered card reuses the same poster asset the feed
//  renderers produce (CardStore.posterURL).
//

#if os(iOS)
import UIKit

final class FeedCardStackView: UIView {

    // MARK: - Callbacks

    var onTap: ((Card) -> Void)?
    /// Fired when the user deletes a card (long-press → Delete). The host is
    /// responsible for removing it from the store.
    var onDelete: ((Card) -> Void)?
    /// Fired when the deck becomes empty (e.g. the last card was deleted) so
    /// the host can restore the orb / empty state.
    var onEmptied: (() -> Void)?

    // MARK: - State

    /// Remaining cards, top of the stack first.
    private var cards: [Card] = []
    /// Live card views, parallel to `cards` for the first `maxVisible` entries.
    private var cardViews: [CardPosterView] = []

    private let maxVisible = 3
    private let swipeThreshold: CGFloat = 100
    /// True while a pan is actively driving the top card, so layout passes don't
    /// stomp the drag transform back to identity mid-gesture.
    private var isDragging = false
    /// Vertical peek + scale falloff per depth level behind the top card.
    private let peekOffset: CGFloat = 14
    private let scaleStep: CGFloat = 0.06

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        // One pan + tap on the stack itself, always driving the current top
        // card. Attaching to the stack (not each card) means the card under the
        // finger and the card we move are guaranteed to be the same one, and
        // there's no stale per-card gesture to track backwards.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - API

    /// Replace the stack contents and rebuild the visible cards.
    func setCards(_ cards: [Card]) {
        self.cards = cards
        rebuild()
    }

    var isEmpty: Bool { cards.isEmpty }

    // MARK: - Build

    private func rebuild() {
        cardViews.forEach { $0.removeFromSuperview() }
        cardViews.removeAll()

        // Build from back to front so the top card ends up on top in z-order.
        let count = min(cards.count, maxVisible)
        for depth in (0..<count).reversed() {
            let cardView = makeCardView(for: cards[depth])
            addSubview(cardView)
            cardViews.insert(cardView, at: 0) // keep index 0 == top
        }

        setNeedsLayout()
        layoutIfNeeded()
        // Re-apply resting transforms without animation on a full rebuild.
        applyStackTransforms(animated: false)
    }

    /// Create a configured card view wired to the delete menu.
    private func makeCardView(for card: Card) -> CardPosterView {
        let cardView = CardPosterView()
        cardView.configure(with: card)
        cardView.onDeleteRequested = { [weak self] card in
            self?.deleteCard(card)
        }
        return cardView
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // All cards share the same frame; depth is expressed via transform so
        // the fling animation can interpolate cleanly.
        for cardView in cardViews {
            cardView.frame = bounds
        }
        applyStackTransforms(animated: false)
    }

    /// Position each card by depth: deeper cards sit lower and smaller.
    private func applyStackTransforms(animated: Bool) {
        let apply = {
            for (depth, cardView) in self.cardViews.enumerated() {
                // Never reset the top card while the user is dragging it — the
                // pan handler owns its transform until the gesture ends.
                if depth == 0 && self.isDragging { continue }
                if depth == 0 {
                    // Top card rests at full size, centered. (During a drag the
                    // pan handler owns this transform; this method isn't called
                    // mid-drag.)
                    cardView.transform = .identity
                } else {
                    let scale = 1 - self.scaleStep * CGFloat(depth)
                    let y = self.peekOffset * CGFloat(depth)
                    cardView.transform = CGAffineTransform(scaleX: scale, y: scale)
                        .concatenating(CGAffineTransform(translationX: 0, y: y))
                }
            }
        }
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8,
                           initialSpringVelocity: 0, options: [.allowUserInteraction], animations: apply)
        } else {
            apply()
        }
    }

    // MARK: - Gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let card = cards.first else { return }
        onTap?(card)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let top = cardViews.first else { return }
        let translation = gesture.translation(in: self)

        switch gesture.state {
        case .began:
            isDragging = true

        case .changed:
            let rotation = (translation.x / max(bounds.width, 1)) * 0.32 // up to ~18°
            // Set the translation components explicitly so the card always
            // tracks the finger 1:1 regardless of the rotation applied.
            var t = CGAffineTransform(rotationAngle: rotation)
            t.tx = translation.x
            t.ty = translation.y * 0.4
            top.transform = t

        case .ended, .cancelled, .failed:
            isDragging = false
            let velocity = gesture.velocity(in: self)
            if translation.x > swipeThreshold || velocity.x > 800 {
                fling(top, toRight: true)
            } else if translation.x < -swipeThreshold || velocity.x < -800 {
                fling(top, toRight: false)
            } else {
                // Below threshold: snap back to the resting (centered) position.
                UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7,
                               initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                    top.transform = .identity
                }
            }
        default:
            break
        }
    }

    /// Animate the top card off-screen, then cycle it to the back of the deck.
    private func fling(_ cardView: CardPosterView, toRight: Bool) {
        let offX: CGFloat = toRight ? bounds.width * 1.6 : -bounds.width * 1.6
        let rotation: CGFloat = toRight ? 0.4 : -0.4

        UIView.animate(withDuration: 0.3, animations: {
            cardView.transform = CGAffineTransform(translationX: offX, y: 0).rotated(by: rotation)
            cardView.alpha = 0
        }, completion: { _ in
            cardView.removeFromSuperview()
            self.advance()
        })
    }

    /// Cycle the flung top card to the back of the deck and promote the rest,
    /// so the deck repeats endlessly.
    private func advance() {
        guard !cards.isEmpty else { return }
        // Rotate the deck: the card we just flung goes to the back.
        let flung = cards.removeFirst()
        cards.append(flung)
        if !cardViews.isEmpty { cardViews.removeFirst() }

        // Refill the back of the visible stack from the rotated deck.
        if cards.count > cardViews.count {
            let cardView = makeCardView(for: cards[cardViews.count])
            cardView.frame = bounds
            insertSubview(cardView, at: 0) // behind everything
            cardViews.append(cardView)
        }

        applyStackTransforms(animated: true)
    }

    /// Permanently drop a card from the deck (long-press → Delete).
    private func deleteCard(_ card: Card) {
        onDelete?(card)
        cards.removeAll { $0.id == card.id }
        rebuild()
        if cards.isEmpty { onEmptied?() }
    }
}

// MARK: - Gesture delegate

extension FeedCardStackView: UIGestureRecognizerDelegate {
    /// Only let the swipe begin on a predominantly horizontal drag, so it
    /// doesn't fight vertical gestures from the surrounding chat.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard !cardViews.isEmpty else { return false }
        let v = pan.velocity(in: self)
        return abs(v.x) >= abs(v.y)
    }
}

// MARK: - Card poster view

/// A single poster card: image (or dark placeholder), bottom title overlay,
/// and a kind badge. Long-press surfaces a delete menu via context interaction.
private final class CardPosterView: UIView {

    /// The card this view currently shows.
    private var card: Card?
    /// Invoked when the user picks Delete from the long-press menu.
    var onDeleteRequested: ((Card) -> Void)?

    private let posterImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1)
        return iv
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 24, weight: .bold)
        l.textColor = .white
        l.numberOfLines = 3
        return l
    }()

    private let badgeLabel: PaddingLabel = {
        let l = PaddingLabel()
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .white
        l.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        l.layer.cornerRadius = 10
        l.clipsToBounds = true
    return l
    }()

    private let gradientLayer: CAGradientLayer = {
        let g = CAGradientLayer()
        g.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.75).cgColor]
        g.locations = [0.45, 1.0]
        return g
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        layer.cornerRadius = 22
        clipsToBounds = true
        backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1)

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 8)
        // A shadow needs masksToBounds=false, which fights cornerRadius clip,
        // so let the poster image own the clipped rounded corners instead.
        layer.masksToBounds = false
        posterImageView.layer.cornerRadius = 22
        posterImageView.layer.masksToBounds = true

        for v in [posterImageView, titleLabel, badgeLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        posterImageView.layer.addSublayer(gradientLayer)

        NSLayoutConstraint.activate([
            posterImageView.topAnchor.constraint(equalTo: topAnchor),
            posterImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            posterImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            posterImageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),

            badgeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            badgeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
        ])

        // Long-press → context menu (Delete).
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = posterImageView.bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 22).cgPath
    }

    func configure(with card: Card) {
        self.card = card
        titleLabel.text = card.title
        badgeLabel.text = card.kind.rawValue
        alpha = 1

        posterImageView.image = nil
        guard let posterURL = CardStore.shared.posterURL(for: card) else { return }
        let cardId = card.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let data = try? Data(contentsOf: posterURL),
                  let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                // Guard against cell reuse racing a slow decode.
                guard self?.currentCardId == cardId else { return }
                self?.posterImageView.image = image
            }
        }
        currentCardId = cardId
    }

    private var currentCardId: String?
}

// MARK: - Context menu (delete)

extension CardPosterView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let card = card else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let delete = UIAction(title: "Delete",
                                  image: UIImage(systemName: "trash"),
                                  attributes: .destructive) { _ in
                self?.onDeleteRequested?(card)
            }
            return UIMenu(title: card.title, children: [delete])
        }
    }
}

// MARK: - Small UI helpers

/// Label with internal padding, used for the kind/state badge.
private final class PaddingLabel: UILabel {
    private let inset = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: inset))
    }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right,
                      height: s.height + inset.top + inset.bottom)
    }
}

#endif
