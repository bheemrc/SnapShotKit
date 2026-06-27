import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes a sequence of frames into an animated GIF using ImageIO.
enum GIFEncoder {
    /// Writes the given frames to an animated GIF at `url`.
    /// - Parameters:
    ///   - frames: Ordered frames to encode. Must contain at least one image.
    ///   - frameDelay: Per-frame display duration in seconds.
    ///   - loop: When `true` the animation loops forever; otherwise it plays once.
    ///   - url: Destination file URL.
    /// - Returns: `true` on success, `false` on any failure.
    @discardableResult
    static func write(frames: [CGImage], frameDelay: Double, loop: Bool = true, to url: URL) -> Bool {
        guard !frames.isEmpty else { return false }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            return false
        }

        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: loop ? 0 : 1
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let delay = max(0, frameDelay)
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay
            ]
        ]

        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        }

        return CGImageDestinationFinalize(destination)
    }
}
