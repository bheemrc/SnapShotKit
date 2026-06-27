import AppKit
import UniformTypeIdentifiers

/// Clipboard and PNG export helpers shared by the toolbar, menu-bar, and
/// keyboard-shortcut paths.
///
/// All images passed in are expected to already be flattened (base image +
/// annotations) via `PDFExporter.flatten`, which is the single source of truth
/// for rendering. This service only deals with delivery: pasteboard, save
/// panels, and on-disk PNG encoding at full pixel resolution.
@MainActor
enum ExportService {

    // MARK: - Pasteboard

    /// Clears the general pasteboard and writes `image` to it so it can be
    /// pasted into other applications.
    static func copyToPasteboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Prefer writing PNG data alongside the NSImage so receivers that ask
        // for a concrete bitmap type get full-resolution pixels.
        if let data = pngData(image) {
            pasteboard.setData(data, forType: .png)
            return
        }

        guard pasteboard.writeObjects([image]) else {
            NSSound.beep()
            return
        }
    }

    // MARK: - Single PNG save

    /// Presents an `NSSavePanel` (filtered to PNG) and, on confirmation, writes
    /// `image` as a PNG. Beeps and ignores on failure.
    static func savePNG(_ image: NSImage, suggestedName: String) {
        let panel = NSSavePanel()
        panel.title = "Save PNG"
        panel.prompt = "Save"
        panel.nameFieldStringValue = pngFileName(from: suggestedName)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.png]

        // Bring the app/panel to the front; menu-bar apps may not be active.
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let data = pngData(image) else {
            NSSound.beep()
            return
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSSound.beep()
        }
    }

    // MARK: - Quick save to Desktop

    /// Writes `image` as a PNG to the user's Desktop using a unique file name
    /// derived from `name`. Returns the written URL, or `nil` on failure.
    @discardableResult
    static func quickSaveToDesktop(_ image: NSImage, name: String) -> URL? {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory,
                                                      in: .userDomainMask).first else {
            NSSound.beep()
            return nil
        }

        guard let data = pngData(image) else {
            NSSound.beep()
            return nil
        }

        let url = uniqueURL(in: desktop, baseName: sanitized(name))
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            NSSound.beep()
            return nil
        }
    }

    // MARK: - Batch PNG export

    /// Presents an `NSOpenPanel` to choose a destination folder, then writes
    /// each `(name, image)` pair as a PNG into it. File names are made unique
    /// within the chosen folder so nothing is overwritten. Beeps and ignores on
    /// failure.
    static func saveAllPNGs(_ items: [(name: String, image: NSImage)]) {
        guard !items.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.title = "Export PNGs"
        panel.prompt = "Export"
        panel.message = "Choose a folder to save the PNG files into."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let folder = panel.url else { return }

        var failed = false
        for item in items {
            guard let data = pngData(item.image) else {
                failed = true
                continue
            }
            let url = uniqueURL(in: folder, baseName: sanitized(item.name))
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                failed = true
            }
        }

        if failed {
            NSSound.beep()
        }
    }

    // MARK: - PNG encoding

    /// Encodes `image` as PNG data at full pixel resolution.
    ///
    /// Prefers an existing `NSBitmapImageRep` (the true source pixels, so Retina
    /// captures keep their resolution); otherwise rebuilds a bitmap from the
    /// image's `CGImage` at its pixel dimensions.
    static func pngData(_ image: NSImage) -> Data? {
        if let rep = largestBitmapRep(in: image) {
            return rep.representation(using: .png, properties: [:])
        }

        guard let rep = bitmapRepFromCGImage(image) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Bitmap helpers

    /// Returns the highest-resolution `NSBitmapImageRep` already attached to the
    /// image, if any.
    private static func largestBitmapRep(in image: NSImage) -> NSBitmapImageRep? {
        var best: NSBitmapImageRep?
        var bestPixels = 0
        for rep in image.representations {
            guard let bitmap = rep as? NSBitmapImageRep else { continue }
            let pixels = bitmap.pixelsWide * bitmap.pixelsHigh
            if pixels > bestPixels {
                bestPixels = pixels
                best = bitmap
            }
        }
        return best
    }

    /// Builds a bitmap rep from the image's `CGImage` at full pixel resolution.
    private static func bitmapRepFromCGImage(_ image: NSImage) -> NSBitmapImageRep? {
        let size = image.pixelSize
        var rect = CGRect(origin: .zero, size: size)
        guard size.width > 0, size.height > 0,
              let cgImage = image.cgImage(forProposedRect: &rect,
                                          context: nil,
                                          hints: nil) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        // Report the size in points; pixel counts come from the CGImage so PNG
        // encoding stays at native resolution.
        rep.size = size
        return rep
    }

    // MARK: - File-name helpers

    /// Ensures a name carries a `.png` extension.
    private static func pngFileName(from name: String) -> String {
        let base = sanitized(name)
        if base.lowercased().hasSuffix(".png") {
            return base
        }
        return base + ".png"
    }

    /// Strips path separators and trims whitespace, falling back to a default
    /// when the result would be empty. The returned value has no extension.
    private static func sanitized(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasSuffix(".png") {
            cleaned = String(cleaned.dropLast(4))
        }
        return cleaned.isEmpty ? "Screenshot" : cleaned
    }

    /// Produces a `baseName.png` URL inside `folder`, appending " 2", " 3", …
    /// until the name is free.
    private static func uniqueURL(in folder: URL, baseName: String) -> URL {
        let fileManager = FileManager.default
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension("png")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let name = "\(baseName) \(counter)"
            candidate = folder.appendingPathComponent(name).appendingPathExtension("png")
            counter += 1
        }
        return candidate
    }
}
