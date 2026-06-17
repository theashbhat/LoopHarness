//
//  CardMarkdown.swift
//  Loop
//
//  Lightweight Markdown → NSAttributedString converter for feed cards. Handles
//  the block + inline subset that shows up in card bodies: headings (#, ##,
//  ###), bullet and numbered lists, bold, italic, and inline code. Used by the
//  markdown poster renderer and the card detail view so a markdown card reads
//  as formatted text rather than literal `#`/`*` characters.
//
//  Deliberately not a full CommonMark parser — Foundation's AttributedString
//  markdown init collapses block structure (lists/headings lose their styling),
//  which is exactly what we need to preserve here.
//

#if os(iOS)
import UIKit

enum CardMarkdown {

    /// Convert `markdown` to an attributed string laid out for a card.
    /// - Parameters:
    ///   - bodyFont: base font for paragraph text; headings scale from it.
    ///   - textColor: color for body/list text.
    ///   - headingColor: color for heading lines (defaults to `textColor`).
    static func attributed(_ markdown: String,
                           bodyFont: UIFont,
                           textColor: UIColor,
                           headingColor: UIColor? = nil) -> NSAttributedString {
        let headingColor = headingColor ?? textColor
        let out = NSMutableAttributedString()
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        for (idx, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            let para = NSMutableParagraphStyle()
            para.lineSpacing = bodyFont.pointSize * 0.16
            para.paragraphSpacing = bodyFont.pointSize * 0.45

            let content: NSAttributedString
            if trimmed.hasPrefix("### ") {
                let f = UIFont.systemFont(ofSize: bodyFont.pointSize * 1.15, weight: .semibold)
                para.paragraphSpacingBefore = bodyFont.pointSize * 0.3
                content = inline(String(trimmed.dropFirst(4)), baseFont: f, color: headingColor)
            } else if trimmed.hasPrefix("## ") {
                let f = UIFont.systemFont(ofSize: bodyFont.pointSize * 1.35, weight: .bold)
                para.paragraphSpacingBefore = bodyFont.pointSize * 0.4
                content = inline(String(trimmed.dropFirst(3)), baseFont: f, color: headingColor)
            } else if trimmed.hasPrefix("# ") {
                let f = UIFont.systemFont(ofSize: bodyFont.pointSize * 1.6, weight: .bold)
                content = inline(String(trimmed.dropFirst(2)), baseFont: f, color: headingColor)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                para.headIndent = bodyFont.pointSize * 1.2 // wrapped lines hang under text
                content = inline("•  " + String(trimmed.dropFirst(2)), baseFont: bodyFont, color: textColor)
            } else if let rest = numberedListBody(trimmed) {
                para.headIndent = bodyFont.pointSize * 1.4
                content = inline(rest, baseFont: bodyFont, color: textColor)
            } else {
                content = inline(trimmed, baseFont: bodyFont, color: textColor)
            }

            let m = NSMutableAttributedString(attributedString: content)
            m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
            out.append(m)
            if idx < lines.count - 1 {
                out.append(NSAttributedString(string: "\n"))
            }
        }
        return out
    }

    // MARK: - Inline

    /// Parse `**bold**`, `*italic*` / `_italic_`, and `` `code` `` within a line.
    private static func inline(_ text: String, baseFont: UIFont, color: UIColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let chars = Array(text)
        var i = 0
        var run = ""
        var bold = false, italic = false, code = false

        func emit() {
            guard !run.isEmpty else { return }
            var font = baseFont
            if code {
                font = UIFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.92,
                                                   weight: bold ? .bold : .regular)
            } else {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if bold { traits.insert(.traitBold) }
                if italic { traits.insert(.traitItalic) }
                if !traits.isEmpty,
                   let d = baseFont.fontDescriptor.withSymbolicTraits(traits) {
                    font = UIFont(descriptor: d, size: baseFont.pointSize)
                }
            }
            out.append(NSAttributedString(string: run, attributes: [.font: font, .foregroundColor: color]))
            run = ""
        }

        while i < chars.count {
            let c = chars[i]
            if c == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                emit(); bold.toggle(); i += 2; continue
            }
            if c == "*" || c == "_" {
                emit(); italic.toggle(); i += 1; continue
            }
            if c == "`" {
                emit(); code.toggle(); i += 1; continue
            }
            run.append(c); i += 1
        }
        emit()
        return out
    }

    /// If `line` is a numbered list item ("1. foo"), return the item with the
    /// marker preserved; otherwise nil.
    private static func numberedListBody(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let digits = line[line.startIndex..<dot]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else { return nil }
        let after = line.index(after: dot)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return line
    }
}

#endif
