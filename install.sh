#!/bin/bash
# Builds Claude Menu Bar from source and installs it for the current user:
#   app    → ~/Applications/ClaudeMenuBar.app
#   helper → ~/.local/bin/claude-notify
#   hooks  → ~/.claude/settings.json (backup first; other settings untouched)
#
# Usage: ./install.sh [--no-hooks] [--dry-run-hooks]
set -euo pipefail
cd "$(dirname "$0")"

HOOKS_MODE=install
case "${1:-}" in
  "") ;;
  --no-hooks) HOOKS_MODE=skip ;;
  --dry-run-hooks) HOOKS_MODE=dry ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  *) echo "✗ Unknown option: $1  (use --no-hooks or --dry-run-hooks)"; exit 2 ;;
esac

APP_DIR="$HOME/Applications"
BIN_DIR="$HOME/.local/bin"
BUILD="$(pwd)/build"

need() { command -v "$1" >/dev/null 2>&1 || { echo "✗ $1 is required. $2"; exit 1; }; }
need xcodebuild "Install Xcode 16 or newer from the App Store."
need python3 "Run: xcode-select --install"
if ! command -v xcodegen >/dev/null 2>&1; then
  need brew "Install Homebrew (https://brew.sh) or XcodeGen manually."
  echo "→ Installing XcodeGen…"; brew install xcodegen
fi

if [ "$HOOKS_MODE" != skip ]; then
  # Check settings.json BEFORE replacing anything, so a broken file can't
  # leave you with a half-finished install.
  python3 scripts/hooks.py check
fi

echo "→ Generating Xcode project"
xcodegen generate --quiet

echo "→ Building (Release)"
for target in ClaudeMenuBar claude-notify; do
  xcodebuild -project ClaudeMenuBar.xcodeproj -target "$target" -configuration Release \
    SYMROOT="$BUILD" -quiet build
done

echo "→ Installing helper to $BIN_DIR/claude-notify"
mkdir -p "$BIN_DIR"
install -m 755 "$BUILD/Release/claude-notify" "$BIN_DIR/claude-notify.new"
mv -f "$BIN_DIR/claude-notify.new" "$BIN_DIR/claude-notify"

echo "→ Installing app to $APP_DIR"
mkdir -p "$APP_DIR"
rm -rf "$APP_DIR/ClaudeMenuBar.app.new"
cp -R "$BUILD/Release/ClaudeMenuBar.app" "$APP_DIR/ClaudeMenuBar.app.new"
pkill -x ClaudeMenuBar 2>/dev/null || true
# Keep the previous app until the new one is in place (rollback on failure).
rm -rf "$APP_DIR/ClaudeMenuBar.app.old"
[ -d "$APP_DIR/ClaudeMenuBar.app" ] && mv "$APP_DIR/ClaudeMenuBar.app" "$APP_DIR/ClaudeMenuBar.app.old"
if mv "$APP_DIR/ClaudeMenuBar.app.new" "$APP_DIR/ClaudeMenuBar.app"; then
  rm -rf "$APP_DIR/ClaudeMenuBar.app.old"
else
  [ -d "$APP_DIR/ClaudeMenuBar.app.old" ] && mv "$APP_DIR/ClaudeMenuBar.app.old" "$APP_DIR/ClaudeMenuBar.app"
  echo "✗ Could not install the new app; the previous version was kept."; exit 1
fi

case "$HOOKS_MODE" in
  skip) echo "→ Skipping hooks (--no-hooks)";;
  dry)  echo "→ Hooks (dry run)"; python3 scripts/hooks.py install "$BIN_DIR/claude-notify" --dry-run;;
  *)    echo "→ Adding Claude Code hooks"; python3 scripts/hooks.py install "$BIN_DIR/claude-notify";;
esac

open "$APP_DIR/ClaudeMenuBar.app"
echo ""
echo "✓ Installed. Look for the brain icon in your menu bar."
echo "  New Claude Code sessions pick up the hooks automatically."
