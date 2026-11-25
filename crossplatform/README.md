# Claude Menu Bar for Windows and Linux

A Rust workspace with three crates:

| Crate | What it is |
|---|---|
| `core/` (`claude_menubar_core`) | Shared logic: session files (docs/PROTOCOL.md), hook classification, the session reducer and ageing, hook install/uninstall, prompt counting, model switch. |
| `notify/` (`claude-notify`) | The hook helper. Tiny (about 460 KB) and fast (about 2 ms per hook). Also installs and removes the hooks. |
| `app/src-tauri/` (`claude-menu-bar`) | The tray app, built with Tauri v2. The panel UI is plain HTML/CSS/JS in `app/ui/`, with no npm or bundler. |

The macOS app stays native Swift (`../Sources`). All three apps use the same session files, so they behave the same.

## What works where

| | Windows 10/11 | Linux X11 | Linux Wayland |
|---|---|---|---|
| Tray icon that changes with the state | ✅ | ✅ (AppIndicator) | ✅ KDE; GNOME needs the "AppIndicator" extension |
| Floating panel (always on top, bottom-right) | ✅ | ✅ | 🟡 the compositor may place it elsewhere |
| Banners | ✅ | ✅ | ✅ |
| Sounds (rain, knock, whistle) | ✅ | ✅ | ✅ |
| Model switch, Today / This Week counts | ✅ | ✅ | ✅ |
| Start at login | ✅ | ✅ | ✅ |
| **Open** (bring the session's terminal forward) | ✅ when the window title contains the project name | ✅ needs `wmctrl` | ❌ copies the project path instead |
| One-Click Approve | ❌ macOS only, by design | ❌ | ❌ |

On Linux the tray icon has no separate left-click action; use **Show / hide panel** in its menu.

## Building

Linux needs the WebKitGTK and AppIndicator development packages:

```sh
sudo apt-get install -y build-essential pkg-config libwebkit2gtk-4.1-dev \
  libayatana-appindicator3-dev librsvg2-dev libssl-dev libxdo-dev
cargo install tauri-cli --version "^2" --locked
```

Windows needs the Rust MSVC toolchain and WebView2, which ships with Windows 10/11. Then:

```sh
cd crossplatform
cargo test --workspace
cargo build --release -p claude-notify

# The app ships the helper (Tauri externalBin), named with the target triple:
mkdir -p app/src-tauri/binaries
cp target/release/claude-notify app/src-tauri/binaries/claude-notify-$(rustc -vV | sed -n 's/host: //p')
#   (Windows: claude-notify.exe → claude-notify-x86_64-pc-windows-msvc.exe)

cd app/src-tauri && cargo tauri build     # → target/release/bundle/{deb,rpm,appimage,msi,nsis}
```

CI (`.github/workflows/crossplatform.yml`) does all of this on Ubuntu, Windows and macOS. It runs the shared protocol tests and uploads the installers as artifacts. A `v*` tag attaches them to a draft GitHub release.

Shared protocol tests, from the repository root:

```sh
python3 protocol/run_vectors.py crossplatform/target/release/claude-notify   # add .exe on Windows
```

## Hooks

Use the tray menu's **Set up Claude Code hooks** item. It copies the bundled helper to a fixed place, then adds the six hooks to `~/.claude/settings.json` (backup first, other hooks kept):

- Windows: `%LOCALAPPDATA%\ClaudeMenuBar\bin\claude-notify.exe`
- Linux: `~/.local/bin/claude-notify`

A fixed place matters because an AppImage runs from a new path every time. **Remove Claude Code hooks** undoes it.

The helper can also do this from a terminal:

```sh
claude-notify install-hooks [--dry-run]      # hooks point at this binary's path
claude-notify install-hooks --wsl            # inside WSL, when the app runs on Windows
claude-notify uninstall-hooks [--dry-run]
claude-notify check-hooks
```

### WSL

If Claude Code runs inside WSL and the app runs on Windows:

1. Copy the Linux `claude-notify` into WSL, for example `~/.local/bin/`.
2. Run `claude-notify install-hooks --wsl` there.

The hooks then write to the Windows sessions folder (`/mnt/c/Users/<you>/AppData/Local/ClaudeMenuBar/sessions`).

## Testing the app without Claude Code

```sh
echo '{"session_id":"demo","cwd":"/tmp/my-app","hook_event_name":"PermissionRequest","tool_name":"Bash"}' \
  | target/release/claude-notify waiting
echo '{"session_id":"demo"}' | target/release/claude-notify end
```

Headless Linux (as used to test this app): start `Xvfb :99`, run the app with `DISPLAY=:99 dbus-run-session -- target/debug/claude-menu-bar`, and screenshot with `DISPLAY=:99 import -window root shot.png`.
