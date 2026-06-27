import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct SnapShotKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(AppState.shared)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shared application state, also injected into the SwiftUI scene.
    let appState = AppState.shared

    private var statusItem: NSStatusItem?
    private let hotkeyManager = HotkeyManager()

    /// The full action menu, shown on right-click (or control-click) of the icon.
    private var statusMenu: NSMenu?

    /// Submenu of capturable windows, rebuilt on demand via `NSMenuDelegate`.
    private let windowMenu = NSMenu(title: "Capture Window")

    /// The recording toggle item, whose title flips between Record and Stop.
    private var recordItem: NSMenuItem!

    /// Identifiers used to route global hotkeys back to their handlers.
    private enum Hotkey {
        static let fullScreen: UInt32 = 1
        static let region: UInt32 = 2
        static let record: UInt32 = 3
        static let panel: UInt32 = 4
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupStatusItem()
        registerHotkeys()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregisterAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Menu-bar status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder",
                                accessibilityDescription: "SnapShotKit")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "SnapShotKit — click for the capture panel, right-click for the full menu"
            button.action = #selector(statusButtonClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()

        let fullScreenItem = NSMenuItem(title: "Capture Full Screen",
                                        action: #selector(captureFullScreenAction(_:)),
                                        keyEquivalent: "\\")
        fullScreenItem.keyEquivalentModifierMask = [.command, .shift]
        fullScreenItem.target = self
        menu.addItem(fullScreenItem)

        let regionItem = NSMenuItem(title: "Capture Region",
                                    action: #selector(captureRegionAction(_:)),
                                    keyEquivalent: "2")
        regionItem.keyEquivalentModifierMask = [.command, .shift]
        regionItem.target = self
        menu.addItem(regionItem)

        let windowItem = NSMenuItem(title: "Capture Window", action: nil, keyEquivalent: "")
        windowMenu.delegate = self
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)

        let scrollingItem = NSMenuItem(title: "Scrolling Capture",
                                       action: #selector(captureScrollingAction(_:)),
                                       keyEquivalent: "7")
        scrollingItem.keyEquivalentModifierMask = [.command, .shift]
        scrollingItem.target = self
        menu.addItem(scrollingItem)

        let delayItem = NSMenuItem(title: "Capture After Delay (3s)",
                                   action: #selector(captureAfterDelayAction(_:)),
                                   keyEquivalent: "")
        delayItem.target = self
        menu.addItem(delayItem)

        menu.addItem(.separator())

        // Recording toggle; its title updates each time the menu opens.
        recordItem = NSMenuItem(title: "Record Screen",
                                action: #selector(toggleRecordingAction(_:)),
                                keyEquivalent: "6")
        recordItem.keyEquivalentModifierMask = [.command, .shift]
        recordItem.target = self
        menu.delegate = self
        menu.addItem(recordItem)

        menu.addItem(.separator())

        let copyItem = NSMenuItem(title: "Copy to Clipboard",
                                  action: #selector(copyClipboardAction(_:)),
                                  keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let savePNGItem = NSMenuItem(title: "Save PNG…",
                                     action: #selector(savePNGAction(_:)),
                                     keyEquivalent: "")
        savePNGItem.target = self
        menu.addItem(savePNGItem)

        let copyTextItem = NSMenuItem(title: "Copy Text (OCR)",
                                      action: #selector(copyTextAction(_:)),
                                      keyEquivalent: "")
        copyTextItem.target = self
        menu.addItem(copyTextItem)

        let pinItem = NSMenuItem(title: "Pin to Screen",
                                 action: #selector(pinAction(_:)),
                                 keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)

        menu.addItem(.separator())

        let redactItem = NSMenuItem(title: "Auto-Redact PII",
                                    action: #selector(autoRedactAction(_:)),
                                    keyEquivalent: "r")
        redactItem.keyEquivalentModifierMask = [.command, .shift]
        redactItem.target = self
        menu.addItem(redactItem)

        let loupeItem = NSMenuItem(title: "Color Loupe",
                                   action: #selector(colorLoupeAction(_:)),
                                   keyEquivalent: "l")
        loupeItem.keyEquivalentModifierMask = [.command, .shift]
        loupeItem.target = self
        menu.addItem(loupeItem)

        menu.addItem(.separator())

        let exportItem = NSMenuItem(title: "Export PDF…",
                                    action: #selector(exportAction(_:)),
                                    keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        exportItem.target = self
        menu.addItem(exportItem)

        let exportPPTXItem = NSMenuItem(title: "Export PowerPoint…",
                                        action: #selector(exportPPTXAction(_:)),
                                        keyEquivalent: "e")
        exportPPTXItem.keyEquivalentModifierMask = [.command, .shift, .option]
        exportPPTXItem.target = self
        menu.addItem(exportPPTXItem)

        menu.addItem(.separator())

        let showItem = NSMenuItem(title: "Show Window",
                                  action: #selector(showWindowAction(_:)),
                                  keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SnapShotKit",
                                  action: #selector(quitAction(_:)),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Store the menu for right-click; left-click opens the popover panel
        // instead, so we do NOT assign it as the status item's permanent menu.
        statusMenu = menu
        statusItem = item
    }

    // MARK: - Status-item click handling

    @objc private func statusButtonClicked(_ sender: Any?) {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showStatusMenu()
        } else {
            toggleMenuBarPopover()
        }
    }

    private func showStatusMenu() {
        guard let button = statusItem?.button, let menu = statusMenu else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    private func toggleMenuBarPopover() {
        CapturePanelController.shared.toggle(anchorTo: statusItem?.button) { [weak self] in
            self?.showWindowAction(nil)
        }
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        // ⌘⇧\ — full-screen capture.
        hotkeyManager.registerHotkey(id: Hotkey.fullScreen,
                                     keyCode: UInt32(kVK_ANSI_Backslash),
                                     modifiers: UInt32(cmdKey | shiftKey)) {
            Task { @MainActor in
                await AppState.shared.capture()
            }
        }

        // ⌘⇧2 — region capture. (⌘⇧3/4/5 are reserved by macOS.)
        hotkeyManager.registerHotkey(id: Hotkey.region,
                                     keyCode: UInt32(kVK_ANSI_2),
                                     modifiers: UInt32(cmdKey | shiftKey)) {
            Task { @MainActor in
                await AppState.shared.captureRegion()
            }
        }

        // ⌘⇧6 — toggle screen recording.
        hotkeyManager.registerHotkey(id: Hotkey.record,
                                     keyCode: UInt32(kVK_ANSI_6),
                                     modifiers: UInt32(cmdKey | shiftKey)) {
            Task { @MainActor in
                await AppState.shared.toggleRecording()
            }
        }

        // ⌘⇧Space — summon the floating capture panel from anywhere, including
        // over full-screen apps (no need to find the menu-bar icon).
        hotkeyManager.registerHotkey(id: Hotkey.panel,
                                     keyCode: UInt32(kVK_Space),
                                     modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.toggleMenuBarPopover()
        }
    }

    // MARK: - Actions

    @objc private func captureFullScreenAction(_ sender: Any?) {
        Task { @MainActor in await appState.capture() }
    }

    @objc private func captureRegionAction(_ sender: Any?) {
        Task { @MainActor in await appState.captureRegion() }
    }

    @objc private func captureAfterDelayAction(_ sender: Any?) {
        Task { @MainActor in await appState.capture(afterDelay: 3) }
    }

    @objc private func captureScrollingAction(_ sender: Any?) {
        Task { @MainActor in await appState.captureScrolling() }
    }

    @objc private func toggleRecordingAction(_ sender: Any?) {
        Task { @MainActor in await appState.toggleRecording() }
    }

    @objc private func autoRedactAction(_ sender: Any?) {
        Task { @MainActor in await appState.autoRedactSelected() }
    }

    @objc private func colorLoupeAction(_ sender: Any?) {
        appState.pickColorLoupe()
    }

    @objc private func exportPPTXAction(_ sender: Any?) {
        appState.exportPPTX()
    }

    @objc private func captureWindowAction(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        let windowID = CGWindowID(number.uint32Value)
        Task { @MainActor in await appState.captureWindow(id: windowID) }
    }

    @objc private func copyClipboardAction(_ sender: Any?) {
        appState.copySelectedToClipboard()
    }

    @objc private func savePNGAction(_ sender: Any?) {
        appState.saveSelectedPNG()
    }

    @objc private func copyTextAction(_ sender: Any?) {
        Task { @MainActor in await appState.copyTextFromSelected() }
    }

    @objc private func pinAction(_ sender: Any?) {
        appState.pinSelected()
    }

    @objc private func exportAction(_ sender: Any?) {
        appState.exportPDF()
    }

    @objc private func showWindowAction(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quitAction(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

// MARK: - Window submenu population

extension AppDelegate: NSMenuDelegate {
    /// Rebuilds the "Capture Window" submenu each time it opens. The window list
    /// is fetched asynchronously, so a placeholder is shown first and replaced in
    /// place once the results arrive (the menu stays open during the update).
    func menuNeedsUpdate(_ menu: NSMenu) {
        // The top-level status menu only needs its recording toggle refreshed.
        guard menu === windowMenu else {
            recordItem?.title = appState.isRecording ? "Stop Recording" : "Record Screen"
            return
        }

        menu.removeAllItems()
        let loading = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        loading.isEnabled = false
        menu.addItem(loading)

        Task { @MainActor in
            let windows = await appState.availableWindows()
            menu.removeAllItems()

            guard !windows.isEmpty else {
                let empty = NSMenuItem(title: "No Windows Available", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
                return
            }

            for window in windows {
                let title = window.title.isEmpty
                    ? window.appName
                    : "\(window.appName) — \(window.title)"
                let menuItem = NSMenuItem(title: title,
                                          action: #selector(self.captureWindowAction(_:)),
                                          keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = NSNumber(value: window.id)
                menu.addItem(menuItem)
            }
        }
    }
}
