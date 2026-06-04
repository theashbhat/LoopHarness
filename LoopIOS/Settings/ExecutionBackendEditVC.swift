//
//  ExecutionBackendEditVC.swift
//  Loop
//
//  Detail screen for adding or editing a remote SSH VM execution backend. Lets
//  the user set a name, the SSH endpoint (host/port/username), the private key
//  (+ optional passphrase), and the workspace path. Saving validates
//  connectivity and that the workspace is reachable; on success the backend is
//  marked validated and selected as the active backend.
//
//  Secrets are write-only here: once a private key (or passphrase) has been
//  saved, it is never read back into the field. Editing an existing backend
//  shows the saved private key as a masked, non-editable placeholder with a
//  "Clear" button above the box — tap Clear to type a replacement (or leave it
//  blank to remove the key); the change only lands on Save. The passphrase
//  field keeps its blank-means-keep behavior. Secrets live in the Keychain via
//  `ExecutionBackendStore` and are never logged.
//

import UIKit

final class ExecutionBackendEditVC: UIViewController {

    // MARK: - UI

    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    private let nameField: UITextField = {
        let f = ExecutionBackendEditVC.makeField(placeholder: "Name (e.g. prod-nyc1)")
        f.autocapitalizationType = .words
        f.autocorrectionType = .default
        f.font = .preferredFont(forTextStyle: .body)
        return f
    }()
    private let hostField = ExecutionBackendEditVC.makeField(placeholder: "Host (e.g. vm.example.com)")
    private let portField = ExecutionBackendEditVC.makeField(placeholder: "Port", keyboard: .numberPad)
    private let usernameField = ExecutionBackendEditVC.makeField(placeholder: "Username")
    private let privateKeyView = ExecutionBackendEditVC.makeTextView()
    /// Hint shown only when a key is already stored, explaining the write-only field.
    private let keyHintLabel = UILabel()
    /// "Clear" button above the key box; shown only while a saved key is masked.
    private let clearKeyButton = UIButton(type: .system)
    private let passphraseField: UITextField = {
        let f = ExecutionBackendEditVC.makeField(placeholder: "Passphrase (optional)")
        f.isSecureTextEntry = true
        return f
    }()
    private let workspaceField = ExecutionBackendEditVC.makeField(placeholder: "Workspace path (e.g. ~/loop-workspace)")
    private let agentField = ExecutionBackendEditVC.makeField(placeholder: "Agent ID (default: main)")

    // Connection status row (hidden until a save triggers validation).
    private let statusRow = UIStackView()
    private let statusSpinner = UIActivityIndicatorView(style: .medium)
    private let statusDot = UIView()
    private let statusLabel = UILabel()

    // MARK: - Editing target

    /// The backend being edited. nil initializer ⇒ "new".
    private var editingBackend: ExecutionBackend
    private let isNew: Bool

    /// Whether the backend already had a stored private key / passphrase when
    /// editing began. Drives the write-only secret behavior: a blank field keeps
    /// the stored secret rather than clearing it.
    private let hadStoredKey: Bool
    private let hadStoredPassphrase: Bool

    /// Set when the user taps Clear on a saved key. Until Save nothing is
    /// persisted; on Save the stored key is replaced by whatever's now typed
    /// (blank ⇒ the key is removed).
    private var keyCleared = false

    init(backend: ExecutionBackend?) {
        self.editingBackend = backend ?? ExecutionBackend(name: "")
        self.isNew = (backend == nil)
        self.hadStoredKey = !(backend?.config.privateKey.isEmpty ?? true)
        self.hadStoredPassphrase = !(backend?.config.passphrase.isEmpty ?? true)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? "New Backend" : "Edit Backend"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save", style: .done, target: self, action: #selector(saveTapped))

        setupLayout()
        loadCurrent()

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

        let intro = UILabel()
        intro.font = .preferredFont(forTextStyle: .footnote)
        intro.textColor = .secondaryLabel
        intro.numberOfLines = 0
        intro.text = "Loop drives the OpenClaw agent on this VM: conversations come from the agent's sessions and new messages run the agent over SSH. The workspace path is used for the Files and Skills tabs. The private key is kept in your keychain and never logged."
        stack.addArrangedSubview(intro)

        let items: [(String, UIView)] = [
            ("Name", nameField),
            ("Host", hostField),
            ("Port", portField),
            ("Username", usernameField),
            ("Private Key", privateKeyView),
            ("Passphrase", passphraseField),
            ("Workspace Path", workspaceField),
            ("Agent ID", agentField),
        ]
        for (label, field) in items {
            if field === privateKeyView {
                // The key field gets a header row with a trailing "Clear" button
                // instead of a plain label.
                stack.addArrangedSubview(makeKeyHeaderRow(title: label))
            } else {
                let lbl = UILabel()
                lbl.text = label
                lbl.font = .preferredFont(forTextStyle: .subheadline)
                lbl.textColor = .secondaryLabel
                stack.addArrangedSubview(lbl)
            }
            stack.addArrangedSubview(field)
            if let tv = field as? UITextView {
                tv.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
                // Slot the key hint immediately under the private-key field.
                keyHintLabel.font = .preferredFont(forTextStyle: .footnote)
                keyHintLabel.textColor = .secondaryLabel
                keyHintLabel.numberOfLines = 0
                stack.addArrangedSubview(keyHintLabel)
            }
        }

        setupStatusRow()
        stack.addArrangedSubview(statusRow)

        // Editing an existing backend: offer an interactive terminal to the VM,
        // mirroring Settings → SSH. Hidden when adding a new backend — there's
        // nothing to connect to yet.
        if !isNew {
            stack.setCustomSpacing(28, after: statusRow)
            stack.addArrangedSubview(makeTerminalButton())
        }
    }

    private func makeTerminalButton() -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.tinted()
        config.title = "Open Terminal"
        config.image = UIImage(systemName: "terminal")
        config.imagePadding = 8
        config.baseForegroundColor = .systemGreen
        config.baseBackgroundColor = .systemGreen
        config.cornerStyle = .large
        button.configuration = config
        button.addTarget(self, action: #selector(openTerminalTapped), for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: 50).isActive = true
        return button
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

    // MARK: - Connection status

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
        let cfg = editingBackend.config
        nameField.text = editingBackend.isLocal ? "" : editingBackend.name
        hostField.text = cfg.host
        portField.text = cfg.port == 0 ? "22" : String(cfg.port)
        usernameField.text = cfg.username
        workspaceField.text = cfg.workspacePath
        agentField.text = cfg.agentId

        // Secrets are write-only: never load the stored values back into the
        // fields. When a key is already saved, show a masked, non-editable
        // placeholder plus a Clear button rather than an empty box.
        passphraseField.text = ""
        if hadStoredKey {
            privateKeyView.text = String(repeating: "•", count: 24)
            setKeyFieldEditable(false)
            clearKeyButton.isHidden = false
            keyHintLabel.isHidden = false
            keyHintLabel.text = "A private key is saved for this backend. Tap Clear to replace it."
        } else {
            privateKeyView.text = ""
            setKeyFieldEditable(true)
            clearKeyButton.isHidden = true
            keyHintLabel.isHidden = true
        }
    }

    /// Builds an `ExecutionBackend` from the current field values, preserving the
    /// edited backend's id and keeping stored secrets when their fields are left
    /// blank.
    private func currentBackend() -> ExecutionBackend {
        let port = Int(portField.text ?? "22") ?? 22
        let host = hostField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // While a saved key is shown masked (not cleared), keep it untouched —
        // the field's bullets aren't a real key. After Clear, use whatever's now
        // typed (blank ⇒ the key is removed on save).
        let privateKey: String
        if hadStoredKey && !keyCleared {
            privateKey = editingBackend.config.privateKey
        } else {
            privateKey = privateKeyView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let typedPass = passphraseField.text ?? ""
        let passphrase = typedPass.isEmpty && hadStoredPassphrase ? editingBackend.config.passphrase : typedPass

        let config = OpenClawConfig(
            host: host,
            port: port,
            username: usernameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            privateKey: privateKey,
            passphrase: passphrase,
            workspacePath: workspaceField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            agentId: agentField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "main")

        return ExecutionBackend(id: editingBackend.id,
                                name: name.isEmpty ? host : name,
                                config: config)
    }

    // MARK: - Private key field

    /// Header row for the key box: the field label on the left and a trailing
    /// "Clear" button that's only visible while a saved key is masked.
    private func makeKeyHeaderRow(title: String) -> UIView {
        let lbl = UILabel()
        lbl.text = title
        lbl.font = .preferredFont(forTextStyle: .subheadline)
        lbl.textColor = .secondaryLabel
        lbl.setContentHuggingPriority(.defaultLow, for: .horizontal)

        clearKeyButton.setTitle("Clear", for: .normal)
        clearKeyButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        clearKeyButton.setContentHuggingPriority(.required, for: .horizontal)
        clearKeyButton.addTarget(self, action: #selector(clearKeyTapped), for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [lbl, clearKeyButton])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        return row
    }

    /// Toggles the key box between the masked, read-only state and an editable
    /// empty box the user can paste a new key into.
    private func setKeyFieldEditable(_ editable: Bool) {
        privateKeyView.isEditable = editable
        privateKeyView.isSelectable = editable
        privateKeyView.textColor = editable ? .label : .secondaryLabel
    }

    /// Clears the saved-key placeholder so a new key can be typed. Nothing is
    /// persisted until Save — on save the stored key is replaced by whatever's
    /// in the box (blank removes it).
    @objc private func clearKeyTapped() {
        keyCleared = true
        privateKeyView.text = ""
        setKeyFieldEditable(true)
        clearKeyButton.isHidden = true
        keyHintLabel.isHidden = false
        keyHintLabel.text = "Enter a new private key, or leave blank to remove the saved key."
        privateKeyView.becomeFirstResponder()
    }

    // MARK: - Terminal

    /// Opens the in-app SSH terminal against the current field values (keeping a
    /// stored, un-cleared key). Mirrors Settings → SSH. Doesn't require saving
    /// first, so the user can poke at the VM while still editing.
    @objc private func openTerminalTapped() {
        view.endEditing(true)
        let ssh = currentBackend().config.sshConfig
        guard ssh.isConfigured else {
            let alert = UIAlertController(
                title: "Not configured",
                message: "Add a host, username, and private key before opening a terminal.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let terminal = SSHTerminalViewController(config: ssh)
        terminal.modalPresentationStyle = .fullScreen
        present(terminal, animated: true)
    }

    // MARK: - Actions

    @objc private func saveTapped() {
        view.endEditing(true)

        // Persist the entry regardless of connectivity so it's saved (and shows
        // in the list) even if the VM is currently unreachable. Re-read it back
        // so subsequent edits keep the now-stored secrets.
        let backend = ExecutionBackendStore.shared.addOrUpdate(currentBackend())
        editingBackend = backend

        guard backend.config.isConfigured else {
            ExecutionBackendStore.shared.setValidated(false, for: backend.id)
            setStatus(.failed("Enter host, username, private key, and workspace path to connect."))
            return
        }

        setStatus(.checking)
        let config = backend.config
        let id = backend.id
        Task { @MainActor in
            do {
                let summary = try await OpenClawConversationStore.validate(config)
                ExecutionBackendStore.shared.setValidated(true, for: id)
                // Make the freshly-validated backend the active one.
                ExecutionBackendStore.shared.select(id: id)
                self.setStatus(.connected(summary))
                // Pop back to the list so the new active checkmark is visible.
                self.navigationController?.popViewController(animated: true)
            } catch {
                ExecutionBackendStore.shared.setValidated(false, for: id)
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

    private static func makeTextView() -> UITextView {
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
