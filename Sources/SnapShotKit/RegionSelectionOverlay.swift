import AppKit

/// Presents a full-screen, dimmed overlay that lets the user drag out a rectangular
/// region of the screen, then reports the selection back in global screen coordinates.
///
/// Coordinate note: the rectangle handed to `completion` is in AppKit *global screen*
/// coordinates — bottom-left origin, y-up, measured in points (not pixels). This matches
/// what `CGWindowListCreateImage` / display-bounds APIs expect for a sub-region capture.
///
/// The overlay keeps itself alive via a static strong reference for the duration of the
/// interaction; without it the window (and its delegate machinery) could be deallocated
/// mid-drag once `present` returns.
@MainActor
final class RegionSelectionOverlay {

    // MARK: - Active-instance retention

    /// Holds the in-flight overlay so it isn't deallocated while the user is dragging.
    /// Cleared the moment the selection finishes (success or cancel).
    private static var active: RegionSelectionOverlay?

    // MARK: - State

    /// One borderless window per screen so every display is dimmed and interactive.
    private var windows: [NSWindow] = []

    /// Invoked exactly once with the selected rect (global, bottom-left origin) or `nil`.
    private var completion: ((CGRect?) -> Void)?

    /// Guards against the completion handler firing more than once (e.g. Esc landing on
    /// one window while a mouse-up arrives from another).
    private var didFinish = false

    private init() {}

    // MARK: - Public API

    /// Shows the selection overlay across all screens. `completion` is called on the main
    /// thread with the chosen region in global screen points, or `nil` if the user pressed
    /// Esc or made a zero-size selection. The overlay windows are removed *before*
    /// `completion` runs, so a subsequent screen capture never includes the overlay itself.
    static func present(completion: @escaping (CGRect?) -> Void) {
        // If an overlay is somehow already up, tear it down first.
        active?.finish(with: nil)

        let overlay = RegionSelectionOverlay()
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
            // A non-activating panel can become key (to receive Esc/mouse) WITHOUT
            // activating the app. Activating would pull a full-screen Space back to
            // the app's own desktop Space — exactly the jump we must avoid.
            let window = OverlayPanel(
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
            // Position in global coordinates so per-view points map back to screen points.
            window.setFrame(screen.frame, display: false)

            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.owner = self
            window.contentView = view

            windows.append(window)
            window.orderFrontRegardless()
        }

        // Make the first overlay key so it receives keyboard (Esc) and mouse events,
        // without activating the app (which would switch away from a full-screen Space).
        windows.first?.makeKey()

        // A crosshair cursor reinforces the "draw a region" affordance.
        NSCursor.crosshair.push()
    }

    // MARK: - Completion plumbing

    /// Converts a selection rect expressed in a window's local view coordinates into global
    /// screen coordinates, then finishes the interaction.
    fileprivate func finishWithLocalRect(_ localRect: CGRect, in window: NSWindow) {
        // Reject degenerate selections.
        guard localRect.width >= 1, localRect.height >= 1 else {
            finish(with: nil)
            return
        }
        // View origin == window content origin (borderless, no title bar), so the local
        // rect maps to window coordinates directly, then to global screen coordinates.
        let globalRect = window.convertToScreen(localRect)
        finish(with: globalRect.standardized)
    }

    /// Tears down every overlay window, then invokes the completion handler exactly once.
    /// Ordering matters: windows must be gone before `completion` runs so the caller can
    /// immediately capture the screen without the overlay being visible.
    fileprivate func finish(with rect: CGRect?) {
        guard !didFinish else { return }
        didFinish = true

        NSCursor.pop()

        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()

        let handler = completion
        completion = nil

        // Release the static retention before calling back, in case the handler presents
        // another overlay synchronously.
        if RegionSelectionOverlay.active === self {
            RegionSelectionOverlay.active = nil
        }

        handler?(rect)
    }
}

// MARK: - Overlay window

/// A borderless, non-activating panel that can still become key, so the overlay
/// receives keyboard (Esc) and mouse events without activating the app — which
/// would yank a full-screen Space back to the app's own desktop Space.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Drawing & mouse handling

/// The content view for each overlay window. Draws the dimmed backdrop, the live selection
/// rectangle (clear interior, bright border), and the "W × H px" dimension label, and
/// translates mouse/keyboard input into a final selection.
private final class SelectionView: NSView {

    /// Back-reference to the coordinator that owns the windows and completion handler.
    weak var owner: RegionSelectionOverlay?

    /// Drag anchor and current point, in this view's local coordinates (y-up).
    private var anchor: CGPoint?
    private var current: CGPoint?

    /// The pixels-per-point scale of the screen this view lives on, used to report the
    /// selection size in physical pixels in the dimension label.
    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? (window?.screen?.backingScaleFactor ?? 1)
    }

    // MARK: NSView configuration

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    // The borderless window must be allowed to become key to receive keyboard events.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    /// The current selection rectangle in local view coordinates, or `nil` if nothing
    /// has been dragged yet.
    private var selectionRect: CGRect? {
        guard let anchor, let current else { return nil }
        return CGRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        )
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 1. Dim the whole backdrop.
        context.setFillColor(NSColor.black.withAlphaComponent(0.30).cgColor)
        context.fill(bounds)

        guard let rect = selectionRect, rect.width >= 1, rect.height >= 1 else { return }

        // 2. Punch a clear hole where the selection is, so the user sees the real content.
        context.setBlendMode(.clear)
        context.fill(rect)
        context.setBlendMode(.normal)

        // 3. Bright 1px border around the selection.
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.0)
        // Inset by half a point so the 1px stroke sits crisply on the pixel grid.
        context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))

        // 4. Live "W × H px" dimension label near the cursor.
        drawDimensionLabel(for: rect)
    }

    private func drawDimensionLabel(for rect: CGRect) {
        let scale = backingScale
        let pxWidth = Int((rect.width * scale).rounded())
        let pxHeight = Int((rect.height * scale).rounded())
        let text = "\(pxWidth) × \(pxHeight) px"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()

        let padding: CGFloat = 6
        let gap: CGFloat = 8
        let boxSize = CGSize(width: textSize.width + padding * 2,
                             height: textSize.height + padding)

        // Prefer placing the label just below the selection's bottom-left; flip above if
        // there isn't room near the bottom edge of the screen.
        var origin = CGPoint(x: rect.minX, y: rect.minY - gap - boxSize.height)
        if origin.y < 0 {
            origin.y = rect.maxY + gap
        }
        origin.x = max(0, min(origin.x, bounds.width - boxSize.width))
        origin.y = max(0, min(origin.y, bounds.height - boxSize.height))

        let boxRect = CGRect(origin: origin, size: boxSize)

        let path = NSBezierPath(roundedRect: boxRect, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        path.fill()

        let textOrigin = CGPoint(
            x: boxRect.minX + padding,
            y: boxRect.minY + (boxRect.height - textSize.height) / 2
        )
        attributed.draw(at: textOrigin)
    }

    // MARK: Mouse events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        anchor = point
        current = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true

        guard let rect = selectionRect, let window else {
            owner?.finish(with: nil)
            return
        }
        owner?.finishWithLocalRect(rect, in: window)
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
