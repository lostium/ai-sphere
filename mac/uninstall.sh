#!/bin/sh
# Remove the AI Sphere LaunchAgent. Leaves logs, state, config and Keychain items in place.
set -eu

LABEL="local.ai-sphere.sync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
# Also agents installed under an older label.
for old in "$HOME/Library/LaunchAgents/"*aisphere.sync.plist; do
  [ -f "$old" ] || continue
  launchctl bootout "gui/$(id -u)/$(basename "$old" .plist)" 2>/dev/null || true
  rm -f "$old"
done
echo "Uninstalled $LABEL."
echo "Kept: ~/Library/Logs/AI-Sphere, ~/Library/Application Support/AI-Sphere,"
echo "~/.config/ai-sphere and the Keychain items."
