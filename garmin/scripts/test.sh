#!/bin/sh
# Run the Monkey C unit tests (garmin/tests) in the Connect IQ simulator.
# Usage: scripts/test.sh     (starts the simulator if it is not running)
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CIQ="$HOME/Library/Application Support/Garmin/ConnectIQ"
SDK="$(cat "$CIQ/current-sdk.cfg")"
KEY="${CIQ_DEVELOPER_KEY:-$HOME/.config/connectiq/developer_key.der}"
DEVICE="${DEVICE:-epix2pro51mm}"

# Tests do not need the real URL or key.
mkdir -p "$HERE/build/resources" "$HERE/bin"
[ -f "$HERE/build/resources/properties.xml" ] || cat > "$HERE/build/resources/properties.xml" <<XML
<properties>
    <property id="dataUrl" type="string"></property>
    <property id="accessKey" type="string"></property>
    <property id="refreshMinutes" type="number">15</property>
</properties>
XML

"$SDK/bin/monkeyc" -f "$HERE/monkey.jungle" -d "$DEVICE" -y "$KEY" -o "$HERE/bin/AISphere-test.prg" -t -w
pgrep -f "ConnectIQ.app" >/dev/null || { open "$SDK/bin/ConnectIQ.app"; sleep 5; }
"$SDK/bin/monkeydo" "$HERE/bin/AISphere-test.prg" "$DEVICE" -t
