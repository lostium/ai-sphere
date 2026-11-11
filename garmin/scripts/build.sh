#!/bin/sh
# Build AI Sphere for the Epix Pro (Gen 2) 51 mm.
#
#   scripts/build.sh            personal build: embeds the Bunny URL and X-Key as default settings
#   scripts/build.sh release    empty defaults (to be set from Garmin Connect, e.g. for a store build)
#
# Output: bin/AISphere.prg. The URL and the X-Key reference come from the publisher's config
# (~/.config/ai-sphere/publish.json); both end up only in build/ and bin/, which are not committed.
set -eu

MODE="${1:-personal}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CIQ="$HOME/Library/Application Support/Garmin/ConnectIQ"
SDK="$(cat "$CIQ/current-sdk.cfg")"
KEY="${CIQ_DEVELOPER_KEY:-$HOME/.config/connectiq/developer_key.der}"
DEVICE="${DEVICE:-epix2pro51mm}"

[ -f "$KEY" ] || { echo "Developer key not found: $KEY (see garmin/README.md)" >&2; exit 1; }

URL=""
XKEY=""
if [ "$MODE" = "personal" ]; then
  # Same source of truth as the publisher: ~/.config/ai-sphere/publish.json (or the older bunny.json).
  SYNC="$HERE/../mac/aisphere_sync.py"
  URL="$(/usr/bin/python3 "$SYNC" --public-url)"
  REF="$(/usr/bin/python3 "$SYNC" --watch-key-ref)"
  [ -n "$URL" ] || { echo "No publicUrl in the publish config (see hosting/README.md)." >&2; exit 1; }
  case "$URL" in https://*) ;; *) echo "The watch needs HTTPS; publicUrl is: $URL" >&2; exit 1 ;; esac
  case "$REF" in
    env:*) XKEY="$(printenv "${REF#env:}")" ;;
    *)     XKEY="$(security find-generic-password -s "${REF#keychain:}" -w)" ;;
  esac
fi

mkdir -p "$HERE/build/resources" "$HERE/bin"
umask 077
cat > "$HERE/build/resources/properties.xml" <<EOF
<properties>
    <property id="dataUrl" type="string">$URL</property>
    <property id="accessKey" type="string">$XKEY</property>
    <property id="refreshMinutes" type="number">15</property>
</properties>
EOF

"$SDK/bin/monkeyc" -f "$HERE/monkey.jungle" -d "$DEVICE" -y "$KEY" -o "$HERE/bin/AISphere.prg" -w
echo "Built ($MODE): $HERE/bin/AISphere.prg"
