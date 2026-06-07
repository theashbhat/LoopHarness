//
//  VMCronTasksVC.swift
//  Loop
//
//  Settings → VM Agents. Lists recurring jobs that run on the user's SSH VM via
//  cron (see VMCronManager). Create with the "+" button, swipe to delete (which
//  also removes the cron entry + files on the VM), tap a row to open its thread.
//

#if os(iOS)

import UIKit

final class VMCronTasksVC: UIViewController {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var jobs: [VMCronJob] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "VM Agents"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addTapped))

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        jobs = VMCronManager.shared.list().sorted { $0.createdAt > $1.createdAt }
        tableView.reloadData()
    }

    // MARK: - Create

    @objc private func addTapped() {
        let create = VMCronCreateVC { [weak self] in self?.reload() }
        let nav = UINavigationController(rootViewController: create)
        present(nav, animated: true)
    }

    // MARK: - Per-row actions

    private func openThread(for job: VMCronJob) {
        guard let conv = SimpleConversationManager.shared.getConversation(by: job.conversationId),
              let nav = navigationController,
              let messagingVC = nav.viewControllers.first(where: { $0 is MessagingVC }) as? MessagingVC else { return }
        messagingVC.loadConversation(conv)
        nav.popToRootViewController(animated: true)
    }

    private func delete(_ job: VMCronJob) {
        // Drop the local record immediately so the row disappears; the VM cleanup
        // runs in the background (best-effort).
        jobs.removeAll { $0.id == job.id }
        tableView.reloadData()
        Task { _ = await VMCronManager.shared.delete(id: job.id) }
    }
}

extension VMCronTasksVC: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return max(jobs.count, 1)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        var config = cell.defaultContentConfiguration()
        if jobs.isEmpty {
            config.text = "No VM agents yet."
            config.secondaryText = "Tap + or ask Loop, e.g. \"every 2 hours read Hacker News and send me the top stories\"."
            config.textProperties.color = .secondaryLabel
            cell.contentConfiguration = config
            cell.selectionStyle = .none
            cell.accessoryType = .none
            return cell
        }
        let job = jobs[indexPath.row]
        config.text = job.title
        var secondary = job.humanSchedule
        if let last = job.lastRunAt {
            secondary += " · last run " + Self.relative.localizedString(for: last, relativeTo: Date())
        }
        config.secondaryText = secondary
        config.image = UIImage(systemName: "clock.arrow.2.circlepath")
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !jobs.isEmpty, indexPath.row < jobs.count else { return }
        openThread(for: jobs[indexPath.row])
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !jobs.isEmpty, indexPath.row < jobs.count else { return nil }
        let job = jobs[indexPath.row]
        let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            self?.delete(job)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    private static let relative = RelativeDateTimeFormatter()
}

// MARK: - Create form

private final class VMCronCreateVC: UIViewController, UITextViewDelegate {

    private let onSaved: () -> Void
    private let titleField = UITextField()
    private let scheduleField = UITextField()
    private let promptView = UITextView()
    private let promptPlaceholder = "What should run each time? e.g. Fetch the Hacker News front page and list the top 5 stories with a one-line summary and link each."
    private var saveButton: UIBarButtonItem!

    init(onSaved: @escaping () -> Void) {
        self.onSaved = onSaved
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "New VM Agent"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        saveButton = UIBarButtonItem(
            barButtonSystemItem: .save, target: self, action: #selector(saveTapped))
        navigationItem.rightBarButtonItem = saveButton

        titleField.placeholder = "Title (e.g. HN top stories)"
        titleField.borderStyle = .roundedRect
        titleField.autocapitalizationType = .sentences

        scheduleField.placeholder = "Schedule: 2h, 30m, 1d, or a cron expr"
        scheduleField.borderStyle = .roundedRect
        scheduleField.autocapitalizationType = .none
        scheduleField.autocorrectionType = .no

        promptView.font = .preferredFont(forTextStyle: .body)
        promptView.layer.cornerRadius = 8
        promptView.layer.borderWidth = 1
        promptView.layer.borderColor = UIColor.separator.cgColor
        promptView.delegate = self
        promptView.text = promptPlaceholder
        promptView.textColor = .placeholderText

        let scheduleHint = label("Cron times use the VM's local timezone. Shorthand: 30m = every 30 min, 2h = every 2 hours, 1d = daily 9am.")
        let promptLabel = label("Prompt")
        promptLabel.font = .preferredFont(forTextStyle: .headline)

        let stack = UIStackView(arrangedSubviews: [
            titleField, scheduleField, scheduleHint, promptLabel, promptView,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(4, after: scheduleField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            promptView.heightAnchor.constraint(equalToConstant: 160),
        ])
    }

    private func label(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.numberOfLines = 0
        l.font = .preferredFont(forTextStyle: .footnote)
        l.textColor = .secondaryLabel
        return l
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        if textView.textColor == .placeholderText {
            textView.text = ""
            textView.textColor = .label
        }
    }
    func textViewDidEndEditing(_ textView: UITextView) {
        if textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textView.text = promptPlaceholder
            textView.textColor = .placeholderText
        }
    }

    @objc private func cancelTapped() { dismiss(animated: true) }

    @objc private func saveTapped() {
        let title = (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = (scheduleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = promptView.textColor == .placeholderText
            ? "" : promptView.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty, !prompt.isEmpty else {
            return showError("Please enter a title and a prompt.")
        }
        guard let parsed = VMCronManager.parseSchedule(schedule) else {
            return showError("Couldn't read the schedule. Use shorthand like 2h or 30m, or a 5-field cron expression like 0 */2 * * *.")
        }

        saveButton.isEnabled = false
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)

        Task { [weak self] in
            let result = await VMCronManager.shared.create(
                title: title, prompt: prompt, cronExpr: parsed.cron, humanSchedule: parsed.human)
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success:
                    self.onSaved()
                    self.dismiss(animated: true)
                case .failure(let reason):
                    self.navigationItem.rightBarButtonItem = self.saveButton
                    self.saveButton.isEnabled = true
                    self.showError(reason)
                }
            }
        }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Couldn't create agent", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

#endif
