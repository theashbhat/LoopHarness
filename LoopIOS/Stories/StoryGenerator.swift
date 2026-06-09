//
//  StoryGenerator.swift
//  Loop
//
//  JSON → HTML renderer. Takes structured data and a template identifier,
//  loads the corresponding HTML template from the bundle, injects the data
//  payload, and writes a single self-contained .html file to the workspace.
//

import Foundation

final class StoryGenerator {
    static let shared = StoryGenerator()
    private init() {}

    enum GenerationError: Error, LocalizedError {
        case templateNotFound(String)
        case invalidJSON
        case fileWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .templateNotFound(let name): return "Template '\(name)' not found in bundle"
            case .invalidJSON: return "Invalid JSON payload"
            case .fileWriteFailed(let reason): return "Failed to write HTML: \(reason)"
            }
        }
    }

    /// Generate a self-contained HTML story file from structured data.
    ///
    /// - Parameters:
    ///   - template: Which template to use.
    ///   - jsonPayload: JSON string of the data to inject.
    ///   - outputDirectory: Where to write the rendered HTML. Defaults to tmp.
    /// - Returns: URL of the rendered .html file.
    func generate(template: StoryAttachment.Template,
                  jsonPayload: String,
                  outputDirectory: URL? = nil) throws -> URL {
        // Validate JSON
        guard let jsonData = jsonPayload.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: jsonData)) != nil else {
            throw GenerationError.invalidJSON
        }

        // Templates are embedded as Swift constants (StoryBundledTemplates)
        // because Xcode's synchronized groups don't copy .html into the app
        // bundle. Prefer the embedded copy; fall back to a bundled resource
        // if one is ever added so editing-via-bundle still works.
        if let embedded = StoryBundledTemplates.html(for: template) {
            return try renderAndWrite(html: embedded, json: jsonPayload, outputDir: outputDirectory)
        }

        if let templateURL = Bundle.main.url(forResource: template.rawValue,
                                             withExtension: "html",
                                             subdirectory: "StoryTemplates")
            ?? Bundle.main.url(forResource: template.rawValue, withExtension: "html"),
           let templateHTML = try? String(contentsOf: templateURL, encoding: .utf8) {
            return try renderAndWrite(html: templateHTML, json: jsonPayload, outputDir: outputDirectory)
        }

        throw GenerationError.templateNotFound(template.rawValue)
    }

    /// Inject the JSON data into the template and write to disk.
    private func renderAndWrite(html: String, json: String, outputDir: URL?) throws -> URL {
        // Inject the data payload as a global variable before the closing </script>
        let injection = "\nwindow.__STORY_DATA__ = \(json);\n"
        let rendered: String
        if let range = html.range(of: "<script>") {
            // Insert right after the opening <script> tag
            let insertionPoint = range.upperBound
            var mutable = html
            mutable.insert(contentsOf: injection, at: insertionPoint)
            rendered = mutable
        } else {
            // Append a script block
            rendered = html + "\n<script>\nwindow.__STORY_DATA__ = \(json);\nwindow.StoryBridge && window.StoryBridge.init(window.__STORY_DATA__);\nwindow.StoryBridge && window.StoryBridge.startAutoPlay();\n</script>"
        }

        // Write to disk
        let dir = outputDir ?? FileManager.default.temporaryDirectory
        let fileName = "story_\(UUID().uuidString.prefix(8)).html"
        let fileURL = dir.appendingPathComponent(fileName)

        do {
            try rendered.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw GenerationError.fileWriteFailed(error.localizedDescription)
        }

        return fileURL
    }

    /// Convenience: generate from a dictionary payload.
    func generate(template: StoryAttachment.Template,
                  data: [String: Any],
                  outputDirectory: URL? = nil) throws -> URL {
        let jsonData = try JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed])
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw GenerationError.invalidJSON
        }
        return try generate(template: template, jsonPayload: jsonString, outputDirectory: outputDirectory)
    }
}
