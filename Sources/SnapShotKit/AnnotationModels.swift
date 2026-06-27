import SwiftUI
import AppKit

// MARK: - Capture item

/// A single screenshot plus any annotations the user has drawn on it.
/// `image` is the raw captured bitmap; `annotations` are stored in IMAGE PIXEL
/// coordinates (top-left origin, y-down) so that view resizing never corrupts
/// saved data and the export flatten path needs no scale factor.
struct CaptureItem: Identifiable {
    let id = UUID()
    var image: NSImage
    var annotations: [Annotation] = []
    var title: String
}

// MARK: - Annotation model

enum AnnotationKind: String, Codable, CaseIterable, Identifiable {
    case arrow
    case rectangle
    case line
    case ellipse
    case text
    case highlight
    case pen
    case blur
    case step

    var id: String { rawValue }

    /// User-facing label for pickers/menus.
    var displayName: String {
        switch self {
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .line: return "Line"
        case .ellipse: return "Ellipse"
        case .text: return "Text"
        case .highlight: return "Highlight"
        case .pen: return "Pen"
        case .blur: return "Blur"
        case .step: return "Step"
        }
    }

    /// SF Symbol name suitable for a toolbar control.
    var systemImageName: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .line: return "line.diagonal"
        case .ellipse: return "oval"
        case .text: return "textformat"
        case .highlight: return "highlighter"
        case .pen: return "scribble.variable"
        case .blur: return "eye.slash"
        case .step: return "number.circle.fill"
        }
    }
}

/// A single drawn annotation.
///
/// `start` and `end` are stored in image-pixel coordinates (top-left origin,
/// y-down) — the same convention SwiftUI's `Canvas` and `DragGesture` use.
/// The export/flatten path is solely responsible for flipping y to AppKit's
/// bottom-left, y-up convention.
struct Annotation: Identifiable {
    let id = UUID()
    var kind: AnnotationKind
    var start: CGPoint
    var end: CGPoint
    var text: String = ""
    var colorHex: String = "#FF3B30"

    /// Freehand pen path, stored in image-pixel coordinates (top-left, y-down).
    /// Empty for every non-pen kind.
    var points: [CGPoint] = []

    /// Badge number for `.step` annotations; nil for every other kind.
    var number: Int? = nil

    /// Optional stroke width override in image pixels. When nil the flatten and
    /// canvas paths fall back to a size-scaled default.
    var lineWidth: CGFloat? = nil

    /// Convenience: the annotation's color as a SwiftUI `Color`.
    var color: Color { Color(hex: colorHex) }

    /// Convenience: the annotation's color as an `NSColor` for the flatten path.
    var nsColor: NSColor { NSColor(hex: colorHex) }

    /// Axis-aligned rectangle spanning the annotation, normalized so the origin
    /// is the top-left-most point. For pen annotations the bounds are computed
    /// from the recorded path points; otherwise from `start`/`end`. Useful for
    /// rectangle, highlight, ellipse, and blur kinds and for hit testing.
    var boundingRect: CGRect {
        if !points.isEmpty {
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            let minX = xs.min() ?? 0
            let minY = ys.min() ?? 0
            let maxX = xs.max() ?? 0
            let maxY = ys.max() ?? 0
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        return CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}

// MARK: - Color(hex:) helpers

extension Color {
    /// Creates a `Color` from a hex string. Accepts the forms
    /// `#RGB`, `#RGBA`, `#RRGGBB`, and `#RRGGBBAA` (with or without a leading
    /// `#`). Falls back to opaque black on a malformed string.
    init(hex: String) {
        let (r, g, b, a) = hexComponents(hex)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Returns the color as a `#RRGGBBAA` (or `#RRGGBB` when fully opaque)
    /// hex string in the sRGB space.
    func toHex(includeAlpha: Bool = false) -> String {
        NSColor(self).toHex(includeAlpha: includeAlpha)
    }
}

extension NSColor {
    /// Creates an sRGB `NSColor` from a hex string. See `Color(hex:)`.
    convenience init(hex: String) {
        let (r, g, b, a) = hexComponents(hex)
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Returns the color as a `#RRGGBBAA` (or `#RRGGBB` when fully opaque)
    /// hex string in the sRGB space.
    func toHex(includeAlpha: Bool = false) -> String {
        let converted = usingColorSpace(.sRGB) ?? self
        let r = Int((converted.redComponent * 255).rounded())
        let g = Int((converted.greenComponent * 255).rounded())
        let b = Int((converted.blueComponent * 255).rounded())
        let a = Int((converted.alphaComponent * 255).rounded())
        if includeAlpha {
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// Parses a hex color string into normalized sRGB components in 0...1.
/// Supports `#RGB`, `#RGBA`, `#RRGGBB`, and `#RRGGBBAA`. Returns opaque black
/// for any unparseable input.
private func hexComponents(_ hex: String) -> (red: Double, green: Double, blue: Double, alpha: Double) {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    s = s.uppercased()

    guard let value = UInt64(s, radix: 16) else {
        return (0, 0, 0, 1)
    }

    func norm(_ v: UInt64) -> Double { Double(v) / 255.0 }

    switch s.count {
    case 3: // RGB (4-bit per channel, expanded)
        let r = (value >> 8) & 0xF
        let g = (value >> 4) & 0xF
        let b = value & 0xF
        return (norm(r << 4 | r), norm(g << 4 | g), norm(b << 4 | b), 1)
    case 4: // RGBA (4-bit per channel, expanded)
        let r = (value >> 12) & 0xF
        let g = (value >> 8) & 0xF
        let b = (value >> 4) & 0xF
        let a = value & 0xF
        return (norm(r << 4 | r), norm(g << 4 | g), norm(b << 4 | b), norm(a << 4 | a))
    case 6: // RRGGBB
        let r = (value >> 16) & 0xFF
        let g = (value >> 8) & 0xFF
        let b = value & 0xFF
        return (norm(r), norm(g), norm(b), 1)
    case 8: // RRGGBBAA
        let r = (value >> 24) & 0xFF
        let g = (value >> 16) & 0xFF
        let b = (value >> 8) & 0xFF
        let a = value & 0xFF
        return (norm(r), norm(g), norm(b), norm(a))
    default:
        return (0, 0, 0, 1)
    }
}

// MARK: - Pixel size helper

extension NSImage {
    /// True pixel dimensions of the image, read from the largest bitmap
    /// representation when available (`image.size` is in points and differs
    /// from pixels on Retina or for many loaded files). Falls back to the
    /// point size scaled by nothing when no bitmap rep exists.
    ///
    /// Both the on-screen coordinate mapping and the export flatten canvas
    /// should use THIS size so exported resolution matches the source.
    var pixelSize: CGSize {
        var best: CGSize = .zero
        for rep in representations {
            // pixelsWide/High return 0 for vector reps; skip those.
            let w = CGFloat(rep.pixelsWide)
            let h = CGFloat(rep.pixelsHigh)
            guard w > 0, h > 0 else { continue }
            if w * h > best.width * best.height {
                best = CGSize(width: w, height: h)
            }
        }
        if best.width > 0, best.height > 0 {
            return best
        }
        return size
    }
}
