//
//  RunnerEditVC.swift
//  Loop
//
//  Add/edit form for a single Loop Runner. Shows nickname, URL, and shared
//  secret fields plus a "Test Connection" button that calls `GET /health`.
//  Secrets are stored in the Keychain via RunnerStore — never in UserDefaults.
//
//  On first runner add the app requests notification permission
//  (`.alert + .sound + .badge`) so results can surface as local notifications.
//

#if os(iOS)

import UIKit
import UserNotifications
import os

final class RunnerEditVC: UIViewController {

    var onSave: (() -> Void)?

    private var runner: RunnerConfig?
    private let isNew: Bool

    private let nicknameField = UITextField()
    private let urlField = UITextField()
    private let secretField = UITextField()
    private let testButton = UIButton(type: .system)
    private let statusLabel = UILabel()

    // SSH-transport controls.
    private let urlLabel = UILabel()
    private let portLabel = UILabel()
    private let portField = UITextField()
    private let sshSwitch = UISwitch()
    private let sshHintLabel = UILabel()

    init(runner: RunnerConfig?) {
        self.runner = runner
        self.isNew = runner == nil
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? "Add Runner" : "Edit Runner"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .save,
            target: self,
            action: #selector(saveTapped)
        )

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
        ])

        stack.addArrangedSubview(makeLabel("Nickname"))
        configureField(nicknameField, placeholder: "My Runner VM", text: runner?.nickname)
        stack.addArrangedSubview(nicknameField)

        // Transport toggle — poll over the Settings → SSH host instead of a URL.
        let sshRow = UIStackView()
        sshRow.axis = .horizontal
        sshRow.alignment = .center
        sshRow.addArrangedSubview(makeLabel("Connect via SSH host"))
        sshRow.addArrangedSubview(sshSwitch)
        sshSwitch.addTarget(self, action: #selector(sshSwitchChanged), for: .valueChanged)
        stack.addArrangedSubview(sshRow)

        sshHintLabel.font = .preferredFont(forTextStyle: .caption1)
        sshHintLabel.textColor = .secondaryLabel
        sshHintLabel.numberOfLines = 0
        sshHintLabel.text = "Polls the runner at 127.0.0.1:<port> on your Settings → SSH host over SSH. No public URL needed."
        stack.addArrangedSubview(sshHintLabel)

        urlLabel.text = "Base URL"
        urlLabel.font = .preferredFont(forTextStyle: .subheadline)
        urlLabel.textColor = .secondaryLabel
        stack.addArrangedSubview(urlLabel)
        configureField(urlField, placeholder: "https://my-vm.example.com:8080", text: runner?.baseURL)
        urlField.keyboardType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        stack.addArrangedSubview(urlField)

        portLabel.text = "Remote port"
        portLabel.font = .preferredFont(forTextStyle: .subheadline)
        portLabel.textColor = .secondaryLabel
        stack.addArrangedSubview(portLabel)
        configureField(portField, placeholder: "8088", text: runner?.sshRemotePort.map(String.init))
        portField.keyboardType = .numberPad
        stack.addArrangedSubview(portField)

        stack.addArrangedSubview(makeLabel("Shared Secret"))
        configureField(secretField, placeholder: "Bearer token", text: nil)
        secretField.isSecureTextEntry = true
        secretField.autocapitalizationType = .none
        secretField.autocorrectionType = .no
        if let ref = runner?.secretRef, let existing = RunnerStore.shared.secret(for: ref) {
            secretField.text = existing
        }
        stack.addArrangedSubview(secretField)

        testButton.setTitle("  Test Connection", for: .normal)
        testButton.setImage(UIImage(systemName: "bolt.horizontal"), for: .normal)
        testButton.addTarget(self, action: #selector(testTapped), for: .touchUpInside)
        testButton.contentHorizontalAlignment = .center
        stack.addArrangedSubview(testButton)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        stack.addArrangedSubview(statusLabel)

        sshSwitch.isOn = runner?.usesSSH ?? false
        updateTransportVisibility()
    }

    // MARK: - Actions

    @objc private func saveTapped() {
        guard let nickname = nicknameField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !nickname.isEmpty else {
            showAlert("Nickname is required")
            return
        }
        guard let secret = secretField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty else {
            showAlert("Shared secret is required")
            return
        }

        // Resolve the transport: SSH host + remote port, or a direct URL.
        let baseURL: String
        let sshPort: Int?
        if sshSwitch.isOn {
            let cfg = SSHConfigStore.shared.config
            guard cfg.isConfigured else {
                showAlert("Configure your SSH host in Settings → SSH first.")
                return
            }
            guard let port = resolvedPort() else {
                showAlert("Enter a valid remote port (e.g. 8088).")
                return
            }
            sshPort = port
            baseURL = "ssh://\(cfg.host):\(port)"
        } else {
            guard let urlStr = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !urlStr.isEmpty,
                  URL(string: urlStr) != nil else {
                showAlert("A valid URL is required")
                return
            }
            sshPort = nil
            baseURL = urlStr
        }

        let isFirstRunner = RunnerStore.shared.loadRunners().isEmpty && isNew

        if isNew {
            let config = RunnerConfig(nickname: nickname, baseURL: baseURL, sshRemotePort: sshPort)
            RunnerStore.shared.setSecret(secret, for: config.secretRef)
            RunnerStore.shared.addRunner(config)
        } else if var existing = runner {
            existing.nickname = nickname
            existing.baseURL = baseURL
            existing.sshRemotePort = sshPort
            RunnerStore.shared.setSecret(secret, for: existing.secretRef)
            RunnerStore.shared.updateRunner(existing)
        }

        if isFirstRunner {
            requestNotificationPermission()
        }

        onSave?()
        navigationController?.popViewController(animated: true)
    }

    @objc private func testTapped() {
        guard let secret = secretField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty else {
            statusLabel.text = "Fill in the shared secret first"
            statusLabel.textColor = .systemOrange
            return
        }

        // Pick the probe matching the selected transport.
        let probe: () async throws -> RunnerHealthResponse
        if sshSwitch.isOn {
            guard SSHConfigStore.shared.config.isConfigured else {
                statusLabel.text = "Configure your SSH host in Settings → SSH first"
                statusLabel.textColor = .systemOrange
                return
            }
            guard let port = resolvedPort() else {
                statusLabel.text = "Enter a valid remote port"
                statusLabel.textColor = .systemOrange
                return
            }
            let client = LoopRunnerSSHClient(sharedSecret: secret, remotePort: port)
            probe = { try await client.checkHealth() }
        } else {
            guard let urlStr = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: urlStr) else {
                statusLabel.text = "Fill in URL and secret first"
                statusLabel.textColor = .systemOrange
                return
            }
            let client = LoopRunnerClient(baseURL: url, sharedSecret: secret)
            probe = { try await client.checkHealth() }
        }

        statusLabel.text = "Testing…"
        statusLabel.textColor = .secondaryLabel
        testButton.isEnabled = false

        Task {
            do {
                let health = try await probe()
                await MainActor.run {
                    statusLabel.text = "Connected — \(health.summary)"
                    statusLabel.textColor = .systemGreen
                    testButton.isEnabled = true
                }
            } catch {
                await MainActor.run {
                    statusLabel.text = "Failed: \(error.localizedDescription)"
                    statusLabel.textColor = .systemRed
                    testButton.isEnabled = true
                }
            }
        }
    }

    /// Remote port from the field, defaulting to 8088 when blank. Returns nil if
    /// a non-empty value isn't a valid TCP port.
    private func resolvedPort() -> Int? {
        let raw = portField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return 8088 }
        guard let p = Int(raw), p > 0, p < 65536 else { return nil }
        return p
    }

    private func updateTransportVisibility() {
        let ssh = sshSwitch.isOn
        urlLabel.isHidden = ssh
        urlField.isHidden = ssh
        portLabel.isHidden = !ssh
        portField.isHidden = !ssh
        sshHintLabel.isHidden = !ssh
    }

    @objc private func sshSwitchChanged() {
        updateTransportVisibility()
    }

    // MARK: - Notification permission

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error = error {
                os_log(.error, "Notification auth error: %{public}@", error.localizedDescription)
            }
            // Now that the user has authorized, obtain the APNs token and
            // register it with the backend immediately (don't wait for next launch).
            if granted {
                PushRegistration.shared.registerIfAuthorized()
            }
        }
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        return label
    }

    private func configureField(_ field: UITextField, placeholder: String, text: String?) {
        field.borderStyle = .roundedRect
        field.placeholder = placeholder
        field.text = text
        field.font = .preferredFont(forTextStyle: .body)
    }

    private func showAlert(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

#endif
