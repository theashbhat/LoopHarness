//
//  OpenClawModelsVC.swift
//  Loop
//
//  Settings ▸ Model, while a remote OpenClaw backend is active. Lists the VM's
//  configured model catalog grouped by provider, with the agent's current default
//  checkmarked. Tapping an available model sets it as the new default on the VM
//  (`openclaw models set`) — the one place this screen writes back, since the
//  model keys themselves are managed on the VM.
//

#if os(iOS)

import UIKit

final class OpenClawModelsVC: OpenClawSettingsBaseVC {

    /// Catalog grouped into provider sections, rebuilt each reload.
    private var grouped: [(provider: String, models: [OpenClawSettingsService.Model])] = []

    init() { super.init(title: "Model") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var emptyMessage: String { "No models are configured on this VM." }
    override var footerText: String? {
        "Models the VM has credentials for. Tap an available model to make it the agent's default. Add or remove keys on the VM."
    }
    override var hasContent: Bool { !grouped.isEmpty }

    override func loadData() async throws {
        grouped = try await service!.fetchModels().byProvider
    }

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int { grouped.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        OpenClawSettingsService.providerDisplayName(grouped[section].provider)
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == grouped.count - 1 ? footerText : nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        grouped[section].models.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let model = grouped[indexPath.section].models[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = model.name
        config.secondaryText = subtitle(for: model)
        config.secondaryTextProperties.color = .secondaryLabel
        // Dim models we can't switch to (no working credentials) so the list still
        // shows them but the tappable ones read as actionable.
        config.textProperties.color = model.available ? .label : .secondaryLabel
        cell.contentConfiguration = config
        cell.accessoryType = model.isDefault ? .checkmark : .none
        cell.selectionStyle = model.available ? .default : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let model = grouped[indexPath.section].models[indexPath.row]
        guard model.available, !model.isDefault else { return }
        setDefault(model)
    }

    private func subtitle(for model: OpenClawSettingsService.Model) -> String {
        var parts: [String] = []
        if let alias = model.aliases.first { parts.append(alias) }
        if let ctx = model.contextWindow, ctx > 0 {
            parts.append("\(ctx / 1000)K ctx")
        }
        if !model.available { parts.append("No key") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Set default (write-back)

    private func setDefault(_ model: OpenClawSettingsService.Model) {
        let progress = UIAlertController(title: "Setting default…",
                                         message: model.name, preferredStyle: .alert)
        present(progress, animated: true)
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.service!.setDefaultModel(model.preferredAlias)
                await MainActor.run {
                    progress.dismiss(animated: true) { self.reload() }
                }
            } catch {
                await MainActor.run {
                    progress.dismiss(animated: true) {
                        let alert = UIAlertController(title: "Couldn't set model",
                                                      message: error.localizedDescription,
                                                      preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        self.present(alert, animated: true)
                    }
                }
            }
        }
    }
}

#endif
