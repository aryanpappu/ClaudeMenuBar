import Foundation

// claude-notify <running|waiting|done|idle|end>
//
// Run by Claude Code hooks. Reads the hook's JSON payload from stdin and writes
// the session's state to ~/.claude-menubar/sessions/<session_id>.json, as
// described in docs/PROTOCOL.md (the Windows/Linux helper in crossplatform/
// follows the same rules; both are tested with protocol/vectors.json).
//
// Rules for a hook helper:
//  - Be fast: PreToolUse hooks run before every tool call.
//  - Print nothing to stdout when run as a hook: for UserPromptSubmit and
//    SessionStart, Claude Code adds plain stdout to the model's context.
//  - Never fail the hook: always exit 0 for valid states.

// MARK: Helpers

func finish() -> Never {
    // Wake the app at once; its folder watcher is the fallback.
    DistributedNotificationCenter.default().postNotificationName(
        .init("com.claudemenubar.changed"), object: nil, userInfo: nil, deliverImmediately: true)
    Thread.sleep(forTimeInterval: 0.02)   // let distnoted take the message before we exit
    if interactive && isatty(STDOUT_FILENO) == 1 { print("→ claude state: \(command)") }
    exit(0)
}

func sessionsDirectory() -> URL {
    if let custom = ProcessInfo.processInfo.environment["CLAUDE_MENUBAR_DIR"], custom.hasPrefix("/") {
        return URL(fileURLWithPath: custom, isDirectory: true)
    }
    return URL(fileURLWithPath: NSHomeDirectory() + "/.claude-menubar/sessions", isDirectory: true)
}

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
        && id.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_" }
}

// MARK: Main

let valid = ["running", "idle", "waiting", "done", "end"]
let startMs = Int64(Date().timeIntervalSince1970 * 1000)

guard CommandLine.arguments.count == 2, valid.contains(CommandLine.arguments[1]) else {
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
let command = CommandLine.arguments[1]
let interactive = isatty(STDIN_FILENO) == 1

// MARK: Payload → what to write

var payload: [String: Any] = [:]
var sessionID = "manual"   // run by hand in a terminal (no stdin): for testing
if !interactive {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sid = json["session_id"] as? String, isSafeID(sid) else { exit(0) }
    payload = json
    sessionID = sid
}

let dir = sessionsDirectory()
let fileURL = dir.appendingPathComponent(sessionID + ".json")

if command == "end" {
    try? FileManager.default.removeItem(at: fileURL)
    finish()
}

var record: [String: Any] = ["v": 1, "session_id": sessionID, "state": command, "ts": startMs]

if command == "waiting" {
    if payload["hook_event_name"] as? String == "PermissionRequest" {
        record["kind"] = "approval"
        if let tool = payload["tool_name"] as? String, !tool.isEmpty { record["request"] = String(tool.prefix(40)) }
    } else if let type = payload["notification_type"] as? String {
        switch type {
        case "permission_prompt":
            record["kind"] = "approval"
            record["request"] = (payload["message"] as? String).flatMap(toolName(fromMessage:))
        case "elicitation_dialog", "agent_needs_input":
            record["kind"] = "question"
        default:
            exit(0)   // login results, quota notices, idle reminders: not a state change
        }
    } else if let message = payload["message"] as? String, message.lowercased().contains("permission") {
        // Older Claude Code without notification_type.
        record["kind"] = "approval"
        record["request"] = toolName(fromMessage: message)
    } else if !interactive {
        exit(0)
    }
}

for key in ["cwd", "transcript_path"] {
    if let v = payload[key] as? String, !v.isEmpty, v.count <= 1024 { record[key] = v }
}
if let event = payload["hook_event_name"] as? String, !event.isEmpty, event.count <= 40 { record["event"] = event }

// MARK: Atomic write; a newer event already on disk wins

do {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
    let tmp = dir.appendingPathComponent(".\(sessionID).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
    try data.write(to: tmp)
    if let existing = try? Data(contentsOf: fileURL),
       let json = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
       let ts = (json["ts"] as? NSNumber)?.int64Value, ts > startMs {
        try? FileManager.default.removeItem(at: tmp)
        finish()
    }
    if rename(tmp.path, fileURL.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
} catch {
    fputs("claude-notify: \(error.localizedDescription)\n", stderr)
}
finish()
