//
//  ImageCardRenderer.swift
//  Loop
//
//  v1 image renderer: pipes image_prompt through the existing generate_image
//  pipeline at 4:3 (landscape aspect). Saves the result as a PNG poster in
//  the workspace cards/assets/ folder.
//

#if os(iOS)
import UIKit

final class ImageCardRenderer: CardRendering {
    let kind: CardKind = .image

    /// Poster dimensions — 4:3 landscape.
    private let posterSize = "1536x1024"

    func render(card: Card, completion: @escaping (Result<URL, Error>) -> Void) {
        // The card body IS the image prompt for image-kind cards.
        let prompt = card.body
        guard !prompt.isEmpty else {
            completion(.failure(CardRendererRegistry.CardRendererError.renderFailed("Empty image prompt")))
            return
        }

        // Use the existing ImageGenerationService infrastructure but grab the
        // raw image data instead of going through the chat host flow.
        generateImageData(prompt: prompt) { result in
            switch result {
            case .success(let imageData):
                let relativePath = CardStore.shared.posterRelativePath(for: card.id)
                let url = Workspace.shared.rootURL.appendingPathComponent(relativePath)
                do {
                    try imageData.write(to: url, options: .atomic)
                    CardStore.shared.updateImageURL(id: card.id, imageURL: relativePath)
                    completion(.success(url))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Hit the OpenAI image generation endpoint directly for card rendering.
    /// Reuses the same API key and endpoint logic as ImageGenerationService.
    private func generateImageData(prompt: String, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let apiKey = KeyStore.shared.value(for: .openAI) else {
            completion(.failure(CardRendererRegistry.CardRendererError.renderFailed("No OpenAI API key configured")))
            return
        }

        let url = URL(string: "https://api.openai.com/v1/images/generations")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let payload: [String: Any] = [
            "model": "gpt-image-1",
            "prompt": prompt,
            "n": 1,
            "size": posterSize,
            "quality": "medium"
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]],
                  let first = dataArr.first else {
                completion(.failure(CardRendererRegistry.CardRendererError.renderFailed("Unexpected API response")))
                return
            }

            // Handle both b64_json and url responses
            if let b64 = first["b64_json"] as? String,
               let imageData = Data(base64Encoded: b64) {
                completion(.success(imageData))
            } else if let urlStr = first["url"] as? String,
                      let imageURL = URL(string: urlStr) {
                // Download from URL
                URLSession.shared.dataTask(with: imageURL) { imgData, _, imgErr in
                    if let imgData = imgData {
                        completion(.success(imgData))
                    } else {
                        completion(.failure(imgErr ?? CardRendererRegistry.CardRendererError.renderFailed("Failed to download image")))
                    }
                }.resume()
            } else {
                completion(.failure(CardRendererRegistry.CardRendererError.renderFailed("No image data in response")))
            }
        }.resume()
    }
}

#endif
