import ScreenCaptureKit
import AppKit

// Region and per-window capture built on ScreenCaptureKit, layered on top of
// the full-screen path in `CaptureEngine`. Like the full-screen path these
// require the Screen Recording TCC permission, so they must run from the signed
// `.app` bundle rather than the bare SwiftPM binary.
extension CaptureEngine {

    /// A capturable on-screen window, reduced to a `Sendable` value so it can be
    /// passed across actor boundaries and bound into SwiftUI. The live
    /// `SCWindow` is intentionally not carried here — it is re-resolved by
    /// `windowID` inside `captureWindow(windowID:)`.
    struct WindowInfo: Identifiable, Sendable {
        let id: CGWindowID
        let title: String
        let appName: String
    }

    /// Backing scale factor for the display identified by `displayID`. Resolved
    /// on the main actor because `NSScreen` is main-actor isolated under strict
    /// concurrency. Falls back to 2.0 (retina) when no match is found; never
    /// returns below 1.
    private static func backingScale(forDisplayID displayID: CGDirectDisplayID) async -> Int {
        await MainActor.run {
            let matched = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID) == displayID
            }
            let factor = matched?.backingScaleFactor ?? 2.0
            return max(1, Int(factor.rounded()))
        }
    }

    /// Resolves the `NSScreen` whose frame contains `globalPoint` (global screen
    /// points, bottom-left origin), returning its display ID and frame. Falls
    /// back to the main screen when the point lies outside every display.
    private static func screen(containing globalPoint: CGPoint) async
        -> (displayID: CGDirectDisplayID, frame: CGRect)? {
        await MainActor.run {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            let match = NSScreen.screens.first { $0.frame.contains(globalPoint) }
                ?? NSScreen.main
                ?? NSScreen.screens.first
            guard
                let screen = match,
                let displayID = screen.deviceDescription[key] as? CGDirectDisplayID
            else { return nil }
            return (displayID, screen.frame)
        }
    }

    /// Captures a rectangular region of the screen.
    ///
    /// `screenRect` is in global screen points with a bottom-left origin, exactly
    /// as produced by the region-selection overlay. The region is mapped onto the
    /// display containing its center, then converted into that display's local
    /// top-left-origin coordinate space for `SCStreamConfiguration.sourceRect`.
    /// The returned `NSImage` is sized to the region's point size but carries the
    /// full retina pixel buffer.
    static func captureRegion(_ screenRect: CGRect) async throws -> NSImage {
        // 1. Enumerate shareable content. The first call triggers the TCC
        //    Screen Recording prompt; failure here usually means denied.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw CaptureError.permissionDenied
        }

        // 2. Locate the display that owns the region's center point.
        let center = CGPoint(x: screenRect.midX, y: screenRect.midY)
        guard let target = await screen(containing: center) else {
            throw CaptureError.noDisplay
        }
        guard let display = content.displays.first(where: {
            $0.displayID == target.displayID
        }) else {
            throw CaptureError.noDisplay
        }

        // 3. Convert the global bottom-left rect into the display's local
        //    top-left-origin space (points). X is offset by the display origin;
        //    Y is flipped relative to the display's top edge.
        let screenFrame = target.frame
        let localRect = CGRect(
            x: screenRect.minX - screenFrame.minX,
            y: screenFrame.maxY - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        )

        // 4. Retina-aware configuration. The source rect is in points; the output
        //    pixel dimensions are the region size scaled by the backing factor.
        let scale = await backingScale(forDisplayID: display.displayID)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = localRect
        config.width = max(1, Int((localRect.width * CGFloat(scale)).rounded()))
        config.height = max(1, Int((localRect.height * CGFloat(scale)).rounded()))
        config.captureResolution = .best
        config.scalesToFit = false
        config.showsCursor = false

        // 5. One-shot capture into a CGImage.
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

        // 6. Wrap at the region's logical (point) size, keeping retina pixels.
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: screenRect.width, height: screenRect.height)
        )
    }

    /// Lists the windows that are reasonable capture targets: on-screen, titled,
    /// at least a minimal size, and not owned by this app. Sorted by application
    /// name, then window title, for a stable picker order.
    static func listWindows() async throws -> [WindowInfo] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw CaptureError.permissionDenied
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let minimumSide: CGFloat = 40

        let infos: [WindowInfo] = content.windows.compactMap { window in
            guard window.isOnScreen else { return nil }
            guard let title = window.title, !title.isEmpty else { return nil }
            guard window.frame.width >= minimumSide,
                  window.frame.height >= minimumSide else { return nil }

            let app = window.owningApplication
            let appName = app?.applicationName ?? ""
            // Exclude our own windows by bundle identifier, with a name-based
            // fallback for unsigned/dev runs where the bundle ID may be absent.
            if let ownBundleID, app?.bundleIdentifier == ownBundleID { return nil }
            if appName == "SnapShotKit" { return nil }

            return WindowInfo(id: window.windowID, title: title, appName: appName)
        }

        return infos.sorted {
            if $0.appName != $1.appName {
                return $0.appName.localizedCaseInsensitiveCompare($1.appName)
                    == .orderedAscending
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title)
                == .orderedAscending
        }
    }

    /// Captures a single window by its `CGWindowID`.
    ///
    /// The window is re-resolved from fresh shareable content so no non-`Sendable`
    /// `SCWindow` crosses an actor boundary. Capture is desktop-independent (the
    /// window only, excluding anything behind it) and retina-aware. The returned
    /// `NSImage` is sized to the window's point size but carries retina pixels.
    static func captureWindow(windowID: CGWindowID) async throws -> NSImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw CaptureError.permissionDenied
        }

        guard let window = content.windows.first(where: {
            $0.windowID == windowID
        }) else {
            throw CaptureError.noDisplay
        }

        // Resolve the backing scale from the display under the window's center so
        // retina pixels match the screen the window currently lives on.
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let displayID: CGDirectDisplayID = content.displays.first {
            $0.frame.contains(center)
        }?.displayID ?? CGMainDisplayID()
        let scale = await backingScale(forDisplayID: displayID)

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = max(1, Int((window.frame.width * CGFloat(scale)).rounded()))
        config.height = max(1, Int((window.frame.height * CGFloat(scale)).rounded()))
        config.captureResolution = .best
        config.scalesToFit = false
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true

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

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: window.frame.width, height: window.frame.height)
        )
    }
}
