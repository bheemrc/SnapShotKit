import AppKit

/// Manages floating "pin to screen" panels that keep a captured image visible
/// above other windows. Each pinned image lives in its own borderless panel at
/// the floating window level, can be dragged anywhere by its background, and is
/// dismissed with the Escape key or its close button.
@MainActor
final class PinnedWindowController {
    static let shared = PinnedWindowController()

    /// Strong references to every open panel. Borderless `NSPanel`s are not
    /// retained by AppKit on their own, so we hold them here and release each
    /// one when it closes.
    private var panels: [PinnedPanel] = []

    /// Running offset used to cascade successive pins so they do not stack
    /// perfectly on top of one another.
    private var cascadeStep = 0

    private init() {}

    /// Pin `image` to the screen in a new floating panel.
    /// - Parameters:
    ///   - image: The image to display. Its pixel dimensions drive the aspect
    ///     ratio; the panel is capped to roughly 40% of the active screen.
    ///   - title: Accessibility title for the panel.
    func pin(_ image: NSImage, title: String) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let panelSize = initialSize(for: image, on: screen)
        let origin = cascadeOrigin(for: panelSize, on: screen)

        let panel = PinnedPanel(
            contentRect: NSRect(origin: origin, size: panelSize),
            image: image,
            title: title
        )
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.panels.removeAll { $0 === panel }
        }

        panels.append(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Close every open pinned panel.
    func closeAll() {
        // Closing mutates `panels` via each panel's `onClose`, so iterate a copy.
        for panel in panels {
            panel.close()
        }
        panels.removeAll()
        cascadeStep = 0
    }

    // MARK: - Geometry

    /// Compute an initial panel size that preserves the image aspect ratio and
    /// fits within ~40% of the target screen's visible frame.
    private func initialSize(for image: NSImage, on screen: NSScreen?) -> NSSize {
        let pixelSize = image.pixelSize
        let aspect: CGFloat
        if pixelSize.width > 0, pixelSize.height > 0 {
            aspect = pixelSize.width / pixelSize.height
        } else {
            aspect = 1
        }

        let visible = screen?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let maxWidth = max(160, visible.width * 0.40)
        let maxHeight = max(120, visible.height * 0.40)

        // Start from the natural pixel size, then shrink to fit the cap while
        // keeping the aspect ratio intact.
        var width = pixelSize.width > 0 ? pixelSize.width : maxWidth
        var height = pixelSize.height > 0 ? pixelSize.height : maxHeight

        if width > maxWidth {
            width = maxWidth
            height = width / aspect
        }
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }

        return NSSize(width: width.rounded(), height: height.rounded())
    }

    /// Cascade successive pins from the top-left region of the screen.
    private func cascadeOrigin(for size: NSSize, on screen: NSScreen?) -> NSPoint {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let offset = CGFloat(cascadeStep % 8) * 28

        var x = visible.minX + 60 + offset
        // AppKit origin is bottom-left; place the panel near the top of the screen.
        var y = visible.maxY - size.height - 60 - offset

        // Keep the panel fully on-screen even after several cascades.
        x = min(x, visible.maxX - size.width - 20)
        y = max(y, visible.minY + 20)

        cascadeStep += 1
        return NSPoint(x: x, y: y)
    }
}

// MARK: - PinnedPanel

/// A borderless, floating panel that displays a single image and provides a
/// close affordance. Movable by dragging its background.
private final class PinnedPanel: NSPanel {
    /// Invoked after the panel closes so the controller can drop its reference.
    var onClose: (() -> Void)?

    private var didClose = false

    init(contentRect: NSRect, image: NSImage, title: String) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.title = title
        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow

        let content = PinnedContentView(image: image)
        content.frame = NSRect(origin: .zero, size: contentRect.size)
        content.autoresizingMask = [.width, .height]
        content.closeAction = { [weak self] in
            self?.close()
        }
        contentView = content
    }

    /// Borderless panels normally cannot become key; allow it so the Escape key
    /// and dragging behave naturally.
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        // Escape key.
        close()
    }

    override func close() {
        guard !didClose else { return }
        didClose = true
        super.close()
        onClose?()
    }
}

// MARK: - PinnedContentView

/// Root content view for a pinned panel: a rounded image with a subtle shadow
/// and an always-visible close button in the top-left corner.
private final class PinnedContentView: NSView {
    var closeAction: (() -> Void)?

    private let imageView = NSImageView()
    private let closeButton = NSButton()

    private let cornerRadius: CGFloat = 10
    private let closeButtonSize: CGFloat = 18
    private let closeButtonInset: CGFloat = 8

    init(image: NSImage) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        configureImageView(image)
        configureCloseButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureImageView(_ image: NSImage) {
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = cornerRadius
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        addSubview(imageView)

        // Soft drop shadow on the view layer (the image layer is clipped).
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.45).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 16
        layer?.shadowOffset = NSSize(width: 0, height: -6)
    }

    private func configureCloseButton() {
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        closeButton.layer?.cornerRadius = closeButtonSize / 2
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .white
        if let symbol = NSImage(systemSymbolName: "xmark",
                                accessibilityDescription: "Close pinned image") {
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            closeButton.image = symbol.withSymbolConfiguration(config)
        } else {
            closeButton.title = "✕"
        }
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        closeButton.toolTip = "Close"
        addSubview(closeButton)
    }

    @objc private func handleClose() {
        closeAction?()
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        // Top-left corner (AppKit origin is bottom-left).
        closeButton.frame = NSRect(
            x: closeButtonInset,
            y: bounds.maxY - closeButtonSize - closeButtonInset,
            width: closeButtonSize,
            height: closeButtonSize
        )
    }

    /// Let drags on the image background move the window, while the close button
    /// still receives its own clicks.
    override var mouseDownCanMoveWindow: Bool { true }
}
