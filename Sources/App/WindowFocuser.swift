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

    /// True when `pid` belongs to one of the allowed terminals/editors.
    static func isAllowedApp(pid: pid_t) -> Bool {
        isAllowed(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
    }

    private static func isAllowed(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if allowedExactBundleIDs.contains(bundleID) { return true }
        return allowedBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// The exact window that was raised, so a caller can verify it is still
    /// the focused window before acting on it.
    struct Target {
        let pid: pid_t
        let window: AXUIElement
    }

    /// Finds a terminal/editor window whose title contains `projectName` as a
    /// whole word (so "api" does not match "rapid-api-tests"), activates its
    /// app and raises it.
    ///
    /// With `requireUnique` (used before typing an approval) the search fails
    /// closed: nothing is raised unless exactly one window matches AND every
    /// candidate app could be inspected. An app that times out could be hiding
    /// a second match.
    ///
    /// The AX enumeration runs off the main thread; activate/raise and
    /// `completion` run on the main thread. `completion` gets the raised
    /// window, or nil.
    static func focus(projectName: String, requireUnique: Bool = false,
                      completion: @escaping (Target?) -> Void) {
        guard AXIsProcessTrusted(), !projectName.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let pattern = "(^|[^\\p{L}\\p{N}_.-])" + NSRegularExpression.escapedPattern(for: projectName)
            + "($|[^\\p{L}\\p{N}_.-])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.processIdentifier != selfPID
                && isAllowed($0.bundleIdentifier)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var matches: [(NSRunningApplication, AXUIElement)] = []
            var inspectionFailed = false
            outer: for app in candidates {
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(appElement, 0.5)   // don't hang on a frozen app
                var windowsRef: CFTypeRef?
                let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
                guard err == .success, let windows = windowsRef as? [AXUIElement] else {
                    // .noValue = the app simply has no windows; anything else
                    // means we couldn't look.
                    if err != .noValue && err != .attributeUnsupported { inspectionFailed = true }
                    continue
                }

                for window in windows {
                    var titleRef: CFTypeRef?
                    let titleErr = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                    if titleErr != .success && titleErr != .noValue { inspectionFailed = true }
                    guard let title = titleRef as? String,
                          regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
                    else { continue }
                    matches.append((app, window))
                    if !requireUnique || matches.count > 1 { break outer }
                }
            }

            let unique = matches.count == 1 && !inspectionFailed
            guard let (app, window) = matches.first, !requireUnique || unique else {
                if requireUnique && (matches.count > 1 || inspectionFailed) {
                    NSLog("ClaudeMenuBar: can't single out a window for '\(projectName)'; not approving")
                }
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async {
                let activated = app.activate()
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                if requireUnique && (!activated || raised != .success) {
                    completion(nil)
                    return
                }
                completion(Target(pid: app.processIdentifier, window: window))
            }
        }
    }

    /// True only if `target`'s app is frontmost AND its focused window is
    /// exactly `target.window`. Checked immediately before typing.
    static func isFocused(_ target: Target) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              isAllowedApp(pid: target.pid) else { return false }
        let appElement = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return false }
        return CFEqual(focused, target.window)
    }
}
