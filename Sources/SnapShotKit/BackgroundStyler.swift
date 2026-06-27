import AppKit

/// A decorative backdrop applied behind a screenshot to produce a polished,
/// shareable image: padded margins, rounded corners, a soft drop shadow, and
/// either a solid fill or a vertical gradient.
enum BackgroundStyle: String, CaseIterable, Identifiable {
    case none
    case light
    case dark
    case oceanGradient
    case sunsetGradient
    case mintGradient
    case violetGradient

    var id: String { rawValue }

    /// Human-readable label for menus and pickers.
    var displayName: String {
        switch self {
        case .none:           return "None"
        case .light:          return "Light"
        case .dark:           return "Dark"
        case .oceanGradient:  return "Ocean"
        case .sunsetGradient: return "Sunset"
        case .mintGradient:   return "Mint"
        case .violetGradient: return "Violet"
        }
    }

    /// Solid fill color for the flat styles. `nil` for gradient styles.
    fileprivate var solidColor: NSColor? {
        switch self {
        case .light: return NSColor(srgbRed: 0.949, green: 0.953, blue: 0.965, alpha: 1.0)
        case .dark:  return NSColor(srgbRed: 0.110, green: 0.118, blue: 0.137, alpha: 1.0)
        default:     return nil
        }
    }

    /// Top-to-bottom gradient for the gradient styles. `nil` for flat styles.
    fileprivate var gradient: NSGradient? {
        switch self {
        case .oceanGradient:
            return NSGradient(starting: NSColor(srgbRed: 0.157, green: 0.553, blue: 0.961, alpha: 1.0),
                              ending:   NSColor(srgbRed: 0.122, green: 0.290, blue: 0.733, alpha: 1.0))
        case .sunsetGradient:
            return NSGradient(starting: NSColor(srgbRed: 0.992, green: 0.541, blue: 0.337, alpha: 1.0),
                              ending:   NSColor(srgbRed: 0.910, green: 0.247, blue: 0.490, alpha: 1.0))
        case .mintGradient:
            return NSGradient(starting: NSColor(srgbRed: 0.310, green: 0.886, blue: 0.706, alpha: 1.0),
                              ending:   NSColor(srgbRed: 0.118, green: 0.612, blue: 0.553, alpha: 1.0))
        case .violetGradient:
            return NSGradient(starting: NSColor(srgbRed: 0.553, green: 0.361, blue: 0.965, alpha: 1.0),
                              ending:   NSColor(srgbRed: 0.357, green: 0.180, blue: 0.745, alpha: 1.0))
        default:
            return nil
        }
    }
}

/// Composites a screenshot onto a styled background at full pixel resolution.
///
/// All geometry is computed in pixel space and drawn into an explicit
/// `NSBitmapImageRep` so Retina sources keep every pixel. Padding, corner
/// radius, and shadow are expressed in points and scaled by the source image's
/// Retina factor so the result looks consistent regardless of capture scale.
@MainActor
enum BackgroundStyler {

    /// Renders `image` centered on the chosen background.
    ///
    /// - Parameters:
    ///   - image: The source screenshot (may carry Retina pixels).
    ///   - style: The backdrop to apply. `.none` returns `image` unchanged.
    ///   - padding: Margin around the screenshot, in points.
    ///   - cornerRadius: Corner radius applied to the screenshot, in points.
    ///   - shadow: Whether to draw a soft drop shadow behind the screenshot.
    /// - Returns: A new composited `NSImage` at full resolution, or the original
    ///   image when `style == .none`.
    static func render(_ image: NSImage,
                       style: BackgroundStyle,
                       padding: CGFloat = 64,
                       cornerRadius: CGFloat = 16,
                       shadow: Bool = true) -> NSImage {
        guard style != .none else { return image }

        let imagePx = pixelSize(of: image)
        guard imagePx.width > 0, imagePx.height > 0 else { return image }

        // Derive the Retina factor from pixel-vs-logical size so point-based
        // measurements scale to match the source's pixel density.
        let logical = image.size
        let scale: CGFloat = logical.width > 0
            ? max(1.0, imagePx.width / logical.width)
            : 1.0

        let padPx = (padding * scale).rounded()
        let radiusPx = max(0, cornerRadius * scale)

        let canvasPx = NSSize(width: imagePx.width + padPx * 2,
                              height: imagePx.height + padPx * 2)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvasPx.width),
            pixelsHigh: Int(canvasPx.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return image
        }
        rep.size = canvasPx

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return image
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let canvasRect = NSRect(origin: .zero, size: canvasPx)

        // 1. Background fill (solid or vertical gradient).
        if let gradient = style.gradient {
            // Angle of -90 paints top color at the top, bottom color at the
            // bottom in AppKit's y-up space.
            gradient.draw(in: canvasRect, angle: -90)
        } else if let solid = style.solidColor {
            solid.setFill()
            canvasRect.fill()
        }

        // The screenshot sits centered with `padPx` margins on all sides.
        let imageRect = NSRect(x: padPx,
                               y: padPx,
                               width: imagePx.width,
                               height: imagePx.height)
        let clipPath = NSBezierPath(roundedRect: imageRect,
                                    xRadius: radiusPx,
                                    yRadius: radiusPx)

        // 2. Optional soft drop shadow, cast by the rounded image silhouette.
        if shadow {
            NSGraphicsContext.saveGraphicsState()
            let dropShadow = NSShadow()
            dropShadow.shadowBlurRadius = max(8, 24 * scale)
            // Negative y offset moves the shadow downward in y-up space.
            dropShadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
            dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            dropShadow.set()
            // Fill the rounded silhouette so the shadow has an opaque caster.
            NSColor.black.setFill()
            clipPath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // 3. Draw the screenshot, clipped to the rounded rectangle.
        NSGraphicsContext.saveGraphicsState()
        clipPath.setClip()
        image.draw(in: imageRect,
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver,
                   fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: canvasPx)
        out.addRepresentation(rep)
        return out
    }

    /// Returns the true pixel dimensions of an image, preferring the bitmap
    /// rep's pixel count so Retina sources keep full resolution.
    private static func pixelSize(of image: NSImage) -> NSSize {
        var maxWidth = 0
        var maxHeight = 0
        for rep in image.representations {
            maxWidth = max(maxWidth, rep.pixelsWide)
            maxHeight = max(maxHeight, rep.pixelsHigh)
        }
        if maxWidth > 0 && maxHeight > 0 {
            return NSSize(width: maxWidth, height: maxHeight)
        }
        let w = max(1, Int(image.size.width.rounded()))
        let h = max(1, Int(image.size.height.rounded()))
        return NSSize(width: w, height: h)
    }
}
