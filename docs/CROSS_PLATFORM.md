# Claude Menu Bar on Windows and Linux

**Status (v1.2, November 2026):** steps 1–4 below are implemented.

| Step | Done |
|---|---|
| 1. State files | The macOS app and helper use them (`docs/PROTOCOL.md`). Sessions survive an app restart. |
| 2. Helper for every OS | Rust `claude-notify` in `crossplatform/notify`, about 2 ms per hook, passes the same 24 shared tests as the Swift helper. |
| 3. Tray app | Tauri v2 app in `crossplatform/app`. Tested live on Linux (Ubuntu 24.04, ARM64, X11). |
| 4. Packaging | `.github/workflows/crossplatform.yml` builds `.deb`, `.rpm`, `.AppImage`, `.msi` and `-setup.exe`. |

Not yet done:
- Code signing for Windows (SmartScreen will warn).
- Testing on a real Windows 11 machine and on GNOME Wayland. The Windows build is compiled in CI but hasn't been clicked through by a person yet.
- Flatpak and winget packages.

The rest of this page is the original plan, kept for the reasoning behind it.

## What ties it to macOS today

| Part | macOS technology | Problem elsewhere |
|---|---|---|
| Messages from hooks to app | `DistributedNotificationCenter` | Doesn't exist on Windows or Linux |
| Hook helper `claude-notify` | Swift + Foundation | Swift on Windows/Linux has no distributed notifications |
| Menu bar icon | `NSStatusItem` | Windows: system tray. Linux: AppIndicator (GNOME needs an extension) |
| Floating panel | `NSPanel`, always on top | Windows: fine. Linux Wayland: apps can't choose their own window position |
| Bring terminal to front | Accessibility API (`AXUIElement`) | Windows: limited by focus-stealing rules. Linux X11: possible. Wayland: mostly not possible |
| One-Click Approve (typing keys) | `CGEvent` | Windows: `SendInput` works but is risky. Wayland: not possible |
| Sounds | `AVAudioEngine` | Needs a cross-platform audio library |
| Notifications | `UserNotifications` | Windows toast / Linux libnotify |
| Launch at login | `SMAppService` | Windows registry Run key / Linux XDG autostart |

The logic itself (sessions, states, sweep rules, history counting) is plain code and can be shared.

## Step 1: a platform-neutral message channel (do this first, on macOS too)

Replace the distributed notification with **state files**. Every OS has files, and this also fixes "sessions are forgotten when the app restarts" (review issue 14).

```
~/.claude-menubar/sessions/<session_id>.json      (Windows: %LOCALAPPDATA%\ClaudeMenuBar\sessions\)
{ "v": 1, "seq": 42, "state": "waiting", "cwd": "...", "request": "Bash", "ts": 1764061234567 }
```

- The helper writes the file atomically (temp file + rename) and deletes it on `SessionEnd`.
- The app watches the folder: FSEvents on macOS, `ReadDirectoryChangesW` on Windows, inotify on Linux. On launch it reads every file, so sessions survive an app restart.
- `seq` and `ts` solve the out-of-order problem (issue 13): ignore an event older than the one already shown.
- Optional: keep sending the distributed notification on macOS as a faster "wake up" signal.

**WSL note:** Claude Code often runs inside WSL on Windows. The helper inside WSL can write to the Windows folder through `/mnt/c/Users/<you>/AppData/Local/ClaudeMenuBar/sessions/`. The installer should detect WSL and set this path.

## Step 2: one hook helper for every OS

Rewrite `claude-notify` in **Go** (or Rust): one small static binary per OS and CPU, starting in a few milliseconds, cross-compiled from one machine.

- Same arguments (`running | waiting | done | idle | end`) and the same rules: fast, silent on stdout, always exit 0.
- Builds: `darwin/arm64`, `darwin/amd64`, `windows/amd64`, `windows/arm64`, `linux/amd64`, `linux/arm64`.
- The installer adds hooks with the right path for each OS (`claude-notify.exe` on Windows).

## Step 3: the tray app for Windows and Linux

Two good options:

| | **Tauri v2** (Rust + web UI) | **Go + systray + Fyne** |
|---|---|---|
| Size | about 5–10 MB | about 15–25 MB |
| Tray, notifications, autostart | official plugins | libraries, more glue |
| Panel UI | HTML/CSS, easy to match the current design | Fyne widgets, plainer look |
| Shared with the helper | no (Rust vs Go) unless the helper is written in Rust | yes, one Go codebase |

**Recommendation: Tauri v2**, with the helper written in Rust so everything shares one language and the session-state code. Keep the native Swift app on macOS: it's already polished, and a native menu bar app feels better there. Both apps read the same state files, so they behave the same.

### Feature mapping

| Feature | Windows | Linux X11 | Linux Wayland |
|---|---|---|---|
| Tray icon with state | ✅ | ✅ (AppIndicator) | ✅ KDE; GNOME needs the AppIndicator extension |
| Floating panel | ✅ always-on-top window | ✅ | 🟡 shows, but the compositor decides where |
| Banners | ✅ Windows toast | ✅ libnotify | ✅ libnotify |
| Sounds | ✅ | ✅ | ✅ |
| Open session (bring terminal forward) | 🟡 works for Windows Terminal/VS Code; Windows can block focus stealing | ✅ via `wmctrl`/EWMH | ❌ not allowed; show the project path instead |
| One-Click Approve | ❌ not offered (too risky without macOS-style checks) | ❌ | ❌ |
| Launch at login | ✅ | ✅ XDG autostart | ✅ |
| Model switch, usage counts | ✅ same files under `%USERPROFILE%\.claude` | ✅ | ✅ |

## Step 4: packaging

- **Windows:** MSI or NSIS installer from Tauri, plus `winget`. Sign with a code-signing certificate, or SmartScreen will warn users.
- **Linux:** AppImage and `.deb`, later Flatpak. Note that a Flatpak sandbox needs permission for `~/.claude`.
- **macOS:** notarized zip and a Homebrew cask (separate from this plan).
- One GitHub Actions release workflow builds all three on their own runners.

## Effort estimate

| Step | Work |
|---|---|
| 1. State files (helper + macOS app) | 2–3 days |
| 2. Go/Rust helper + cross-compile | 2 days |
| 3. Tauri tray app (tray, panel, banners, sounds, autostart) | 1–2 weeks |
| 4. Installers, signing, CI | 3–5 days |
| Testing on Windows 11, Ubuntu (GNOME Wayland), Fedora/KDE, WSL | 3–4 days |

Start with step 1. It improves the macOS app on its own, and it's the foundation for the rest.
