# State-file protocol (v1)

How the hook helper (`claude-notify`) tells the app what each Claude Code session is doing. The same protocol is used on macOS, Windows and Linux:

- The **macOS** helper is Swift (`Sources/CLI`).
- The **Windows and Linux** helper is Rust (`crossplatform/notify`).

Both must pass the shared test cases in `protocol/vectors.json`, run by `protocol/run_vectors.py`.

## Sessions folder

The first of these that applies:

1. `$CLAUDE_MENUBAR_DIR` (an absolute path; used for tests and for WSL, see below)
2. Windows: `%LOCALAPPDATA%\ClaudeMenuBar\sessions`
3. macOS and Linux: `~/.claude-menubar/sessions`

The helper creates it if it's missing (mode `0700` on Unix).

## One file per session

`<session_id>.json`. The `session_id` must match `^[A-Za-z0-9_-]{1,100}$`; anything else is ignored.

```json
{
  "v": 1,
  "session_id": "8f9c…",
  "state": "waiting",
  "kind": "approval",
  "request": "Bash",
  "cwd": "/Users/me/code/my-app",
  "transcript_path": "/Users/me/.claude/projects/-Users-me-code-my-app/8f9c….jsonl",
  "event": "PermissionRequest",
  "ts": 1764061234567
}
```

| Field | Rule |
|---|---|
| `v` | always `1` |
| `state` | `running`, `waiting`, `done` or `idle` |
| `kind` | only when `state` is `waiting`: `approval` (yes/no) or `question` (needs a typed answer) |
| `request` | only when `state` is `waiting` and known: the tool name, at most 40 characters |
| `cwd`, `transcript_path` | copied from the hook payload when present, at most 1024 characters, otherwise omitted |
| `event` | the payload's `hook_event_name` (at most 40 chars), or omitted |
| `ts` | Unix time in **milliseconds**, taken when the helper starts |

## Writing

1. Write to a temporary file in the same folder (a name starting with `.`, ending in `.tmp`).
2. If `<id>.json` already exists and its `ts` is **greater** than ours, delete the temp file and stop. A newer event already won; this handles hooks that finish out of order.
3. Rename the temp file over `<id>.json` (atomic on every OS; on Windows use replace-existing).

`end` deletes `<id>.json` (a missing file is fine).

The helper prints nothing to stdout when stdin is piped, always exits 0 for valid commands, and should finish within about 50 ms.

On macOS the helper then also posts the distributed notification `com.claudemenubar.changed` (no payload) so the app rescans instantly; the folder watcher is the fallback.

## From hook to file

Command line: `claude-notify <running|waiting|done|idle|end>`. The hook JSON is on stdin.

1. **No stdin (run by hand in a terminal):** use session id `manual`, no other fields. This is for testing.
2. **Piped stdin that isn't a JSON object:** do nothing.
3. **Payload without a valid `session_id`:** do nothing.
4. `end`: delete the file.
5. `running`, `done`, `idle`: write that state.
6. `waiting`:
   - `hook_event_name == "PermissionRequest"` → `kind: approval`, `request` = `tool_name`.
   - Otherwise, if `notification_type` is present:
     - `permission_prompt` → `kind: approval`, `request` = the text after `to use ` in `message`, trimmed of whitespace and `.,:;`.
     - `elicitation_dialog`, `agent_needs_input` → `kind: question`.
     - anything else (login, quota, idle reminders…) → do nothing.
   - Otherwise, if `message` contains `permission` (any case) → `kind: approval`, `request` from the message as above.
   - Otherwise → do nothing.

## Reading (apps)

- Ignore files that don't parse, have `v != 1`, or whose name doesn't equal `session_id` + `.json`. Ignore temp files (leading `.`).
- Keep the last applied `ts` per session id. Apply a file only if its `ts` is newer. A session that the app dropped by itself (see ageing) is not re-added by the same old file.
- A file that disappears means the session ended: remove it.
- On app start, load every file **silently** (no sounds, no banners), using `ts` as the last activity time.
- Ageing (same on all platforms): `done` becomes `idle` after 30 s; `idle` is dropped after 10 min; `running` is dropped after 30 min without events (crash cleanup); `waiting` is kept.
- Files whose `ts` is older than 24 hours are deleted by the app (re-read just before deleting, in case the file changed).

## WSL

When Claude Code runs inside WSL and the app runs on Windows, the hook command sets the folder explicitly:

```
CLAUDE_MENUBAR_DIR='/mnt/c/Users/<you>/AppData/Local/ClaudeMenuBar/sessions' '/home/<you>/.local/bin/claude-notify' running
```

`claude-notify install-hooks --wsl` writes hooks in this form.
