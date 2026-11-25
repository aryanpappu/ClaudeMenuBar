# Code review: issues, fixes and roadmap

Reviewed on 25 November 2026 by two independent reviewers, Claude Code (Claude Opus) and OpenAI Codex. Each read the full source tree. Then fixes were made, built and tested. This page lists everything found and what happened to it.

**Status:** ✅ fixed in v1.1.0 · 🟡 partly fixed · ⏳ open (roadmap)

## Correctness

| # | Issue | Found by | Status |
|---|---|---|---|
| 1 | The hook helper printed `→ claude state: …` to stdout. For `UserPromptSubmit`, Claude Code adds printed text to the model's context, so every prompt wasted tokens on it. | Claude | ✅ prints only when run by hand in a terminal |
| 2 | The helper slept 150 ms on every call. `PreToolUse` runs before every tool call, so that added up to about 15 s per 100 tool calls. | Codex | ✅ 30 ms. Measured about 50 ms per call, 26 of 26 events delivered in a burst test |
| 3 | `setup.sh` didn't install `UserPromptSubmit` or `SessionEnd`, so long thinking showed "Ready" and closed sessions could stay stuck on "Waiting". | Codex | ✅ `install.sh` adds all six hooks |
| 4 | Permission prompts were detected by looking for the English word "permission" in the message. Messages without text stayed "waiting". | Codex | ✅ uses `notification_type` and the `PermissionRequest` hook, with the old text check as a fallback |
| 5 | The history watcher never started if `history.jsonl` didn't exist yet, and stopped working when the file was replaced. | Claude, Codex | ✅ re-arms itself on delete/rename and every 5 s |
| 6 | Every message re-read and re-parsed the entire, ever-growing `history.jsonl`. Overlapping reads could publish old counts. | Claude, Codex | ✅ one serial reader that only reads new bytes (`UsageTracker`) |
| 7 | "This Session" actually counted all of today's prompts, and the count didn't roll over at midnight. | Codex | ✅ renamed "Today"; recounted every 5 s |
| 8 | The transcript tail was decoded as strict UTF-8, so one cut-off multi-byte character dropped the whole tail. | Codex | ✅ lossy decode |
| 9 | Model buttons didn't fit after adding "Auto". | Claude (found while testing) | ✅ pills share the row evenly |
| 10 | Preferences (mute, panel, sections) reset on every launch. | Claude | ✅ saved in UserDefaults |
| 11 | The floating panel could be left off-screen after unplugging a display. | Claude | ✅ moves back on screen-change events |
| 12 | Debug "Force Running / Idle" buttons were in the public menu and acted on a hidden session. | Claude, Codex | ✅ Debug builds only |
| 13 | Late or out-of-order events can overwrite newer state or re-create a removed session (events have no sequence number). | Codex | ⏳ add a per-session sequence/timestamp to events |
| 14 | Restarting the app forgets live sessions until their next hook fires. | Codex | ⏳ see "state files" in [CROSS_PLATFORM.md](CROSS_PLATFORM.md) |

## Security and privacy

| # | Issue | Found by | Status |
|---|---|---|---|
| 15 | Approve typed `y` + Return into the first window whose title merely *contained* the folder name. Two matching windows, or a focus change, could approve the wrong prompt. | Claude, Codex | ✅ opt-in (off by default); whole-word match; refuses if more than one window matches; re-checks the front app before typing; 0.5 s timeout on frozen apps |
| 16 | An old "Approval needed" banner kept a working Approve button after the request was answered. | Codex | ✅ the banner is removed when the session leaves "waiting"; no Approve action while the feature is off |
| 17 | Distributed notifications can be posted by any local process. The app trusted session IDs and opened any `transcript_path` it was sent. | Codex | ✅ IDs validated, sizes capped, transcripts only read from `~/.claude/projects/**/*.jsonl` (symlinks resolved), reads capped at 64 KB. Spoofing state stays possible by design (low impact) |
| 18 | Model switch rewrote `~/.claude/settings.json` non-atomically, escaped `/` as `\/`, and showed the new model even if the write failed. | Claude, Codex | ✅ re-read before writing, atomic write, refuses invalid JSON, UI updates only on success, "Auto" removes the key |
| 19 | Completion banners showed the session title or last prompt, which can leak into screen shares and the lock screen. | Codex | ✅ off by default ("Show Prompt in Banners") |
| 20 | `/tmp/cmb.txt` debug breadcrumbs were written on every launch. | Claude | ✅ removed |
| 21 | The maintainer's Apple team ID was hard-coded, so nobody else could build. | Claude, Codex | ✅ ad-hoc by default; personal identity in the git-ignored `Config/Signing.local.xcconfig` |
| 22 | The commit history contained a work email address. | Claude | ✅ history re-authored before publishing |

## Performance and battery

| # | Issue | Status |
|---|---|---|
| 23 | `AVAudioEngine` ran all the time from launch, keeping the audio hardware awake. | ✅ starts on demand and pauses after the last sound |
| 24 | Rain/knock buffers are generated on the main actor each time. | ⏳ cache the generated buffers |
| 25 | The sweep timer wakes every 5 s even with no sessions. | ⏳ suspend when the list is empty |

## Build and release

| # | Issue | Status |
|---|---|---|
| 26 | `SWIFT_VERSION: 5.9` isn't a language mode; Info.plist said macOS 14 while the build targets macOS 15. | ✅ Swift 5 mode, macOS 15 everywhere |
| 27 | `setup.sh` didn't build anything and pointed at a wrong output path. `rebuild.sh` deleted the old app before the new one was ready. | ✅ `install.sh` builds both targets and swaps the app only after a successful build; `uninstall.sh` added |
| 28 | No README, LICENSE or CI. | ✅ README, MIT license, GitHub Actions (build + helper + hook-installer tests) |
| 29 | No signed, notarized download for people without Xcode. | ⏳ release workflow: Developer ID sign → notarize → staple → upload a zip |
| 30 | No unit tests for the session state machine. | ⏳ extract a pure reducer and test it with recorded hook payloads |

## Second review of the fixes (Codex)

After the fixes above, Codex reviewed the changes again and found 14 more problems. All of them were fixed before release:

| Issue | Fix |
|---|---|
| Approve checked only the front *app*, not the exact window, and didn't re-check the request | It keeps the matched window and types only if that exact window is focused, the session is still waiting, the request is unchanged and the feature is still on. State changes come only from the next hook. |
| An app whose windows couldn't be read was treated as "no match" | Approve fails closed if any terminal can't be inspected |
| Unrelated notifications (login, quota…) reset a session to idle; invalid input created a fake "waiting" row | The helper ignores them |
| Questions (`elicitation_dialog`) showed an Approve button | They show **Open**: a typed answer is needed |
| A replaced history file could be read from the old offset; a deleted file kept old numbers | Tracks the file's inode; shows zero when the file is gone |
| Queued sound timers could restart a knock after muting or cut off a new whistle | Generation counter on every timer |
| The floating panel showed at launch even when hidden | Respects the saved setting |
| An unreadable or empty `settings.json` could be overwritten | Only a *missing* file is created; anything else is left alone |
| The hook installer matched any command containing "claude-notify" and could remove user hooks | Matches only exact helper commands; untouched groups are kept byte-for-byte; paths are shell-quoted; symlinked settings are followed |
| `install.sh` accepted unknown flags and replaced the app before checking settings | Flags validated, settings checked first, old app kept until the new one is in place |
| A CI build failure could be hidden by a pipe | `set -o pipefail` |
| Three README claims didn't match the app | Corrected |

## Feature roadmap

Ranked by value to users. Items marked 🧭 also need the cross-platform core.

1. **Signed download** (no Xcode needed) plus Homebrew cask `brew install --cask claude-menu-bar`.
2. **Session recovery after restart** 🧭: helper writes small state files, the app reloads them on launch.
3. **Exact "Open session"**: target the exact terminal tab or pane (iTerm2 and Terminal scripting, VS Code URI, tmux pane) instead of matching window titles.
4. **Hook doctor**: a menu item that checks the hooks, sends a test event and shows the last event per session.
5. **Per-project alert settings**: mute sounds or banners per project; quiet hours.
6. **Keyboard shortcut**: show or hide the panel and jump to the waiting session.
7. **Compact mode and reduced motion**: icon-only panel; respect "Reduce motion".
8. **Per-session usage**: prompts and duration per session, plus time spent waiting for you.
9. **Localization**: Nepali and Hindi first.
10. **Windows and Linux** 🧭: see [CROSS_PLATFORM.md](CROSS_PLATFORM.md).
