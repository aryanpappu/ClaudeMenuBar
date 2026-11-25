import Foundation

// claude-notify <state>
//
// Tiny helper run by Claude Code hooks. It reads the hook's JSON payload from
// stdin and posts a DistributedNotification ("com.claudemenubar.state.<state>")
// that the menu bar app listens for. Installed to ~/.local/bin by install.sh.
//
// Rules for a hook helper:
//  - Be fast: PreToolUse hooks run before every tool call.
//  - Print nothing to stdout when run as a hook: for UserPromptSubmit and
//    SessionStart, Claude Code adds plain stdout to the model's context.
//  - Never fail the hook: always exit 0 for valid states.

let valid = ["running", "idle", "waiting", "done", "end"]
let interactive = isatty(STDOUT_FILENO) == 1 && isatty(STDIN_FILENO) == 1

guard CommandLine.arguments.count > 1 else {
    fputs("""
    Usage: claude-notify <state>
    States: \(valid.joined(separator: " | "))

    Wire it to Claude Code hooks (install.sh does this for you):
      claude-notify running   # UserPromptSubmit / PreToolUse: session is working
      claude-notify waiting   # Notification / PermissionRequest: needs you
      claude-notify done      # Stop: session finished
      claude-notify idle      # reset a session to ready
      claude-notify end       # SessionEnd: remove the session from the list

    """, stderr)
    exit(1)
}

var command = CommandLine.arguments[1]

guard valid.contains(command) else {
    fputs("Unknown state '\(command)'. Valid: \(valid.joined(separator: ", "))\n", stderr)
    exit(1)
}

let stdinIsPipe = isatty(STDIN_FILENO) == 0
let payload = readHookPayload()
var userInfo: [String: String] = [:]

// Piped input that isn't a JSON object: something is wrong, so don't guess
// a session (that would create a fake global "waiting" row).
if stdinIsPipe && payload == nil && command != "running" { exit(0) }

if command == "waiting", let payload {
    let event = payload["hook_event_name"] as? String
    if event == "PermissionRequest" {
        // A real permission prompt: the tool is named directly.
        if let tool = payload["tool_name"] as? String, !tool.isEmpty {
            userInfo["request"] = String(tool.prefix(40))
        }
    } else if let type = payload["notification_type"] as? String {
        // Notification hook: only a permission prompt (or a question for the
        // user) should show "waiting"; everything else just means idle.
        switch type {
        case "permission_prompt":
            if let message = payload["message"] as? String,
               let tool = toolName(fromMessage: message) {
                userInfo["request"] = tool
            }
        case "elicitation_dialog", "agent_needs_input":
            userInfo["kind"] = "question"   // needs a typed answer, not y/n
        default:
            // Login results, quota notices, idle reminders… are not about
            // this session's state: leave it unchanged.
            exit(0)
        }
    } else if let message = payload["message"] as? String {
        // Older Claude Code without notification_type: fall back to the text.
        if message.lowercased().contains("permission") {
            if let tool = toolName(fromMessage: message) { userInfo["request"] = tool }
        } else {
            exit(0)
        }
    } else {
        exit(0)
    }
}

// `end` is a pseudo-state: post `idle` with a remove flag so the app drops
// the session from the list entirely.
if command == "end" {
    command = "idle"
    userInfo["remove"] = "1"
}
if let sid = payload?["session_id"] as? String, isSafeID(sid) { userInfo["session_id"] = sid }
if let cwd = payload?["cwd"] as? String, !cwd.isEmpty, cwd.count < 1024 { userInfo["cwd"] = cwd }
if let tp = payload?["transcript_path"] as? String, !tp.isEmpty, tp.count < 1024 {
    userInfo["transcript_path"] = tp
}

DistributedNotificationCenter.default().postNotificationName(
    .init("com.claudemenubar.state.\(command)"),
    object: nil,
    userInfo: userInfo.isEmpty ? nil : userInfo,
    deliverImmediately: true
)

// Give distnoted a moment to take the message before the process exits.
Thread.sleep(forTimeInterval: 0.03)
if interactive { print("→ claude state: \(command)") }

// MARK: Helpers

// "Claude needs your permission to use Bash" → "Bash"
func toolName(fromMessage message: String) -> String? {
    guard let r = message.range(of: "to use ") else { return nil }
    let tool = message[r.upperBound...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;"))
    return tool.isEmpty ? nil : String(tool.prefix(40))
}

func isSafeID(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 100
        && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
}

// Reads the hook's JSON payload from stdin. Returns nil when run by hand from
// a terminal (no piped input), so the state argument alone is used.
func readHookPayload() -> [String: Any]? {
    guard isatty(STDIN_FILENO) == 0 else { return nil }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return json
}
