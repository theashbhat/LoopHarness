//
//  ExecutionBackendVC.swift
//  Loop
//
//  Settings → Execution Backend. Lets the user choose where Loop runs from:
//  the default Local / iCloud store, or a remote OpenClaw VM reached over SSH.
//
//  Local / iCloud is selected by default and behaves exactly as before. When
//  OpenClaw is selected the SSH endpoint + workspace fields appear; saving
//  validates connectivity and that the workspace path is reachable before the
//  backend is marked active. Until validation passes, new conversations keep
//  going to local — a calm, lossless degradation.
//
//  Secrets (private key, passphrase) are persisted to the Keychain via
//  OpenClawConfigStore and are never logged.
//

import UIKit

final class ExecutionBackendVC: UIViewController {

    // MARK: - UI

    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    private let backendControl = UISegmentedControl(items: [
        ConversationBackend.local.displayName,
        ConversationBackend.openclaw.displayName
    ])

    private let activeLabel = UILabel()

    /// Container for the OpenClaw fields; hidden when Local is selected.
    private let openClawSection = UIStackView()

    private let hostField = ExecutionBackendVC.makeField(placeholder: "Host (e.g. vm.example.com)")
    private let portField = ExecutionBackendVC.makeField(placeholder: "Port", keyboard: .numberPad)
    private let usernameField = ExecutionBackendVC.makeField(placeholder: "Username")
    private let privateKeyView = ExecutionBackendVC.makeTextView(placeholder: "Private Key (PEM)")
    private let passphraseField: UITextField = {
        let f = ExecutionBackendVC.makeField(placeholder: "Passphrase (optional)")
        f.isSecureTextEntry = true
        return f
    }()
    private let workspaceField = ExecutionBackendVC.makeField(placeholder: "Workspace path (e.g. ~/loop-workspace)")

    // Connection status row (hidden until a save triggers validation).
    private let statusRow = UIStackView()
    private let statusSpinner = UIActivityIndicatorView(style: .medium)
    private let statusDot = UIView()
    private let statusLabel = UILabel()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Execution Backend"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save", style: .done, target: self, action: #selector(saveTapped))

        setupLayout()
        loadCurrent()
        updateSectionVisibility()
        refreshActiveLabel()

        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    // MARK: - Layout

    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
        ])

        // Backend picker
        backendControl.addTarget(self, action: #selector(backendChanged), for: .valueChanged)
        stack.addArrangedSubview(backendControl)

        activeLabel.font = .preferredFont(forTextStyle: .subheadline)
        activeLabel.textColor = .secondaryLabel
        activeLabel.numberOfLines = 0
        stack.addArrangedSubview(activeLabel)

        // OpenClaw fields
        openClawSection.axis = .vertical
        openClawSection.spacing = 16

        let intro = UILabel()
        intro.font = .preferredFont(forTextStyle: .footnote)
        intro.textColor = .secondaryLabel
        intro.numberOfLines = 0
        intro.text = "Loop will store new conversations on this VM under the workspace path. The private key is kept in your keychain and never logged."
        openClawSection.addArrangedSubview(intro)

        let items: [(String, UIView)] = [
            ("Host", hostField),
            ("Port", portField),
            ("Username", usernameField),
            ("Private Key", privateKeyView),
            ("Passphrase", passphraseField),
            ("Workspace Path", workspaceField),
        ]
        for (label, field) in items {
            let lbl = UILabel()
            lbl.text = label
            lbl.font = .preferredFont(forTextStyle: .subheadline)
            lbl.textColor = .secondaryLabel
            openClawSection.addArrangedSubview(lbl)
            openClawSection.addArrangedSubview(field)
            if let tv = field as? UITextView {
                tv.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            }
        }

        // Clearing the validated flag when fields change forces a re-validate.
        for field in [hostField, portField, usernameField, passphraseField, workspaceField] {
            field.addTarget(self, action: #selector(connectionFieldsChanged), for: .editingChanged)
        }

        setupStatusRow()
        openClawSection.addArrangedSubview(statusRow)

        stack.addArrangedSubview(openClawSection)
    }

    private func setupStatusRow() {
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 8
        statusRow.isHidden = true

        statusSpinner.hidesWhenStopped = true

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.layer.cornerRadius = 5
        statusDot.isHidden = true
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),
        ])

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.numberOfLines = 0

        statusRow.addArrangedSubview(statusSpinner)
        statusRow.addArrangedSubview(statusDot)
        statusRow.addArrangedSubview(statusLabel)
    }

    // MARK: - Status

    private enum ConnState {
        case checking
        case connected(String)
        case failed(String)
    }

    private func setStatus(_ state: ConnState) {
        statusRow.isHidden = false
        switch state {
        case .checking:
            statusDot.isHidden = true
            statusSpinner.startAnimating()
            statusLabel.text = "Validating connection…"
            statusLabel.textColor = .secondaryLabel
        case .connected(let detail):
            statusSpinner.stopAnimating()
            statusDot.isHidden = false
            statusDot.backgroundColor = .systemGreen
            statusLabel.text = "Connected — \(detail)"
            statusLabel.textColor = .label
        case .failed(let message):
            statusSpinner.stopAnimating()
            statusDot.isHidden = false
            statusDot.backgroundColor = .systemRed
            statusLabel.text = message
            statusLabel.textColor = .label
        }
    }

    // MARK: - Data

    private func loadCurrent() {
        backendControl.selectedSegmentIndex =
            (ExecutionBackendStore.shared.selectedBackend == .openclaw) ? 1 : 0

        let cfg = OpenClawConfigStore.shared.config
        hostField.text = cfg.host
        portField.text = cfg.port == 0 ? "22" : String(cfg.port)
        usernameField.text = cfg.username
        privateKeyView.text = cfg.privateKey
        passphraseField.text = cfg.passphrase
        workspaceField.text = cfg.workspacePath
    }

    private func currentConfig() -> OpenClawConfig {
        OpenClawConfig(
            host: hostField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            port: Int(portField.text ?? "22") ?? 22,
            username: usernameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            privateKey: privateKeyView.text.trimmingCharacters(in: .whitespacesAndNewlines),
            passphrase: passphraseField.text ?? "",
            workspacePath: workspaceField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    private var selectedBackend: ConversationBackend {
        backendControl.selectedSegmentIndex == 1 ? .openclaw : .local
    }

    private func refreshActiveLabel() {
        let active = ExecutionBackendStore.shared.isOpenClawActive
            ? ConversationBackend.openclaw
            : ConversationBackend.local
        activeLabel.text = "Active backend: \(active.displayName). New conversations are created here."
    }

    private func updateSectionVisibility() {
        openClawSection.isHidden = (selectedBackend != .openclaw)
    }

    // MARK: - Actions

    @objc private func backendChanged() {
        view.endEditing(true)
        // Persist selection immediately. Routing to OpenClaw still requires a
        // successful validation, so selecting it alone never risks data.
        ExecutionBackendStore.shared.selectedBackend = selectedBackend
        updateSectionVisibility()
        refreshActiveLabel()
        if selectedBackend == .local {
            statusRow.isHidden = true
        }
    }

    @objc private func connectionFieldsChanged() {
        // Any edit invalidates a prior validation — the endpoint may have moved.
        if ExecutionBackendStore.shared.openClawValidated {
            ExecutionBackendStore.shared.openClawValidated = false
            refreshActiveLabel()
        }
    }

    @objc private func saveTapped() {
        view.endEditing(true)

        ExecutionBackendStore.shared.selectedBackend = selectedBackend

        // Local needs no validation — selection is enough.
        guard selectedBackend == .openclaw else {
            OpenClawConfigStore.shared.update(currentConfig())
            refreshActiveLabel()
            navigationController?.popViewController(animated: true)
            return
        }

        let config = currentConfig()
        OpenClawConfigStore.shared.update(config)

        guard config.isConfigured else {
            ExecutionBackendStore.shared.openClawValidated = false
            refreshActiveLabel()
            setStatus(.failed("Enter host, username, private key, and workspace path to connect."))
            return
        }

        setStatus(.checking)
        Task { @MainActor in
            do {
                let summary = try await OpenClawConversationStore.shared.validate(config)
                ExecutionBackendStore.shared.openClawValidated = true
                // Pull any conversations already on the VM into the local cache.
                OpenClawConversationStore.shared.refreshFromRemote()
                self.setStatus(.connected(summary))
                self.refreshActiveLabel()
            } catch {
                ExecutionBackendStore.shared.openClawValidated = false
                self.refreshActiveLabel()
                self.setStatus(.failed("Could not connect: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Keyboard insets

    @objc private func keyboardFrameWillChange(_ note: Notification) {
        guard
            let endFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
            let window = view.window
        else { return }
        let frameInView = view.convert(endFrame, from: window)
        let overlap = max(0, scrollView.frame.maxY - frameInView.minY)
        applyKeyboardInset(overlap, note: note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        applyKeyboardInset(0, note: note)
    }

    private func applyKeyboardInset(_ bottom: CGFloat, note: Notification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? UIView.AnimationCurve.easeInOut.rawValue
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw) << 16)
        UIView.animate(withDuration: duration, delay: 0, options: options, animations: {
            self.scrollView.contentInset.bottom = bottom
            self.scrollView.verticalScrollIndicatorInsets.bottom = bottom
            if bottom > 0, let focused = self.findFirstResponder(in: self.view) {
                let target = focused.convert(focused.bounds, to: self.scrollView).insetBy(dx: 0, dy: -12)
                self.scrollView.scrollRectToVisible(target, animated: false)
            }
        })
    }

    private func findFirstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for sub in view.subviews {
            if let found = findFirstResponder(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Factory helpers

    private static func makeField(placeholder: String, keyboard: UIKeyboardType = .default) -> UITextField {
        let f = UITextField()
        f.placeholder = placeholder
        f.borderStyle = .roundedRect
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.keyboardType = keyboard
        f.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        return f
    }

    private static func makeTextView(placeholder: String) -> UITextView {
        let tv = UITextView()
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.layer.cornerRadius = 8
        tv.layer.borderWidth = 0.5
        tv.layer.borderColor = UIColor.separator.cgColor
        tv.backgroundColor = .secondarySystemGroupedBackground
        tv.autocapitalizationType = .none
        tv.autocorrectionType = .no
        tv.isSecureTextEntry = true
        return tv
    }
}
