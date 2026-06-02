//
//  SettingsVC.swift
//  Loop
//
//  Root settings screen reachable from the conversation pane's nav bar.
//  Organized as a section'd table so future panes (model picker, sync, etc.)
//  drop in without restructuring.
//

import UIKit

final class SettingsVC: UIViewController {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    /// Single row in a section. The `handler` is invoked on the main queue
    /// when the user taps it.
    private struct Row {
        let title: String
        let icon: String
        let handler: (SettingsVC) -> Void
    }

    private struct Section {
        let header: String?
        let rows: [Row]
    }

    private let sections: [Section] = [
        Section(header: "Core", rows: [
            Row(title: "Execution Backend", icon: "externaldrive.badge.icloud") { settings in
                settings.navigationController?.pushViewController(ExecutionBackendVC(), animated: true)
            }
        ]),
        Section(header: "Main", rows: [
            Row(title: "Model", icon: "cpu") { settings in
                settings.navigationController?.pushViewController(ModelPickerVC(), animated: true)
            },
            Row(title: "Integrations", icon: "puzzlepiece.extension.fill") { settings in
                settings.navigationController?.pushViewController(IntegrationsVC(), animated: true)
            },
            Row(title: "Skills", icon: "sparkles") { settings in
                settings.navigationController?.pushViewController(SkillsVC(), animated: true)
            },
            Row(title: "Scheduled", icon: "calendar.badge.clock") { settings in
                settings.navigationController?.pushViewController(ScheduledTasksVC(), animated: true)
            },
            Row(title: "Subagents", icon: "hammer") { settings in
                settings.navigationController?.pushViewController(SubagentsListVC(), animated: true)
            },
            Row(title: "Keys", icon: "key.fill") { settings in
                settings.navigationController?.pushViewController(KeysVC(), animated: true)
            }
        ]),
        // Lives in its own section so it reads as a discrete debug/utility
        // affordance rather than something the user would tap as part of a
        // normal settings sweep.
        Section(header: "Help", rows: [
            Row(title: "Replay onboarding", icon: "arrow.counterclockwise") { settings in
                settings.confirmReplayOnboarding()
            },
            Row(title: "View Source Code", icon: "curlybraces") { _ in
                if let url = URL(string: "https://github.com/theashbhat/LoopHarness") {
                    UIApplication.shared.open(url)
                }
            }
        ]),
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = .systemGroupedBackground

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

        // Standard "Done" so the user can dismiss when we're presented modally.
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissTapped)
        )
    }

    @objc private func dismissTapped() {
        dismiss(animated: true)
    }

    /// Confirm before clearing the onboarding flags — the row sits in a normal
    /// settings list and we don't want a stray tap to throw the user back to
    /// step 1 unexpectedly.
    private func confirmReplayOnboarding() {
        let alert = UIAlertController(
            title: "Replay onboarding?",
            message: "You'll see the welcome flow again from the start.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Replay", style: .default) { [weak self] _ in
            self?.replayOnboarding()
        })
        present(alert, animated: true)
    }

    /// Resets the onboarding flags and dismisses Settings. The conversational
    /// onboarding now lives inside MessagingVC; calling `resetForReplay()`
    /// on the coordinator lets `resumeIfNeeded()` re-fire in the existing
    /// MessagingVC instance — the user lands back on the chat with the
    /// greeting card already posted.
    private func replayOnboarding() {
        OnboardingState.isComplete = false
        OnboardingState.lastStep = 0
        OnboardingState.actionButtonSkipped = false
        OnboardingState.actionButtonReminderDismissedAt = nil

        OnboardingCoordinator.shared.resetForReplay()

        dismiss(animated: true) {
            OnboardingCoordinator.shared.resumeIfNeeded()
        }
    }
}

extension SettingsVC: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].header
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        let row = sections[indexPath.section].rows[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = row.title
        config.image = UIImage(systemName: row.icon)
        cell.contentConfiguration = config
        cell.accessoryType = row.title == "View Source Code" ? .none : .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        sections[indexPath.section].rows[indexPath.row].handler(self)
    }
}
