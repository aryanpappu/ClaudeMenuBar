import AppKit
import ApplicationServices

/// Raises the terminal/editor window for a Claude session by matching the
/// project folder name against on-screen window titles. Uses the Accessibility
/// API (same permission the Approve keystroke needs) — no Screen Recording
/// permission required, unlike CGWindowList title reads.
enum WindowFocuser {

    /// Bundle IDs (or prefixes) we're willing to raise and inject keystrokes
    /// into. Deliberately restricted to terminals/editors so a browser tab or
    /// Slack channel that merely contains the folder name is never matched.
    private static let allowedExactBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "io.alacritty",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.apple.dt.Xcode",
    ]
    private static let allowedBundlePrefixes: [String] = [
        "com.jetbrains.",   // PhpStorm, IntelliJ, WebStorm, …
    ]

    private static func isAllowed(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if allowedExactBundleIDs.contains(bundleID) { return true }
        return allowedBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Finds a terminal/editor window whose title contains `projectName`,
    /// activates its app and raises it. The AX enumeration (which can block on
    /// unresponsive apps) runs off the main thread; the activate/raise and the
    /// `completion` callback are delivered on the main thread. `completion`
    /// reports whether a window was actually matched and raised.
    static func focus(projectName: String, completion: @escaping (Bool) -> Void) {
        guard AXIsProcessTrusted(), !projectName.isEmpty else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        let needle = projectName.lowercased()
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.processIdentifier != selfPID
                && isAllowed($0.bundleIdentifier)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            for app in candidates {
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                var windowsRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                      let windows = windowsRef as? [AXUIElement] else { continue }

                for window in windows {
                    var titleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                    guard let title = titleRef as? String,
                          title.lowercased().contains(needle) else { continue }

                    DispatchQueue.main.async {
                        app.activate()
                        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                        completion(true)
                    }
                    return
                }
            }
            DispatchQueue.main.async { completion(false) }
        }
    }
}
