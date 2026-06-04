//
//  OpenClawKeysVC.swift
//  Loop
//
//  Settings ▸ Keys, while a remote OpenClaw backend is active. Shows which model
//  providers the VM has working credentials for, derived from the configured
//  model catalog (the single source that reflects what actually resolves — provider
//  keys live in `.env`, IAM, and auth-profiles.json on the VM). Read-only: adding
//  or rotating keys happens on the VM, since it's an interactive flow there.
//

#if os(iOS)

import UIKit

final class OpenClawKeysVC: OpenClawSettingsBaseVC {

    private var items: [OpenClawSettingsService.ProviderKey] = []

    init() { super.init(title: "Keys") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var emptyMessage: String { "No model provider keys are configured on this VM." }
    override var footerText: String? {
        "Model providers your OpenClaw VM has working credentials for. Add or rotate keys on the VM."
    }
    override var hasContent: Bool { !items.isEmpty }

    override func loadData() async throws {
        items = try await service!.fetchProviderKeys()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let key = items[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = key.displayName
        config.secondaryText = key.configured
            ? "\(key.availableModels) model\(key.availableModels == 1 ? "" : "s") available"
            : "No usable models"
        config.secondaryTextProperties.color = .secondaryLabel
        config.image = UIImage(systemName: "key.fill")
        config.imageProperties.tintColor = key.configured ? .systemGreen : .systemGray
        cell.contentConfiguration = config

        // Green check mirrors the local Keys screen's "is set" affordance.
        if key.configured {
            let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            check.tintColor = .systemGreen
            cell.accessoryView = check
        } else {
            cell.accessoryView = nil
        }
        cell.selectionStyle = .none
        return cell
    }
}

#endif
