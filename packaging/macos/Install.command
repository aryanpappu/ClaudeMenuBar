#!/bin/bash
# Claude Menu Bar installer for the downloaded zip (macOS 15+).
# Copies the app to ~/Applications and the hook helper to ~/.local/bin, then
# adds the Claude Code hooks (your other settings and hooks are kept).
set -euo pipefail
cd "$(dirname "$0")"
echo "Installing Claude Menu Bar…"
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
pkill -x ClaudeMenuBar 2>/dev/null || true
rm -rf "$HOME/Applications/ClaudeMenuBar.app"
cp -R ClaudeMenuBar.app "$HOME/Applications/"
cp claude-notify "$HOME/.local/bin/claude-notify"
chmod +x "$HOME/.local/bin/claude-notify"
# The build is not notarized: remove the download quarantine so it can open.
xattr -dr com.apple.quarantine "$HOME/Applications/ClaudeMenuBar.app" "$HOME/.local/bin/claude-notify" 2>/dev/null || true
python3 hooks.py install "$HOME/.local/bin/claude-notify"
open "$HOME/Applications/ClaudeMenuBar.app"
echo
echo "✓ Done. Look for the icon in your menu bar. Restart open Claude Code sessions."
echo "  To uninstall: python3 hooks.py uninstall, then delete ~/Applications/ClaudeMenuBar.app"
