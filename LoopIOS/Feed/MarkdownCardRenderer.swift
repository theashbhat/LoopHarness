//
//  MarkdownCardRenderer.swift
//  Loop
//
//  v1 markdown renderer: renders title + body markdown to a 4:3 poster-style
//  PNG via UIKit offscreen render. Clean typography, Loop-branded dark
//  background with white text.
//

#if os(iOS)
import UIKit

final class MarkdownCardRenderer: CardRendering {
    let kind: CardKind = .markdown

    /// Poster dimensions — 4:3 landscape at 2x for retina.
    private let posterWidth: CGFloat = 1200
    private let posterHeight: CGFloat = 900

    func render(card: Card, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.main.async { [self] in
            let image = renderPoster(title: card.title, body: card.body)
            guard let pngData = image.pngData() else {
                completion(.failure(CardRendererRegistry.CardRendererError.renderFailed("Failed to encode PNG")))
                return
            }

            let relativePath = CardStore.shared.posterRelativePath(for: card.id)
            let url = Workspace.shared.rootURL.appendingPathComponent(relativePath)

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try pngData.write(to: url, options: .atomic)
                    CardStore.shared.updateImageURL(id: card.id, imageURL: relativePath)
                    completion(.success(url))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Render a poster-style card with title + body using UIKit drawing.
    private func renderPoster(title: String, body: String) -> UIImage {
        let size = CGSize(width: posterWidth, height: posterHeight)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { ctx in
            // Dark gradient background (Loop-branded)
            let bgColors = [
                UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0).cgColor,
                UIColor(red: 0.12, green: 0.10, blue: 0.18, alpha: 1.0).cgColor,
            ]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: bgColors as CFArray,
                                      locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient,
                                            start: .zero,
                                            end: CGPoint(x: 0, y: size.height),
                                            options: [])

            // Subtle accent bar at top
            let accentColor = UIColor(red: 0.55, green: 0.36, blue: 1.0, alpha: 0.8)
            accentColor.setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: size.width, height: 4)).fill()

            let margin: CGFloat = 60
            let textWidth = size.width - margin * 2

            // Title
            let titleFont = UIFont.systemFont(ofSize: 48, weight: .bold)
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: UIColor.white,
            ]
            let titleRect = CGRect(x: margin, y: margin + 20, width: textWidth, height: 120)
            let titleStr = NSString(string: title)
            titleStr.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttrs, context: nil)

            // Body — rendered as formatted markdown (headings, bullets, bold)
            // rather than literal characters.
            let bodyFont = UIFont.systemFont(ofSize: 28, weight: .regular)
            let bodyTop: CGFloat = margin + 160
            let bodyRect = CGRect(x: margin, y: bodyTop, width: textWidth, height: size.height - bodyTop - margin)
            let bodyStr = CardMarkdown.attributed(body,
                                                  bodyFont: bodyFont,
                                                  textColor: UIColor(white: 0.85, alpha: 1.0),
                                                  headingColor: .white)
            bodyStr.draw(with: bodyRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)

            // Loop watermark bottom-right
            let wmFont = UIFont.systemFont(ofSize: 18, weight: .medium)
            let wmAttrs: [NSAttributedString.Key: Any] = [
                .font: wmFont,
                .foregroundColor: UIColor(white: 0.4, alpha: 1.0),
            ]
            let wm = NSString(string: "Loop")
            let wmSize = wm.size(withAttributes: wmAttrs)
            wm.draw(at: CGPoint(x: size.width - margin - wmSize.width,
                                y: size.height - margin + 10),
                    withAttributes: wmAttrs)
        }
    }
}

#endif
