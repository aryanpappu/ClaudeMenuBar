#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "→ Syncing project..."
xcodegen generate --quiet 2>/dev/null || true

echo "→ Building..."
xcodebuild \
  -project ClaudeMenuBar.xcodeproj \
  -target ClaudeMenuBar \
  -configuration Release \
  SYMROOT="$(pwd)/build" \
  -quiet

echo "→ Installing to ~/Applications..."
pkill -x ClaudeMenuBar 2>/dev/null || true
sleep 0.5
rm -rf ~/Applications/ClaudeMenuBar.app
cp -r build/Release/ClaudeMenuBar.app ~/Applications/ClaudeMenuBar.app

echo "→ Launching..."
open ~/Applications/ClaudeMenuBar.app
sleep 1
pgrep -x ClaudeMenuBar && echo "✓ Running (PID: $(pgrep -x ClaudeMenuBar))" || echo "✗ Failed to start"
