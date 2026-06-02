//
//  ImageGenerationService.swift
//  Loop
//
//  Built from LoopIOS/Specs/image_spec.md.
//
//  Owns long-running image-generation HTTP so ImageSkill can stay a thin
//  tool wrapper. Decouples "submit" from "complete" — the skill returns a
//  function-result immediately ("queued, appears inline shortly"), the
//  service does the actual network work, and the UI placeholder swaps in
//  when the image is ready.
//
//  Why a dedicated service:
//  - URLSession.shared.dataTask has a 60s default timeoutIntervalForRequest
//    in our prior code, which gpt-image-2 sometimes blows past under load.
//    Here we run a custom session with 300s/600s timeouts and
//    waitsForConnectivity = true.
//  - When the app is backgrounded mid-generation, iOS will suspend
//    URLSession tasks unless we hold a UIBackgroundTaskIdentifier. The
//    service brackets every request in beginBackgroundTask so iOS gives
//    us extra wall-clock time.
//  - In-memory registry + retry/cancel keep the surface tidy for the UI
//    layer to ask "is X still generating?" without hitting the network.
//

#if os(iOS)
import UIKit
#endif
import Foundation

final class ImageGenerationService {
    static let shared = ImageGenerationService()

    /// Notified on completion (success or failure). The host doubles as
    /// MessagingVC's ImageSkillHost — same protocol, no extra plumbing.
    weak var host: ImageSkillHost?

    /// Active jobs keyed by attachment id. Read on main; mutated through
    /// `mutate(_:)` so we never race the URLSession completion handler.
    private var jobs: [String: URLSessionDataTask] = [:]
    /// API `size` string used for each attachment id, remembered so `retry`
    /// regenerates at the same aspect the user originally asked for. Guarded
    /// by `jobsQueue` alongside `jobs`.
    private var sizes: [String: String] = [:]
    private let jobsQueue = DispatchQueue(label: "loop.image-gen.jobs")

    /// API `size` sent when a caller doesn't specify one. Matches the prior
    /// always-square behavior.
    static let defaultSize = "1024x1024"

    /// Custom session — 5min per request, 10min total resource budget,
    /// waits for connectivity instead of failing immediately so a flaky
    /// cellular blip doesn't kill a generation in flight.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Public API

    /// Kick off a new generation. Returns synchronously with the placeholder
    /// attachment so the caller can drop a UI bubble before the network
    /// even starts. The host's didStart/didFinish callbacks fire on main.
    @discardableResult
    func submit(prompt: String,
                size: String = ImageGenerationService.defaultSize,
                attachmentId: String? = nil,
                conversationId: String? = nil) -> ImageAttachment {
        let id = attachmentId ?? UUID().uuidString
        let attachment = ImageAttachment(id: id,
                                         prompt: prompt,
                                         status: .generating,
                                         conversationId: conversationId)
        jobsQueue.sync { sizes[id] = size }

        // Tell the UI a placeholder should appear right now — even before
        // we've checked the API key. Failures still surface through
        // didFinishGenerating with status .failed, so the placeholder
        // doesn't hang.
        DispatchQueue.main.async { [weak self] in
            self?.host?.imageSkillDidStartGenerating(attachment)
        }

        startNetworkRequest(attachment: attachment, size: size)
        return attachment
    }

    /// Cancel any in-flight task for this attachment (used by retry).
    func cancel(attachmentId: String) {
        jobsQueue.sync {
            jobs[attachmentId]?.cancel()
            jobs.removeValue(forKey: attachmentId)
        }
    }

    /// Cancel and re-submit with the same prompt + id so the placeholder
    /// row in the chat updates in place (same id → existing message gets
    /// mutated rather than a new one inserted).
    @discardableResult
    func retry(attachmentId: String, prompt: String, size: String? = nil, conversationId: String? = nil) -> ImageAttachment {
        // Reuse the size the original generation used unless the caller
        // overrides it, so "regenerate" keeps the same aspect.
        let resolvedSize = size ?? jobsQueue.sync { sizes[attachmentId] } ?? ImageGenerationService.defaultSize
        cancel(attachmentId: attachmentId)
        return submit(prompt: prompt,
                      size: resolvedSize,
                      attachmentId: attachmentId,
                      conversationId: conversationId)
    }

    // MARK: - Network

    private func startNetworkRequest(attachment: ImageAttachment, size: String) {
        guard let apiKey = ImageGenerationService.openAIAPIKey else {
            deliverFailure(message: "No OpenAI API key is configured. Add one in Settings → Keys → OpenAI and the app will store it securely in the iOS Keychain on-device.",
                           attachment: attachment)
            return
        }
        guard let url = URL(string: "https://api.openai.com/v1/images/generations") else {
            deliverFailure(message: "Bad image URL", attachment: attachment)
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Per-request belt + suspenders. Session config sets the upper bound;
        // this restates it locally for the task.
        req.timeoutInterval = 300

        let body: [String: Any] = [
            "model": "gpt-image-2",
            "prompt": attachment.prompt,
            "size": size,
            "n": 1
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            deliverFailure(message: "Failed to encode image request",
                           attachment: attachment)
            return
        }
        req.httpBody = bodyData

        // Hold a UIBackgroundTaskIdentifier so iOS gives us wall-clock time
        // when the user backgrounds the app mid-generation. Released in
        // every code path that finishes the request. macOS doesn't need this
        // (no equivalent reclamation pressure for foreground apps).
#if os(iOS)
        var bgTaskId: UIBackgroundTaskIdentifier = .invalid
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "loop.image-gen.\(attachment.id)") {
            // Expiration handler — iOS is reclaiming the task. Cancel the
            // network request so we don't get a half-uploaded payload, and
            // surface a failure so the UI doesn't spin forever.
            self.cancel(attachmentId: attachment.id)
            self.deliverFailure(message: "Background time expired before generation completed.",
                                attachment: attachment)
            if bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskId)
                bgTaskId = .invalid
            }
        }
#endif

        let task = session.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            defer {
#if os(iOS)
                if bgTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskId)
                }
#endif
                self.jobsQueue.sync {
                    self.jobs.removeValue(forKey: attachment.id)
                }
            }
            if let error = error {
                let nserr = error as NSError
                // .cancelled fires when retry() pulled the rug out from under
                // us. The fresh submit will deliver its own callbacks; don't
                // double-fire a failure for the cancelled task.
                if nserr.domain == NSURLErrorDomain, nserr.code == NSURLErrorCancelled {
                    return
                }
                self.deliverFailure(message: "Network error: \(error.localizedDescription)",
                                    attachment: attachment)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                let detail = ImageGenerationService.errorDetail(from: bodyStr) ?? "HTTP \(http.statusCode)"
                self.deliverFailure(message: "Image API error: \(detail)",
                                    attachment: attachment)
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json["data"] as? [[String: Any]],
                  let first = arr.first,
                  let b64 = first["b64_json"] as? String,
                  let imageData = Data(base64Encoded: b64) else {
                self.deliverFailure(message: "Image API returned an unexpected payload.",
                                    attachment: attachment)
                return
            }
            do {
                let fileURL = try ImageGenerationService.saveImage(imageData, id: attachment.id)
                let ready = ImageAttachment(id: attachment.id,
                                            prompt: attachment.prompt,
                                            fileURL: fileURL,
                                            status: .ready,
                                            conversationId: attachment.conversationId)
                DispatchQueue.main.async { [weak self] in
                    self?.host?.imageSkillDidFinishGenerating(ready)
                }
            } catch {
                self.deliverFailure(message: "Failed to save image: \(error.localizedDescription)",
                                    attachment: attachment)
            }
        }
        jobsQueue.sync {
            jobs[attachment.id] = task
        }
        task.resume()
    }

    private func deliverFailure(message: String, attachment: ImageAttachment) {
        let failed = ImageAttachment(id: attachment.id,
                                     prompt: attachment.prompt,
                                     status: .failed,
                                     failureReason: message,
                                     conversationId: attachment.conversationId)
        DispatchQueue.main.async { [weak self] in
            self?.host?.imageSkillDidFinishGenerating(failed)
        }
    }

    // MARK: - Storage

    private static let imagesSubdir = "images"

    private static func saveImage(_ data: Data, id: String) throws -> URL {
        let workspace = Workspace.shared
        let dirURL = workspace.rootURL.appendingPathComponent(imagesSubdir, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dirURL.path) {
            try FileManager.default.createDirectory(at: dirURL,
                                                    withIntermediateDirectories: true)
        }
        let fileURL = dirURL.appendingPathComponent("\(id).png")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    // MARK: - Helpers

    private static var openAIAPIKey: String? {
        return KeyStore.shared.value(for: .openAI)
    }

    private static func errorDetail(from bodyStr: String) -> String? {
        guard let data = bodyStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = json["error"] as? [String: Any] {
            if let msg = error["message"] as? String { return msg }
            if let code = error["code"] as? String { return code }
        }
        if let msg = json["message"] as? String { return msg }
        return nil
    }
}
