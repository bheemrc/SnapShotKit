import Foundation

/// Optional helper for hiding the Finder desktop icons before a capture so that
/// screenshots of the full screen are free of personal files and folders.
///
/// Hiding and restoring icons is implemented by toggling the
/// `com.apple.finder CreateDesktop` user default and relaunching Finder. Because
/// this restarts Finder (windows reflow, the desktop briefly redraws), it is a
/// deliberately heavyweight operation and should be wired up as an opt-in toggle
/// rather than run automatically on every capture. Callers are responsible for
/// pairing `hideIcons()` with a later `restoreIcons()` so the user's desktop is
/// returned to its normal state.
///
/// Both methods are best-effort: if `defaults` or `killall` are unavailable or
/// exit non-zero, the failure is swallowed so that capture flows are never
/// blocked by desktop-cleanup problems.
@MainActor
enum DesktopCleanup {

    /// Hides the desktop icons by disabling `CreateDesktop` and relaunching
    /// Finder. Restarts Finder; intended for opt-in use only.
    static func hideIcons() {
        setCreateDesktop(false)
        relaunchFinder()
    }

    /// Restores the desktop icons by re-enabling `CreateDesktop` and relaunching
    /// Finder. Restarts Finder; should be called to undo a prior `hideIcons()`.
    static func restoreIcons() {
        setCreateDesktop(true)
        relaunchFinder()
    }

    // MARK: - Private helpers

    /// Writes the `com.apple.finder CreateDesktop` boolean default.
    private static func setCreateDesktop(_ enabled: Bool) {
        run("/usr/bin/defaults",
            ["write", "com.apple.finder", "CreateDesktop", "-bool", enabled ? "true" : "false"])
    }

    /// Relaunches Finder so the `CreateDesktop` change takes visual effect.
    private static func relaunchFinder() {
        run("/usr/bin/killall", ["Finder"])
    }

    /// Runs a tool via `Process`, swallowing any error. The desktop-cleanup
    /// feature is strictly best-effort and must never throw into a capture path.
    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
