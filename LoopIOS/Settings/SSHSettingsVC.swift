//
//  SSHSettingsVC.swift
//  Loop
//
//  Detail screen pushed from Settings → SSH. Lets the user configure host,
//  port, username, private key (secure textarea), and optional passphrase.
//  Values are persisted through SSHConfigStore.
//

import UIKit

final class SSHSettingsVC: UIViewController {

    // MARK: - UI

    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    private let nameField: UITextField = {
        let f = SSHSettingsVC.makeField(placeholder: "Name (e.g. prod-nyc1)")
        f.autocapitalizationType = .words
        f.autocorrectionType = .default
        f.font = .preferredFont(forTextStyle: .body)
        return f
    }()
    private let hostField = SSHSettingsVC.makeField(placeholder: "Host (e.g. 192.168.1.10)")
    private let portField = SSHSettingsVC.makeField(placeholder: "Port", keyboard: .numberPad)
    private let usernameField = SSHSettingsVC.makeField(placeholder: "Username")
    private let privateKeyView = SSHSettingsVC.makeTextView(placeholder: "Private Key (PEM)")
    private let passphraseField: UITextField = {
        let f = SSHSettingsVC.makeField(placeholder: "Passphrase (optional)")
        f.isSecureTextEntry = true
        return f
    }()

    // Connection status row (hidden until a save triggers a connection check).
    private let statusRow = UIStackView()
    private let statusSpinner = UIActivityIndicatorView(style: .medium)
    private let statusDot = UIView()
    private let statusLabel = UILabel()

    // Opens an interactive shell using the current values.
    private let openTerminalButton: UIButton = {
        var cfg = UIButton.Configuration.filled()
        cfg.title = "Open Terminal"
        cfg.image = UIImage(systemName: "terminal")
        cfg.imagePadding = 8
        cfg.buttonSize = .large
        return UIButton(configuration: cfg)
    }()

    // MARK: - Editing target

    /// The connection being edited. A nil initializer argument means "new".
    private var editingConnection: SSHConfig
    private let isNew: Bool

    /// Placeholder shown over the (empty) private-key text view.
    private let keyPlaceholder = UILabel()
    /// True when the edited connection already has a saved key — we show a masked
    /// "saved" placeholder instead of the raw key and keep it unless replaced.
    private var savedKeyPresent = false
    /// True once the user has typed in the private-key field this session.
    private var keyFieldEdited = false

    init(connection: SSHConfig?) {
        self.editingConnection = connection ?? SSHConfig()
        self.isNew = (connection == nil)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? "New Connection" : "Edit Connection"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save", style: .done, target: self, action: #selector(saveTapped))

        setupLayout()
        loadCurrent()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

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

        let items: [(String, UIView)] = [
            ("Name", nameField),
            ("Host", hostField),
            ("Port", portField),
            ("Username", usernameField),
            ("Private Key", privateKeyView),
            ("Passphrase", passphraseField),
        ]

        for (label, field) in items {
            let lbl = UILabel()
            lbl.text = label
            lbl.font = .preferredFont(forTextStyle: .subheadline)
            lbl.textColor = .secondaryLabel
            stack.addArrangedSubview(lbl)
            stack.addArrangedSubview(field)

            if let tv = field as? UITextView {
                tv.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            }
        }

        // Placeholder overlay for the private-key text view (UITextView has none).
        keyPlaceholder.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        keyPlaceholder.textColor = .placeholderText
        keyPlaceholder.numberOfLines = 0
        keyPlaceholder.isUserInteractionEnabled = false
        keyPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        privateKeyView.addSubview(keyPlaceholder)
        NSLayoutConstraint.activate([
            keyPlaceholder.topAnchor.constraint(equalTo: privateKeyView.topAnchor, constant: 8),
            keyPlaceholder.leadingAnchor.constraint(equalTo: privateKeyView.leadingAnchor, constant: 6),
            keyPlaceholder.trailingAnchor.constraint(equalTo: privateKeyView.trailingAnchor, constant: -6),
        ])
        privateKeyView.delegate = self

        setupStatusRow()

        openTerminalButton.addTarget(self, action: #selector(openTerminalTapped), for: .touchUpInside)
        stack.addArrangedSubview(openTerminalButton)
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
        stack.addArrangedSubview(statusRow)
    }

    // MARK: - Connection status

    private enum ConnState {
        case checking
        case connected
        case failed(String)
    }

    private func setStatus(_ state: ConnState) {
        statusRow.isHidden = false
        switch state {
        case .checking:
            statusDot.isHidden = true
            statusSpinner.startAnimating()
            statusLabel.text = "Checking connection…"
            statusLabel.textColor = .secondaryLabel
        case .connected:
            statusSpinner.stopAnimating()
            statusDot.isHidden = false
            statusDot.backgroundColor = .systemGreen
            statusLabel.text = "Connected"
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
        let cfg = editingConnection
        nameField.text = cfg.name
        hostField.text = cfg.host
        portField.text = cfg.port == 0 ? "22" : String(cfg.port)
        usernameField.text = cfg.username
        passphraseField.text = cfg.passphrase
        // Never re-display the stored private key. If one is saved, show a masked
        // "saved" placeholder; the field stays empty unless the user types a new
        // key (which then replaces it).
        savedKeyPresent = !cfg.privateKey.isEmpty
        privateKeyView.text = ""
        updateKeyPlaceholder()
    }

    private func updateKeyPlaceholder() {
        keyPlaceholder.isHidden = !privateKeyView.text.isEmpty
        if savedKeyPresent && !keyFieldEdited {
            keyPlaceholder.text = "•••••••••••••• · saved\nTap to paste a new key (leave blank to keep)"
        } else {
            keyPlaceholder.text = "Private Key (PEM)"
        }
    }

    /// Builds an `SSHConfig` from the current field values, preserving the
    /// edited connection's identity (so saves update in place).
    private func currentConfig() -> SSHConfig {
        let port = Int(portField.text ?? "22") ?? 22
        let host = hostField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let typedKey = privateKeyView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the saved key when the field was left untouched; only overwrite
        // when the user actually typed a new one.
        let privateKey = (!keyFieldEdited && savedKeyPresent) ? editingConnection.privateKey : typedKey
        return SSHConfig(
            id: editingConnection.id,
            name: name.isEmpty ? host : name,
            host: host,
            port: port,
            username: usernameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            privateKey: privateKey,
            passphrase: passphraseField.text ?? ""
        )
    }

    /// Persists the current field values into the store and keeps editing the
    /// same connection identity.
    @discardableResult
    private func persist() -> SSHConfig {
        let config = currentConfig()
        SSHConfigStore.shared.addOrUpdate(config)
        editingConnection = config
        return config
    }

    @objc private func saveTapped() {
        view.endEditing(true)

        let config = persist()

        guard config.isConfigured else {
            setStatus(.failed("Enter host, username, and private key to connect."))
            return
        }

        // Confirm the private key actually landed in the keychain — surfaces a
        // sync/keychain write failure immediately instead of a later empty field.
        if !SSHConfigStore.shared.privateKeyPersists(id: config.id) {
            let st = SSHConfigStore.shared.lastKeyWriteStatus
            setStatus(.failed("Couldn't save the private key to the keychain (status \(st)). Try toggling iCloud Keychain, or report this code."))
            return
        }
        // The key is saved; reflect that as the masked placeholder going forward.
        savedKeyPresent = true
        keyFieldEdited = false
        privateKeyView.text = ""
        updateKeyPlaceholder()

        setStatus(.checking)
        Task { @MainActor in
            do {
                try await SSHSkill.shared.testConnection(config)
                self.setStatus(.connected)
            } catch {
                self.setStatus(.failed("Could not connect: \(error.localizedDescription)"))
            }
        }
    }

    @objc private func openTerminalTapped() {
        view.endEditing(true)

        let config = persist()
        guard config.isConfigured else {
            setStatus(.failed("Enter host, username, and private key to open a terminal."))
            return
        }
        // Open the interactive shell full screen (not a push) so it stands on
        // its own, edge to edge.
        let terminal = SSHTerminalViewController(config: config)
        terminal.modalPresentationStyle = .fullScreen
        present(terminal, animated: true)
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
        // (placeholder param retained for call-site clarity; the overlay label
        // in setupLayout provides the actual placeholder behavior.)
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

extension SSHSettingsVC: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        if !textView.text.isEmpty { keyFieldEdited = true }
        updateKeyPlaceholder()
    }
}
