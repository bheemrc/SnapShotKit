import AppKit
import Vision

/// Optical character recognition for captured images.
///
/// Wraps Vision's text recognition into a single async entry point. Results are
/// returned in natural reading order (top-to-bottom), one recognized line per
/// output line. The recognizer prioritizes accuracy over speed and applies
/// language correction so transcribed text reads cleanly.
enum OCRService {

    /// Recognizes text in the given image.
    ///
    /// - Parameter image: The image to scan.
    /// - Returns: The recognized text, with each line separated by a newline and
    ///   ordered top-to-bottom. Returns an empty string if no text is found or
    ///   if recognition fails for any reason.
    static func recognizeText(in image: NSImage) async -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "")
                return
            }

            guard let observations = request.results else {
                continuation.resume(returning: "")
                return
            }

            // Vision reports observations in confidence order. Sort by vertical
            // position so the output matches the visual reading order of the
            // source image. Vision's normalized coordinate space is bottom-left
            // origin, so a larger maxY is higher on the page.
            let lines = observations
                .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                .compactMap { $0.topCandidates(1).first?.string }
                .filter { !$0.isEmpty }

            continuation.resume(returning: lines.joined(separator: "\n"))
        }
    }
}
