#!/bin/bash
set -euo pipefail

echo "→ ClaudeMenuBar setup"

# 1. XcodeGen
if ! command -v xcodegen &>/dev/null; then
  echo "→ Installing xcodegen..."
  brew install xcodegen
fi

# 2. Generate Xcode project
echo "→ Generating Xcode project..."
xcodegen generate

echo ""
echo "✓ ClaudeMenuBar.xcodeproj created"
echo ""
echo "── Next steps ─────────────────────────────────────────────"
echo ""
echo "1. Open in Xcode:"
echo "   open ClaudeMenuBar.xcodeproj"
echo ""
echo "2. Build & Run the 'ClaudeMenuBar' target (⌘R)"
echo "   The brain icon appears in your menu bar."
echo ""
echo "3. Build the 'claude-notify' CLI target, then install it:"
echo "   xcodebuild -target claude-notify -configuration Release"
echo "   cp .build/Release/claude-notify /usr/local/bin/"
echo ""
echo "4. Add hooks to ~/.claude/settings.json:"
cat << 'JSON'
{
  "hooks": {
    "PreToolUse":  [{ "hooks": [{ "type": "command", "command": "claude-notify running" }] }],
    "Notification":[{ "hooks": [{ "type": "command", "command": "claude-notify waiting" }] }],
    "Stop":        [{ "hooks": [{ "type": "command", "command": "claude-notify done"    }] }]
  }
}
JSON
echo ""
echo "   (Merge with any existing hooks you have.)"
echo ""
echo "── State reference ─────────────────────────────────────────"
echo "  running  →  brain icon pulses blue   (Claude is working)"
echo "  waiting  →  bell badge bounces       (needs your input)"
echo "  done     →  green checkmark (3 sec)  (task finished)"
echo "  idle     →  static brain             (no active session)"
echo "────────────────────────────────────────────────────────────"
