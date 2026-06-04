//
//  OpenClawCronsVC.swift
//  Loop
//
//  Settings ▸ Scheduled, while a remote OpenClaw backend is active. Lists the
//  VM's cron jobs (`openclaw cron list`) with their schedule, last run status,
//  and next fire time. Read-only mirror — cron jobs are created and managed on
//  the VM; tapping a row shows its full prompt + run state.
//

#if os(iOS)

import UIKit

final class OpenClawCronsVC: OpenClawSettingsBaseVC {

    private var items: [OpenClawSettingsService.Cron] = []

    init() { super.init(title: "Scheduled") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var emptyMessage: String { "No cron jobs are scheduled on this VM." }
    override var footerText: String? { "Cron jobs configured on your OpenClaw VM. Manage them on the VM." }
    override var hasContent: Bool { !items.isEmpty }

    override func loadData() async throws {
        items = try await service!.fetchCrons()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let cron = items[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = cron.name
        config.secondaryText = subtitle(for: cron)
        config.secondaryTextProperties.color = .secondaryLabel
        config.secondaryTextProperties.numberOfLines = 0
        config.image = UIImage(systemName: cron.enabled ? "calendar.badge.clock" : "calendar.badge.minus")
        config.imageProperties.tintColor = cron.enabled ? .systemBlue : .systemGray
        // A disabled job reads dimmed so the user can tell it won't fire.
        config.textProperties.color = cron.enabled ? .label : .secondaryLabel
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let cron = items[indexPath.row]
        var lines: [String] = [cron.scheduleText]
        if !cron.enabled { lines.append("Disabled") }
        if let status = cron.lastStatus, let date = cron.lastRunDate {
            lines.append("Last run: \(status) · \(OpenClawSettingsService.shortDateTime(date))")
        }
        if let next = cron.nextRunDate, cron.enabled {
            lines.append("Next run: \(OpenClawSettingsService.shortDateTime(next))")
        }
        if let message = cron.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            lines.append("\n\(message)")
        }
        let alert = UIAlertController(title: cron.name,
                                      message: lines.joined(separator: "\n"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Done", style: .default))
        present(alert, animated: true)
    }

    private func subtitle(for cron: OpenClawSettingsService.Cron) -> String {
        var parts: [String] = [cron.scheduleText]
        if let status = cron.lastStatus, let date = cron.lastRunDate {
            parts.append("\(status) · \(relativeTime(date))")
        } else if !cron.enabled {
            parts.append("Disabled")
        }
        return parts.joined(separator: " · ")
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

#endif
