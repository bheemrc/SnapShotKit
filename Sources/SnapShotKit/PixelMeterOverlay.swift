import AppKit
import CoreGraphics

/// A full-screen overlay offering two on-screen measurement tools:
///
/// - `.colorPicker` shows a magnifier loupe that follows the cursor, sampling the screen
///   pixel underneath and reporting it as HEX / RGB / HSL. Clicking copies all three
///   representations (newline-joined) to the pasteboard and reports the hex string back.
/// - `.ruler` lets the user drag between two points and reads out the distance in pixels
///   (dx, dy and the hypotenuse) live; releasing copies a `"W×H px (NN px)"` summary.
///
/// Screen pixel sampling relies on `CGDisplayCreateImage`, which requires the Screen
/// Recording permission. If permission is missing the captured image is empty and the
/// loupe simply shows black; the rest of the interaction still behaves normally.
///
/// The overlay keeps itself alive through a static strong reference for the duration of
/// the interaction; without it the window (and its event machinery) could be deallocated
/// once `present` returns.
@MainActor
final class PixelMeterOverlay {

    /// Selects which tool the overlay presents.
    enum Mode {
        case colorPicker
        case ruler
    }

    // MARK: - Active-instance retention

    /// Holds the in-flight overlay so it isn't deallocated mid-interaction. Cleared the
    /// moment the interaction finishes (success or cancel).
    private static var active: PixelMeterOverlay?

    // MARK: - State

    private var windows: [NSWindow] = []
    private var mode: Mode = .colorPicker

    /// Invoked exactly once with the copied result string, or `nil` if the user pressed Esc.
    private var completion: ((String?) -> Void)?

    /// Guards against the completion handler firing more than once.
    private var didFinish = false

    private init() {}

    // MARK: - Public API

    /// Presents the overlay across every screen in the requested `mode`. `completion` is
    /// invoked on the main thread with the copied result string (the hex color for
    /// `.colorPicker`, the `"W×H px (NN px)"` summary for `.ruler`), or `nil` when the
    /// user cancels with Esc. The overlay windows are removed *before* `completion` runs.
    static func present(mode: Mode, completion: @escaping (String?) -> Void) {
        // Tear down any overlay that is somehow still up.
        active?.finish(with: nil)

        let overlay = PixelMeterOverlay()
        overlay.mode = mode
        overlay.completion = completion
        active = overlay
        overlay.show()
    }

    // MARK: - Window setup

    private func show() {
        let screens = NSScreen.screens.isEmpty
            ? [NSScreen.main].compactMap { $0 }
            : NSScreen.screens

        for screen in screens {
            // Non-activating panel: becomes key for keyboard/mouse without activating
            // the app, so summoning the loupe over a full-screen app doesn't switch
            // away to the app's desktop Space.
            let window = MeterPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            // Mouse-moved events are required so the colour loupe can track the cursor.
            window.acceptsMouseMovedEvents = true
            window.setFrame(screen.frame, display: false)

            let view = PixelMeterView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.owner = self
            view.mode = mode
            window.contentView = view

            windows.append(window)
            window.orderFrontRegardless()
        }

        windows.first?.makeKey()
        NSCursor.crosshair.push()
    }

    // MARK: - Completion plumbing

    /// Copies `string` to the general pasteboard and finishes with `result`. The pasteboard
    /// payload and the reported result can differ (colour picker copies three formats but
    /// reports only the hex string).
    fileprivate func finish(copying pasteboardString: String, reporting result: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(pasteboardString, forType: .string)
        finish(with: result)
    }

    /// Tears down every overlay window, then invokes the completion handler exactly once.
    /// Windows are removed before the callback so a follow-up capture never includes them.
    fileprivate func finish(with result: String?) {
        guard !didFinish else { return }
        didFinish = true

        NSCursor.pop()

        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()

        let handler = completion
        completion = nil

        if PixelMeterOverlay.active === self {
            PixelMeterOverlay.active = nil
        }

        handler?(result)
    }
}

// MARK: - Sampled colour value

/// A single RGB sample plus its derived textual representations.
private struct PixelColor {
    let r: Int
    let g: Int
    let b: Int

    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    var rgb: String { "rgb(\(r), \(g), \(b))" }

    /// HSL with hue in degrees and saturation/lightness as percentages.
    var hsl: String {
        let rf = Double(r) / 255.0
        let gf = Double(g) / 255.0
        let bf = Double(b) / 255.0
        let maxV = max(rf, gf, bf)
        let minV = min(rf, gf, bf)
        let l = (maxV + minV) / 2.0

        var h = 0.0
        var s = 0.0
        if maxV != minV {
            let d = maxV - minV
            s = l > 0.5 ? d / (2.0 - maxV - minV) : d / (maxV + minV)
            switch maxV {
            case rf: h = (gf - bf) / d + (gf < bf ? 6.0 : 0.0)
            case gf: h = (bf - rf) / d + 2.0
            default: h = (rf - gf) / d + 4.0
            }
            h /= 6.0
        }

        let hDeg = Int((h * 360.0).rounded())
        let sPct = Int((s * 100.0).rounded())
        let lPct = Int((l * 100.0).rounded())
        return "hsl(\(hDeg), \(sPct)%, \(lPct)%)"
    }

    var swatch: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1.0)
    }
}

// MARK: - Overlay window

/// A borderless, non-activating panel that can still become key, so the loupe/ruler
/// overlay receives keyboard and mouse events without activating the app — which would
/// switch away from a full-screen Space to the app's own desktop Space.
private final class MeterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay content view

/// Renders and drives both overlay modes. The window backdrop stays fully transparent so
/// the user keeps seeing the real screen content underneath the tool chrome.
private final class PixelMeterView: NSView {

    weak var owner: PixelMeterOverlay?
    var mode: PixelMeterOverlay.Mode = .colorPicker

    // MARK: Colour-picker state

    /// The most recently captured neighbourhood around the cursor (top-left origin pixels),
    /// drawn zoomed inside the loupe.
    private var sampleImage: CGImage?
    /// The colour at the centre pixel of `sampleImage`.
    private var sampledColor: PixelColor?
    /// Cursor location in this view's local coordinates, or `nil` if the cursor is elsewhere.
    private var cursorLocal: CGPoint?

    /// Number of points captured on each side around the cursor for the loupe.
    private let sampleSpan: CGFloat = 15
    private let loupeDiameter: CGFloat = 132

    // MARK: Ruler state

    private var anchor: CGPoint?
    private var current: CGPoint?

    private var trackingArea: NSTrackingArea?

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? (window?.screen?.backingScaleFactor ?? 1)
    }

    // MARK: NSView configuration

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        if mode == .colorPicker {
            // Seed the loupe immediately so it appears before the first mouse move.
            sampleColorAtCurrentCursor()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Geometry

    private var rulerRect: CGRect? {
        guard let anchor, let current else { return nil }
        return CGRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        )
    }

    // MARK: Screen sampling

    /// Samples the screen around the current global cursor position if it falls on this
    /// view's display, updating `sampleImage`, `sampledColor` and `cursorLocal`.
    private func sampleColorAtCurrentCursor() {
        guard let window, let screen = window.screen else { return }
        let global = NSEvent.mouseLocation
        guard screen.frame.contains(global) else {
            cursorLocal = nil
            sampleImage = nil
            sampledColor = nil
            needsDisplay = true
            return
        }
        let local = convert(window.convertPoint(fromScreen: global), from: nil)
        updateSample(globalPoint: global, localPoint: local, screen: screen)
    }

    private func updateSample(globalPoint: CGPoint, localPoint: CGPoint, screen: NSScreen) {
        cursorLocal = localPoint
        if let image = captureNeighbourhood(aroundGlobal: globalPoint, screen: screen) {
            sampleImage = image
            sampledColor = centrePixel(of: image)
        }
        needsDisplay = true
    }

    /// Captures a small square of the screen centred on a global (AppKit, bottom-left) point.
    private func captureNeighbourhood(aroundGlobal global: CGPoint, screen: NSScreen) -> CGImage? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = number.uint32Value

        // Convert the global AppKit point (bottom-left origin) into the global Core Graphics
        // display space (top-left origin) used by CGDisplayCreateImage.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgPoint = CGPoint(x: global.x, y: primaryHeight - global.y)

        let half = sampleSpan / 2
        let rect = CGRect(
            x: (cgPoint.x - half).rounded(.down),
            y: (cgPoint.y - half).rounded(.down),
            width: sampleSpan,
            height: sampleSpan
        )
        return CGDisplayCreateImage(displayID, rect: rect)
    }

    /// Reads the centre pixel of `image`, normalised to sRGB.
    private func centrePixel(of image: CGImage) -> PixelColor? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &data,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: info
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let cx = w / 2
        let cy = h / 2
        let idx = cy * bytesPerRow + cx * 4
        return PixelColor(r: Int(data[idx]), g: Int(data[idx + 1]), b: Int(data[idx + 2]))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        switch mode {
        case .colorPicker:
            drawColorLoupe()
        case .ruler:
            drawRuler()
        }
    }

    // MARK: Colour loupe

    private func drawColorLoupe() {
        guard let cursorLocal else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let gap: CGFloat = 26
        let panelWidth: CGFloat = 188
        let panelHeight: CGFloat = 74
        let groupWidth = max(loupeDiameter, panelWidth)
        let groupHeight = loupeDiameter + 10 + panelHeight

        // Default placement: up and to the right of the cursor, flipped to stay on-screen.
        var originX = cursorLocal.x + gap
        var originY = cursorLocal.y + gap
        if originX + groupWidth > bounds.width { originX = cursorLocal.x - gap - groupWidth }
        if originY + groupHeight > bounds.height { originY = cursorLocal.y - gap - groupHeight }
        originX = max(8, min(originX, bounds.width - groupWidth - 8))
        originY = max(8, min(originY, bounds.height - groupHeight - 8))

        let loupeRect = CGRect(
            x: originX + (groupWidth - loupeDiameter) / 2,
            y: originY + panelHeight + 10,
            width: loupeDiameter,
            height: loupeDiameter
        )

        // Loupe disc with crisp, non-interpolated zoomed pixels.
        context.saveGState()
        let circle = CGPath(ellipseIn: loupeRect, transform: nil)
        context.addPath(circle)
        context.clip()
        context.setFillColor(NSColor.black.cgColor)
        context.fill(loupeRect)

        if let sampleImage {
            let cells = CGFloat(sampleImage.width)
            let cell = cells > 0 ? loupeDiameter / cells : loupeDiameter
            context.interpolationQuality = .none
            context.draw(sampleImage, in: loupeRect)

            // Pixel grid, drawn only when cells are large enough to read.
            if cell >= 6 {
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
                context.setLineWidth(1)
                var x = loupeRect.minX
                while x <= loupeRect.maxX + 0.5 {
                    context.move(to: CGPoint(x: x, y: loupeRect.minY))
                    context.addLine(to: CGPoint(x: x, y: loupeRect.maxY))
                    x += cell
                }
                var y = loupeRect.minY
                while y <= loupeRect.maxY + 0.5 {
                    context.move(to: CGPoint(x: loupeRect.minX, y: y))
                    context.addLine(to: CGPoint(x: loupeRect.maxX, y: y))
                    y += cell
                }
                context.strokePath()
            }

            // Highlight the exact centre pixel being sampled.
            let cx = CGFloat(sampleImage.width / 2)
            let cy = CGFloat(sampleImage.height / 2)
            let pixelRect = CGRect(
                x: loupeRect.minX + cx * cell,
                y: loupeRect.maxY - (cy + 1) * cell,
                width: cell,
                height: cell
            )
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(2)
            context.stroke(pixelRect.insetBy(dx: -0.5, dy: -0.5))
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.stroke(pixelRect.insetBy(dx: 0.5, dy: 0.5))
        }
        context.restoreGState()

        // Loupe ring.
        context.addPath(circle)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(3)
        context.strokePath()

        drawColorPanel(at: CGRect(
            x: originX + (groupWidth - panelWidth) / 2,
            y: originY,
            width: panelWidth,
            height: panelHeight
        ))
    }

    private func drawColorPanel(at rect: CGRect) {
        let panel = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.82).setFill()
        panel.fill()

        let swatchSize: CGFloat = 40
        let swatchRect = CGRect(
            x: rect.minX + 12,
            y: rect.midY - swatchSize / 2,
            width: swatchSize,
            height: swatchSize
        )
        if let color = sampledColor {
            color.swatch.setFill()
        } else {
            NSColor.darkGray.setFill()
        }
        let swatchPath = NSBezierPath(roundedRect: swatchRect, xRadius: 5, yRadius: 5)
        swatchPath.fill()
        NSColor.white.withAlphaComponent(0.6).setStroke()
        swatchPath.lineWidth = 1
        swatchPath.stroke()

        let lines: [String]
        if let color = sampledColor {
            lines = ["HEX \(color.hex)", "RGB \(color.r),\(color.g),\(color.b)", "HSL " + color.hsl.dropFirst(4).dropLast()]
        } else {
            lines = ["HEX —", "RGB —", "HSL —"]
        }

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let lineHeight: CGFloat = 18
        let textX = swatchRect.maxX + 10
        let totalTextHeight = lineHeight * CGFloat(lines.count)
        var y = rect.midY + totalTextHeight / 2 - lineHeight + 3
        for line in lines {
            NSAttributedString(string: line, attributes: attributes)
                .draw(at: CGPoint(x: textX, y: y))
            y -= lineHeight
        }
    }

    // MARK: Ruler

    private func drawRuler() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard let anchor, let current else { return }

        // Connecting measurement line.
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(1.5)
        context.move(to: anchor)
        context.addLine(to: current)
        context.strokePath()

        // Endpoint markers.
        for point in [anchor, current] {
            let dot = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
            context.setFillColor(NSColor.systemRed.cgColor)
            context.fillEllipse(in: dot)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: dot)
        }

        guard let rect = rulerRect else { return }
        let scale = backingScale
        let dxPx = Int((rect.width * scale).rounded())
        let dyPx = Int((rect.height * scale).rounded())
        let hypPx = Int((hypot(rect.width, rect.height) * scale).rounded())
        let text = "Δx \(dxPx) · Δy \(dyPx) · \(hypPx) px"

        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let padding: CGFloat = 6
        let boxSize = CGSize(width: textSize.width + padding * 2, height: textSize.height + padding)

        var origin = CGPoint(x: current.x + 12, y: current.y + 12)
        origin.x = max(0, min(origin.x, bounds.width - boxSize.width))
        origin.y = max(0, min(origin.y, bounds.height - boxSize.height))
        let boxRect = CGRect(origin: origin, size: boxSize)

        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: boxRect, xRadius: 4, yRadius: 4).fill()
        attributed.draw(at: CGPoint(
            x: boxRect.minX + padding,
            y: boxRect.minY + (boxRect.height - textSize.height) / 2
        ))
    }

    // MARK: Mouse events

    override func mouseEntered(with event: NSEvent) {
        if mode == .colorPicker {
            handleColorMove(event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode == .colorPicker else { return }
        handleColorMove(event)
    }

    private func handleColorMove(_ event: NSEvent) {
        guard let window, let screen = window.screen else { return }
        let local = convert(event.locationInWindow, from: nil)
        let global = NSEvent.mouseLocation
        updateSample(globalPoint: global, localPoint: local, screen: screen)
    }

    override func mouseDown(with event: NSEvent) {
        switch mode {
        case .colorPicker:
            handleColorMove(event)
        case .ruler:
            let point = convert(event.locationInWindow, from: nil)
            anchor = point
            current = point
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        switch mode {
        case .colorPicker:
            handleColorMove(event)
        case .ruler:
            current = convert(event.locationInWindow, from: nil)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .colorPicker:
            handleColorMove(event)
            guard let color = sampledColor else {
                owner?.finish(with: nil)
                return
            }
            let pasteboard = [color.hex, color.rgb, color.hsl].joined(separator: "\n")
            owner?.finish(copying: pasteboard, reporting: color.hex)

        case .ruler:
            current = convert(event.locationInWindow, from: nil)
            guard let rect = rulerRect, rect.width >= 1 || rect.height >= 1 else {
                owner?.finish(with: nil)
                return
            }
            let scale = backingScale
            let w = Int((rect.width * scale).rounded())
            let h = Int((rect.height * scale).rounded())
            let hyp = Int((hypot(rect.width, rect.height) * scale).rounded())
            let summary = "\(w)×\(h) px (\(hyp) px)"
            owner?.finish(copying: summary, reporting: summary)
        }
    }

    // MARK: Keyboard events

    override func keyDown(with event: NSEvent) {
        // Esc (key code 53) cancels the entire interaction.
        if event.keyCode == 53 {
            owner?.finish(with: nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        owner?.finish(with: nil)
    }
}
