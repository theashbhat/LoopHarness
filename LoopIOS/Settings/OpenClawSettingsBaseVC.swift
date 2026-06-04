//
//  OpenClawSettingsBaseVC.swift
//  Loop
//
//  Shared scaffolding for the OpenClaw-backed Settings screens (Models, Crons,
//  Subagents, Keys). Each subclass renders a remote slice of the VM's config, so
//  they all share the same lifecycle: an inset-grouped table, a refresh control,
//  and three transient states — loading, error, and loaded — driven by an async
//  fetch against `OpenClawSettingsService`.
//
//  Non-generic on purpose: a generic UIViewController subclass can't expose the
//  `@objc` members UIKit needs (target/action selectors, `UITableViewDataSource`
//  conformance). So the base owns the table + state machine, and each subclass
//  stores its own typed rows, fetches them in `loadData()`, and renders them
//  through the table methods it overrides.
//

#if os(iOS)

import UIKit

class OpenClawSettingsBaseVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let refreshControl = UIRefreshControl()
    private let statusLabel = UILabel()

    /// The active backend's service, resolved once on load. Nil only if the user
    /// navigated here while the backend was deactivating — handled as an error.
    let service: OpenClawSettingsService?

    init(title: String) {
        self.service = OpenClawSettingsService.active
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Subclass hooks

    /// Register cell classes. Called once in `viewDidLoad`.
    func registerCells() {
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    /// Fetch the remote data and store it into the subclass's own state. Throwing
    /// surfaces the error UI; returning normally then consults `hasContent`.
    func loadData() async throws {}

    /// Whether the last load produced anything to show. Drives the empty state.
    var hasContent: Bool { false }

    /// Copy shown (centered) when a successful fetch returns nothing.
    var emptyMessage: String { "Nothing here yet." }

    /// Optional footer under the section.
    var footerText: String? { nil }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.estimatedRowHeight = 64
        tableView.rowHeight = UITableView.automaticDimension
        registerCells()
        refreshControl.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        tableView.refreshControl = refreshControl
        view.addSubview(tableView)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textAlignment = .center
        statusLabel.textColor = .secondaryLabel
        statusLabel.font = .preferredFont(forTextStyle: .callout)
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])

        load(showSpinner: true)
    }

    // MARK: - Loading

    @objc private func refreshPulled() { load(showSpinner: false) }

    /// Re-run the fetch. Subclasses can call this after a mutation (e.g. setting a
    /// new default model) to reflect the change.
    func reload() { load(showSpinner: true) }

    private func load(showSpinner: Bool) {
        guard service != nil else {
            showStatus("This screen needs an active OpenClaw backend.")
            return
        }
        if showSpinner && !hasContent { showStatus("Loading…") }
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.loadData()
                await MainActor.run {
                    self.refreshControl.endRefreshing()
                    if self.hasContent {
                        self.hideStatus()
                    } else {
                        self.showStatus(self.emptyMessage)
                    }
                    self.tableView.reloadData()
                }
            } catch {
                await MainActor.run {
                    self.refreshControl.endRefreshing()
                    if !self.hasContent {
                        self.showStatus("Couldn't reach the VM.\n\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func showStatus(_ text: String) {
        statusLabel.text = text
        statusLabel.isHidden = false
        tableView.isHidden = true
    }

    private func hideStatus() {
        statusLabel.isHidden = true
        tableView.isHidden = false
    }

    // MARK: - UITableViewDataSource (subclasses override what they need)

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 0 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        footerText
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

#endif
