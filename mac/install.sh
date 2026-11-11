#!/bin/sh
# Install (or reinstall) the AI Sphere sync as a per-user LaunchAgent.
# Usage: mac/install.sh [interval-seconds]   (default 600 = 10 minutes)
set -eu

LABEL="local.ai-sphere.sync"
INTERVAL="${1:-600}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/aisphere_sync.py"
TEMPLATE="$HERE/ai-sphere.sync.plist.template"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"
LOGDIR="$HOME/Library/Logs/AI-Sphere"
DOMAIN="gui/$(id -u)"

case "$INTERVAL" in
  ''|*[!0-9]*) echo "The interval must be a number of seconds." >&2; exit 1 ;;
esac
if [ "$INTERVAL" -lt 300 ]; then
  echo "Minimum interval: 300 seconds (5 minutes)." >&2; exit 1
fi

# Preconditions: an upload target config and codexbar. The target's secrets are checked on the first run
# (see ~/Library/Logs/AI-Sphere/sync.log).
/usr/bin/python3 "$SCRIPT" --public-url >/dev/null 2>&1 \
  || { echo "No upload target configured: create ~/.config/ai-sphere/publish.json (see hosting/README.md)." >&2; exit 1; }
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" command -v codexbar >/dev/null 2>&1 \
  || { echo "codexbar CLI not found (install CodexBar and its CLI)." >&2; exit 1; }

# The paths go into the plist through sed and XML: refuse characters that would break either.
case "$SCRIPT$LOGDIR" in
  *'|'*|*'&'*|*'<'*|*'>'*) echo "The project path contains | & < or >; move it to a plain path." >&2; exit 1 ;;
esac

mkdir -p "$AGENTS" "$LOGDIR"
chmod +x "$SCRIPT"

sed -e "s|__SCRIPT__|$SCRIPT|g" \
    -e "s|__INTERVAL__|$INTERVAL|g" \
    -e "s|__LOGDIR__|$LOGDIR|g" \
    "$TEMPLATE" > "$PLIST.tmp"
plutil -lint "$PLIST.tmp" >/dev/null
mv "$PLIST.tmp" "$PLIST"

# Remove agents installed under an older label (any "*aisphere.sync" other than this one).
for old in "$AGENTS"/*aisphere.sync.plist; do
  [ -f "$old" ] && [ "$old" != "$PLIST" ] || continue
  launchctl bootout "$DOMAIN/$(basename "$old" .plist)" 2>/dev/null || true
  rm -f "$old"
  echo "Removed older agent $(basename "$old" .plist)."
done

# Reload if it was already installed.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL"

echo "Installed $LABEL: every $INTERVAL s."
echo "Log: $LOGDIR/sync.log"
echo "Run it now: launchctl kickstart -k $DOMAIN/$LABEL"
