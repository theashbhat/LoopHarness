//
//  StoryPlayerView.swift
//  Loop
//
//  Chromeless WKWebView that renders a 1080×1920 HTML story. Supports two
//  modes:
//    1. Inline (thumbnail in chat): scaled down to fit the cell, auto-plays
//       the timeline, non-interactive (tap opens full-screen).
//    2. Full-screen: native tap-to-advance (left 30% = back, right 70% = next),
//       auto-plays on load with controls for pause/resume.
//
//  The web view is configured with no scroll, no bounce, no selection, and
//  no navigation — a pure render surface for the self-contained HTML story.
//

#if os(iOS)

import UIKit
import WebKit

protocol StoryPlayerViewDelegate: AnyObject {
    /// Story finished playing (reached the last scene).
    func storyPlayerDidFinish(_ player: StoryPlayerView)
    /// User tapped the thumbnail card in inline mode.
    func storyPlayerDidRequestFullScreen(_ player: StoryPlayerView)
}

final class StoryPlayerView: UIView {

    weak var delegate: StoryPlayerViewDelegate?

    /// Whether this instance is in inline (scaled thumbnail) mode.
    /// When true, user interaction on the web view is disabled and a tap
    /// gesture on the container opens full-screen instead.
    var isInlineMode: Bool = true {
        didSet { configureInteraction() }
    }

    // MARK: - Subviews

    private let webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.suppressesIncrementalRendering = true

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.scrollView.showsVerticalScrollIndicator = false
        wv.scrollView.showsHorizontalScrollIndicator = false
        // Remove any selection / callout menu
        wv.allowsLinkPreview = false
        return wv
    }()

    /// Overlay for inline tap gesture.
    private let tapOverlay = UIView()

    // MARK: - State

    private var currentScene = 0
    private var totalScenes = 0
    private var isPlaying = false

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        clipsToBounds = true
        layer.cornerRadius = 16

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Tap overlay for inline mode
        tapOverlay.translatesAutoresizingMaskIntoConstraints = false
        tapOverlay.backgroundColor = .clear
        addSubview(tapOverlay)
        NSLayoutConstraint.activate([
            tapOverlay.topAnchor.constraint(equalTo: topAnchor),
            tapOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            tapOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            tapOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let inlineTap = UITapGestureRecognizer(target: self, action: #selector(handleInlineTap))
        tapOverlay.addGestureRecognizer(inlineTap)

        // Full-screen tap zones
        let fullTap = UITapGestureRecognizer(target: self, action: #selector(handleFullScreenTap(_:)))
        webView.addGestureRecognizer(fullTap)

        configureInteraction()
    }

    private func configureInteraction() {
        if isInlineMode {
            tapOverlay.isHidden = false
            webView.isUserInteractionEnabled = false
        } else {
            tapOverlay.isHidden = true
            webView.isUserInteractionEnabled = true
        }
    }

    // MARK: - Loading

    /// Load a story from a local HTML file URL.
    func loadStory(fileURL: URL) {
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        // After loading, the story auto-plays via embedded JS.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.querySceneState()
        }
    }

    /// Load a story from raw HTML string.
    func loadStoryHTML(_ html: String) {
        webView.loadHTMLString(html, baseURL: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.querySceneState()
        }
    }

    // MARK: - Navigation

    func advance() {
        webView.evaluateJavaScript("window.StoryBridge && window.StoryBridge.advance()") { [weak self] _, _ in
            self?.querySceneState()
        }
    }

    func retreat() {
        webView.evaluateJavaScript("window.StoryBridge && window.StoryBridge.retreat()") { [weak self] _, _ in
            self?.querySceneState()
        }
    }

    func goToScene(_ index: Int) {
        webView.evaluateJavaScript("window.StoryBridge && window.StoryBridge.goToScene(\(index))") { [weak self] _, _ in
            self?.querySceneState()
        }
    }

    func startAutoPlay() {
        isPlaying = true
        webView.evaluateJavaScript("window.StoryBridge && window.StoryBridge.startAutoPlay()", completionHandler: nil)
    }

    func stopAutoPlay() {
        isPlaying = false
        webView.evaluateJavaScript("window.StoryBridge && window.StoryBridge.stopAutoPlay()", completionHandler: nil)
    }

    // MARK: - Private

    private func querySceneState() {
        webView.evaluateJavaScript("""
            (function() {
                if (!window.StoryBridge) return JSON.stringify({current: 0, total: 0});
                return JSON.stringify({
                    current: window.StoryBridge.getCurrentScene(),
                    total: window.StoryBridge.getTotalScenes()
                });
            })()
        """) { [weak self] result, _ in
            guard let self = self,
                  let jsonStr = result as? String,
                  let data = jsonStr.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return }
            self.currentScene = dict["current"] ?? 0
            self.totalScenes = dict["total"] ?? 0
            if self.currentScene >= self.totalScenes - 1 {
                self.delegate?.storyPlayerDidFinish(self)
            }
        }
    }

    // MARK: - Gestures

    @objc private func handleInlineTap() {
        delegate?.storyPlayerDidRequestFullScreen(self)
    }

    @objc private func handleFullScreenTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        let threshold = bounds.width * 0.3
        if location.x < threshold {
            retreat()
        } else {
            advance()
        }
    }

    // MARK: - Scaling for inline mode

    /// Apply a transform to fit the 1080×1920 content into the given container
    /// size. Call this after layout if using inline mode.
    func applyInlineScale(containerSize: CGSize) {
        let storyWidth: CGFloat = 1080
        let storyHeight: CGFloat = 1920
        let scaleX = containerSize.width / storyWidth
        let scaleY = containerSize.height / storyHeight
        let scale = min(scaleX, scaleY)

        webView.transform = CGAffineTransform(scaleX: scale, y: scale)
        webView.frame = CGRect(
            x: (containerSize.width - storyWidth * scale) / 2,
            y: (containerSize.height - storyHeight * scale) / 2,
            width: storyWidth,
            height: storyHeight
        )
        // Reset transform origin
        webView.layer.anchorPoint = CGPoint(x: 0, y: 0)
        webView.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    /// Simpler approach: use CSS viewport scaling. The HTML is 1080×1920 and
    /// WKWebView will scale to fit via pageZoom.
    func applyContentScale(for containerSize: CGSize) {
        let zoom = containerSize.width / 1080.0
        webView.pageZoom = zoom
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if isInlineMode {
            applyContentScale(for: bounds.size)
        }
    }
}

#endif
