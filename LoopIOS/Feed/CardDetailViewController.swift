//
//  CardDetailViewController.swift
//  Loop
//
//  Expanded detail for a single card, presented as a dark sheet. A header row
//  carries the icon tile, kind badge, and a close button; the body renders the
//  card's markdown; a pinned bottom bar offers Archive / Done.
//

#if os(iOS)
import UIKit

final class CardDetailViewController: UIViewController {

    private let card: Card

    /// Warm gold accent shared with the card list.
    private let accent = FeedCardListView.accent
    /// Near-black sheet background.
    private let sheetBackground = UIColor(red: 0.05, green: 0.05, blue: 0.055, alpha: 1)

    // MARK: - UI

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private let iconTile: UIView = {
        let v = UIView()
        v.layer.cornerRadius = 11
        v.layer.cornerCurve = .continuous
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let iconView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let badgeLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13, weight: .bold)
        return l
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 32, weight: .bold)
        l.textColor = .white
        l.numberOfLines = 0
        return l
    }()

    private let bodyLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 17, weight: .regular)
        l.textColor = UIColor(white: 0.78, alpha: 1)
        l.numberOfLines = 0
        return l
    }()

    private let divider: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(white: 1, alpha: 0.1)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let metaLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 14, weight: .regular)
        l.textColor = UIColor(white: 0.5, alpha: 1)
        l.numberOfLines = 0
        return l
    }()

    // MARK: - Init

    init(card: Card) {
        self.card = card
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = sheetBackground
        navigationController?.setNavigationBarHidden(true, animated: false)
        if let sheet = (navigationController ?? self).sheetPresentationController {
            sheet.prefersGrabberVisible = true
        }
        setupLayout()
        populate()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    // MARK: - Layout

    private func setupLayout() {
        let header = makeHeader()
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        let actionBar = makeActionBar()
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionBar)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 18
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(bodyLabel)
        contentStack.addArrangedSubview(divider)
        contentStack.addArrangedSubview(metaLabel)
        contentStack.setCustomSpacing(22, after: bodyLabel)
        contentStack.setCustomSpacing(14, after: divider)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: actionBar.topAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -24),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -48),

            divider.heightAnchor.constraint(equalToConstant: 1),

            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            actionBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }

    /// Icon tile + kind badge on the left, close button on the right.
    private func makeHeader() -> UIView {
        let container = UIView()

        iconTile.addSubview(iconView)
        container.addSubview(iconTile)
        container.addSubview(badgeLabel)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
                       for: .normal)
        close.tintColor = UIColor(white: 0.85, alpha: 1)
        close.backgroundColor = UIColor(white: 1, alpha: 0.1)
        close.layer.cornerRadius = 18
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        container.addSubview(close)

        NSLayoutConstraint.activate([
            iconTile.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            iconTile.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconTile.widthAnchor.constraint(equalToConstant: 40),
            iconTile.heightAnchor.constraint(equalToConstant: 40),
            container.heightAnchor.constraint(equalToConstant: 40),

            iconView.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),

            badgeLabel.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: 12),
            badgeLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            close.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            close.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 36),
            close.heightAnchor.constraint(equalToConstant: 36),
        ])
        return container
    }

    /// Pinned Archive (gold-outlined) / Done (filled) buttons.
    private func makeActionBar() -> UIView {
        let archive = UIButton(type: .system)
        archive.setTitle("Archive", for: .normal)
        archive.setTitleColor(accent, for: .normal)
        archive.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        archive.backgroundColor = accent.withAlphaComponent(0.08)
        archive.layer.cornerRadius = 14
        archive.layer.cornerCurve = .continuous
        archive.layer.borderWidth = 1
        archive.layer.borderColor = accent.withAlphaComponent(0.7).cgColor
        archive.addTarget(self, action: #selector(archiveTapped), for: .touchUpInside)

        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.setTitleColor(.white, for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        done.backgroundColor = UIColor(white: 1, alpha: 0.1)
        done.layer.cornerRadius = 14
        done.layer.cornerCurve = .continuous
        done.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [archive, done])
        stack.axis = .horizontal
        stack.spacing = 14
        stack.distribution = .fillEqually
        archive.heightAnchor.constraint(equalToConstant: 56).isActive = true
        done.heightAnchor.constraint(equalToConstant: 56).isActive = true
        return stack
    }

    // MARK: - Populate

    private func populate() {
        let style = card.displayIcon
        iconView.image = UIImage(systemName: style.symbol)
        iconView.tintColor = style.tint.withAlphaComponent(0.95)
        iconTile.backgroundColor = style.tint.withAlphaComponent(0.22)

        badgeLabel.attributedText = NSAttributedString(
            string: card.displayBadge,
            attributes: [.kern: 1.5, .foregroundColor: accent,
                         .font: UIFont.systemFont(ofSize: 13, weight: .bold)])

        titleLabel.text = card.title

        if card.kind == .markdown {
            bodyLabel.attributedText = CardMarkdown.attributed(
                card.body,
                bodyFont: .systemFont(ofSize: 17, weight: .regular),
                textColor: UIColor(white: 0.82, alpha: 1),
                headingColor: .white,
                bulletColor: accent)
        } else {
            bodyLabel.text = card.body
        }

        var meta = "\(card.kind.rawValue.capitalized) card"
        if let source = card.source { meta += " · created from \(source)" }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        meta += " · \(df.string(from: card.createdAt))"
        metaLabel.text = meta
    }

    // MARK: - Actions

    @objc private func closeTapped() { dismiss(animated: true) }

    @objc private func doneTapped() {
        // "Done" acknowledges the card but keeps it in the feed.
        CardStore.shared.updateState(id: card.id, state: .kept)
        dismiss(animated: true)
    }

    @objc private func archiveTapped() {
        CardStore.shared.updateState(id: card.id, state: .archived)
        dismiss(animated: true)
    }
}

#endif
