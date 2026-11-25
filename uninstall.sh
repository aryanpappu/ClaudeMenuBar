#!/bin/bash
# Removes Claude Menu Bar: its hooks (other hooks are kept), the helper and the app.
set -euo pipefail
cd "$(dirname "$0")"
echo "→ Removing Claude Code hooks"
python3 scripts/hooks.py uninstall
pkill -x ClaudeMenuBar 2>/dev/null || true
rm -f "$HOME/.local/bin/claude-notify"
rm -rf "$HOME/Applications/ClaudeMenuBar.app"
rm -rf "$HOME/.claude-menubar"   # session state files
defaults delete com.claudemenubar.app >/dev/null 2>&1 || true
echo "✓ Uninstalled."
