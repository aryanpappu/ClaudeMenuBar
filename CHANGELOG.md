# Changelog

## 1.1.0 (2026-11-25): first public release

### Fixed
- The hook helper no longer prints anything when run as a hook. Its output was being added to Claude's context on every prompt.
- Hooks are about 3× faster (30 ms wait instead of 150 ms).
- "Waiting" now comes from `notification_type` and the `PermissionRequest` hook instead of English text matching. Unrelated notifications and invalid input are ignored.
- The model switch writes `settings.json` atomically and never overwrites a file it can't read.
- Prompt counting reads only new lines of `history.jsonl` and copes with the file being replaced or deleted.
- The audio engine runs only while a sound plays.
- Model buttons no longer truncate; the floating panel comes back after a display is unplugged.

### Changed
- One-Click Approve is now opt-in. By default the button is **Open**, which only brings the terminal forward. When on, Approve types only into exactly one matching window, after re-checking it.
- Banners no longer show prompt text unless **Show Prompt in Banners** is on.
- "This Session" is renamed **Today**.
- Builds are ad-hoc signed by default. A personal identity goes in `Config/Signing.local.xcconfig`.
- Debug "Force" buttons appear only in Debug builds.

### Added
- Model option **Auto** (removes the `model` key).
- Settings are remembered: mute, rain, panel, notifications, sections.
- `install.sh`, `uninstall.sh` and `scripts/hooks.py`, which add or remove all six hooks safely.
- README, MIT license, CI, `docs/REVIEW.md`, `docs/CROSS_PLATFORM.md`.

## 1.0.0
- Private version: multi-session panel, sounds, notifications, app icon.
