import SwiftUI

/// The main application window.
///
/// Layout:
///   - A top toolbar with "Capture (⌘⇧\)" and "Export PDF" actions.
///   - A `NavigationSplitView` whose sidebar lists capture thumbnails and whose
///     detail shows the `AnnotationCanvas` bound to the selected capture.
///   - An empty state with instructions shown when there are no captures yet.
struct ContentView: View {
    @EnvironmentObject var appState: AppState

    /// Observed directly so the Record control reflects live recording state.
    @ObservedObject private var recorder = RecordingEngine.shared

    /// Capturable windows, refreshed when the Capture menu's Window submenu opens.
    @State private var windows: [CaptureEngine.WindowInfo] = []

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        .frame(minWidth: 900, minHeight: 600)
        .overlay(alignment: .bottom) { statusBanner }
        .animation(.easeInOut(duration: 0.2), value: appState.statusMessage)
    }

    /// Whether a capture is currently selected and available for the per-capture
    /// actions (copy, save, OCR, pin).
    private var hasSelection: Bool {
        appState.selectedID != nil && !appState.captures.isEmpty
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            captureMenu

            recordControl

            Button(action: appState.copySelectedToClipboard) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!hasSelection)
            .help("Copy the selected capture to the clipboard")

            Button(action: appState.saveSelectedPNG) {
                Label("Save PNG", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!hasSelection)
            .help("Save the selected capture as a PNG")

            Button(action: runCopyText) {
                Label("Copy Text", systemImage: "text.viewfinder")
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!hasSelection)
            .help("Recognize and copy text from the selected capture")

            Button(action: appState.pinSelected) {
                Label("Pin", systemImage: "pin")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!hasSelection)
            .help("Pin the selected capture to a floating window")

            toolsMenu

            Picker(selection: $appState.backgroundStyle) {
                ForEach(BackgroundStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            } label: {
                Label("Background", systemImage: "rectangle.portrait.on.rectangle.portrait")
            }
            .pickerStyle(.menu)
            .help("Backdrop applied to copied, saved, and pinned images")

            exportMenu
        }
    }

    // MARK: - Record control

    private var recordControl: some View {
        Menu {
            if recorder.isRecording {
                Button {
                    Task { await appState.stopRecordingAndSaveMP4() }
                } label: {
                    Label("Stop & Save MP4", systemImage: "stop.circle")
                }

                Button {
                    Task { await appState.stopRecordingAndExportGIF() }
                } label: {
                    Label("Stop & Export GIF", systemImage: "stop.circle")
                }
            } else {
                Button {
                    Task { await appState.startRecording(region: nil) }
                } label: {
                    Label("Record Full Screen", systemImage: "record.circle")
                }
                .keyboardShortcut("6", modifiers: [.command, .shift])
            }
        } label: {
            Label("Record", systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                .foregroundStyle(recorder.isRecording ? Color.red : Color.primary)
        }
        .menuStyle(.button)
        .tint(recorder.isRecording ? .red : nil)
        .help(recorder.isRecording ? "Stop the screen recording" : "Record the screen to MP4 or GIF")
    }

    // MARK: - Tools menu

    private var toolsMenu: some View {
        Menu {
            Button {
                Task { await appState.autoRedactSelected() }
            } label: {
                Label("Auto-Redact PII", systemImage: "eye.slash")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!hasSelection)

            Button {
                Task { await appState.scanBarcodesInSelected() }
            } label: {
                Label("Scan QR / Barcode", systemImage: "qrcode.viewfinder")
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(!hasSelection)

            Divider()

            Button(action: appState.pickColorLoupe) {
                Label("Color Loupe", systemImage: "eyedropper")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button(action: appState.measureRuler) {
                Label("Measure (Ruler)", systemImage: "ruler")
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        } label: {
            Label("Tools", systemImage: "wrench.and.screwdriver")
        }
        .menuStyle(.button)
        .help("Redact PII, scan codes, pick a color, or measure on screen")
    }

    // MARK: - Export menu

    private var exportMenu: some View {
        Menu {
            Button(action: appState.exportPDF) {
                Label("Export PDF…", systemImage: "doc.richtext")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Button(action: appState.exportPPTX) {
                Label("Export PowerPoint…", systemImage: "rectangle.on.rectangle")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift, .option])
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .disabled(appState.captures.isEmpty)
        .help("Export all captures as a PDF or PowerPoint deck")
    }

    private var captureMenu: some View {
        Menu {
            Button {
                runCaptureFullScreen()
            } label: {
                Label("Full Screen", systemImage: "camera.viewfinder")
            }
            .keyboardShortcut("\\", modifiers: [.command, .shift])

            Button {
                Task { await appState.captureRegion() }
            } label: {
                Label("Region…", systemImage: "selection.pin.in.out")
            }
            .keyboardShortcut("2", modifiers: [.command, .shift])

            Button {
                Task { await appState.captureScrolling() }
            } label: {
                Label("Scrolling…", systemImage: "scroll")
            }
            .keyboardShortcut("7", modifiers: [.command, .shift])

            Menu {
                if windows.isEmpty {
                    Text("No windows available")
                } else {
                    ForEach(windows) { window in
                        Button(windowLabel(window)) {
                            Task { await appState.captureWindow(id: window.id) }
                        }
                    }
                }
            } label: {
                Label("Window", systemImage: "macwindow")
            }
            .onAppear(perform: loadWindows)

            Button {
                Task { await appState.capture(afterDelay: 3) }
            } label: {
                Label("After 3s", systemImage: "timer")
            }

            Divider()

            Toggle(isOn: $appState.hideDesktopBeforeCapture) {
                Label("Hide Desktop Icons", systemImage: "menubar.dock.rectangle")
            }
            .help("Temporarily hide Desktop icons during full-screen and region captures")
        } label: {
            Label("Capture", systemImage: "camera.viewfinder")
        }
        .menuStyle(.button)
        .disabled(appState.isCapturing)
        .help("Capture the full screen, a region, a window, or after a delay")
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let message = appState.statusMessage {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        Group {
            if appState.captures.isEmpty {
                emptySidebar
            } else {
                List(selection: $appState.selectedID) {
                    ForEach(appState.captures) { item in
                        CaptureRow(item: item)
                            .tag(item.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 200)
    }

    private var emptySidebar: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No Captures")
                .font(.headline)
            Text("Use the Capture menu or ⌘⇧\\ (full screen) / ⌘⇧2 (region) to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail

    private var detail: some View {
        Group {
            if let binding = selectedCaptureBinding {
                AnnotationCanvas(item: binding)
                    .id(binding.wrappedValue.id)
            } else {
                emptyDetail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDetail: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("SnapShotKit")
                .font(.largeTitle.bold())
            VStack(spacing: 6) {
                instruction("1.", "Capture the full screen, a region, a window, or a tall scrolling area — or record the screen to MP4 or GIF.")
                instruction("2.", "Annotate with arrows, shapes, highlights, text, blur/redact, and numbered steps, or auto-redact PII in one click.")
                instruction("3.", "Pull out text with OCR, sample a color with the loupe, measure with the ruler, and scan QR/barcodes.")
                instruction("4.", "Copy, save as PNG, pin to a floating window, or export every capture to PDF or PowerPoint.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number).monospacedDigit().fontWeight(.semibold)
            Text(text)
        }
    }

    // MARK: - Helpers

    /// A two-way binding to the currently selected `CaptureItem`, so the
    /// `AnnotationCanvas` can mutate its annotations in place.
    private var selectedCaptureBinding: Binding<CaptureItem>? {
        guard let id = appState.selectedID,
              let index = appState.captures.firstIndex(where: { $0.id == id })
        else { return nil }

        return Binding(
            get: { appState.captures[index] },
            set: { appState.captures[index] = $0 }
        )
    }

    private func runCaptureFullScreen() {
        Task { await appState.capture() }
    }

    private func runCopyText() {
        Task { await appState.copyTextFromSelected() }
    }

    /// A concise label for a window menu entry: app name plus window title.
    private func windowLabel(_ window: CaptureEngine.WindowInfo) -> String {
        window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title)"
    }

    /// Refreshes the capturable-window list for the Capture ▸ Window submenu.
    private func loadWindows() {
        Task { windows = await appState.availableWindows() }
    }
}

/// A single sidebar row showing a capture thumbnail and its title.
private struct CaptureRow: View {
    let item: CaptureItem

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.quaternary, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                if !item.annotations.isEmpty {
                    Text("\(item.annotations.count) annotation\(item.annotations.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.shared)
}
