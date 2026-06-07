//
//  SSHConnectionsVC.swift
//  Loop
//
//  Root screen for Settings → SSH: a list of saved SSH connections. The top
//  row is the default — the connection the `ssh_client` skill and the Loop
//  Runner transport use each session. A + button adds a new connection; rows
//  tap into the per-connection editor (`SSHSettingsVC`); swipe trailing to
//  Delete or open a Terminal, swipe leading to make a connection the default.
//
//  iOS-only (references the SwiftTerm-backed terminal); excluded from the
//  Mac/Vision targets.
//

import UIKit

final class SSHConnectionsVC: UITableViewController {

    private var connections: [SSHConfig] = []
    private let emptyLabel = UILabel()

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "SSH"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addTapped))
        // Edit button toggles drag-to-reorder mode.
        navigationItem.leftBarButtonItem = editButtonItem
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        emptyLabel.text = "No SSH connections.\nTap + to add one."
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .subheadline)

        // Refresh if the list changes from an iCloud sync while this screen is open.
        NotificationCenter.default.addObserver(
            forName: SSHConfigStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        connections = SSHConfigStore.shared.connections
        tableView.backgroundView = connections.isEmpty ? emptyLabel : nil
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func addTapped() {
        navigationController?.pushViewController(SSHSettingsVC(connection: nil), animated: true)
    }

    private func openTerminal(_ connection: SSHConfig) {
        guard connection.isConfigured else {
            let alert = UIAlertController(
                title: "Not configured",
                message: "Add a host, username, and private key before opening a terminal.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let terminal = SSHTerminalViewController(config: connection)
        terminal.modalPresentationStyle = .fullScreen
        present(terminal, animated: true)
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        connections.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        connections.isEmpty ? nil : "Tap a connection to make it active (✓). The active one is used for new sessions and background handoffs. Tap Edit to reorder; swipe a row to edit, open a Terminal, or delete."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "cell")
        let conn = connections[indexPath.row]
        let isActive = conn.id == SSHConfigStore.shared.effectiveSelectedID

        cell.textLabel?.text = conn.displayName
        cell.detailTextLabel?.text = conn.endpointSummary
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        cell.imageView?.image = UIImage(systemName: "terminal",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13))
        cell.imageView?.tintColor = .secondaryLabel

        // Checkmark marks the active connection (mirrors Execution Backend).
        cell.accessoryType = isActive ? .checkmark : .none
        cell.showsReorderControl = true
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let conn = connections[indexPath.row]
        // Tapping the already-active connection opens its editor; tapping another
        // makes it active (a second tap then edits it).
        if conn.id == SSHConfigStore.shared.effectiveSelectedID {
            navigationController?.pushViewController(SSHSettingsVC(connection: conn), animated: true)
        } else {
            SSHConfigStore.shared.select(id: conn.id)
            reload()
        }
    }

    // MARK: - Reordering

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        true
    }

    override func tableView(_ tableView: UITableView,
                            moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        SSHConfigStore.shared.move(from: sourceIndexPath.row, to: destinationIndexPath.row)
        connections = SSHConfigStore.shared.connections
    }

    // Reorder-only editing mode: no delete circle, no indent (delete stays on swipe).
    override func tableView(_ tableView: UITableView,
                            editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        .none
    }

    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }

    // MARK: - Swipe actions

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let conn = connections[indexPath.row]

        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            SSHConfigStore.shared.delete(id: conn.id)
            self?.reload()
            done(true)
        }
        let edit = UIContextualAction(style: .normal, title: "Edit") { [weak self] _, _, done in
            self?.navigationController?.pushViewController(SSHSettingsVC(connection: conn), animated: true)
            done(true)
        }
        edit.backgroundColor = .systemBlue
        let terminal = UIContextualAction(style: .normal, title: "Terminal") { [weak self] _, _, done in
            self?.openTerminal(conn)
            done(true)
        }
        terminal.backgroundColor = .systemGreen
        return UISwipeActionsConfiguration(actions: [delete, edit, terminal])
    }
}
