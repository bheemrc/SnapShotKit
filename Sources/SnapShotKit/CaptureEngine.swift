import ScreenCaptureKit
import AppKit

/// One-shot full-screen capture via ScreenCaptureKit (macOS 14+).
///
/// Requires the Screen Recording TCC permission, which the OS keys on the app's
/// bundle identifier and code signature — run from the real `.app` bundle
/// produced by `make-app.sh`, not the bare SwiftPM binary, or the OS denies the
/// capture (typically surfacing as `SCStreamError` code `-3801`, userDeclined).
enum CaptureEngine {

    /// Errors surfaced by the capture pipeline with user-facing descriptions.
    enum CaptureError: LocalizedError {
        case noDisplay
        case permissionDenied
        case captureFailed(Error)

        var errorDescription: String? {
            switch self {
            case .noDisplay:
                return "No display was found to capture."
            case .permissionDenied:
                return "Screen Recording permission is required. Grant it in "
                    + "System Settings ▸ Privacy & Security ▸ Screen Recording, "
                    + "then relaunch SnapShotKit."
            case .captureFailed(let underlying):
                return "Screen capture failed: \(underlying.localizedDescription)"
            }
        }
    }

    /// Captures the full main display (all windows) and returns it as an
    /// `NSImage` sized in points, carrying retina pixels.
    ///
    /// This is `async throws`; the ScreenCaptureKit calls are not main-actor
    /// bound, so they run off the main actor. Only the `NSScreen` scale lookup
    /// hops to the main actor.
    static func captureFullScreen() async throws -> NSImage {
        // 1. Enumerate shareable content. The first call triggers the TCC
        //    Screen Recording prompt; failure here usually means denied.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw CaptureError.permissionDenied
        }

        // 2. Pick the main display, falling back to the first available one.
        guard let display = content.displays.first(where: {
            $0.displayID == CGMainDisplayID()
        }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        // 3. Full-display filter; empty array includes every window on-screen.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // 4. Resolve the backing scale factor on the main actor (NSScreen is
        //    main-actor isolated under strict concurrency). Don't assume 2.0.
        let displayID = display.displayID
        let scale = await MainActor.run { () -> Int in
            let matched = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID) == displayID
            }
            let factor = matched?.backingScaleFactor ?? 2.0
            return max(1, Int(factor.rounded()))
        }

        // 5. Retina-aware configuration: pixel dimensions = points * scale,
        //    and disable any rescaling so SCK delivers full resolution.
        let config = SCStreamConfiguration()
        config.width = display.width * scale
        config.height = display.height * scale
        config.captureResolution = .best
        config.scalesToFit = false
        config.showsCursor = true

        // 6. One-shot capture into a CGImage.
        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw CaptureError.permissionDenied
        } catch {
            throw CaptureError.captureFailed(error)
        }

        // 7. Wrap at logical (point) size so the image displays correctly while
        //    retaining its retina pixel buffer.
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: display.width, height: display.height)
        )
    }
}
