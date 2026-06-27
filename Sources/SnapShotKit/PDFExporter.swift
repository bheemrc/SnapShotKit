import PDFKit
import AppKit
import CoreImage

/// Assembles `CaptureItem`s (image + annotations) into a single multi-page PDF.
///
/// Each item's annotations are flattened onto the base image at full pixel
/// resolution, then embedded as one PDF page sized to the image's pixel
/// dimensions (1px -> 1pt) so no detail is lost.
enum PDFExporter {

    enum ExportError: LocalizedError {
        case noItems
        case pageCreationFailed(itemTitle: String)
        case writeFailed(url: URL)

        var errorDescription: String? {
            switch self {
            case .noItems:
                return "There are no captures to export."
            case .pageCreationFailed(let title):
                return "Could not create a PDF page for \"\(title)\"."
            case .writeFailed(let url):
                return "Failed to write the PDF to \(url.path)."
            }
        }
    }

    /// Exports the given items as a single PDF written to `url`.
    static func export(_ items: [CaptureItem], to url: URL) throws {
        guard !items.isEmpty else { throw ExportError.noItems }

        let document = PDFDocument()
        for item in items {
            let flattened = flatten(item)
            guard let page = PDFPage(image: flattened) else {
                throw ExportError.pageCreationFailed(itemTitle: item.title)
            }
            document.insert(page, at: document.pageCount)
        }

        guard document.write(to: url) else {
            throw ExportError.writeFailed(url: url)
        }
    }

    // MARK: - Flattening

    /// Returns the pixel dimensions of an NSImage, preferring the bitmap rep's
    /// true pixel count (so Retina sources keep full resolution).
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
        // Fall back to logical size if no rep reports pixel dimensions.
        let w = max(1, Int(image.size.width.rounded()))
        let h = max(1, Int(image.size.height.rounded()))
        return NSSize(width: w, height: h)
    }

    /// Draws the base image plus its annotations into a new NSImage built at
    /// full pixel resolution. Annotations are stored in image *pixel*
    /// coordinates with a top-left origin (matching the on-screen Canvas), so
    /// every y is flipped here for AppKit's bottom-left/y-up drawing space.
    static func flatten(_ item: CaptureItem) -> NSImage {
        let base = item.image
        let px = pixelSize(of: base)

        // Render into an explicit bitmap rep for deterministic output.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(px.width),
            pixelsHigh: Int(px.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            // Extremely unlikely; return the base image unmodified.
            return base
        }
        rep.size = px

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return base
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let fullRect = NSRect(origin: .zero, size: px)
        base.draw(in: fullRect,
                  from: NSRect(origin: .zero, size: base.size),
                  operation: .copy,
                  fraction: 1.0)

        for annotation in item.annotations {
            draw(annotation, base: base, pixelSize: px)
        }

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: px)
        out.addRepresentation(rep)
        return out
    }

    // MARK: - Annotation drawing (pixel space, y-up)

    /// Flip a top-left y into AppKit's bottom-left coordinate space.
    private static func flipY(_ y: CGFloat, height: CGFloat) -> CGFloat {
        height - y
    }

    private static func flip(_ p: CGPoint, height: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: flipY(p.y, height: height))
    }

    private static func draw(_ annotation: Annotation, base: NSImage, pixelSize px: NSSize) {
        let color = NSColor(hex: annotation.colorHex)
        // Scale stroke weight with image size so it reads well on large captures,
        // unless the annotation carries an explicit pixel-space override.
        let lineWidth = annotation.lineWidth ?? max(2.0, min(px.width, px.height) / 250.0)

        let s = flip(annotation.start, height: px.height)
        let e = flip(annotation.end, height: px.height)

        switch annotation.kind {
        case .arrow:
            drawArrow(from: s, to: e, color: color, lineWidth: lineWidth)
        case .rectangle:
            drawRectangle(from: s, to: e, color: color, lineWidth: lineWidth)
        case .line:
            drawLine(from: s, to: e, color: color, lineWidth: lineWidth)
        case .ellipse:
            drawEllipse(from: s, to: e, color: color, lineWidth: lineWidth)
        case .pen:
            let pts = annotation.points.map { flip($0, height: px.height) }
            drawPen(points: pts, color: color, lineWidth: lineWidth)
        case .step:
            drawStep(number: annotation.number ?? 1,
                     at: s, color: color, pixelSize: px)
        case .blur:
            drawBlur(annotation, base: base, pixelSize: px)
        case .highlight:
            drawHighlight(from: s, to: e, color: color)
        case .text:
            // Text placement uses NSString's own top-left layout, so pass the
            // unflipped origin (top-left of the start point) directly.
            drawText(annotation.text,
                     at: annotation.start,
                     color: color,
                     pixelSize: px)
        }
    }

    private static func drawLine(from s: CGPoint,
                                 to e: CGPoint,
                                 color: NSColor,
                                 lineWidth: CGFloat) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.move(to: s)
        path.line(to: e)
        path.stroke()
    }

    private static func drawEllipse(from s: CGPoint,
                                    to e: CGPoint,
                                    color: NSColor,
                                    lineWidth: CGFloat) {
        let rect = normalizedRect(s, e)
        color.setStroke()
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = lineWidth
        path.stroke()
    }

    private static func drawPen(points: [CGPoint],
                                color: NSColor,
                                lineWidth: CGFloat) {
        guard let first = points.first, points.count > 1 else { return }
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: first)
        for p in points.dropFirst() { path.line(to: p) }
        path.stroke()
    }

    private static func drawStep(number: Int,
                                 at center: CGPoint,
                                 color: NSColor,
                                 pixelSize px: NSSize) {
        let radius = max(14.0, min(px.width, px.height) / 40.0)
        let rect = NSRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()

        let fontSize = radius * 1.1
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style
        ]
        let string = NSString(string: "\(number)")
        let size = string.size(withAttributes: attributes)
        let origin = CGPoint(x: center.x - size.width / 2,
                             y: center.y - size.height / 2)
        string.draw(at: origin, withAttributes: attributes)
    }

    /// Shared CoreImage context for blur/pixelation rendering.
    private static let ciContext = CIContext(options: nil)

    /// Real redaction: crop the annotation's pixel region from the base image,
    /// pixelate it with CoreImage, and draw the result back into that region.
    private static func drawBlur(_ annotation: Annotation,
                                 base: NSImage,
                                 pixelSize px: NSSize) {
        // Region in top-left pixel coordinates, clamped to the image bounds.
        let raw = annotation.boundingRect
        let bounds = CGRect(origin: .zero, size: CGSize(width: px.width, height: px.height))
        let region = raw.intersection(bounds).integral
        guard region.width >= 1, region.height >= 1 else { return }

        guard let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        // The base CGImage shares the image's top-left pixel coordinate space, so
        // the crop rect is the top-left region directly.
        guard let cropped = cg.cropping(to: region) else { return }

        let ciInput = CIImage(cgImage: cropped)
        let scale = max(8.0, min(region.width, region.height) / 12.0)
        guard let filter = CIFilter(name: "CIPixellate") else { return }
        filter.setValue(ciInput, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: ciInput.extent.midX, y: ciInput.extent.midY),
                        forKey: kCIInputCenterKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)

        guard let output = filter.outputImage,
              let result = ciContext.createCGImage(output, from: ciInput.extent) else {
            return
        }

        // Draw into the y-up flatten context: convert the top-left region to the
        // bottom-left draw rect.
        guard let cgContext = NSGraphicsContext.current?.cgContext else { return }
        let drawRect = CGRect(x: region.minX,
                              y: px.height - region.maxY,
                              width: region.width,
                              height: region.height)
        cgContext.saveGState()
        cgContext.interpolationQuality = .none
        cgContext.draw(result, in: drawRect)
        cgContext.restoreGState()
    }

    private static func drawArrow(from s: CGPoint,
                                  to e: CGPoint,
                                  color: NSColor,
                                  lineWidth: CGFloat) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: s)
        path.line(to: e)

        // Arrowhead computed AFTER the y-flip (on flipped points).
        let angle = atan2(e.y - s.y, e.x - s.x)
        let wing = CGFloat.pi / 7.0
        let head = max(10.0, lineWidth * 5.0)
        for d in [angle + .pi - wing, angle + .pi + wing] {
            path.move(to: e)
            path.line(to: CGPoint(x: e.x + head * cos(d),
                                  y: e.y + head * sin(d)))
        }
        path.stroke()
    }

    private static func drawRectangle(from s: CGPoint,
                                      to e: CGPoint,
                                      color: NSColor,
                                      lineWidth: CGFloat) {
        let rect = normalizedRect(s, e)
        color.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = lineWidth
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func drawHighlight(from s: CGPoint,
                                      to e: CGPoint,
                                      color: NSColor) {
        let rect = normalizedRect(s, e)
        color.withAlphaComponent(0.30).setFill()
        NSBezierPath(rect: rect).fill()
    }

    private static func drawText(_ text: String,
                                 at topLeft: CGPoint,
                                 color: NSColor,
                                 pixelSize px: NSSize) {
        guard !text.isEmpty else { return }
        let fontSize = max(14.0, min(px.width, px.height) / 35.0)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: color
        ]
        let string = NSString(string: text)
        // NSString.draw uses its own top-left layout even in a y-up context, so
        // convert the stored top-left origin to a bottom-left draw origin by
        // subtracting the line height.
        let size = string.size(withAttributes: attributes)
        let origin = CGPoint(x: topLeft.x,
                             y: flipY(topLeft.y, height: px.height) - size.height)
        string.draw(at: origin, withAttributes: attributes)
    }

    private static func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> NSRect {
        NSRect(x: min(a.x, b.x),
               y: min(a.y, b.y),
               width: abs(a.x - b.x),
               height: abs(a.y - b.y))
    }
}

// Hex color helper (`NSColor(hex:)`) is defined in AnnotationModels.swift.
