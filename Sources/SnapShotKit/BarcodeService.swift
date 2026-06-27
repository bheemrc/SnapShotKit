import AppKit
import Vision

/// Detects QR codes and barcodes within images using the Vision framework.
enum BarcodeService {

    /// Detects all barcodes/QR codes in the given image and returns their decoded payload strings.
    ///
    /// - Parameter image: The image to scan.
    /// - Returns: The decoded payload strings for every barcode found. Observations whose payload
    ///   could not be decoded are skipped. Returns an empty array if none are found or on error.
    static func detectBarcodes(in image: NSImage) async -> [String] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }

        return await withCheckedContinuation { continuation in
            let request = VNDetectBarcodesRequest { request, _ in
                let payloads = (request.results as? [VNBarcodeObservation] ?? [])
                    .compactMap { $0.payloadStringValue }
                continuation.resume(returning: payloads)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
}
