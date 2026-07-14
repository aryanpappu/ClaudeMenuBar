import Foundation

// claude-notify <state>
// Posts a DistributedNotification that the menu bar app listens for.
// Install to /usr/local/bin/claude-notify and wire into ~/.claude/settings.json hooks.

let valid = ["running", "idle", "waiting", "done"]

guard CommandLine.arguments.count > 1 else {
    fputs("""
    Usage: claude-notify <state>
    States: \(valid.joined(separator: " | "))

    Example:
      claude-notify running   # Claude started a tool call
      claude-notify waiting   # Claude needs your permission
      claude-notify done      # Claude finished
      claude-notify idle      # Reset to idle

    """, stderr)
    exit(1)
}

let command = CommandLine.arguments[1]

guard valid.contains(command) else {
    fputs("Unknown state '\(command)'. Valid: \(valid.joined(separator: ", "))\n", stderr)
    exit(1)
}

DistributedNotificationCenter.default().postNotificationName(
    .init("com.claudemenubar.state.\(command)"),
    object: nil,
    userInfo: nil,
    deliverImmediately: true
)

// Brief sleep so the notification delivers before the process exits
Thread.sleep(forTimeInterval: 0.15)
print("→ claude state: \(command)")
