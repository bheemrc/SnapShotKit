import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The central, observable application store for SnapShotKit.
///
/// Owns the list of screen captures and the current selection, and provides the
/// two primary user actions: taking a screenshot and exporting the captures to a
/// PDF. All mutation happens on the main actor so SwiftUI views and AppKit calls
/// remain thread-safe under Swift 6 strict concurrency.
@MainActor
final class AppState: ObservableObject {

    /// Shared instance used by both `SnapShotKitApp` and `AppDelegate`.
    static let shared = AppState()

    /// All captures taken during this session, in capture order.
    @Published var captures: [CaptureItem] = []

    /// The currently selected capture, if any.
    @Published var selectedID: CaptureItem.ID?

    /// True while a capture is in flight (lets the UI disable the button, etc.).
    @Published var isCapturing: Bool = false

    /// Human-readable description of the most recent error, surfaced to the UI.
    @Published var lastErrorMessage: String?

    /// Decorative background applied when copying, saving, or pinning the
    /// selected capture. `.none` outputs the flattened screenshot unchanged.
    @Published var backgroundStyle: BackgroundStyle = .none

    /// Transient, non-error status note (e.g. "Copied text", "Saved to Desktop").
    /// Cleared automatically a few seconds after it is set.
    @Published var statusMessage: String?

    /// When true, the Desktop icons are temporarily hidden around full-screen and
    /// region captures so they do not clutter the resulting image.
    @Published var hideDesktopBeforeCapture: Bool = false

    /// Screen-recording engine, exposed so the UI can observe `isRecording` and
    /// offer Start/Stop controls. Owned as a shared singleton.
    let recorder = RecordingEngine.shared

    /// Mirrors `recorder.isRecording` for convenient UI binding.
    var isRecording: Bool { recorder.isRecording }

    /// Running counters used to title captures by mode.
    private var captureCount: Int = 0
    private var regionCount: Int = 0
    private var windowCount: Int = 0
    private var scrollingCount: Int = 0

    /// Pending task that clears `statusMessage` after a short delay.
    private var statusClearTask: Task<Void, Never>?

    init() {
        // Restore any captures persisted from a previous session.
        let restored = CapturePersistence.load()
        if !restored.isEmpty {
            captures = restored
            selectedID = restored.last?.id
        }
    }

    // MARK: - Capture

    /// Captures the full main display and appends the result as a new `CaptureItem`.
    ///
    /// Selects the new capture automatically. Any failure (e.g. missing Screen
    /// Recording permission) is reported via `lastErrorMessage` rather than thrown,
    /// since this is a top-level user action.
    func capture() async {
        guard !isCapturing else { return }
        isCapturing = true
        lastErrorMessage = nil
        defer { isCapturing = false }

        let hidDesktop = hideDesktopBeforeCapture
        if hidDesktop { DesktopCleanup.hideIcons() }
        defer { if hidDesktop { DesktopCleanup.restoreIcons() } }

        do {
            let image = try await CaptureEngine.captureFullScreen()
            captureCount += 1
            let item = CaptureItem(image: image, title: "Capture \(captureCount)")
            captures.append(item)
            selectedID = item.id
            persistRecents()
        } catch {
            lastErrorMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    /// Presents the region-selection overlay and, once the user commits a
    /// rectangle, captures it and appends the result as a new `CaptureItem`.
    /// A cancelled selection (escape / empty rect) is a no-op.
    func captureRegion() async {
        guard !isCapturing else { return }

        // The overlay drives its own event loop; await its committed rectangle
        // (global screen points, bottom-left origin) before starting capture.
        let rect: CGRect? = await withCheckedContinuation { continuation in
            RegionSelectionOverlay.present { selectedRect in
                continuation.resume(returning: selectedRect)
            }
        }
        guard let rect else { return }

        isCapturing = true
        lastErrorMessage = nil
        defer { isCapturing = false }

        let hidDesktop = hideDesktopBeforeCapture
        if hidDesktop { DesktopCleanup.hideIcons() }
        defer { if hidDesktop { DesktopCleanup.restoreIcons() } }

        do {
            let image = try await CaptureEngine.captureRegion(rect)
            regionCount += 1
            let item = CaptureItem(image: image, title: "Region \(regionCount)")
            captures.append(item)
            selectedID = item.id
            persistRecents()
        } catch {
            lastErrorMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    /// Captures the on-screen window identified by `id` and appends the result.
    func captureWindow(id: CGWindowID) async {
        guard !isCapturing else { return }
        isCapturing = true
        lastErrorMessage = nil
        defer { isCapturing = false }

        do {
            let image = try await CaptureEngine.captureWindow(windowID: id)
            windowCount += 1
            let item = CaptureItem(image: image, title: "Window \(windowCount)")
            captures.append(item)
            selectedID = item.id
        } catch {
            lastErrorMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    /// Lists the currently capturable on-screen windows. Returns an empty array
    /// (and records `lastErrorMessage`) if the list cannot be retrieved.
    func availableWindows() async -> [CaptureEngine.WindowInfo] {
        do {
            return try await CaptureEngine.listWindows()
        } catch {
            lastErrorMessage = error.localizedDescription
            return []
        }
    }

    /// Waits `seconds` before taking a full-screen capture, giving the user time
    /// to open menus or arrange windows that would otherwise dismiss on focus.
    func capture(afterDelay seconds: Double) async {
        let nanoseconds = UInt64((max(0, seconds) * 1_000_000_000).rounded())
        try? await Task.sleep(nanoseconds: nanoseconds)
        await capture()
    }

    // MARK: - Selected-capture actions

    /// Copies the selected capture (flattened, with the chosen background) to the
    /// general pasteboard.
    func copySelectedToClipboard() {
        guard let item = requireSelected() else { return }
        ExportService.copyToPasteboard(rendered(item, applyBackground: true))
        setStatus("Copied to clipboard")
    }

    /// Presents a save panel and writes the selected capture as a PNG.
    func saveSelectedPNG() {
        guard let item = requireSelected() else { return }
        ExportService.savePNG(rendered(item, applyBackground: true), suggestedName: item.title)
    }

    /// Writes the selected capture to the Desktop, reporting the saved file name.
    func quickSaveSelected() {
        guard let item = requireSelected() else { return }
        if let url = ExportService.quickSaveToDesktop(rendered(item, applyBackground: true),
                                                      name: item.title) {
            setStatus("Saved to Desktop: \(url.lastPathComponent)")
        } else {
            lastErrorMessage = "Could not save to the Desktop."
            NSSound.beep()
        }
    }

    /// Runs OCR on the selected capture and copies any recognized text to the
    /// pasteboard as a plain string. Background styling is intentionally skipped
    /// so recognition runs against the screenshot pixels only.
    func copyTextFromSelected() async {
        guard let item = requireSelected() else { return }
        let image = rendered(item, applyBackground: false)
        let text = await OCRService.recognizeText(in: image)

        guard !text.isEmpty else {
            setStatus("No text found")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        setStatus("Copied \(text.count) character\(text.count == 1 ? "" : "s") of text")
    }

    /// Opens a floating, always-on-top window showing the selected capture.
    func pinSelected() {
        guard let item = requireSelected() else { return }
        PinnedWindowController.shared.pin(rendered(item, applyBackground: true), title: item.title)
        setStatus("Pinned \(item.title)")
    }

    // MARK: - Export

    /// Presents an `NSSavePanel` and, on confirmation, writes all captures (with
    /// their annotations) to a single PDF via `PDFExporter`.
    func exportPDF() {
        guard !captures.isEmpty else {
            lastErrorMessage = "There is nothing to export yet. Capture a screen first."
            NSSound.beep()
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export PDF"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "SnapShotKit.pdf"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.pdf]

        // Bring the app/panel to the front; menu-bar apps may not be active.
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try PDFExporter.export(captures, to: url)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Failed to export PDF: \(error.localizedDescription)"
            NSSound.beep()
        }
    }

    // MARK: - Screen recording

    /// Starts a screen recording. Pass a region (global screen points, bottom-left
    /// origin) to record a sub-area, or `nil` to record the full main display.
    func startRecording(region: CGRect?) async {
        guard !recorder.isRecording else { return }
        lastErrorMessage = nil
        do {
            try await recorder.start(region: region)
            setStatus("Recording…")
        } catch {
            lastErrorMessage = "Could not start recording: \(error.localizedDescription)"
            NSSound.beep()
        }
    }

    /// Toggles recording: starts a full-screen recording when idle, otherwise
    /// stops and saves the current one as MP4. Used by the global hotkey.
    func toggleRecording() async {
        if recorder.isRecording {
            await stopRecordingAndSaveMP4()
        } else {
            await startRecording(region: nil)
        }
    }

    /// Stops the recording and reports the saved `.mp4` location.
    func stopRecordingAndSaveMP4() async {
        guard recorder.isRecording else { return }
        guard let url = await recorder.stop() else {
            lastErrorMessage = "Recording could not be saved."
            NSSound.beep()
            return
        }
        setStatus("Saved recording: \(url.lastPathComponent)")
    }

    /// Stops the recording and exports it as an animated GIF to a user-chosen file.
    func stopRecordingAndExportGIF() async {
        guard recorder.isRecording else { return }
        guard let movieURL = await recorder.stop() else {
            lastErrorMessage = "Recording could not be saved."
            NSSound.beep()
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export GIF"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "SnapShotKit.gif"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let gif = UTType(filenameExtension: "gif") {
            panel.allowedContentTypes = [gif]
        }
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let gifURL = panel.url else { return }

        setStatus("Exporting GIF…")
        let ok = await RecordingEngine.exportGIF(from: movieURL, to: gifURL)
        if ok {
            setStatus("Exported GIF: \(gifURL.lastPathComponent)")
        } else {
            lastErrorMessage = "Failed to export GIF."
            NSSound.beep()
        }
    }

    // MARK: - Scrolling capture

    /// Presents the region overlay and stitches a tall, scrolling capture of the
    /// chosen area into a single image.
    func captureScrolling() async {
        guard !isCapturing else { return }

        let rect: CGRect? = await withCheckedContinuation { continuation in
            RegionSelectionOverlay.present { selectedRect in
                continuation.resume(returning: selectedRect)
            }
        }
        guard let rect else { return }

        isCapturing = true
        lastErrorMessage = nil
        defer { isCapturing = false }

        do {
            let image = try await ScrollingCaptureEngine.capture(region: rect)
            scrollingCount += 1
            let item = CaptureItem(image: image, title: "Scrolling \(scrollingCount)")
            captures.append(item)
            selectedID = item.id
            persistRecents()
        } catch {
            lastErrorMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    // MARK: - Redaction / detection

    /// Detects likely sensitive regions (PII text, faces) in the selected capture
    /// and adds a blur annotation over each, ready for the user to keep or remove.
    func autoRedactSelected() async {
        guard let item = requireSelected() else { return }
        guard let index = captures.firstIndex(where: { $0.id == item.id }) else { return }

        setStatus("Scanning for sensitive content…")
        let rects = await RedactionService.detectSensitiveRegions(in: item.image)

        guard !rects.isEmpty else {
            setStatus("No sensitive content detected")
            return
        }

        for rect in rects {
            let annotation = Annotation(
                kind: .blur,
                start: rect.origin,
                end: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            captures[index].annotations.append(annotation)
        }
        persistRecents()
        setStatus("Redacted \(rects.count) region\(rects.count == 1 ? "" : "s")")
    }

    /// Detects QR codes and barcodes in the selected capture, copying any decoded
    /// payloads to the pasteboard.
    func scanBarcodesInSelected() async {
        guard let item = requireSelected() else { return }

        setStatus("Scanning for codes…")
        let payloads = await BarcodeService.detectBarcodes(in: item.image)

        guard !payloads.isEmpty else {
            setStatus("No codes found")
            return
        }

        let joined = payloads.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(joined, forType: .string)
        setStatus("Copied \(payloads.count) code\(payloads.count == 1 ? "" : "s")")
    }

    // MARK: - Measurement overlays

    /// Presents the full-screen color loupe; the picked color (hex) is copied.
    func pickColorLoupe() {
        PixelMeterOverlay.present(mode: .colorPicker) { [weak self] hex in
            guard let self, let hex else { return }
            self.setStatus("Copied color \(hex)")
        }
    }

    /// Presents the on-screen ruler; the measured distance string is copied.
    func measureRuler() {
        PixelMeterOverlay.present(mode: .ruler) { [weak self] result in
            guard let self, let result else { return }
            self.setStatus("Copied \(result)")
        }
    }

    // MARK: - PPTX export

    /// Presents an `NSSavePanel` and writes all captures to a PowerPoint (.pptx)
    /// deck, one slide per capture.
    func exportPPTX() {
        guard !captures.isEmpty else {
            lastErrorMessage = "There is nothing to export yet. Capture a screen first."
            NSSound.beep()
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export PowerPoint"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "SnapShotKit.pptx"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let pptx = UTType("org.openxmlformats.presentationml.presentation")
            ?? UTType(filenameExtension: "pptx") {
            panel.allowedContentTypes = [pptx]
        }
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try PPTXExporter.export(captures, to: url)
            setStatus("Exported \(captures.count) slide\(captures.count == 1 ? "" : "s")")
        } catch {
            lastErrorMessage = "Failed to export PPTX: \(error.localizedDescription)"
            NSSound.beep()
        }
    }

    // MARK: - Persistence

    /// Persists the current captures to disk so they can be restored next launch.
    /// Best-effort: failures are intentionally ignored to keep callers cheap.
    func persistRecents() {
        CapturePersistence.save(captures)
    }

    // MARK: - Convenience

    /// Two-way binding to the currently selected capture, suitable for passing to
    /// editing views such as `AnnotationCanvas`. Returns `nil` when nothing is
    /// selected or the selection no longer refers to an existing capture.
    var selectedBinding: Binding<CaptureItem>? {
        guard let id = selectedID,
              captures.contains(where: { $0.id == id }) else {
            return nil
        }
        return Binding(
            get: { [weak self] in
                guard let self,
                      let index = self.captures.firstIndex(where: { $0.id == id }) else {
                    return CaptureItem(image: NSImage(), title: "")
                }
                return self.captures[index]
            },
            set: { [weak self] newValue in
                guard let self,
                      let index = self.captures.firstIndex(where: { $0.id == id }) else { return }
                self.captures[index] = newValue
            }
        )
    }

    /// Removes the capture with the given id, updating the selection if needed.
    func remove(_ id: CaptureItem.ID) {
        captures.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = captures.last?.id
        }
        persistRecents()
    }

    // MARK: - Private helpers

    /// The currently selected capture, if the selection still resolves.
    private var selectedItem: CaptureItem? {
        guard let id = selectedID else { return nil }
        return captures.first { $0.id == id }
    }

    /// Returns the selected capture, or reports a gentle error and beeps when
    /// nothing is selected.
    private func requireSelected() -> CaptureItem? {
        guard let item = selectedItem else {
            lastErrorMessage = "Select a capture first."
            NSSound.beep()
            return nil
        }
        return item
    }

    /// Flattens `item` (base image plus annotations) and, when `applyBackground`
    /// is set and a background style is chosen, composites it onto that backdrop.
    /// `PDFExporter.flatten` is the single source of truth for annotation render.
    private func rendered(_ item: CaptureItem, applyBackground: Bool) -> NSImage {
        let flattened = PDFExporter.flatten(item)
        if applyBackground, backgroundStyle != .none {
            return BackgroundStyler.render(flattened, style: backgroundStyle)
        }
        return flattened
    }

    /// Sets a transient status message and schedules it to clear shortly after.
    private func setStatus(_ message: String) {
        statusMessage = message
        statusClearTask?.cancel()
        statusClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }
}
