import AppKit
import Foundation
import UniformTypeIdentifiers

/// Lightweight on-disk persistence for the "recents" strip.
///
/// Only the raw captured bitmap of each item is stored, written as a PNG into an
/// Application Support subdirectory so the most recent captures survive an app
/// relaunch. Annotations are intentionally NOT persisted in v1 — they remain
/// session-only — so a reloaded item comes back as a clean, un-annotated image.
///
/// Files are named `NN-title.png` with a zero-padded ordinal prefix so the
/// directory listing sorts back into the original order. Every operation is
/// defensive: unreadable or malformed entries are skipped and no failure is ever
/// allowed to crash the app.
@MainActor
enum CapturePersistence {

    /// Directory holding the persisted recents. Created on demand.
    /// `~/Library/Application Support/SnapShotKit/recents`
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base
            .appendingPathComponent("SnapShotKit", isDirectory: true)
            .appendingPathComponent("recents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }

    /// Persist the base image of each capture, replacing the entire directory
    /// contents. Annotations are not written (session-only in v1).
    static func save(_ items: [CaptureItem]) {
        let fm = FileManager.default
        let dir = directory

        // Start from a clean slate so removed items don't linger on disk.
        clear()

        for (index, item) in items.enumerated() {
            guard let data = pngData(for: item.image) else { continue }
            let name = filename(index: index, title: item.title)
            let url = dir.appendingPathComponent(name, isDirectory: false)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // Skip anything we can't write; never abort the whole save.
                continue
            }
        }
        _ = fm // silence unused in case of empty input
    }

    /// Load previously saved PNGs back into `CaptureItem`s, ordered by their
    /// filename prefix. Unreadable files are ignored.
    static func load() -> [CaptureItem] {
        let fm = FileManager.default
        let dir = directory

        guard let names = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else {
            return []
        }

        let pngs = names
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var items: [CaptureItem] = []
        for url in pngs {
            guard let image = NSImage(contentsOf: url) else { continue }
            let title = titleFromFilename(url.deletingPathExtension().lastPathComponent)
            items.append(CaptureItem(image: image, title: title))
        }
        return items
    }

    /// Remove all persisted recents from disk.
    static func clear() {
        let fm = FileManager.default
        let dir = directory
        guard let contents = try? fm.contentsOfDirectory(at: dir,
                                                         includingPropertiesForKeys: nil,
                                                         options: []) else {
            return
        }
        for url in contents {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    /// Build a stable, sortable filename: `NN-sanitizedTitle.png`.
    private static func filename(index: Int, title: String) -> String {
        let prefix = String(format: "%03d", index)
        let safe = sanitize(title)
        return safe.isEmpty ? "\(prefix).png" : "\(prefix)-\(safe).png"
    }

    /// Recover the human title from a stored filename stem, dropping the
    /// `NN-` ordinal prefix if present.
    private static func titleFromFilename(_ stem: String) -> String {
        if let dash = stem.firstIndex(of: "-") {
            let ordinal = stem[stem.startIndex..<dash]
            if !ordinal.isEmpty, ordinal.allSatisfy(\.isNumber) {
                let title = String(stem[stem.index(after: dash)...])
                return title.isEmpty ? "Capture" : title
            }
        }
        return stem.isEmpty ? "Capture" : stem
    }

    /// Strip path-hostile characters so titles round-trip safely.
    private static func sanitize(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.controlCharacters)
        let cleaned = trimmed.components(separatedBy: illegal).joined(separator: "_")
        // Keep filenames reasonable on disk.
        return String(cleaned.prefix(80))
    }

    /// PNG-encode an image at its true pixel resolution.
    /// Prefers the shared `ExportService` encoder, with a direct
    /// `NSBitmapImageRep` fallback so persistence never depends on it.
    private static func pngData(for image: NSImage) -> Data? {
        if let data = ExportService.pngData(image) {
            return data
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }
}
