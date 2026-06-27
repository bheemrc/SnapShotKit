import AppKit
import CoreGraphics

/// Best-effort "scrolling" capture that stitches several screen captures of a
/// fixed region into a single tall image, revealing content that does not fit in
/// one screenful.
///
/// The flow, starting with the target scrolled to the top:
///   1. Capture the region.
///   2. Post a synthetic scroll-down over the region's center.
///   3. Wait briefly for the target to redraw.
///   4. Capture again, find the vertical overlap against the previous frame, and
///      append only the new (non-overlapping) bottom rows to an accumulating
///      bitmap.
/// Repeat until a frame adds no new content or `maxScreens` is reached.
///
/// Known limitations (intentional, this is a heuristic):
///   - Synthetic scroll events require the Accessibility (input-monitoring) TCC
///     permission. Without it the OS silently drops the events, no scrolling is
///     observed, and this engine returns the single captured frame instead of
///     throwing or looping.
///   - It assumes uniform, content-shifting scroll behavior. Sticky headers or
///     footers, parallax, lazy-loaded reflow, or inertial overshoot can throw off
///     the row-overlap detection. The detector is conservative: when it cannot
///     find a confident overlap it stops rather than appending garbage.
///   - Scroll direction follows the conventional "negative = down" CGEvent
///     convention. If the system inverts it (or the target ignores the event),
///     no new bottom content appears and capture stops early — bounded, never
///     infinite.
@MainActor
enum ScrollingCaptureEngine {

    /// Captures `region` (global screen points, bottom-left origin, as produced by
    /// `RegionSelectionOverlay` / consumed by `CaptureEngine.captureRegion`) and
    /// returns a stitched long image at full pixel resolution.
    ///
    /// Always returns at least the first captured frame; it never throws solely
    /// because scrolling failed. It only rethrows if the very first capture fails.
    static func capture(region: CGRect, maxScreens: Int = 12) async throws -> NSImage {
        // First frame is mandatory; let a real capture failure propagate.
        let firstImage = try await CaptureEngine.captureRegion(region)
        guard let firstFrame = Frame(image: firstImage) else { return firstImage }

        let frames = max(1, maxScreens)
        let frameHeight = firstFrame.height
        var canvas = LongCanvas(firstFrame)
        var previous = firstFrame

        // Resolve the scroll target point in Quartz global coordinates (top-left
        // origin), flipping the region center from Cocoa's bottom-left space about
        // the primary display.
        let primary = NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let primaryTop = primary?.frame.maxY ?? region.maxY
        let scrollPoint = CGPoint(
            x: region.midX,
            y: primaryTop - region.midY
        )

        // Scroll down by most of the region height so consecutive frames retain a
        // healthy overlap band for the detector to lock onto. Negative wheel1
        // scrolls content downward (reveals lower content).
        let scrollDelta = -max(1, Int((region.height * 0.72).rounded()))

        // Remember and restore the cursor so the capture is non-destructive.
        let originalCursor = NSEvent.mouseLocation
        defer {
            let restore = CGPoint(x: originalCursor.x, y: primaryTop - originalCursor.y)
            CGWarpMouseCursorPosition(restore)
        }

        var captured = 1
        while captured < frames {
            postScroll(at: scrollPoint, deltaPixels: scrollDelta)

            // Give the target a moment to redraw before the next capture.
            try? await Task.sleep(nanoseconds: 230_000_000)

            let nextImage: NSImage
            do {
                nextImage = try await CaptureEngine.captureRegion(region)
            } catch {
                break // A later capture failed; keep what we have.
            }

            guard
                let next = Frame(image: nextImage),
                next.width == previous.width,
                next.height == previous.height
            else { break }

            // Find how many new bottom rows `next` adds relative to `previous`.
            // nil means no confident overlap / no progress — stop here.
            guard let newRows = newBottomRows(previous: previous, current: next) else {
                break
            }

            canvas.append(next, newRows: newRows)
            previous = next
            captured += 1
        }

        // Convert accumulated pixels back to points using the per-frame scale so
        // the result displays at the same physical size as the source region.
        let pixelsPerPoint = region.height > 0
            ? CGFloat(frameHeight) / region.height
            : 1
        let pointHeight = pixelsPerPoint > 0
            ? CGFloat(canvas.rows) / pixelsPerPoint
            : region.height

        return canvas.image(pointWidth: region.width, pointHeight: pointHeight)
            ?? firstImage
    }

    // MARK: - Synthetic scrolling

    /// Warps the cursor over the target and posts a pixel-unit scroll event there.
    /// If Accessibility permission is missing the OS drops the event silently;
    /// that surfaces upstream as "no new content" and stops the loop.
    private nonisolated static func postScroll(at point: CGPoint, deltaPixels: Int) {
        CGWarpMouseCursorPosition(point)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(clamping: deltaPixels),
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Overlap detection

    /// Returns the number of new bottom rows `current` contributes beyond
    /// `previous`, or `nil` when no confident, content-advancing overlap is found
    /// (identical frames, scrolled the wrong way, or an untrustworthy match).
    private nonisolated static func newBottomRows(previous: Frame, current: Frame) -> Int? {
        let height = previous.height
        let cols = previous.cols
        guard cols > 0, current.cols == cols else { return nil }

        // Require a meaningful overlap band so we don't latch onto a thin sliver.
        let minOverlap = max(8, height / 5)
        let minShift = max(1, height / 200)
        let maxShift = height - minOverlap
        guard maxShift >= minShift else { return nil }

        let a = previous.signature
        let b = current.signature

        // Baseline: cost at zero shift. For an unchanged frame this is ~0, which
        // lets us reject "no scroll happened".
        let zeroCost = rowCost(a, b, cols: cols, height: height, shift: 0, rowStride: 2)

        // Coarse search, then refine around the coarse minimum for row accuracy.
        var bestShift = minShift
        var bestCost = Double.greatestFiniteMagnitude
        let coarseStep = max(1, (maxShift - minShift) / 64)

        var shift = minShift
        while shift <= maxShift {
            let cost = rowCost(a, b, cols: cols, height: height, shift: shift, rowStride: 2)
            if cost < bestCost {
                bestCost = cost
                bestShift = shift
            }
            shift += coarseStep
        }

        let refineLow = max(minShift, bestShift - coarseStep)
        let refineHigh = min(maxShift, bestShift + coarseStep)
        shift = refineLow
        while shift <= refineHigh {
            let cost = rowCost(a, b, cols: cols, height: height, shift: shift, rowStride: 1)
            if cost < bestCost {
                bestCost = cost
                bestShift = shift
            }
            shift += 1
        }

        // Accept only a genuinely good match that also clearly beats the no-scroll
        // baseline. Luminance signatures are on a 0...255 scale.
        let matchIsTight = bestCost < 18.0
        let beatsBaseline = bestCost < zeroCost * 0.55
        guard matchIsTight, beatsBaseline, bestShift > 0 else { return nil }

        return bestShift
    }

    /// Mean absolute difference between `previous` (shifted down by `shift` rows)
    /// and `current` over their overlapping region, using the sampled per-row
    /// column luminances. Lower is a better alignment.
    private nonisolated static func rowCost(
        _ a: [Double],
        _ b: [Double],
        cols: Int,
        height: Int,
        shift: Int,
        rowStride: Int
    ) -> Double {
        let overlap = height - shift
        guard overlap > 0 else { return .greatestFiniteMagnitude }
        let stride = max(1, rowStride)

        var sum = 0.0
        var count = 0
        var k = 0
        while k < overlap {
            let aBase = (k + shift) * cols
            let bBase = k * cols
            var c = 0
            while c < cols {
                sum += abs(a[aBase + c] - b[bBase + c])
                c += 1
            }
            count += cols
            k += stride
        }
        return count > 0 ? sum / Double(count) : .greatestFiniteMagnitude
    }

    // MARK: - Pixel frame

    /// A captured frame's pixels (RGBA8, row 0 = top, `width * 4` bytes per row)
    /// plus a compact per-row luminance signature used for overlap detection.
    private struct Frame {
        let width: Int
        let height: Int
        let cols: Int
        let pixels: [UInt8]
        /// Flattened `height * cols` luminance samples; row `r`, column `c` lives
        /// at `signature[r * cols + c]`.
        let signature: [Double]

        init?(image: NSImage) {
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            let w = cg.width
            let h = cg.height
            guard w > 0, h > 0 else { return nil }

            let bytesPerRow = w * 4
            var buffer = [UInt8](repeating: 0, count: bytesPerRow * h)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

            let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(
                    data: raw.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                ) else { return false }
                // Flip so buffer row 0 corresponds to the image's top edge.
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }

            // Sample a fixed set of evenly spaced columns to build a per-row
            // luminance signature that is cheap to compare yet keeps horizontal
            // structure (averaging a whole row alone matches too eagerly).
            let sampleCount = min(w, 32)
            var sig = [Double](repeating: 0, count: h * sampleCount)
            for r in 0..<h {
                let rowBase = r * bytesPerRow
                let sigBase = r * sampleCount
                for s in 0..<sampleCount {
                    let x = sampleCount > 1
                        ? (s * (w - 1)) / (sampleCount - 1)
                        : 0
                    let p = rowBase + x * 4
                    let red = Double(buffer[p])
                    let green = Double(buffer[p + 1])
                    let blue = Double(buffer[p + 2])
                    sig[sigBase + s] = 0.299 * red + 0.587 * green + 0.114 * blue
                }
            }

            self.width = w
            self.height = h
            self.cols = sampleCount
            self.pixels = buffer
            self.signature = sig
        }
    }

    // MARK: - Accumulating tall bitmap

    /// Growing RGBA8 bitmap (row 0 = top) that the stitched frames append into.
    private struct LongCanvas {
        let width: Int
        private(set) var rows: Int
        private(set) var pixels: [UInt8]

        init(_ frame: Frame) {
            width = frame.width
            rows = frame.height
            pixels = frame.pixels
        }

        /// Appends the bottom `newRows` rows of `frame` to the canvas.
        mutating func append(_ frame: Frame, newRows: Int) {
            guard frame.width == width, newRows > 0, newRows <= frame.height else { return }
            let start = (frame.height - newRows) * width * 4
            pixels.append(contentsOf: frame.pixels[start...])
            rows += newRows
        }

        /// Renders the accumulated pixels into an `NSImage` sized in points while
        /// carrying the full pixel buffer.
        func image(pointWidth: CGFloat, pointHeight: CGFloat) -> NSImage? {
            guard width > 0, rows > 0 else { return nil }
            let data = Data(pixels)
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            guard let cg = CGImage(
                width: width,
                height: rows,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ) else { return nil }
            return NSImage(
                cgImage: cg,
                size: NSSize(width: pointWidth, height: max(1, pointHeight))
            )
        }
    }
}
