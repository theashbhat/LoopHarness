//
//  CardDetailViewController.swift
//  Loop
//
//  Expanded detail view for a single card. Shows the full poster, title,
//  body, metadata, and action buttons (Keep / Archive).
//

#if os(iOS)
import UIKit

final class CardDetailViewController: UIViewController {

    private let card: Card

    // MARK: - UI

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private let posterImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 12
        iv.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        return iv
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 28, weight: .bold)
        l.textColor = .label
        l.numberOfLines = 0
        return l
    }()

    private let bodyLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 17, weight: .regular)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        return l
    }()

    private let metaLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13, weight: .regular)
        l.textColor = .tertiaryLabel
        l.numberOfLines = 0
        return l
    }()

    private let actionStack: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = 16
        s.distribution = .fillEqually
        return s
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
        view.backgroundColor = .systemBackground
        title = "Card"
        // When presented modally (pill tap / new-chat stack) we're the root of
        // a navigation controller, so there's no back button — add Done.
        if navigationController?.viewControllers.first === self,
           presentingViewController != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        }
        setupLayout()
        populate()
    }

    @objc private func doneTapped() {
        dismissOrPop()
    }

    /// Pop when pushed, dismiss when presented modally.
    private func dismissOrPop() {
        if let nav = navigationController, nav.viewControllers.first !== self {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    // MARK: - Layout

    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
        ])

        // Poster with 4:3 aspect
        posterImageView.translatesAutoresizingMaskIntoConstraints = false
        let posterHeight = posterImageView.heightAnchor.constraint(equalTo: posterImageView.widthAnchor, multiplier: 3.0/4.0)
        posterHeight.isActive = true

        contentStack.addArrangedSubview(posterImageView)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(bodyLabel)
        contentStack.addArrangedSubview(metaLabel)
        contentStack.addArrangedSubview(actionStack)

        contentStack.setCustomSpacing(24, after: posterImageView)
        contentStack.setCustomSpacing(24, after: bodyLabel)

        // Action buttons
        let keepBtn = makeActionButton(title: "Keep", color: .systemGreen, action: #selector(keepTapped))
        let archiveBtn = makeActionButton(title: "Archive", color: .systemOrange, action: #selector(archiveTapped))
        actionStack.addArrangedSubview(keepBtn)
        actionStack.addArrangedSubview(archiveBtn)
    }

    private func makeActionButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        btn.backgroundColor = color
        btn.layer.cornerRadius = 12
        btn.heightAnchor.constraint(equalToConstant: 48).isActive = true
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    // MARK: - Populate

    private func populate() {
        titleLabel.text = card.title
        if card.kind == .markdown {
            // The markdown body below already carries the full formatted
            // content, so the poster (which renders the same title + body) is
            // redundant here — hide it and let the text stand on its own.
            posterImageView.isHidden = true
            bodyLabel.attributedText = CardMarkdown.attributed(
                card.body,
                bodyFont: .systemFont(ofSize: 17, weight: .regular),
                textColor: .secondaryLabel,
                headingColor: .label)
        } else {
            bodyLabel.text = card.body
        }

        var meta = "\(card.kind.rawValue) card"
        if let source = card.source { meta += " · \(source)" }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        meta += " · \(df.string(from: card.createdAt))"
        if !card.tags.isEmpty { meta += "\n\(card.tags.map { "#\($0)" }.joined(separator: " "))" }
        metaLabel.text = meta

        if card.kind != .markdown, let posterURL = CardStore.shared.posterURL(for: card) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let data = try? Data(contentsOf: posterURL),
                      let image = UIImage(data: data) else { return }
                DispatchQueue.main.async {
                    self?.posterImageView.image = image
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func keepTapped() {
        CardStore.shared.updateState(id: card.id, state: .kept)
        dismissOrPop()
    }

    @objc private func archiveTapped() {
        CardStore.shared.updateState(id: card.id, state: .archived)
        dismissOrPop()
    }
}

#endif
