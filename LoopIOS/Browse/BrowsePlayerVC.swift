//
//  BrowsePlayerVC.swift
//  Loop
//
//  Full-screen viewer for a browse session, presented when the user taps the
//  preview card in chat. Two modes:
//
//    1. LIVE (session still running): mirrors the agent's real WKWebView so the
//       user can watch it navigate in real time. Read-only — a gesture-
//       swallowing overlay eats taps/scrolls so only the agent drives.
//
//    2. REPLAY (session ended): a scrubbable timeline of the frames the agent
//       saw — screenshot + DOM-snapshot pairs from the workspace://browse/<id>/
//       bundle — with play/pause and per-frame Open DOM / Copy text / Share.
//

#if os(iOS)

import UIKit

final class BrowsePlayerVC: UIViewController {

    /// The attachment to display. Set before presentation.
    var attachment: BrowseAttachment!

    // Shared chrome
    private let closeButton = UIButton(type: .system)
    private let statusBanner = UILabel()

    // Live mode
    private let liveContainer = UIView()
    private let gestureSwallow = UIView()
    private var pollTimer: Timer?
    private weak var liveSession: BrowseSession?

    // Replay mode
    private let imageView = UIImageView()
    private let scrubber = UISlider()
    private let playPauseButton = UIButton(type: .system)
    private let frameLabel = UILabel()
    private var frames: [BrowseFrame] = []
    private var replayDir: URL?
    private var currentFrame = 0
    private var playTimer: Timer?
    private var isPlaying = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCloseButton()
        setupStatusBanner()

        if attachment.status == .navigating || attachment.status == .reading,
           let session = BrowseGenerationService.shared.liveSession(for: attachment.id) {
            liveSession = session
            setupLiveMode(session: session)
        } else {
            setupReplayMode()
        }
    }

    override var prefersStatusBarHidden: Bool { true }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollTimer?.invalidate()
        playTimer?.invalidate()
        liveSession?.endMirroring()
    }

    // MARK: - Chrome

    private func setupCloseButton() {
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: cfg), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        closeButton.layer.cornerRadius = 18
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func setupStatusBanner() {
        statusBanner.translatesAutoresizingMaskIntoConstraints = false
        statusBanner.font = .systemFont(ofSize: 13, weight: .semibold)
        statusBanner.textColor = .white
        statusBanner.textAlignment = .center
        statusBanner.numberOfLines = 1
        statusBanner.lineBreakMode = .byTruncatingMiddle
        statusBanner.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        statusBanner.layer.cornerRadius = 10
        statusBanner.clipsToBounds = true
        view.addSubview(statusBanner)
        NSLayoutConstraint.activate([
            statusBanner.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            statusBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusBanner.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -12),
            statusBanner.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    // MARK: - Live mode

    private func setupLiveMode(session: BrowseSession) {
        liveContainer.translatesAutoresizingMaskIntoConstraints = false
        liveContainer.backgroundColor = .black
        view.insertSubview(liveContainer, at: 0)
        NSLayoutConstraint.activate([
            liveContainer.topAnchor.constraint(equalTo: statusBanner.bottomAnchor, constant: 12),
            liveContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            liveContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            liveContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        session.mirror(into: liveContainer)

        // Swallow all touches so the user can watch but not drive.
        gestureSwallow.translatesAutoresizingMaskIntoConstraints = false
        gestureSwallow.backgroundColor = .clear
        gestureSwallow.isUserInteractionEnabled = true
        view.addSubview(gestureSwallow)
        NSLayoutConstraint.activate([
            gestureSwallow.topAnchor.constraint(equalTo: liveContainer.topAnchor),
            gestureSwallow.leadingAnchor.constraint(equalTo: liveContainer.leadingAnchor),
            gestureSwallow.trailingAnchor.constraint(equalTo: liveContainer.trailingAnchor),
            gestureSwallow.bottomAnchor.constraint(equalTo: liveContainer.bottomAnchor),
        ])

        refreshLiveBanner(session.attachment)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.tickLive()
        }
    }

    private func tickLive() {
        guard let session = liveSession else { transitionToReplay(); return }
        let a = session.attachment
        refreshLiveBanner(a)
        if a.status == .done || a.status == .failed ||
            BrowseGenerationService.shared.liveSession(for: attachment.id) == nil {
            transitionToReplay()
        }
    }

    private func refreshLiveBanner(_ a: BrowseAttachment) {
        let detail = a.statusDetail.map { " · \($0)" } ?? ""
        statusBanner.text = "\(a.pillText)\(detail)  (watching — read-only)"
    }

    private func transitionToReplay() {
        pollTimer?.invalidate()
        pollTimer = nil
        liveSession?.endMirroring()
        gestureSwallow.removeFromSuperview()
        liveContainer.removeFromSuperview()
        liveSession = nil
        // Refresh attachment status from disk-backed manifest.
        setupReplayMode()
    }

    // MARK: - Replay mode

    private func setupReplayMode() {
        loadManifest()

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.isUserInteractionEnabled = true
        view.insertSubview(imageView, at: 0)

        frameLabel.translatesAutoresizingMaskIntoConstraints = false
        frameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        frameLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        frameLabel.textAlignment = .center
        frameLabel.numberOfLines = 2
        view.addSubview(frameLabel)

        scrubber.translatesAutoresizingMaskIntoConstraints = false
        scrubber.minimumValue = 0
        scrubber.maximumValue = Float(max(0, frames.count - 1))
        scrubber.minimumTrackTintColor = .white
        scrubber.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)

        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.tintColor = .white
        playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playPauseButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        view.addSubview(playPauseButton)
        view.addSubview(scrubber)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: statusBanner.bottomAnchor, constant: 12),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: frameLabel.topAnchor, constant: -10),

            frameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            frameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            frameLabel.bottomAnchor.constraint(equalTo: scrubber.topAnchor, constant: -10),

            playPauseButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            playPauseButton.centerYAnchor.constraint(equalTo: scrubber.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 36),

            scrubber.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 8),
            scrubber.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrubber.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        imageView.addGestureRecognizer(longPress)

        statusBanner.text = frames.isEmpty ? "Replay · no frames captured" : "Replay · \(frames.count) frames"
        if frames.isEmpty {
            frameLabel.text = attachment.summary ?? "Nothing was captured."
        } else {
            showFrame(0)
        }
    }

    private func loadManifest() {
        let dir: URL
        if let p = attachment.replayDirPath {
            dir = URL(fileURLWithPath: p)
        } else {
            dir = BrowseSession.workspaceBrowseDir().appendingPathComponent(attachment.id)
        }
        replayDir = dir
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BrowseReplayManifest.self, from: data) else {
            frames = []
            return
        }
        frames = manifest.frames
        scrubber.maximumValue = Float(max(0, frames.count - 1))
    }

    private func showFrame(_ index: Int) {
        guard index >= 0, index < frames.count, let dir = replayDir else { return }
        currentFrame = index
        let frame = frames[index]
        if let img = UIImage(contentsOfFile: dir.appendingPathComponent(frame.screenshot).path) {
            imageView.image = img
        }
        scrubber.value = Float(index)
        frameLabel.text = "Step \(index + 1)/\(frames.count) · \(frame.action)\n\(frame.url)"
    }

    @objc private func scrubChanged() {
        showFrame(Int(scrubber.value.rounded()))
    }

    @objc private func togglePlay() {
        isPlaying.toggle()
        playPauseButton.setImage(UIImage(systemName: isPlaying ? "pause.fill" : "play.fill"), for: .normal)
        if isPlaying {
            if currentFrame >= frames.count - 1 { showFrame(0) }
            playTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.currentFrame >= self.frames.count - 1 {
                    self.togglePlay()
                } else {
                    self.showFrame(self.currentFrame + 1)
                }
            }
        } else {
            playTimer?.invalidate()
            playTimer = nil
        }
    }

    // MARK: - Per-frame actions

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, currentFrame < frames.count, let dir = replayDir else { return }
        let frame = frames[currentFrame]
        let sheet = UIAlertController(title: "Step \(currentFrame + 1)", message: frame.url, preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: "Open DOM", style: .default) { [weak self] _ in
            self?.openDOM(at: dir.appendingPathComponent(frame.domSnapshot))
        })
        sheet.addAction(UIAlertAction(title: "Copy text", style: .default) { [weak self] _ in
            self?.copyText(at: dir.appendingPathComponent(frame.domSnapshot))
        })
        sheet.addAction(UIAlertAction(title: "Share screenshot", style: .default) { [weak self] _ in
            self?.shareScreenshot(at: dir.appendingPathComponent(frame.screenshot))
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = imageView
            pop.sourceRect = CGRect(x: imageView.bounds.midX, y: imageView.bounds.midY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    private func openDOM(at url: URL) {
        guard let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        let tv = UITextView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.text = html
        vc.view.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor),
            tv.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
        ])
        let nav = UINavigationController(rootViewController: vc)
        vc.title = "DOM Snapshot"
        vc.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissPresented))
        present(nav, animated: true)
    }

    @objc private func dismissPresented() { presentedViewController?.dismiss(animated: true) }

    private func copyText(at domURL: URL) {
        guard let html = try? String(contentsOf: domURL, encoding: .utf8) else { return }
        UIPasteboard.general.string = BrowsePlayerVC.stripTags(html)
    }

    private func shareScreenshot(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = av.popoverPresentationController {
            pop.sourceView = imageView
            pop.sourceRect = CGRect(x: imageView.bounds.midX, y: imageView.bounds.midY, width: 1, height: 1)
        }
        present(av, animated: true)
    }

    private static func stripTags(_ html: String) -> String {
        var s = html
        // Drop script/style blocks first, then remaining tags.
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<[^>]+>"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#endif
