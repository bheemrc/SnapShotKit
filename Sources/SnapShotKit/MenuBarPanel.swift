import SwiftUI
import AppKit

/// The dropdown panel shown from the menu-bar icon. Because it is hosted in an
/// `NSPopover` anchored to the status item, it floats over the current Space —
/// including other apps running in full screen — so captures and quick actions
/// work without switching back to the desktop.
@MainActor
struct MenuBarPanel: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var recorder = RecordingEngine.shared

    /// Closes the popover. Called before full-screen-style captures so the panel
    /// isn't part of the shot.
    var dismiss: () -> Void = {}
    /// Opens the main editor window (on the active Space).
    var openEditor: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            captureBar

            Divider()

            if appState.captures.isEmpty {
                emptyState
            } else {
                recents
                Divider()
                quickActions
            }

            if let status = appState.statusMessage, !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 380)
    }

    // MARK: - Capture toolbar

    private var captureBar: some View {
        HStack(spacing: 6) {
            toolButton("Full", "camera.viewfinder") {
                runHidden { await appState.capture() }
            }
            toolButton("Region", "rectangle.dashed") {
                dismiss(); Task { await appState.captureRegion() }
            }
            toolButton("Scroll", "arrow.up.and.down") {
                dismiss(); Task { await appState.captureScrolling() }
            }
            toolButton("Delay", "timer") {
                runHidden { await appState.capture(afterDelay: 3) }
            }
            Button {
                Task { await appState.toggleRecording() }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(recorder.isRecording ? Color.red : Color.primary)
                    Text(recorder.isRecording ? "Stop" : "Record")
                        .font(.system(size: 9))
                }
                .frame(width: 60, height: 46)
            }
            .buttonStyle(.bordered)
            .help("Start or stop screen recording (⌘⇧6)")
        }
    }

    private func toolButton(_ title: String,
                            _ symbol: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 16))
                Text(title).font(.system(size: 9))
            }
            .frame(width: 60, height: 46)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Recents

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("No captures yet")
                .font(.callout)
            Text("Use the buttons above — they work over full-screen apps too.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var recents: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(appState.captures.reversed())) { item in
                    Button {
                        appState.selectedID = item.id
                        openEditor()
                    } label: {
                        Image(nsImage: item.image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 100, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(item.id == appState.selectedID
                                            ? Color.accentColor : Color.gray.opacity(0.3),
                                            lineWidth: item.id == appState.selectedID ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 70)
    }

    // MARK: - Quick actions on the selected capture

    private var quickActions: some View {
        let hasSelection = appState.selectedID != nil
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                actionButton("Copy", "doc.on.doc") { appState.copySelectedToClipboard() }
                actionButton("Save", "square.and.arrow.down") { appState.saveSelectedPNG() }
                actionButton("OCR", "text.viewfinder") { Task { await appState.copyTextFromSelected() } }
                actionButton("Pin", "pin") { appState.pinSelected() }
                actionButton("Redact", "eye.slash") { Task { await appState.autoRedactSelected() } }
            }
            .disabled(!hasSelection)

            HStack(spacing: 6) {
                Button("Export PDF…") { appState.exportPDF() }
                Button("Export PPTX…") { appState.exportPPTX() }
            }
            .controlSize(.small)
            .disabled(appState.captures.isEmpty)
        }
    }

    private func actionButton(_ title: String,
                              _ symbol: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 13))
                Text(title).font(.system(size: 9))
            }
            .frame(width: 60, height: 38)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Open Editor", action: openEditor)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }

    // MARK: - Helpers

    /// Closes the panel, waits briefly so it is off-screen, then runs an action.
    /// Used for full-screen captures that would otherwise include the panel.
    private func runHidden(_ operation: @escaping () async -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Task { await operation() }
        }
    }
}
