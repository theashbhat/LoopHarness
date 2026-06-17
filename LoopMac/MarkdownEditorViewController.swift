//
//  MarkdownEditorViewController.swift
//  LoopMac
//
//  Editable markdown editor for the Mac app. The host
//  (ConversationWindowController) slides this up vertically over the chat
//  message area when the user opens a `.md` file from the Files sidebar or
//  clicks a markdown file link in a reply.
//
//  The buffer stays raw markdown; MarkdownSourceHighlighter layers styling
//  live so it reads like a document while staying fully editable. Saving is
//  an explicit Save button (⌘S) plus an automatic save whenever the editor
//  is dismissed with unsaved changes — the host calls `autosaveIfNeeded()`
//  on its way out, and Done / Esc route through the same path.
//

import AppKit

final class MarkdownEditorViewController: NSViewController {

    static func isMarkdownFile(_ url: URL) -> Bool {
        MarkdownSourceHighlighter.isMarkdownFile(url)
    }

    /// Invoked when the editor wants to go away (Done button, Esc). The host
    /// is responsible for the slide-out animation + removing this controller.
    var onClose: (() -> Void)?

    // MARK: - State

    private let fileURL: URL
    private let baseFontSize: CGFloat = 14
    private var savedText: String = ""
    private var isLoaded = false
    private var isDirty: Bool { isLoaded && textView.string != savedText }
    private let ioQueue = DispatchQueue(label: "markdown-editor-mac.io")

    // MARK: - Views

    private let titleLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let spinner = NSProgressIndicator()
    private let errorLabel = NSTextField(labelWithString: "")
    private let shareToolbar = MacMarkdownShareToolbar()

    // MARK: - Init

    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .windowBackground
        root.blendingMode = .withinWindow
        root.state = .active
        root.wantsLayer = true

        let header = makeHeader()
        root.addSubview(header)

        configureTextView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        root.addSubview(scrollView)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        root.addSubview(spinner)

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = .systemFont(ofSize: 13)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        errorLabel.maximumNumberOfLines = 4
        errorLabel.isHidden = true
        root.addSubview(errorLabel)

        shareToolbar.translatesAutoresizingMaskIntoConstraints = false
        shareToolbar.onShare = { [weak self] in
            self?.shareMarkdownText()
        }
        root.addSubview(shareToolbar)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: shareToolbar.topAnchor),

            shareToolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            shareToolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            shareToolbar.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
        ])

        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        spinner.startAnimation(nil)
        loadFile()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Start in the buffer so the user can type immediately once loaded.
        view.window?.makeFirstResponder(textView)
    }

    // MARK: - Header

    private func makeHeader() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.stringValue = fileURL.lastPathComponent
        header.addSubview(titleLabel)

        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .regular
        doneButton.keyEquivalent = "\u{1b}" // Esc
        doneButton.target = self
        doneButton.action = #selector(doneTapped)
        header.addSubview(doneButton)

        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .regular
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.isEnabled = false
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        header.addSubview(saveButton)

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        header.addSubview(separator)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: saveButton.leadingAnchor, constant: -12),

            doneButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            doneButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            saveButton.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -8),
            saveButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        return header
    }

    // MARK: - Text view

    private func configureTextView() {
        textView.autoresizingMask = [.width]
        textView.isEditable = false // until loaded
        textView.isRichText = true  // we layer attributes via the highlighter
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.font = .systemFont(ofSize: baseFontSize)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 14)
        textView.textContainer?.widthTracksTextView = true
        // Markdown is punctuation-sensitive — keep AppKit from rewriting
        // -- / quotes / "helpful" replacements as the user types.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.delegate = self
    }

    // MARK: - Load

    private func loadFile() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            try? Workspace.shared.ensureDownloaded(self.fileURL)
            let result: Result<String, Error>
            do {
                let data = try Data(contentsOf: self.fileURL)
                result = .success(String(decoding: data, as: UTF8.self))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let contents): self.applyLoaded(contents)
                case .failure(let error):    self.presentLoadError(error)
                }
            }
        }
    }

    private func applyLoaded(_ contents: String) {
        savedText = contents
        textView.string = contents
        textView.isEditable = true
        isLoaded = true
        spinner.stopAnimation(nil)
        rehighlight()
        updateSaveButton()
        view.window?.makeFirstResponder(textView)
    }

    private func presentLoadError(_ error: Error) {
        spinner.stopAnimation(nil)
        textView.isHidden = true
        errorLabel.isHidden = false
        errorLabel.stringValue = "Couldn't open \(fileURL.lastPathComponent)\n\(error.localizedDescription)"
    }

    // MARK: - Highlight

    private func rehighlight() {
        guard let storage = textView.textStorage else { return }
        let selected = textView.selectedRanges
        MarkdownSourceHighlighter.highlight(storage, baseSize: baseFontSize)
        textView.selectedRanges = selected
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: baseFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
    }

    // MARK: - Save / close

    @objc private func saveTapped() {
        guard isDirty else { return }
        persist(textView.string)
    }

    @objc private func doneTapped() {
        autosaveIfNeeded()
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        // Esc — same as Done.
        doneTapped()
    }

    /// Called by the host before tearing the editor down so unsaved edits
    /// are flushed even if the user dismissed via some other path.
    func autosaveIfNeeded() {
        guard isDirty else { return }
        persist(textView.string)
    }

    private func persist(_ contents: String) {
        savedText = contents
        updateSaveButton()
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let writeError: Error?
            do {
                let data = Data(contents.utf8)
                try Workspace.shared.coordinatedWrite(to: self.fileURL) { target in
                    try data.write(to: target, options: .atomic)
                }
                writeError = nil
            } catch {
                writeError = error
            }
            if let error = writeError {
                DispatchQueue.main.async { self.presentSaveError(error) }
            }
        }
    }

    private func presentSaveError(_ error: Error) {
        savedText = "" // mark dirty again so the user can retry
        updateSaveButton()
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't save \(fileURL.lastPathComponent)"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    private func updateSaveButton() {
        saveButton.isEnabled = isDirty
    }

    private func shareMarkdownText() {
        guard isLoaded else { return }
        let text = textView.string
        let picker = NSSharingServicePicker(items: [text])
        picker.show(relativeTo: shareToolbar.shareButtonBounds,
                    of: shareToolbar.shareButtonView,
                    preferredEdge: .minY)
    }
}

// MARK: - NSTextViewDelegate

extension MarkdownEditorViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        rehighlight()
        updateSaveButton()
    }
}
