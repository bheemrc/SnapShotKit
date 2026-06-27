import SwiftUI
import AppKit

/// Presents the capture panel as a borderless floating window.
///
/// Unlike a window tied to the app's own Space, this panel uses
/// `.canJoinAllSpaces` + `.fullScreenAuxiliary` collection behavior and a high
/// window level, so it appears over whatever is on screen — including another
/// app running in full screen — and it can be summoned by a global hotkey
/// without needing the (often hidden) menu-bar icon.
@MainActor
final class CapturePanelController {
    static let shared = CapturePanelController()

    private var panel: NSPanel?
    private var clickMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Toggles the panel. `anchor` (the status-item button) positions it under
    /// the menu-bar icon when available; otherwise it appears at the top-right of
    /// the active screen. `openEditor` is invoked when the user opens the editor.
    func toggle(anchorTo anchor: NSView?, openEditor: @escaping () -> Void) {
        if isVisible {
            close()
        } else {
            show(anchorTo: anchor, openEditor: openEditor)
        }
    }

    func close() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    private func show(anchorTo anchor: NSView?, openEditor: @escaping () -> Void) {
        let root = MenuBarPanel(
            dismiss: { [weak self] in self?.close() },
            openEditor: { [weak self] in
                self?.close()
                openEditor()
            }
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1)
        )
        .padding(10)

        let hosting = NSHostingView(rootView: root)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(contentRect: hosting.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = hosting

        position(panel, anchorTo: anchor, size: size)
        panel.orderFrontRegardless()
        self.panel = panel

        // Dismiss when the user clicks anywhere outside the panel.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.close()
        }
    }

    private func position(_ panel: NSPanel, anchorTo anchor: NSView?, size: NSSize) {
        let margin: CGFloat = 8
        if let anchor, let window = anchor.window {
            let inWindow = anchor.convert(anchor.bounds, to: nil)
            let onScreen = window.convertToScreen(inWindow)
            panel.setFrameOrigin(NSPoint(x: onScreen.maxX - size.width,
                                         y: onScreen.minY - size.height - 4))
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - margin,
                                         y: frame.maxY - size.height - margin))
        }
    }
}
