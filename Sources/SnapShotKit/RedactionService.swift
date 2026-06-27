import AppKit
import Foundation
import Vision

/// Automatic detection of sensitive content for redaction.
///
/// Scans an image for personally identifiable information (PII) in recognized
/// text and for human faces, returning the regions that should be obscured.
/// The detector combines two Vision passes:
///
/// 1. Text recognition, where each recognized line is matched against a set of
///    patterns for common sensitive data (emails, phone numbers, credit-card
///    numbers, US Social Security numbers, IPv4 addresses, and high-entropy API
///    keys / tokens).
/// 2. Face rectangle detection.
///
/// All returned rectangles are expressed in image-pixel coordinates with a
/// top-left origin and a downward-growing y axis, matching the convention used
/// by ``Annotation``. Callers can therefore drop the rectangles straight into
/// blur annotations without any further coordinate conversion. Overlapping
/// rectangles are merged so the result contains non-redundant regions.
enum RedactionService {

    /// Detects regions of an image that likely contain sensitive content.
    ///
    /// - Parameter image: The image to scan.
    /// - Returns: Rectangles to redact, in image-pixel coordinates with a
    ///   top-left origin (y-down), the same convention ``Annotation`` uses.
    ///   Returns an empty array if nothing sensitive is found or if detection
    ///   fails for any reason.
    static func detectSensitiveRegions(in image: NSImage) async -> [CGRect] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }

        // Prefer the true pixel size; fall back to the CG image dimensions.
        let reported = image.pixelSize
        let pixelSize = (reported.width > 0 && reported.height > 0)
            ? reported
            : CGSize(width: cgImage.width, height: cgImage.height)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return [] }

        async let textRects = detectTextPII(in: cgImage, pixelSize: pixelSize)
        async let faceRects = detectFaces(in: cgImage, pixelSize: pixelSize)

        let combined = await textRects + faceRects
        return merge(combined)
    }

    // MARK: - Text PII

    /// Recognizes text and returns the bounding rectangles of lines that match
    /// any known sensitive-data pattern.
    private static func detectTextPII(in cgImage: CGImage, pixelSize: CGSize) async -> [CGRect] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[CGRect], Never>) in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
                return
            }

            guard let observations = request.results else {
                continuation.resume(returning: [])
                return
            }

            var rects: [CGRect] = []
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let line = candidate.string
                guard containsSensitiveText(line) else { continue }
                rects.append(pixelRect(from: observation.boundingBox, pixelSize: pixelSize))
            }
            continuation.resume(returning: rects)
        }
    }

    /// Reports whether a recognized line contains any sensitive token.
    private static func containsSensitiveText(_ line: String) -> Bool {
        for pattern in Patterns.all {
            if pattern.firstMatch(
                in: line,
                options: [],
                range: NSRange(line.startIndex..<line.endIndex, in: line)
            ) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Faces

    /// Detects faces and returns their bounding rectangles.
    private static func detectFaces(in cgImage: CGImage, pixelSize: CGSize) async -> [CGRect] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[CGRect], Never>) in
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
                return
            }

            guard let observations = request.results else {
                continuation.resume(returning: [])
                return
            }

            let rects = observations.map {
                pixelRect(from: $0.boundingBox, pixelSize: pixelSize)
            }
            continuation.resume(returning: rects)
        }
    }

    // MARK: - Coordinate conversion

    /// Converts a Vision normalized bounding box (bottom-left origin) into an
    /// image-pixel rectangle with a top-left origin (y-down).
    private static func pixelRect(from boundingBox: CGRect, pixelSize: CGSize) -> CGRect {
        let w = pixelSize.width
        let h = pixelSize.height
        let x = boundingBox.minX * w
        // Flip the y axis: Vision's maxY (top edge, bottom-left origin) becomes
        // the rectangle's top in a top-left coordinate space.
        let y = (1 - boundingBox.maxY) * h
        let width = boundingBox.width * w
        let height = boundingBox.height * h
        return CGRect(x: x, y: y, width: width, height: height).standardized
    }

    // MARK: - Merging

    /// Merges overlapping (or touching) rectangles into their union, repeating
    /// until no further merges are possible.
    private static func merge(_ input: [CGRect]) -> [CGRect] {
        var rects = input.filter { $0.width > 0 && $0.height > 0 }
        guard !rects.isEmpty else { return [] }

        var merged = true
        while merged {
            merged = false
            var result: [CGRect] = []
            for rect in rects {
                if let index = result.firstIndex(where: { $0.intersects(rect) }) {
                    result[index] = result[index].union(rect)
                    merged = true
                } else {
                    result.append(rect)
                }
            }
            rects = result
        }
        return rects
    }

    // MARK: - Patterns

    /// Compiled regular expressions for sensitive-data detection.
    private enum Patterns {

        /// All patterns evaluated against each recognized line.
        static let all: [NSRegularExpression] = [
            email,
            phone,
            creditCard,
            ssn,
            ipv4,
            apiKey
        ].compactMap { $0 }

        /// Email addresses.
        static let email = compile(
            #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
            caseInsensitive: true
        )

        /// Phone numbers with optional country code and common separators.
        static let phone = compile(
            #"(?:\+?\d{1,3}[\s.\-]?)?(?:\(\d{2,4}\)[\s.\-]?)?\d{3}[\s.\-]?\d{3,4}[\s.\-]?\d{0,4}"#
        )

        /// Credit-card-like sequences of 13–19 digits with optional spaces or
        /// dashes between groups.
        static let creditCard = compile(
            #"\b(?:\d[ \-]?){13,19}\b"#
        )

        /// US Social Security numbers (NNN-NN-NNNN).
        static let ssn = compile(
            #"\b\d{3}-\d{2}-\d{4}\b"#
        )

        /// IPv4 addresses.
        static let ipv4 = compile(
            #"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#
        )

        /// API-key-like tokens: known cloud-credential prefixes, or long
        /// high-entropy alphanumeric strings (24+ characters).
        static let apiKey = compile(
            #"(?:\bAKIA[0-9A-Z]{12,}\b|\bsk-[A-Za-z0-9\-_]{16,}\b|\b[A-Za-z0-9\-_]{24,}\b)"#
        )

        /// Builds a regular expression, returning `nil` if the pattern is
        /// invalid (which should never happen for the static patterns above).
        private static func compile(
            _ pattern: String,
            caseInsensitive: Bool = false
        ) -> NSRegularExpression? {
            let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
            return try? NSRegularExpression(pattern: pattern, options: options)
        }
    }
}
