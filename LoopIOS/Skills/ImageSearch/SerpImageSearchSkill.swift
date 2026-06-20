//
//  SerpImageSearchSkill.swift
//  Loop
//
//  Lets Loop search the web for images and render them inline as a thumbnail
//  gallery. Calls SerpAPI's Google Images engine
//  (https://serpapi.com/images-results) directly from the device using the
//  SERPAPI_API_KEY in the KeyStore, so this skill does not depend on the
//  backend.
//
//  Synchronous, like MapsSkill: the search returns all image URLs in one call,
//  so the skill returns a `role:"function"` result message that carries an
//  `ImageGalleryAttachment`. The chat cell renders that as a horizontal
//  thumbnail strip; thumbnails load lazily and tapping one opens the full
//  image. No host protocol / generating lifecycle.
//

import Foundation

struct SerpImageSearchSkill {
    static let shared = SerpImageSearchSkill()

    private static let baseURL = "https://serpapi.com/search.json"

    /// Hard cap so a runaway `num_results` can't flood the gallery.
    private static let maxResults = 10
    private static let defaultResults = 6

    static let systemPromptFragment: String = """
You can search the web for REAL photos and render them inline with this tool:
- image_search: pass a `query` (e.g. "Alamo Square park", "golden retriever puppy", "mid-century modern living room") and optional `num_results` (default 6, max 10). Returns Google Images results and renders them as a thumbnail gallery in the chat; the user can tap a thumbnail to open the full image.

This is the DEFAULT and ONLY correct tool whenever the user wants to see real, existing images/photos/pictures of anything in the world ("find me images of…", "show me photos of…", "what does X look like", "pull up pics of…", "get me images of…"). It is much cheaper than generating images.

Hard rules:
- For real/existing subjects, ALWAYS call image_search. NEVER call generate_image for these — generating an AI picture of a real place/person/thing is wrong and expensive.
- Only use generate_image (not this tool) when the user explicitly wants an *invented* or artistic image that doesn't exist yet (a drawing, mockup, concept, logo, moodboard).
- One image_search call per request renders the whole gallery — do not loop or call it once per image, and do not fall back to exa_search/fetch_url to scrape image URLs. If image_search returns an error, tell the user it failed (and why) rather than generating images or scraping pages.

After a successful call: add a short one-liner ("Here are a few shots of Ocean Beach.") — the gallery shows the images, so don't list them out.
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "image_search",
                "description": "Search the web for real images (Google Images via SerpAPI) and render them inline as a tappable thumbnail gallery in the chat. Use when the user wants to see real photos/pictures of something. For invented/AI-generated images use generate_image instead.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "What to find images of, in natural language (e.g. \"Alamo Square park\")."
                        ],
                        "num_results": [
                            "type": "integer",
                            "description": "How many images to show (default 6, max 10)."
                        ]
                    ],
                    "required": ["query"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "image_search"
    ]

    func handles(functionName: String) -> Bool {
        return SerpImageSearchSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "image_search":
            if let q = (call.arguments["query"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
                return "finding images of \(q)"
            }
            return "searching for images"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        // Short-circuit before any network call if no SerpAPI key is set —
        // return a function-role message that prompts the model to explain
        // the situation and offer to store one securely.
        if SerpImageSearchSkill.apiKey == nil {
            completion(SerpImageSearchSkill.noApiKeyMessage(for: functionCall.name))
            return
        }
        switch functionCall.name {
        case "image_search":
            guard let query = (functionCall.arguments["query"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty else {
                completion(MessageStruct(
                    role: "function",
                    content: "I need a `query` to call image_search.",
                    name: "image_search"
                ))
                return
            }
            let requested = intArg(functionCall.arguments["num_results"]) ?? SerpImageSearchSkill.defaultResults
            let n = max(1, min(SerpImageSearchSkill.maxResults, requested))
            imageSearch(query: query,
                        numResults: n,
                        conversationId: functionCall.conversationId,
                        completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the image-search tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Tool handler

    private func imageSearch(query: String,
                             numResults: Int,
                             conversationId: String?,
                             completion: @escaping (MessageStruct) -> Void) {
        guard let apiKey = SerpImageSearchSkill.apiKey else {
            completion(SerpImageSearchSkill.noApiKeyMessage(for: "image_search"))
            return
        }
        var components = URLComponents(string: SerpImageSearchSkill.baseURL)
        components?.queryItems = [
            URLQueryItem(name: "engine", value: "google_images"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "ijn", value: "0"),
            URLQueryItem(name: "api_key", value: apiKey)
        ]
        guard let url = components?.url else {
            completion(SerpImageSearchSkill.errorMessage("couldn't build the request URL"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error = error {
                NSLog("[image_search] transport error: \(error.localizedDescription)")
                completion(SerpImageSearchSkill.errorMessage("Image search failed (network): \(error.localizedDescription)"))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let snippet = data.flatMap { String(data: $0.prefix(300), encoding: .utf8) } ?? "<no body>"
                NSLog("[image_search] non-JSON response (status \(status)): \(snippet)")
                completion(SerpImageSearchSkill.errorMessage("Image search returned an unexpected response (status \(status))."))
                return
            }
            // SerpAPI reports failures both via HTTP status and an `error`
            // field on a 200 — surface either so we don't silently fall back.
            if status >= 400 || json["error"] != nil {
                let msg = (json["error"] as? String) ?? "Image search failed (status \(status))."
                NSLog("[image_search] API error (status \(status)): \(msg)")
                completion(SerpImageSearchSkill.errorMessage(msg))
                return
            }

            let raw = (json["images_results"] as? [[String: Any]]) ?? []
            NSLog("[image_search] query=\"\(query)\" status=\(status) images_results=\(raw.count)")
            let items: [ImageGalleryAttachment.Item] = raw.prefix(numResults).compactMap { r in
                // `original` is the full-res image; `thumbnail` the small grid
                // image. Need at least one usable image URL to render a tile.
                let original = (r["original"] as? String) ?? (r["thumbnail"] as? String)
                let thumb = (r["thumbnail"] as? String) ?? original
                guard let originalURL = original, let thumbURL = thumb,
                      !originalURL.isEmpty, !thumbURL.isEmpty else { return nil }
                let link = (r["link"] as? String)
                let title = (r["title"] as? String)
                return ImageGalleryAttachment.Item(
                    thumbnailURL: thumbURL,
                    originalURL: originalURL,
                    sourceLink: (link?.isEmpty == false) ? link : nil,
                    title: (title?.isEmpty == false) ? title : nil
                )
            }

            guard !items.isEmpty else {
                completion(MessageStruct(
                    role: "function",
                    content: "No images found for \"\(query)\".",
                    name: "image_search"
                ))
                return
            }

            let attachment = ImageGalleryAttachment(
                query: query,
                items: items,
                conversationId: conversationId
            )

            // Short body for the model — the user-visible surface is the
            // rendered gallery; we just confirm what landed plus the sources
            // so the model can attribute/caption without restating the list.
            var lines = ["Showed \(items.count) image\(items.count == 1 ? "" : "s") for \"\(query)\" in a gallery. Sources:"]
            for (i, item) in items.enumerated() {
                let label = item.title ?? URL(string: item.sourceLink ?? "")?.host ?? "image"
                let src = item.sourceLink ?? item.originalURL
                lines.append("\(i + 1). \(SerpImageSearchSkill.truncate(label, to: 80)) — \(src)")
            }

            completion(MessageStruct(
                role: "function",
                content: lines.joined(separator: "\n"),
                name: "image_search",
                imageGalleryAttachment: attachment
            ))
        }.resume()
    }

    // MARK: - Helpers

    private static var apiKey: String? {
        return KeyStore.shared.value(for: .serpAPI)
    }

    private func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func truncate(_ s: String, to max: Int) -> String {
        if s.count <= max { return s }
        let idx = s.index(s.startIndex, offsetBy: max)
        return String(s[..<idx]) + "…"
    }

    /// Tool-result error. Returned as a `role:"function"` message (not
    /// assistant) so the model receives it as the result of the image_search
    /// call and reports the failure to the user, instead of silently falling
    /// back to scraping pages or generating AI images.
    private static func errorMessage(_ message: String) -> MessageStruct {
        return MessageStruct(
            role: "function",
            content: "Image search failed: \(message). Tell the user image search isn't working right now — do NOT generate AI images or scrape web pages as a substitute.",
            name: "image_search"
        )
    }

    /// Returned as the function result when no SerpAPI key is configured.
    /// Sent as a function-role message so the model phrases the ask to the
    /// user instead of us hard-coding a string into the chat.
    private static func noApiKeyMessage(for functionName: String) -> MessageStruct {
        let content = KeyStore.missingKeyInstruction(
            for: [.serpAPI],
            purpose: "web image search (SerpAPI). A free key is available at https://serpapi.com"
        )
        return MessageStruct(role: "function", content: content, name: functionName)
    }
}
