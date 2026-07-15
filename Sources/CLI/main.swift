import Foundation

// claude-notify <state>
// Posts a DistributedNotification that the menu bar app listens for.
// Install to ~/.local/bin/claude-notify and wire into ~/.claude/settings.json hooks.
//
// Reads the hook's JSON payload from stdin (session_id, cwd, message) and
// forwards session_id + cwd so the app can track sessions individually.

let valid = ["running", "idle", "waiting", "done", "end"]

guard CommandLine.arguments.count > 1 else {
    fputs("""
    Usage: claude-notify <state>
    States: \(valid.joined(separator: " | "))

    Example (wire to Claude Code hooks):
      claude-notify running   # PreToolUse / UserPromptSubmit — session is working
      claude-notify waiting   # Notification — needs permission (Approve shown)
      claude-notify done      # Stop — session finished
      claude-notify idle      # reset a session to ready
      claude-notify end       # SessionEnd — remove the session from the list

    """, stderr)
    exit(1)
}

var command = CommandLine.arguments[1]

guard valid.contains(command) else {
    fputs("Unknown state '\(command)'. Valid: \(valid.joined(separator: ", "))\n", stderr)
    exit(1)
}

let payload = readHookPayload()

// The Notification hook fires for BOTH real permission requests
// ("Claude needs your permission to use Bash") AND plain idle
// ("Claude is waiting for your input"). Only the former should surface
// the Approve button — downgrade the rest to `idle`.
if command == "waiting", let message = payload?["message"] as? String {
    if !message.lowercased().contains("permission") {
        command = "idle"
    }
}

// `end` is a pseudo-state: post `idle` with a remove flag so the app drops
// the session from the active list entirely.
var userInfo: [String: String] = [:]
if command == "end" {
    command = "idle"
    userInfo["remove"] = "1"
}
if let sid = payload?["session_id"] as? String, !sid.isEmpty { userInfo["session_id"] = sid }
if let cwd = payload?["cwd"] as? String, !cwd.isEmpty { userInfo["cwd"] = cwd }
if let tp = payload?["transcript_path"] as? String, !tp.isEmpty { userInfo["transcript_path"] = tp }

DistributedNotificationCenter.default().postNotificationName(
    .init("com.claudemenubar.state.\(command)"),
    object: nil,
    userInfo: userInfo.isEmpty ? nil : userInfo,
    deliverImmediately: true
)

// Brief sleep so the notification delivers before the process exits
Thread.sleep(forTimeInterval: 0.15)
print("→ claude state: \(command)")

// Reads the hook's JSON payload from stdin. Returns nil when there's no
// piped input (e.g. run manually) so we fall back to the state argument.
func readHookPayload() -> [String: Any]? {
    guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { return nil }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return json
}
