//
//  ExecutionBackendVC.swift
//  Loop
//
//  Settings → Execution Backend. A list of the backends Loop can run from. The
//  top row is the built-in **Local** backend (on-device / iCloud); it's always
//  present, can't be deleted, and is selected by default. Below it are any
//  remote SSH VM backends the user has added.
//
//  • Tap a row to choose it. Choosing Local takes effect immediately. Choosing a
//    remote that's already configured + validated activates it; otherwise the
//    per-backend editor opens so it can be set up and connection-checked first.
//  • + adds a new remote backend.
//  • Swipe a remote row to Edit or Delete. Local has neither.
//
//  The checkmark marks the *active* backend — where new conversations are
//  created. Each backend keeps its own conversations, so switching never mixes
//  them. Secrets (private key, passphrase) live in the Keychain via
//  `ExecutionBackendStore` and are never shown again after being set.
//

import UIKit

final class ExecutionBackendVC: UITableViewController {

    private var backends: [ExecutionBackend] = []

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Execution Backend"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addTapped))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        backends = ExecutionBackendStore.shared.backends
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func addTapped() {
        navigationController?.pushViewController(ExecutionBackendEditVC(backend: nil), animated: true)
    }

    private func edit(_ backend: ExecutionBackend) {
        navigationController?.pushViewController(ExecutionBackendEditVC(backend: backend), animated: true)
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        backends.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Local stores conversations on this device and in iCloud, and can't be removed. Add a remote VM to run new conversations there. Each backend keeps its own conversations. Swipe a remote to edit or delete it."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "cell")
        let backend = backends[indexPath.row]
        let store = ExecutionBackendStore.shared
        let isSelected = backend.id == store.selectedBackendID

        cell.textLabel?.text = backend.displayName

        // Subtitle: endpoint + a connection hint for remotes.
        if backend.isLocal {
            cell.detailTextLabel?.text = backend.subtitle
        } else if !backend.config.isConfigured {
            cell.detailTextLabel?.text = "Tap to configure"
        } else if store.isValidated(id: backend.id) {
            cell.detailTextLabel?.text = "\(backend.subtitle) · Connected"
        } else {
            cell.detailTextLabel?.text = "\(backend.subtitle) · Not connected"
        }
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        // Leading glyph distinguishes local from remote.
        let symbol = backend.isLocal ? "internaldrive" : "externaldrive.badge.icloud"
        cell.imageView?.image = UIImage(systemName: symbol)
        cell.imageView?.tintColor = .secondaryLabel

        // Checkmark marks the active backend.
        cell.accessoryType = isSelected ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let backend = backends[indexPath.row]
        let store = ExecutionBackendStore.shared

        if backend.isLocal {
            store.select(id: backend.id)
            reload()
            return
        }

        // Tapping the already-active remote drops straight into its editor —
        // once it's selected, a second tap reads as "I want to change this one."
        if backend.id == store.selectedBackendID {
            edit(backend)
            return
        }

        // A configured + validated remote can be activated directly; otherwise
        // open the editor to finish setting it up and connection-check it.
        if backend.config.isConfigured && store.isValidated(id: backend.id) {
            store.select(id: backend.id)
            reload()
        } else {
            edit(backend)
        }
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration? {
        let backend = backends[indexPath.row]
        guard backend.isDeletable else { return nil }   // Local: no edit/delete

        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            ExecutionBackendStore.shared.delete(id: backend.id)
            self?.reload()
            done(true)
        }
        let edit = UIContextualAction(style: .normal, title: "Edit") { [weak self] _, _, done in
            self?.edit(backend)
            done(true)
        }
        edit.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [delete, edit])
    }
}
