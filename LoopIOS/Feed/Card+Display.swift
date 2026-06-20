//
//  Card+Display.swift
//  Loop
//
//  UI-facing derivations for a Card: the one-line summary, the kind badge, and
//  the icon tile's symbol + tint. The model itself stays UI-agnostic; these
//  inferred values back both the card list rows and the detail view.
//

#if os(iOS)
import UIKit

extension Card {

    /// First meaningful line of the body, stripped of markdown markers, used as
    /// the one-line summary under the title.
    var displaySubtitle: String? {
        for raw in body.split(whereSeparator: \.isNewline) {
            var s = raw.trimmingCharacters(in: .whitespaces)
            // Drop leading heading / list / quote markers.
            while let first = s.first, "#-*•>".contains(first) {
                s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            // Drop a leading checkbox.
            if s.hasPrefix("[ ]") || s.hasPrefix("[x]") || s.hasPrefix("[X]") {
                s = String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            // Drop a leading "1." style ordinal.
            if let dot = s.firstIndex(of: "."), dot != s.startIndex,
               s[s.startIndex..<dot].allSatisfy(\.isNumber) {
                s = String(s[s.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            }
            s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if !s.isEmpty { return s }
        }
        return nil
    }

    /// Short uppercase badge describing the card's shape.
    var displayBadge: String {
        switch kind {
        case .image:
            return "IMAGE"
        case .markdown:
            let lower = body.lowercased()
            if lower.contains("- [ ]") || lower.contains("- [x]") || lower.contains("* [ ]") {
                return "CHECKLIST"
            }
            let bulletLines = body.split(whereSeparator: \.isNewline).filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let first = t.first else { return false }
                return first == "-" || first == "*" || first == "•"
            }
            return bulletLines.count >= 2 ? "LIST" : "NOTE"
        }
    }

    /// SF Symbol + tint for the icon tile, inferred from the title and tags.
    var displayIcon: (symbol: String, tint: UIColor) {
        let haystack = (title + " " + tags.joined(separator: " ")).lowercased()
        let rules: [(keys: [String], symbol: String, tint: UIColor)] = [
            (["dinner", "food", "meal", "recipe", "cook", "prep", "kitchen"], "fork.knife", UIColor(red: 0.70, green: 0.45, blue: 0.28, alpha: 1)),
            (["music", "playlist", "song", "track"], "music.note", UIColor(red: 0.78, green: 0.60, blue: 0.30, alpha: 1)),
            (["wine", "drink", "cocktail", "bar"], "wineglass", UIColor(red: 0.66, green: 0.30, blue: 0.34, alpha: 1)),
            (["guest", "people", "friend", "person", "contact"], "person.2.fill", UIColor(red: 0.40, green: 0.52, blue: 0.74, alpha: 1)),
            (["task", "todo", "checklist", "done"], "checklist", UIColor(red: 0.38, green: 0.60, blue: 0.45, alpha: 1)),
            (["travel", "trip", "flight", "map", "world", "news"], "airplane", UIColor(red: 0.36, green: 0.54, blue: 0.70, alpha: 1)),
            (["note", "idea", "thought"], "note.text", UIColor(red: 0.55, green: 0.45, blue: 0.72, alpha: 1)),
        ]
        for rule in rules where rule.keys.contains(where: haystack.contains) {
            return (rule.symbol, rule.tint)
        }
        // Stable fallback tint from the id so cards keep distinct colors.
        let palette: [UIColor] = [
            UIColor(red: 0.55, green: 0.45, blue: 0.72, alpha: 1),
            UIColor(red: 0.40, green: 0.52, blue: 0.74, alpha: 1),
            UIColor(red: 0.38, green: 0.60, blue: 0.45, alpha: 1),
            UIColor(red: 0.70, green: 0.45, blue: 0.28, alpha: 1),
        ]
        let idx = abs(id.hashValue) % palette.count
        return (kind == .image ? "photo" : "doc.text", palette[idx])
    }
}

#endif
