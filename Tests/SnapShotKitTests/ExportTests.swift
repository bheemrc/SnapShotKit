import XCTest
import AppKit
import CoreGraphics
@testable import SnapShotKit

/// Pure-logic export tests. These exercise the file-output paths
/// (`PPTXExporter`, `GIFEncoder`) and the detection path
/// (`RedactionService`) with synthetic images created entirely in code, so the
/// suite is deterministic and runs offline with no capture or network access.
final class ExportTests: XCTestCase {

    // MARK: - Synthetic image helpers

    /// Builds an opaque RGBA `NSImage` of the requested pixel size, filled with a
    /// solid color. The image carries a real `NSBitmapImageRep`, so
    /// `NSImage.pixelSize` reports the true pixel dimensions.
    private func makeImage(width: Int, height: Int, color: NSColor) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: NSSize(width: width, height: height))
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    /// Builds a solid-color `CGImage` of the requested pixel size.
    private func makeCGImage(width: Int, height: Int, gray: CGFloat) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Returns a unique temporary URL with the given extension (file not created).
    private func tempURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapShotKitTests-\(UUID().uuidString).\(ext)")
    }

    /// Runs `/usr/bin/unzip -l` against an archive and returns its stdout text.
    private func unzipListing(of url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - PPTX

    @MainActor
    func testPPTXExportProducesValidPackage() throws {
        let items = [
            CaptureItem(image: makeImage(width: 120, height: 80, color: .systemBlue),
                        title: "First"),
            CaptureItem(image: makeImage(width: 90, height: 160, color: .systemRed),
                        annotations: [
                            Annotation(kind: .rectangle,
                                       start: CGPoint(x: 10, y: 10),
                                       end: CGPoint(x: 70, y: 120))
                        ],
                        title: "Second")
        ]

        let url = tempURL(ext: "pptx")
        defer { try? FileManager.default.removeItem(at: url) }

        try PPTXExporter.export(items, to: url)

        // File exists and is non-empty.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Expected a .pptx file at \(url.path)")
        let size = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0, "Expected a non-empty .pptx archive")

        // The archive is a valid OOXML package: it must list the required parts.
        let listing = try unzipListing(of: url)
        XCTAssertTrue(listing.contains("[Content_Types].xml"),
                      "Archive should contain [Content_Types].xml. Listing:\n\(listing)")
        XCTAssertTrue(listing.contains("ppt/presentation.xml"),
                      "Archive should contain ppt/presentation.xml. Listing:\n\(listing)")
        // One slide per item should be present.
        XCTAssertTrue(listing.contains("ppt/slides/slide1.xml"),
                      "Archive should contain slide1.xml. Listing:\n\(listing)")
        XCTAssertTrue(listing.contains("ppt/slides/slide2.xml"),
                      "Archive should contain slide2.xml. Listing:\n\(listing)")
    }

    @MainActor
    func testPPTXExportRejectsEmptyInput() {
        let url = tempURL(ext: "pptx")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try PPTXExporter.export([], to: url),
                             "Exporting no items should throw")
    }

    // MARK: - GIF

    func testGIFEncoderWritesAnimatedGIF() throws {
        let frames = [
            makeCGImage(width: 48, height: 48, gray: 0.1),
            makeCGImage(width: 48, height: 48, gray: 0.5),
            makeCGImage(width: 48, height: 48, gray: 0.9)
        ]

        let url = tempURL(ext: "gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let ok = GIFEncoder.write(frames: frames, frameDelay: 0.1, to: url)
        XCTAssertTrue(ok, "GIFEncoder.write should report success")

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Expected a .gif file at \(url.path)")

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0, "Expected a non-empty .gif")

        // The GIF magic number is the ASCII bytes "GIF8" (GIF87a / GIF89a).
        let magic = Array(data.prefix(4))
        XCTAssertEqual(magic, Array("GIF8".utf8),
                       "File should begin with the GIF magic bytes")
    }

    func testGIFEncoderRejectsEmptyFrames() {
        let url = tempURL(ext: "gif")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(GIFEncoder.write(frames: [], frameDelay: 0.1, to: url),
                       "Encoding zero frames should fail")
    }

    // MARK: - Redaction

    /// A blank synthetic image contains no PII text and no faces, so detection
    /// should complete without crashing and return an array (empty in this case).
    func testRedactionDetectionReturnsArrayWithoutCrashing() async {
        let image = makeImage(width: 64, height: 64, color: .white)
        let regions = await RedactionService.detectSensitiveRegions(in: image)
        // The contract is an array (possibly empty); a blank image yields none.
        XCTAssertTrue(regions.isEmpty,
                      "A blank image should yield no sensitive regions")
    }
}
