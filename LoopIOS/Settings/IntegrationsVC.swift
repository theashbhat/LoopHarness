//
//  IntegrationsVC.swift
//  Loop
//
//  Settings → Integrations: list of third-party services Loop can pull
//  context from / take actions in. v1 surfaces Google Calendar (live via
//  Apple's EventKit — covers every account the user has added to iOS
//  Settings → Calendars: Google, iCloud, Exchange, Office365), Notion
//  (token-backed via ntn_… integration token in Keychain), and Slack
//  (token-backed via xoxp- user token in Keychain). Gmail is stubbed as
//  coming soon.
//
//  When the user taps an active row Loop requests the relevant permission,
//  opens the key editor, or surfaces a Settings.app deep link.
//  Coming-soon rows are non-selectable.
//

import UIKit
import EventKit
#if canImport(HealthKit)
import HealthKit
#endif

final class IntegrationsVC: UIViewController {

    /// Row model so the same cell renderer handles "Connected" (Google
    /// Calendar via EventKit, Notion via integration token, Slack via user
    /// token), and "Coming soon" (Gmail, which still needs OAuth wiring).
    private struct Integration {
        enum Status {
            case connected
            case notConnected
            case denied              // user said no in iOS settings
            case comingSoon
        }
        let title: String
        let subtitle: String
        let icon: String            // SF Symbol name
        let tint: UIColor
        var status: Status
        let handler: ((IntegrationsVC) -> Void)?
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var integrations: [Integration] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Integrations"
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

        // EventKit status changes (e.g. user toggles Loop in iOS
        // Settings → Privacy → Calendars) come through this notification.
        // Refresh the row so the subtitle reflects current state.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshRows),
            name: .EKEventStoreChanged,
            object: nil
        )

        rebuildIntegrations()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Re-evaluate every appearance — the user might have gone to
        // Settings.app and flipped a permission while away from this screen.
        rebuildIntegrations()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func refreshRows() {
        DispatchQueue.main.async { [weak self] in
            self?.rebuildIntegrations()
        }
    }

    private func rebuildIntegrations() {
        let calendarStatus: Integration.Status
        let calendarSubtitle: String
        switch CalendarSkill.shared.currentAuthorizationStatus {
        case .fullAccess, .authorized:
            calendarStatus = .connected
            calendarSubtitle = "Connected · reads any calendar in iOS Settings"
        case .denied, .restricted, .writeOnly:
            calendarStatus = .denied
            calendarSubtitle = "Calendar access blocked — enable in iOS Settings"
        case .notDetermined:
            calendarStatus = .notConnected
            calendarSubtitle = "Tap to connect Google / iCloud / Exchange"
        @unknown default:
            calendarStatus = .notConnected
            calendarSubtitle = "Tap to connect"
        }

        integrations = [
            Integration(
                title: "Google Calendar",
                subtitle: calendarSubtitle,
                icon: "calendar",
                tint: .systemRed,
                status: calendarStatus,
                handler: { vc in vc.handleCalendarTap() }
            ),
            notionIntegration(),
            // Gmail intentionally omitted until OAuth ships — surfacing a
            // disabled "Coming soon" row reads as a dead end and pushes the
            // working integrations down the list. Restore once the OAuth
            // flow lands.
            slackIntegration(),
            googleWorkspaceIntegration(),
            githubIntegration(),
            devinIntegration(),
            twitterIntegration(),
            healthIntegration(),
        ]

        tableView.reloadData()
    }

    /// GitHub. Token-backed via a Personal Access Token in Settings → Keys
    /// (`githubPAT`). The Enterprise base URL is optional — connection state
    /// is just "did the user paste a `github_pat_…` / `ghp_…` token?", and
    /// the editor surfaces the base URL field next to the PAT for the rare
    /// user on GHES.
    private func githubIntegration() -> Integration {
        let hasToken = !((KeyStore.shared.value(for: .githubPAT) ?? "").isEmpty)
        return Integration(
            title: "GitHub",
            subtitle: hasToken
                ? "Connected · personal access token"
                : "Tap to paste your GitHub PAT (read repos, PRs, issues)",
            icon: "chevron.left.forwardslash.chevron.right",
            tint: .label,
            status: hasToken ? .connected : .notConnected,
            handler: { vc in vc.handleGitHubTap() }
        )
    }

    private func handleGitHubTap() {
        let hasToken = !((KeyStore.shared.value(for: .githubPAT) ?? "").isEmpty)
        guard hasToken else {
            pushGitHubKeyEditor(.githubPAT)
            return
        }
        // Connected. Offer to edit either the PAT or the optional GHES base
        // URL — same shape as the Devin row, which similarly has a primary
        // credential + an optional secondary field.
        let alert = UIAlertController(
            title: "GitHub connected",
            message: "Loop can read repos, PRs, issues, and notifications via your personal access token. You can replace either credential below.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Edit Access Token", style: .default) { [weak self] _ in
            self?.pushGitHubKeyEditor(.githubPAT)
        })
        alert.addAction(UIAlertAction(title: "Edit Base URL (Enterprise)", style: .default) { [weak self] _ in
            self?.pushGitHubKeyEditor(.githubBaseURL)
        })
        alert.addAction(UIAlertAction(title: "Done", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(alert, animated: true)
    }

    private func pushGitHubKeyEditor(_ key: KeyStore.Key) {
        navigationController?.pushViewController(KeyEditVC(focusing: key), animated: true)
    }

    /// Devin coding agent. Connection state is "did the user paste BOTH a
    /// cog_… API key AND an org-… Organization ID?". Both are required by the
    /// Devin v3 API (the key authenticates, the org id selects the workspace
    /// in the URL path). Missing either → show as not-connected and route
    /// straight into the missing-field editor.
    private func devinIntegration() -> Integration {
        let hasKey = !((KeyStore.shared.value(for: .devin) ?? "").isEmpty)
        let hasOrg = !((KeyStore.shared.value(for: .devinOrgID) ?? "").isEmpty)
        let status: Integration.Status
        let subtitle: String
        if hasKey && hasOrg {
            status = .connected
            subtitle = "Connected · dispatches coding agents that open PRs"
        } else if hasKey || hasOrg {
            status = .denied
            subtitle = hasKey
                ? "Almost connected — add your Organization ID"
                : "Almost connected — add your cog_ API key"
        } else {
            status = .notConnected
            subtitle = "Tap to add your Devin API key + Organization ID"
        }
        return Integration(
            title: "Devin.AI",
            subtitle: subtitle,
            icon: "hammer",
            tint: .systemBlue,
            status: status,
            handler: { vc in vc.handleDevinTap() }
        )
    }

    private func handleDevinTap() {
        let hasKey = !((KeyStore.shared.value(for: .devin) ?? "").isEmpty)
        let hasOrg = !((KeyStore.shared.value(for: .devinOrgID) ?? "").isEmpty)

        // Missing both → jump straight to the API key editor; after the user
        // saves it the Integrations row will prompt for the org id next time.
        if !hasKey && !hasOrg { pushDevinEditor(.devin); return }

        // Missing one of two → jump to the missing field directly.
        if !hasKey { pushDevinEditor(.devin); return }
        if !hasOrg { pushDevinEditor(.devinOrgID); return }

        // Both set — offer to edit either.
        let alert = UIAlertController(
            title: "Devin connected",
            message: "Loop can dispatch Devin coding agents on your behalf. You can replace or remove either credential below.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Edit API Key", style: .default) { [weak self] _ in
            self?.pushDevinEditor(.devin)
        })
        alert.addAction(UIAlertAction(title: "Edit Organization ID", style: .default) { [weak self] _ in
            self?.pushDevinEditor(.devinOrgID)
        })
        alert.addAction(UIAlertAction(title: "Done", style: .cancel))
        // iPad needs an anchor for action sheets — fall back to the nav bar
        // if the cell isn't easily reachable from here.
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(alert, animated: true)
    }

    private func pushDevinEditor(_ key: KeyStore.Key) {
        // KeyEditVC edits a whole service (Devin = API key + org id) in a
        // single panel; `focusing:` lands the user on the specific field they
        // came to set (api key vs. org id) without losing the other field.
        navigationController?.pushViewController(KeyEditVC(focusing: key), animated: true)
    }

    /// Notion is token-backed — connection state is "did the user paste an
    /// ntn_… integration token into Settings → Keys → Notion Integration
    /// Token?". Mirrors the Slack pattern below.
    private func notionIntegration() -> Integration {
        let hasToken = !((KeyStore.shared.value(for: .notionIntegrationToken) ?? "").isEmpty)
        return Integration(
            title: "Notion",
            subtitle: hasToken
                ? "Connected · Notion integration token"
                : "Tap to paste your Notion integration token",
            icon: "note.text",
            tint: .label,
            status: hasToken ? .connected : .notConnected,
            handler: { vc in vc.handleNotionTap() }
        )
    }

    private func handleNotionTap() {
        let hasToken = !((KeyStore.shared.value(for: .notionIntegrationToken) ?? "").isEmpty)
        if hasToken {
            let alert = UIAlertController(
                title: "Notion connected",
                message: "Loop is connected to Notion via an integration token. You can replace or remove the token in Settings → Keys → Notion Integration Token.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Edit Token", style: .default) { [weak self] _ in
                self?.pushNotionKeyEditor()
            })
            alert.addAction(UIAlertAction(title: "Done", style: .cancel))
            present(alert, animated: true)
        } else {
            pushNotionKeyEditor()
        }
    }

    private func pushNotionKeyEditor() {
        navigationController?.pushViewController(KeyEditVC(focusing: .notionIntegrationToken), animated: true)
    }

    /// Slack is a personal-only integration in v1 — connection state is just
    /// "did the user paste an xoxp- token into Settings → Keys → Slack User
    /// Token?". A future OAuth phase swaps how the token gets there without
    /// changing this row.
    private func slackIntegration() -> Integration {
        let hasToken = !((KeyStore.shared.value(for: .slackUserToken) ?? "").isEmpty)
        return Integration(
            title: "Slack",
            subtitle: hasToken
                ? "Connected · personal user token"
                : "Tap to paste your Slack user token",
            icon: "message",
            tint: .systemPurple,
            status: hasToken ? .connected : .notConnected,
            handler: { vc in vc.handleSlackTap() }
        )
    }

    private func handleSlackTap() {
        let hasToken = !((KeyStore.shared.value(for: .slackUserToken) ?? "").isEmpty)
        if hasToken {
            let alert = UIAlertController(
                title: "Slack connected",
                message: "Loop is connected to Slack via a personal user token. You can replace or remove the token in Settings → Keys → Slack User Token.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Edit Token", style: .default) { [weak self] _ in
                self?.pushSlackKeyEditor()
            })
            alert.addAction(UIAlertAction(title: "Done", style: .cancel))
            present(alert, animated: true)
        } else {
            pushSlackKeyEditor()
        }
    }

    /// Push the key editor directly onto the Integrations stack so Back from
    /// the editor returns to Integrations (where the user tapped in), not the
    /// generic Keys list. `focusing:` lands them on the specific field.
    private func pushSlackKeyEditor() {
        navigationController?.pushViewController(KeyEditVC(focusing: .slackUserToken), animated: true)
    }

    // MARK: Twitter

    private func twitterIntegration() -> Integration {
        let hasKey = !((KeyStore.shared.value(for: .xAPIKey) ?? "").isEmpty)
        return Integration(
            title: "X (Twitter)",
            subtitle: hasKey
                ? "Connected \u{00B7} OAuth 1.0a keys"
                : "Tap to add your X API keys",
            icon: "bubble.left",
            tint: .label,
            status: hasKey ? .connected : .notConnected,
            handler: { vc in vc.handleTwitterTap() }
        )
    }

    private func handleTwitterTap() {
        let hasKey = !((KeyStore.shared.value(for: .xAPIKey) ?? "").isEmpty)
        if hasKey {
            let alert = UIAlertController(
                title: "X (Twitter) connected",
                message: "Loop can post tweets on your behalf. You can replace or remove the keys in Settings \u{2192} Keys.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Edit Keys", style: .default) { [weak self] _ in
                self?.navigationController?.pushViewController(KeyEditVC(focusing: .xAPIKey), animated: true)
            })
            alert.addAction(UIAlertAction(title: "Done", style: .cancel))
            present(alert, animated: true)
        } else {
            navigationController?.pushViewController(KeyEditVC(focusing: .xAPIKey), animated: true)
        }
    }

    // MARK: - Google Workspace

    private func googleWorkspaceIntegration() -> Integration {
        let hasToken = !((KeyStore.shared.value(for: .googleWorkspaceAccessToken) ?? "").isEmpty)
        return Integration(
            title: "Google Workspace",
            subtitle: hasToken
                ? "Connected \u{00B7} Drive, Gmail, Calendar"
                : "Tap to paste your Google OAuth2 access token",
            icon: "envelope",
            tint: .systemBlue,
            status: hasToken ? .connected : .notConnected,
            handler: { vc in vc.handleGoogleWorkspaceTap() }
        )
    }

    private func handleGoogleWorkspaceTap() {
        let hasToken = !((KeyStore.shared.value(for: .googleWorkspaceAccessToken) ?? "").isEmpty)
        if hasToken {
            let alert = UIAlertController(
                title: "Google Workspace connected",
                message: "Loop can access your Google Drive, Gmail, and Calendar. Services available depend on the scopes granted to your access token.",
                preferredStyle: .actionSheet
            )
            alert.addAction(UIAlertAction(title: "Edit Access Token", style: .default) { [weak self] _ in
                self?.pushGoogleWorkspaceKeyEditor(.googleWorkspaceAccessToken)
            })
            alert.addAction(UIAlertAction(title: "Edit Refresh Token", style: .default) { [weak self] _ in
                self?.pushGoogleWorkspaceKeyEditor(.googleWorkspaceRefreshToken)
            })
            alert.addAction(UIAlertAction(title: "Revoke / Remove", style: .destructive) { [weak self] _ in
                KeyStore.shared.setValue(nil, for: .googleWorkspaceAccessToken)
                KeyStore.shared.setValue(nil, for: .googleWorkspaceRefreshToken)
                KeyStore.shared.setValue(nil, for: .googleWorkspaceClientId)
                KeyStore.shared.setValue(nil, for: .googleWorkspaceClientSecret)
                self?.rebuildIntegrations()
            })
            alert.addAction(UIAlertAction(title: "Done", style: .cancel))
            if let popover = alert.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            present(alert, animated: true)
        } else {
            pushGoogleWorkspaceKeyEditor(.googleWorkspaceAccessToken)
        }
    }

    private func pushGoogleWorkspaceKeyEditor(_ key: KeyStore.Key) {
        navigationController?.pushViewController(KeyEditVC(focusing: key), animated: true)
    }

    // MARK: - Apple Health

    private func healthIntegration() -> Integration {
        #if canImport(HealthKit) && os(iOS)
        let status = HealthKitManager.shared.currentAuthorizationStatus
        let integrationStatus: Integration.Status
        let subtitle: String
        switch status {
        case .authorized:
            integrationStatus = .connected
            subtitle = "Connected \u{00B7} read-only access to steps, workouts, heart rate, sleep"
        case .denied:
            integrationStatus = .denied
            subtitle = "Health access blocked \u{2014} enable in iOS Settings"
        case .notDetermined:
            integrationStatus = .notConnected
            subtitle = "Tap to connect Apple Health (read-only)"
        case .unavailable:
            integrationStatus = .comingSoon
            subtitle = "HealthKit is not available on this device"
        }
        return Integration(
            title: "Apple Health",
            subtitle: subtitle,
            icon: "heart.fill",
            tint: .systemPink,
            status: integrationStatus,
            handler: status == .unavailable ? nil : { vc in vc.handleHealthTap() }
        )
        #else
        return Integration(
            title: "Apple Health",
            subtitle: "Not available on this platform",
            icon: "heart.fill",
            tint: .systemPink,
            status: .comingSoon,
            handler: nil
        )
        #endif
    }

    #if canImport(HealthKit) && os(iOS)
    private func handleHealthTap() {
        let status = HealthKitManager.shared.currentAuthorizationStatus
        switch status {
        case .authorized:
            let alert = UIAlertController(
                title: "Apple Health connected",
                message: "Loop can read your steps, distance, workouts, heart rate, sleep, and body mass. To disconnect, open iOS Settings \u{2192} Privacy & Security \u{2192} Health \u{2192} Loop and disable access.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            })
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            present(alert, animated: true)
        case .denied:
            let alert = UIAlertController(
                title: "Health access blocked",
                message: "Loop's Health access was previously denied. Re-enable Loop in iOS Settings \u{2192} Privacy & Security \u{2192} Health.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            present(alert, animated: true)
        case .notDetermined:
            HealthKitManager.shared.requestAuthorization { [weak self] _, _ in
                self?.rebuildIntegrations()
            }
        case .unavailable:
            break
        }
    }
    #endif

    private func handleCalendarTap() {
        switch CalendarSkill.shared.currentAuthorizationStatus {
        case .fullAccess, .authorized:
            // Already connected. Show a small alert with the option to
            // revoke (which has to happen in iOS Settings — the app can't
            // revoke its own granted access).
            let alert = UIAlertController(
                title: "Google Calendar connected",
                message: "Loop can see your upcoming events and draft new ones via the system event editor. To disconnect, open iOS Settings → Privacy & Security → Calendars and disable Loop.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            })
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            present(alert, animated: true)
        case .denied, .restricted, .writeOnly:
            // The system won't re-prompt; punt the user to Settings.app.
            let alert = UIAlertController(
                title: "Calendar access blocked",
                message: "Loop's calendar access was previously denied. Re-enable Loop in iOS Settings → Privacy & Security → Calendars.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            present(alert, animated: true)
        case .notDetermined:
            CalendarSkill.shared.requestAccessIfNeeded { [weak self] _ in
                self?.rebuildIntegrations()
            }
        @unknown default:
            break
        }
    }
}

extension IntegrationsVC: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return integrations.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        let integration = integrations[indexPath.row]

        var config = cell.defaultContentConfiguration()
        config.text = integration.title
        config.secondaryText = integration.subtitle
        config.image = UIImage(systemName: integration.icon)
        config.imageProperties.tintColor = integration.tint
        cell.contentConfiguration = config

        switch integration.status {
        case .connected:
            let dot = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            dot.tintColor = .systemGreen
            cell.accessoryView = dot
        case .notConnected:
            cell.accessoryView = nil
            cell.accessoryType = .disclosureIndicator
        case .denied:
            let dot = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
            dot.tintColor = .systemOrange
            cell.accessoryView = dot
        case .comingSoon:
            cell.accessoryView = nil
            cell.accessoryType = .none
        }

        cell.selectionStyle = (integration.handler == nil) ? .none : .default
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        integrations[indexPath.row].handler?(self)
    }
}
