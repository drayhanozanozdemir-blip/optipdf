import PencilKit
import UIKit
import Vision

/// Reads handwriting on a page's canvas with Vision, line by line, with positions in canvas coordinates.
enum HandwritingReader {
    struct Line {
        let text: String
        let rect: CGRect
    }

    static func read(_ drawing: PKDrawing, in bounds: CGRect) async -> [Line] {
        guard !drawing.strokes.isEmpty, bounds.width > 1, bounds.height > 1 else { return [] }
        // Light appearance: in dark mode PencilKit would render black ink as white.
        var rendered: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            let ink = drawing.image(from: bounds, scale: 3)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            rendered = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: bounds.size))
                ink.draw(in: CGRect(origin: .zero, size: bounds.size))
            }
        }
        guard let cgImage = rendered?.cgImage else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                let lines: [Line] = (request.results ?? []).compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first, candidate.confidence > 0.3 else { return nil }
                    let box = observation.boundingBox
                    let rect = CGRect(x: bounds.minX + box.minX * bounds.width,
                                      y: bounds.minY + (1 - box.maxY) * bounds.height,
                                      width: box.width * bounds.width,
                                      height: box.height * bounds.height)
                    return Line(text: candidate.string, rect: rect)
                }
                continuation.resume(returning: lines)
            }
        }
    }
}
