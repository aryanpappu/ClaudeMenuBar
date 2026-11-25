import AppKit
import Foundation

// Manual entry point (no @main): an accessory app has no Dock icon and no
// main window, only the status item and the floating panel.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
