import AppKit
import Foundation

// Earliest possible trace — confirms this binary is executing
try? "main_start".write(toFile: "/tmp/cmb.txt", atomically: true, encoding: .utf8)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = MainActor.assumeIsolated { AppDelegate() }
try? "delegate_created".write(toFile: "/tmp/cmb.txt", atomically: true, encoding: .utf8)

app.delegate = delegate
try? "delegate_set".write(toFile: "/tmp/cmb.txt", atomically: true, encoding: .utf8)

app.run()
