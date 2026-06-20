//
//  BrowseSession.swift
//  Loop
//
//  Drives a real WKWebView on-device so the agent can fetch, render, and
//  navigate JavaScript-heavy pages. This is the engine behind the `browse`
//  skill: it owns one fresh `WKWebsiteDataStore.nonPersistent()` web view
//  (stateless — no cookies, no login persistence), injects a JS bridge so the
//  agent can read/act on the DOM, and runs an on-device agent loop:
//
//      load → read page state → model picks next action → execute → capture
//      a frame (screenshot + DOM snapshot) → repeat until finish / max_steps.
//
//  Each step is persisted into a replay bundle at workspace://browse/<id>/ so
//  the chat card can flip into a scrubbable replay when the session ends.
//
//  iOS-first; the driver stays UIKit/WebKit so a Mac fast-follow can host the
//  same `WKWebView` in an AppKit window with identical behaviour.
//

#if os(iOS)

import UIKit
import WebKit

/// Receives per-step progress so the host (MessagingVC) can keep the live
/// preview card and any open full-screen player in sync.
@MainActor
protocol BrowseSessionDelegate: AnyObject {
    func browseSession(_ session: BrowseSession, didUpdate attachment: BrowseAttachment)
}

@MainActor
final class BrowseSession: NSObject {

    // MARK: - Inputs

    let attachmentId: String
    let startURL: URL
    let instructions: String
    let maxSteps: Int
    let viewport: CGSize
    let conversationId: String?

    weak var delegate: BrowseSessionDelegate?

    // MARK: - Live state

    private(set) var attachment: BrowseAttachment
    /// The live web view — exposed so the full-screen player can mirror what
    /// the agent is looking at (read-only) while the session runs.
    let webView: WKWebView

    /// Whether a full-screen player has borrowed the web view. While borrowed
    /// the session leaves the view in the player's hierarchy; otherwise it
    /// lives in an offscreen host so WebKit keeps rendering/snapshotting.
    private(set) var isMirroredFullScreen = false

    // MARK: - Internals

    private let offscreenHost = UIView()
    private var startTime = Date()
    private var frames: [BrowseFrame] = []
    private var convoMessages: [MessageStruct] = []
    private var finished = false
    private var loadContinuation: CheckedContinuation<Void, Never>?

    private let replayDir: URL

    // MARK: - Init

    init(attachmentId: String,
         url: URL,
         instructions: String,
         maxSteps: Int,
         viewport: CGSize,
         conversationId: String?) {
        self.attachmentId = attachmentId
        self.startURL = url
        self.instructions = instructions
        self.maxSteps = maxSteps
        self.viewport = viewport
        self.conversationId = conversationId

        self.replayDir = BrowseSession.workspaceBrowseDir()
            .appendingPathComponent(attachmentId, isDirectory: true)

        // Fresh, non-persistent data store every session — no cookies / no
        // login carried across calls. This is the statelessness guarantee.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let wv = WKWebView(frame: CGRect(origin: .zero, size: viewport), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        wv.allowsLinkPreview = false
        self.webView = wv

        self.attachment = BrowseAttachment(
            id: attachmentId,
            url: url.absoluteString,
            instructions: instructions,
            status: .navigating,
            statusDetail: url.host,
            replayDirPath: replayDir.path,
            conversationId: conversationId
        )

        super.init()

        wv.navigationDelegate = self
        wv.uiDelegate = self

        // Park the web view offscreen inside the key window so WebKit treats
        // it as on-screen (required for full JS rendering + snapshotting).
        offscreenHost.frame = CGRect(origin: CGPoint(x: -10_000, y: 0), size: viewport)
        offscreenHost.isUserInteractionEnabled = false
        offscreenHost.addSubview(wv)
        BrowseSession.keyWindow()?.addSubview(offscreenHost)

        try? FileManager.default.createDirectory(at: replayDir, withIntermediateDirectories: true)
    }

    // MARK: - Full-screen mirroring (read-only live view)

    /// Move the live web view into `container` so the player can show exactly
    /// what the agent sees. Read-only: the player swallows gestures.
    func mirror(into container: UIView) {
        isMirroredFullScreen = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Return the web view to its offscreen host (player dismissed).
    func endMirroring() {
        isMirroredFullScreen = false
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = CGRect(origin: .zero, size: viewport)
        offscreenHost.addSubview(webView)
    }

    // MARK: - Run

    /// Execute the full browse session. Resolves when the agent finishes,
    /// errors, or the step / time budget is exhausted. Returns the terminal
    /// attachment (status .done or .failed).
    func run() async -> BrowseAttachment {
        startTime = Date()

        // Hard session timeout (default 60s) races the agent loop so a stuck
        // page can never hold the runtime open.
        let result = await withTaskGroup(of: BrowseAttachment?.self) { group -> BrowseAttachment in
            group.addTask { [weak self] in
                guard let self else { return nil }
                return await self.driveLoop()
            }
            group.addTask { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(BrowseSession.sessionTimeout * 1_000_000_000))
                guard let self else { return nil }
                return await self.timedOutAttachment()
            }
            // First non-nil wins; cancel the rest.
            for await value in group {
                if let value {
                    group.cancelAll()
                    return value
                }
            }
            return self.attachment
        }

        await persistManifest()
        teardown()
        return result
    }

    private func timedOutAttachment() -> BrowseAttachment {
        if finished { return attachment }
        finished = true
        attachment.status = .done
        attachment.statusDetail = "Stopped at time limit"
        if (attachment.summary ?? "").isEmpty {
            attachment.summary = "Browse session hit the \(Int(BrowseSession.sessionTimeout))s time limit before finishing. Partial observations were captured."
        }
        attachment.finalURL = webView.url?.absoluteString ?? attachment.url
        return attachment
    }

    // MARK: - The agent loop

    private func driveLoop() async -> BrowseAttachment {
        // 1. Navigate to the start URL.
        await load(startURL)
        guard !finished else { return attachment }

        // 2. Capture the initial frame and seed the model.
        let initialState = await readPageState()
        await captureFrame(action: "navigate")
        updateStatus(.reading, detail: webView.url?.host)

        convoMessages = [
            MessageStruct(role: "system", content: Self.systemPrompt(viewport: viewport)),
            MessageStruct(role: "user", content: """
            Task: \(instructions)

            You are now on the page. Current state:
            \(initialState)

            Decide the next action by calling browse_action. When you have
            gathered enough to answer the task, call browse_action with
            action "finish" and provide a grounded summary + observations.
            """),
        ]

        // 3. Step until finish / budget.
        var step = 0
        while step < maxSteps && !finished {
            step += 1
            guard let reply = await modelCall() else {
                // Model unreachable — finish gracefully on what we have.
                finish(summary: "Couldn't reach the model to continue browsing. Captured the initial page state.",
                       observations: [])
                break
            }
            convoMessages.append(reply)

            guard let call = reply.functions.first(where: { $0.name == "browse_action" }) ?? reply.functions.first else {
                // Plain-text reply → treat as the final summary.
                let text = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
                finish(summary: text.isEmpty ? "Finished browsing." : text, observations: [])
                break
            }

            let (observation, isFinish) = await execute(call)
            // Pair the tool result back so providers that require tool_use →
            // tool_result pairing (Anthropic) stay happy on the next call.
            convoMessages.append(MessageStruct(
                role: "function",
                content: observation,
                name: "browse_action",
                callId: call.callId
            ))

            attachment.stepCount = step
            emit()

            if isFinish { break }
        }

        if !finished {
            // Ran out of steps without an explicit finish — summarize what we have.
            finish(summary: "Reached the \(maxSteps)-step limit. " + (attachment.summary ?? "Captured the pages visited above."),
                   observations: [])
        }
        return attachment
    }

    // MARK: - Action execution (JS bridge)

    /// Returns (observation text for the model, isFinish).
    private func execute(_ call: FunctionCallStruct) async -> (String, Bool) {
        let args = call.arguments
        let action = (args["action"] as? String ?? "read").lowercased()
        let selector = args["selector"] as? String
        let text = args["text"] as? String
        let js = args["js"] as? String

        switch action {
        case "finish":
            let summary = (args["summary"] as? String) ?? "Finished browsing."
            let observations = (args["observations"] as? [String]) ?? []
            finish(summary: summary, observations: observations)
            await captureFrame(action: "finish")
            return ("Session finished.", true)

        case "click":
            updateStatus(.navigating, detail: selector)
            let ok = await bridgeClick(selector ?? "")
            await waitForSettle()
            await captureFrame(action: "click \(selector ?? "")")
            let state = await readPageState()
            updateStatus(.reading, detail: webView.url?.host)
            return (ok ? "Clicked \(selector ?? ""). New page state:\n\(state)"
                       : "No element matched \(selector ?? ""). Page unchanged:\n\(state)", false)

        case "type":
            let ok = await bridgeType(selector ?? "", text: text ?? "")
            await captureFrame(action: "type \(selector ?? "")")
            return (ok ? "Typed into \(selector ?? "")."
                       : "No input matched \(selector ?? "").", false)

        case "scroll":
            let dir = (args["direction"] as? String) ?? "down"
            await bridgeScroll(direction: dir, selector: selector)
            await captureFrame(action: "scroll \(dir)")
            let state = await readPageState()
            return ("Scrolled \(dir). Visible content:\n\(state)", false)

        case "wait_for", "waitfor":
            let appeared = await bridgeWaitFor(selector ?? "", timeout: 5)
            await captureFrame(action: "wait_for \(selector ?? "")")
            let state = await readPageState()
            return (appeared ? "Element \(selector ?? "") appeared.\n\(state)"
                             : "Timed out waiting for \(selector ?? "").\n\(state)", false)

        case "query", "queryselectorall":
            let list = await bridgeQueryAll(selector ?? "")
            return ("querySelectorAll(\(selector ?? "")) → \(list.count) matches:\n" +
                    list.prefix(40).enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: "\n"), false)

        case "eval", "eval_js", "evaljs":
            let out = await bridgeEval(js ?? "")
            await captureFrame(action: "eval")
            return ("evalJS result: \(out)", false)

        case "read", "get_text", "gettext":
            fallthrough
        default:
            updateStatus(.reading, detail: webView.url?.host)
            let state = await readPageState(selector: selector)
            await captureFrame(action: selector == nil ? "read" : "read \(selector!)")
            return ("Page content:\n\(state)", false)
        }
    }

    // MARK: - JS bridge primitives

    /// getText — readable text of the page (or a selector subtree), trimmed.
    private func readPageState(selector: String? = nil) async -> String {
        let scope = selector.map { "document.querySelector(\(jsString($0)))" } ?? "document.body"
        let js = """
        (function(){
          var el = \(scope);
          if(!el) return JSON.stringify({error:"no element"});
          var text = (el.innerText||"").replace(/\\n{3,}/g,"\\n\\n").trim();
          var title = document.title||"";
          var url = location.href;
          return JSON.stringify({title:title,url:url,text:text.slice(0,6000)});
        })()
        """
        guard let raw = await eval(js) as? String,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "(could not read page)"
        }
        if let err = obj["error"] as? String { return "(\(err))" }
        let title = obj["title"] as? String ?? ""
        let url = obj["url"] as? String ?? ""
        let text = obj["text"] as? String ?? ""
        return "URL: \(url)\nTitle: \(title)\n---\n\(text)"
    }

    private func bridgeClick(_ selector: String) async -> Bool {
        let js = """
        (function(){
          var el = document.querySelector(\(jsString(selector)));
          if(!el) return false;
          el.scrollIntoView({block:"center"});
          el.click();
          return true;
        })()
        """
        return (await eval(js) as? Bool) ?? false
    }

    private func bridgeType(_ selector: String, text: String) async -> Bool {
        let js = """
        (function(){
          var el = document.querySelector(\(jsString(selector)));
          if(!el) return false;
          el.focus();
          el.value = \(jsString(text));
          el.dispatchEvent(new Event('input',{bubbles:true}));
          el.dispatchEvent(new Event('change',{bubbles:true}));
          return true;
        })()
        """
        return (await eval(js) as? Bool) ?? false
    }

    private func bridgeScroll(direction: String, selector: String?) async {
        let js: String
        if let selector {
            js = "var e=document.querySelector(\(jsString(selector))); if(e) e.scrollIntoView({block:'center'});"
        } else {
            let delta = direction.lowercased() == "up" ? "-window.innerHeight*0.8" : "window.innerHeight*0.8"
            js = "window.scrollBy(0, \(delta));"
        }
        _ = await eval(js)
        await waitForSettle(0.3)
    }

    private func bridgeWaitFor(_ selector: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let present = (await eval("!!document.querySelector(\(jsString(selector)))") as? Bool) ?? false
            if present { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func bridgeQueryAll(_ selector: String) async -> [String] {
        let js = """
        (function(){
          var nodes = document.querySelectorAll(\(jsString(selector)));
          var out = [];
          for(var i=0;i<nodes.length && i<60;i++){
            var n = nodes[i];
            var t = (n.innerText||n.value||n.getAttribute('aria-label')||'').trim().slice(0,120);
            out.push((n.tagName||'').toLowerCase()+ (t? (': '+t):''));
          }
          return JSON.stringify(out);
        })()
        """
        guard let raw = await eval(js) as? String,
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return arr
    }

    private func bridgeEval(_ js: String) async -> String {
        let wrapped = "(function(){ try { return JSON.stringify((function(){ \(js) })()); } catch(e){ return 'error: '+e.message; } })()"
        let out = await eval(wrapped)
        if let s = out as? String { return String(s.prefix(2000)) }
        if let v = out { return String(describing: v).prefix(2000).description }
        return "undefined"
    }

    // MARK: - WebKit primitives

    private func load(_ url: URL) async {
        updateStatus(.navigating, detail: url.host)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.loadContinuation = cont
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            webView.load(req)
        }
    }

    /// Let JS settle after an interaction / SPA navigation.
    private func waitForSettle(_ seconds: TimeInterval = 0.8) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func eval(_ js: String) async -> Any? {
        await withCheckedContinuation { (cont: CheckedContinuation<Any?, Never>) in
            webView.evaluateJavaScript(js) { result, _ in
                cont.resume(returning: result)
            }
        }
    }

    // MARK: - Frame capture + replay persistence

    private func captureFrame(action: String) async {
        let ts = Date().timeIntervalSince(startTime)
        let index = frames.count
        let pngName = String(format: "frame_%03d.png", index)
        let domName = String(format: "frame_%03d.html", index)

        // DOM snapshot.
        let dom = (await eval("document.documentElement.outerHTML") as? String) ?? ""
        try? dom.data(using: .utf8)?.write(to: replayDir.appendingPathComponent(domName))

        // Screenshot.
        if let image = await snapshot(), let png = image.pngData() {
            let url = replayDir.appendingPathComponent(pngName)
            try? png.write(to: url)
            attachment.latestThumbnailPath = url.path
        }

        let frame = BrowseFrame(
            ts: ts,
            url: webView.url?.absoluteString ?? attachment.url,
            action: action,
            screenshot: pngName,
            domSnapshot: domName,
            viewport: "\(Int(viewport.width))x\(Int(viewport.height))"
        )
        frames.append(frame)
        emit()
    }

    private func snapshot() async -> UIImage? {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: viewport)
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            webView.takeSnapshot(with: config) { image, _ in
                cont.resume(returning: image)
            }
        }
    }

    private func persistManifest() async {
        let manifest = BrowseReplayManifest(
            replayId: attachmentId,
            url: startURL.absoluteString,
            instructions: instructions,
            finalURL: attachment.finalURL,
            summary: attachment.summary,
            frames: frames
        )
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: replayDir.appendingPathComponent("manifest.json"))
        }
    }

    // MARK: - Model call

    private func modelCall() async -> MessageStruct? {
        let messages = convoMessages
        return await withCheckedContinuation { (cont: CheckedContinuation<MessageStruct?, Never>) in
            Cloud.connection.chat(messages: messages, tools: BrowseSkill.actionTools) { response, _ in
                cont.resume(returning: response)
            }
        }
    }

    // MARK: - State helpers

    private func finish(summary: String, observations: [String]) {
        guard !finished else { return }
        finished = true
        var body = summary
        if !observations.isEmpty {
            body += "\n\nObservations:\n" + observations.map { "• \($0)" }.joined(separator: "\n")
        }
        attachment.summary = body
        attachment.finalURL = webView.url?.absoluteString ?? attachment.url
        attachment.status = .done
        attachment.statusDetail = nil
        emit()
    }

    private func fail(_ reason: String) {
        guard !finished else { return }
        finished = true
        attachment.status = .failed
        attachment.failureReason = reason
        attachment.finalURL = webView.url?.absoluteString
        loadContinuation?.resume()
        loadContinuation = nil
        emit()
    }

    private func updateStatus(_ status: BrowseAttachment.Status, detail: String?) {
        attachment.status = status
        attachment.statusDetail = detail
        emit()
    }

    private func emit() {
        delegate?.browseSession(self, didUpdate: attachment)
    }

    private func teardown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        if !isMirroredFullScreen {
            webView.removeFromSuperview()
            offscreenHost.removeFromSuperview()
        }
    }

    // MARK: - Structured-observations / final tool result

    /// The JSON the skill returns to the model: { summary, final_url,
    /// observations[], replay_id }.
    func toolResultJSON() -> String {
        var obj: [String: Any] = [
            "summary": attachment.summary ?? "",
            "final_url": attachment.finalURL ?? attachment.url,
            "replay_id": attachmentId,
            "steps": attachment.stepCount,
        ]
        if attachment.status == .failed {
            obj["error"] = attachment.failureReason ?? "browse failed"
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return attachment.summary ?? "{}"
    }

    // MARK: - Static helpers

    private func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        // Strip the surrounding [ ] to get a single JSON string literal.
        return String(arr.dropFirst().dropLast())
    }

    static let sessionTimeout: TimeInterval = 60

    static func workspaceBrowseDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("browse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func systemPrompt(viewport: CGSize) -> String {
        return """
        You are an autonomous web-browsing agent driving a real WebKit web view \
        on an iPhone-sized viewport (\(Int(viewport.width))×\(Int(viewport.height))). \
        Each turn you call the `browse_action` tool exactly once to read or act on \
        the current page, and you receive the resulting page state back.

        Available actions (the `action` field):
        - "read": return the readable text of the page (optionally pass `selector`).
        - "click": click the element matching `selector`.
        - "type": type `text` into the input matching `selector`.
        - "scroll": scroll the page (`direction`: "down"/"up", or pass a `selector` to scroll to).
        - "wait_for": wait until `selector` appears.
        - "query": list elements matching `selector` (querySelectorAll).
        - "eval_js": run `js` and return the result (advanced).
        - "finish": end the session. Provide a grounded `summary` of what you \
          observed (answer the task) and an `observations` array of short bullet strings.

        Rules:
        - Ground every claim in text you actually read from the page — never invent content.
        - Be efficient: a few reads/scrolls/clicks, then finish. Do not loop aimlessly.
        - If the task is just "look at the page and report", read it, scroll once or \
          twice for more content, then finish.
        - Always call finish before you run out of steps.
        """
    }
}

// MARK: - WKNavigationDelegate / WKUIDelegate (safety + load tracking)

extension BrowseSession: WKNavigationDelegate, WKUIDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A failed *initial* provisional load is fatal for the session.
        if frames.isEmpty {
            fail("Couldn't load \(startURL.absoluteString): \(error.localizedDescription)")
        } else {
            loadContinuation?.resume()
            loadContinuation = nil
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Block downloads and non-http(s) schemes (tel:, mailto:, app links).
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme != "http", scheme != "https", scheme != "about" {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // Block popups / new windows — keep everything in the one driven view.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    // Auto-dismiss JS dialogs so a blocking alert can't wedge the session.
    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    static func keyWindow() -> UIWindow? {
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ??
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first
    }
}

#endif
