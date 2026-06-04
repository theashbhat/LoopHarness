//
//  OpenClawSubagentsVC.swift
//  Loop
//
//  Settings ▸ Subagents, while a remote OpenClaw backend is active. Lists the
//  VM's background subagent task runs (`openclaw tasks list --runtime subagent`):
//  anything currently running plus recent history, newest first. Tapping a row
//  shows the full task prompt + its result/progress summary.
//

#if os(iOS)

import UIKit

final class OpenClawSubagentsVC: OpenClawSettingsBaseVC {

    private var items: [OpenClawSettingsService.Subagent] = []

    init() { super.init(title: "Subagents") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var emptyMessage: String { "No subagents have run on this VM yet." }
    override var footerText: String? { "Background subagent runs on your OpenClaw VM — active first, then recent history." }
    override var hasContent: Bool { !items.isEmpty }

    override func loadData() async throws {
        items = try await service!.fetchSubagents()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let agent = items[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = agent.displayTitle
        config.secondaryText = subtitle(for: agent)
        config.secondaryTextProperties.color = .secondaryLabel
        config.image = UIImage(systemName: Self.icon(for: agent.status))
        config.imageProperties.tintColor = Self.tint(for: agent.status)
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let agent = items[indexPath.row]
        var lines: [String] = ["Status: \(Self.statusLabel(agent.status))"]
        if let created = agent.createdDate {
            lines.append("Started: \(OpenClawSettingsService.shortDateTime(created))")
        }
        lines.append("\nTask:\n\(agent.task)")
        if let summary = agent.progressSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            lines.append("\nResult:\n\(summary)")
        }
        let alert = UIAlertController(title: agent.displayTitle,
                                      message: lines.joined(separator: "\n"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Done", style: .default))
        present(alert, animated: true)
    }

    private func subtitle(for agent: OpenClawSettingsService.Subagent) -> String {
        var parts: [String] = [Self.statusLabel(agent.status)]
        if let created = agent.createdDate {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .abbreviated
            parts.append(f.localizedString(for: created, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Status presentation

    private static func statusLabel(_ status: String) -> String {
        switch status {
        case "running":   return "Running"
        case "queued":    return "Queued"
        case "succeeded": return "Succeeded"
        case "failed":    return "Failed"
        case "timed_out": return "Timed out"
        case "cancelled": return "Cancelled"
        case "lost":      return "Lost"
        default:          return status.capitalized
        }
    }

    private static func icon(for status: String) -> String {
        switch status {
        case "running":   return "circle.dotted"
        case "queued":    return "hourglass"
        case "succeeded": return "checkmark.circle.fill"
        case "failed", "timed_out", "lost": return "exclamationmark.triangle.fill"
        case "cancelled": return "slash.circle"
        default:          return "hammer"
        }
    }

    private static func tint(for status: String) -> UIColor {
        switch status {
        case "running":   return .systemGreen
        case "queued":    return .systemYellow
        case "succeeded": return .systemGray
        case "failed", "timed_out", "lost": return .systemRed
        case "cancelled": return .systemGray
        default:          return .label
        }
    }
}

#endif
