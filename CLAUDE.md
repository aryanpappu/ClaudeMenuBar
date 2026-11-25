# CLAUDE.md

Guidance for Claude Code (and other contributors) working in this repository.

## What this is

A macOS menu bar app (`LSUIElement`, no Dock icon) that shows the live state of every Claude Code session: `idle → running → waiting → done`. It has a menu bar icon, a floating panel with one row per session, synthesized sounds and notification banners. Swift (Swift 5 language mode), SwiftUI + AppKit, macOS 15+, Xcode 16+. Public, MIT-licensed; not affiliated with Anthropic.

## Build & run

The Xcode project is **generated** from `project.yml` by XcodeGen. `ClaudeMenuBar.xcodeproj` is git-ignored; never hand-edit it.

- `./install.sh`: build both targets, install the app to `~/Applications`, the helper to `~/.local/bin/claude-notify`, and add the hooks (`--no-hooks`, `--dry-run-hooks`).
- `./rebuild.sh`: the normal dev loop; same as `install.sh --no-hooks`.
- `./uninstall.sh`: remove the hooks (others are kept), the helper and the app.
- `xcodegen generate`: regenerate the project only.
- Signing: `Config/Signing.xcconfig` (ad-hoc by default) optionally includes the git-ignored `Config/Signing.local.xcconfig` with a personal identity. A stable identity keeps the Accessibility grant across rebuilds.
- CI: `.github/workflows/build.yml` builds both targets, checks the helper prints nothing, and tests `scripts/hooks.py`.
- There are no unit tests yet. After UI, sound or panel changes, run the app and look. You can drive it without Claude Code:
  `echo '{"session_id":"demo","cwd":"/tmp/x","hook_event_name":"PermissionRequest","tool_name":"Bash"}' | ~/.local/bin/claude-notify waiting`

## Two targets

- **`ClaudeMenuBar`** (app). The entry point is `Sources/App/main.swift` (not `@main`; it creates `NSApplication` with `.accessory` policy and the `AppDelegate` in `ClaudeMenuBarApp.swift`).
- **`claude-notify`** (`Sources/CLI/main.swift`), run by Claude Code hooks. It reads the hook JSON from stdin and writes `~/.claude-menubar/sessions/<session_id>.json` following **docs/PROTOCOL.md**, then posts `com.claudemenubar.changed` as an instant wake-up. Any change to its rules must also change `protocol/vectors.json` (run `python3 protocol/run_vectors.py build/Release/claude-notify`) and the Rust helper in `crossplatform/`. Hard rules: **fast** (PreToolUse runs before every tool call), **silent on stdout when run as a hook** (Claude Code adds `UserPromptSubmit`/`SessionStart` stdout to the model context), always exit 0.
  - `waiting` comes from `PermissionRequest` (uses `tool_name`) or `Notification` with `notification_type == permission_prompt` (approval) or `elicitation_dialog` / `agent_needs_input` (question). Other notification types are ignored. The English "permission" text check is only a fallback for old Claude Code versions.
  - `end` deletes the session file.

## Hooks (installed by `scripts/hooks.py`)

`UserPromptSubmit`/`PreToolUse` → running · `PermissionRequest`/`Notification` → waiting · `Stop` → done · `SessionEnd` → end. `hooks.py` recognises its own entries by the string `claude-notify`, never duplicates them, backs up `settings.json`, writes atomically and refuses invalid JSON.

## State flow (core architecture)

`AppState` (`Sources/App/AppState.swift`, `@MainActor` singleton) is the single source of truth.

1. **Hooks → `claude-notify` → session files → `SessionFiles` (folder watcher + wake-up notification + 5 s rescan) → `AppState.sync` → `apply(_:info:at:silent:)`.** Only files newer than the last applied `ts` count; a vanished file removes the session; the first load at launch is silent. Treat file contents as untrusted: ids are validated, sizes capped, and `transcript_path` is accepted only inside `~/.claude/projects` (symlinks resolved).
2. **`sessions: [String: Session]`**, keyed by `session_id`. The aggregate `state` (icon, sound) is derived: waiting > running > done > idle.
3. **Sweep timer (5 s):** done → idle after 30 s; idle dropped after 10 min; running dropped after 30 min of silence (crash cleanup); waiting is never auto-cleared. It also calls `UsageTracker.poll()`.
4. **Enrichment:** the last 64 KB of the session transcript (lossy UTF-8) gives `gitBranch` and `aiTitle`/`lastPrompt` for the row subtitle.

## Integration with the user's Claude config (`~/.claude/`): be careful

- **`settings.json`:** `setModel` changes only the `model` key ("Auto" removes it). It re-reads right before writing, writes atomically, refuses invalid JSON, and updates the UI only after a successful write. `loadModel` runs at launch and when a new session appears.
- **`history.jsonl`:** read by `UsageTracker` (serial queue). There is one full read, then only appended bytes. It keeps only this week's timestamps (never prompt text), re-arms its file watcher on delete/rename, and fully re-reads on truncation.

## Other pieces

- **`SoundManager`:** all audio is synthesized with `AVAudioEngine` (rain = running, knock = waiting, whistle = done). The engine starts on demand and pauses after the last sound. Two mutes: everything, and rain only.
- **`FloatingPanel`:** a borderless non-activating `NSPanel`, always on top, pinned bottom-right; it resizes to the SwiftUI content height (`panelContentHeight`) and comes back on screen when displays change. It must be retained strongly by `AppDelegate`.
- **`WindowFocuser`:** raises the terminal/editor window whose title contains the project folder name **as a whole word**, and only in allow-listed terminals/editors. The AX calls have a 0.5 s timeout.
- **`sendApproval`** (One-Click Approve, **opt-in**, default off): only with exactly one matching window (`requireUnique`), and it re-checks the frontmost app just before posting `y` + Return. When it's off, the button and the banner action only open the terminal.
- **`NotificationManager`:** waiting/done banners. The prompt text is shown only with "Show Prompt in Banners". The waiting banner is removed as soon as the session leaves waiting.
- **`Prefs`:** UserDefaults-backed toggles (mute, rain, panel, notifications, previews, one-click approve, expanded sections).
- Debug-only "Force" menu items are behind `#if DEBUG`.

## Docs

`docs/REVIEW.md` lists known issues, fixes and the roadmap. `docs/CROSS_PLATFORM.md` is the Windows/Linux plan (start with the state-files channel).
