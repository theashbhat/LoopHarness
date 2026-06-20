//
//  FeedCardListView.swift
//  Loop
//
//  Scannable vertical list of feed cards shown on the empty new-chat screen.
//  Each row is a compact panel — icon tile, title, one-line summary, a kind
//  badge, and hashtags — laid out to read at a glance. Swipe a row left to
//  Archive or Delete; tap to open its detail. The list only renders when there
//  are unarchived cards; otherwise the hero orb owns the empty state.
//
//  This replaces the old Tinder-style swipe deck. The file kept its original
//  `Feed/` home but the surface is now a list, not a stack.
//

#if os(iOS)
import UIKit

final class FeedCardListView: UIView {

    // MARK: - Callbacks

    /// Fired when a row is tapped — the host opens the card's detail.
    var onTap: ((Card) -> Void)?
    /// Fired when the user archives a card (swipe → Archive). The host updates
    /// the card's state in the store.
    var onArchive: ((Card) -> Void)?
    /// Fired when the list becomes empty (last card archived / deleted) so the
    /// host can restore the orb / empty state.
    var onEmptied: (() -> Void)?

    // MARK: - State

    private var cards: [Card] = []

    /// Warm gold used for badges and accents — matches the app's accent on dark
    /// surfaces.
    static let accent = UIColor(red: 0.82, green: 0.66, blue: 0.40, alpha: 1)

    // MARK: - Subviews

    private let tableView = UITableView(frame: .zero, style: .plain)

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 30, weight: .bold)
        l.textColor = .label
        l.text = "Cards"
        return l
    }()

    private let countLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 14, weight: .regular)
        l.textColor = .secondaryLabel
        return l
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        backgroundColor = .clear

        let header = makeHeader()
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 96
        tableView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        tableView.register(FeedCardCell.self, forCellReuseIdentifier: FeedCardCell.reuseID)
        tableView.tableFooterView = makeFooter()
        addSubview(tableView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),

            tableView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeHeader() -> UIView {
        let container = UIView()
        let textStack = UIStackView(arrangedSubviews: [titleLabel, countLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(textStack)
        NSLayoutConstraint.activate([
            textStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            textStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            textStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        return container
    }

    private func makeFooter() -> UIView {
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 56))
        let label = UILabel()
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.text = "Swipe a card left to Archive"
        label.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            label.topAnchor.constraint(equalTo: footer.topAnchor, constant: 18),
        ])
        return footer
    }

    // MARK: - API

    /// Replace the list contents and refresh.
    func setCards(_ cards: [Card]) {
        self.cards = cards
        updateCount()
        tableView.reloadData()
    }

    var isEmpty: Bool { cards.isEmpty }

    private func updateCount() {
        let n = cards.count
        countLabel.text = "\(n) card\(n == 1 ? "" : "s") · newest first"
    }

    /// Drop the row at `index` with the given persistence action, then notify
    /// the host if the list just emptied.
    private func removeRow(at index: Int, persist: (Card) -> Void) {
        guard cards.indices.contains(index) else { return }
        let card = cards.remove(at: index)
        persist(card)
        updateCount()
        tableView.deleteRows(at: [IndexPath(row: index, section: 0)], with: .left)
        if cards.isEmpty { onEmptied?() }
    }
}

// MARK: - Data source / delegate

extension FeedCardListView: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        cards.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: FeedCardCell.reuseID, for: indexPath) as! FeedCardCell
        cell.configure(with: cards[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard cards.indices.contains(indexPath.row) else { return }
        onTap?(cards[indexPath.row])
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let archive = UIContextualAction(style: .destructive, title: "Archive") { [weak self] _, _, done in
            self?.removeRow(at: indexPath.row) { card in self?.onArchive?(card) }
            done(true)
        }
        archive.image = UIImage(systemName: "archivebox")
        archive.backgroundColor = UIColor(red: 0.62, green: 0.47, blue: 0.20, alpha: 1)

        let config = UISwipeActionsConfiguration(actions: [archive])
        config.performsFirstActionWithFullSwipe = true
        return config
    }
}

// MARK: - Card cell

/// A single scannable card row: icon tile, title, summary, kind badge, tags.
private final class FeedCardCell: UITableViewCell {

    static let reuseID = "FeedCardCell"

    private let panel: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        v.layer.cornerRadius = 20
        v.layer.cornerCurve = .continuous
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor(white: 1, alpha: 0.06).cgColor
        return v
    }()

    private let iconTile: UIView = {
        let v = UIView()
        v.layer.cornerRadius = 14
        v.layer.cornerCurve = .continuous
        return v
    }()

    private let iconView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        return iv
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 20, weight: .bold)
        l.textColor = .white
        l.numberOfLines = 2
        return l
    }()

    private let subtitleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 15, weight: .regular)
        l.textColor = .secondaryLabel
        l.numberOfLines = 1
        return l
    }()

    private let tagsLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13, weight: .regular)
        l.textColor = .tertiaryLabel
        l.numberOfLines = 1
        return l
    }()

    private let badgeLabel: PaddingLabel = {
        let l = PaddingLabel()
        l.font = .systemFont(ofSize: 11, weight: .bold)
        l.textColor = FeedCardListView.accent
        l.backgroundColor = FeedCardListView.accent.withAlphaComponent(0.12)
        l.layer.cornerRadius = 7
        l.layer.cornerCurve = .continuous
        l.clipsToBounds = true
        l.setContentHuggingPriority(.required, for: .horizontal)
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        return l
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        contentView.backgroundColor = .clear
        setupLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupLayout() {
        panel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(panel)

        // Title and badge share the top row; the title wraps in the space left
        // of the badge, which hugs the trailing edge.
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, badgeLabel])
        titleRow.axis = .horizontal
        titleRow.alignment = .top
        titleRow.spacing = 10

        let textStack = UIStackView(arrangedSubviews: [titleRow, subtitleLabel, tagsLabel])
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 3
        textStack.setCustomSpacing(10, after: subtitleLabel)
        textStack.translatesAutoresizingMaskIntoConstraints = false

        for v in [iconTile, textStack] {
            v.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(v)
        }
        iconTile.addSubview(iconView)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
            panel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -7),
            panel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            panel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            iconTile.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            iconTile.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            iconTile.widthAnchor.constraint(equalToConstant: 52),
            iconTile.heightAnchor.constraint(equalToConstant: 52),

            iconView.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: 14),
            textStack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            textStack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
        ])

        // Panel height wraps the taller of the icon tile and the text block.
        let stackBottom = textStack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16)
        stackBottom.priority = .defaultHigh
        let iconBottom = iconTile.bottomAnchor.constraint(lessThanOrEqualTo: panel.bottomAnchor, constant: -16)
        NSLayoutConstraint.activate([stackBottom, iconBottom])
    }

    func configure(with card: Card) {
        titleLabel.text = card.title

        let subtitle = card.displaySubtitle
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = (subtitle == nil)

        if card.tags.isEmpty {
            tagsLabel.isHidden = true
        } else {
            tagsLabel.isHidden = false
            tagsLabel.text = card.tags.map { "#\($0)" }.joined(separator: " ")
        }

        badgeLabel.text = card.displayBadge

        let style = card.displayIcon
        iconView.image = UIImage(systemName: style.symbol)
        iconView.tintColor = style.tint.withAlphaComponent(0.95)
        iconTile.backgroundColor = style.tint.withAlphaComponent(0.22)
    }
}

// MARK: - Small UI helpers

/// Label with internal padding, used for the kind badge.
private final class PaddingLabel: UILabel {
    private let inset = UIEdgeInsets(top: 4, left: 9, bottom: 4, right: 9)
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
