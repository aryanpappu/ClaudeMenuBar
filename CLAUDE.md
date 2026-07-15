# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS menu bar app (`LSUIElement`, no Dock icon) that visualizes the live state of a Claude Code session — the menu bar brain icon and an on-screen floating panel change as Claude transitions through `idle → running → waiting → done`, with synthesized ambient sounds per state. Swift 5.9, SwiftUI + AppKit, macOS 15+ deployment target.

## Build & run

The Xcode project is **generated** from `project.yml` by XcodeGen — `ClaudeMenuBar.xcodeproj` is a build artifact, not source. Never hand-edit the `.xcodeproj`; edit `project.yml` and regenerate.

- **First-time setup:** `./setup.sh` — installs XcodeGen (via brew) and runs `xcodegen generate`, then prints manual install/hook instructions.
- **Iterate (the normal loop):** `./rebuild.sh` — regenerates the project, builds the `ClaudeMenuBar` target Release into `./build`, kills the running instance, copies the app to `~/Applications/`, and relaunches it. Use this after any code change.
- **Regenerate project only:** `xcodegen generate`
- After editing sound synthesis or panel geometry you must actually run the app to verify — there are no automated tests in this repo.

There is no lint or test suite configured.

## Two targets

- **`ClaudeMenuBar`** (app) — the menu bar UI, floating panel, sound, and state logic. Entry point is `Sources/App/main.swift` (not `@main` — it manually creates `NSApplication` with `.accessory` activation policy and an `AppDelegate`).
- **`claude-notify`** (CLI tool, installs to `/usr/local/bin`) — tiny binary invoked by Claude Code hooks. `claude-notify <running|waiting|done|idle>` posts a `DistributedNotification` named `com.claudemenubar.state.<state>` that the app listens for.

## How state flows in (the core architecture)

`AppState` (`Sources/App/AppState.swift`, a `@MainActor` singleton `AppState.shared`) is the single source of truth. State can be driven from **three independent signals**, layered for responsiveness + robustness:

1. **Claude Code hooks → `claude-notify` → `DistributedNotificationCenter` → `IPCListener`** — the primary channel. The user wires PreToolUse/Notification/Stop hooks in `~/.claude/settings.json` to call `claude-notify` (see `setup.sh` for the exact JSON). `IPCListener` observes all four state notifications and calls `AppState.apply(_:)`.
2. **`~/.claude/history.jsonl` file watcher** (`startHistoryWatcher`) — a `DispatchSource` fires the moment the user submits a message, which happens *before* the first PreToolUse hook. This makes extended-thinking phases show "running" from the very start.
3. **`pgrep -x claude` process watcher** (`startProcessWatcher`, every 3s) — safety net that forces `done` if the CLI process died without a Stop hook firing.

`apply(_:)` animates the transition, triggers `SoundManager.play(for:)`, and on `done` schedules a 30s timer before reverting to `idle` (keeps the ✓ visible while the user types the next message).

## Integration points with the user's Claude config (`~/.claude/`)

This app reads and writes the user's real Claude Code config — be careful here:
- **`settings.json`** — `loadModel`/`setModel` read and rewrite the `"model"` key when the user picks Haiku/Sonnet/Opus from the menu.
- **`history.jsonl`** — watched for the submit signal and parsed in `loadUsageStats()` to count today's ("session") and this-week's messages from `timestamp` fields (epoch ms).

## Other notable pieces

- **`SoundManager`** — synthesizes all audio in-process via `AVAudioEngine` (no bundled audio files): rain hiss loop for `running`, a whistle for `done`, a repeating door-knock for `waiting`. Two independent mutes: `isMuted` (all) and `isRainMuted` (running ambience only).
- **`FloatingPanel`** — a borderless `.nonactivatingPanel` at `.floating` level, non-key, pinned bottom-right of the screen under the mouse. Retained strongly by `AppDelegate` (a released panel disappears). Subscribes to `appState.$state` via Combine to grow when the approve button appears in `waiting`.
- **`AppState.sendApproval()`** — synthesizes `y` + Return `CGEvent`s to auto-approve a permission prompt. Requires Accessibility permission (`AXIsProcessTrusted`); prompts for it on first use.
- **Launch-at-login** via `SMAppService.mainApp`.
- `Sources/App/main.swift` and `AppDelegate` write breadcrumb strings to `/tmp/cmb.txt` at each startup stage — a launch-debugging aid, not application logic.
