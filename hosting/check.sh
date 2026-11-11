#!/bin/sh
# Check the hosting end to end, for any target: the X-Key rule blocks requests without the key, and the published
# usage.json is served as JSON and is recent. Prints status codes and age only, never the host or key.
# Usage: hosting/check.sh [publish-config.json]   (default: ~/.config/ai-sphere/publish.json or bunny.json)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL="$(/usr/bin/python3 "$ROOT/mac/aisphere_sync.py" ${1:+--publish-config "$1"} --public-url)"
REF="$(/usr/bin/python3 "$ROOT/mac/aisphere_sync.py" ${1:+--publish-config "$1"} --watch-key-ref)"
[ -n "$URL" ] || { echo "No publicUrl in the publish config (see hosting/README.md)." >&2; exit 1; }
case "$REF" in
  env:*) WK="$(printenv "${REF#env:}")" ;;
  *)     WK="$(security find-generic-password -s "${REF#keychain:}" -w)" ;;
esac
case "$URL" in https://*) ;; *) echo "warning: the watch only accepts HTTPS URLs" >&2 ;; esac
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

code() { curl -s -o /dev/null -w "%{http_code}" "$@" "$URL"; }
fail=0
c=$(code);               printf "no key:     %s (expected 403)\n" "$c"; [ "$c" = 403 ] || fail=1
c=$(code -H "X-Key: x"); printf "wrong key:  %s (expected 403)\n" "$c"; [ "$c" = 403 ] || fail=1

c=$(curl -s -D "$TMP/h" -o "$TMP/b" -w "%{http_code}" -H "X-Key: $WK" "$URL")
printf "right key:  %s (expected 200)\n" "$c"; [ "$c" = 200 ] || fail=1
grep -i -E '^(content-type|cache-control):' "$TMP/h" | tr -d '\r' | sed 's/^/  /'
/usr/bin/python3 - "$TMP/b" <<'PY' || fail=1
import json, sys, datetime as dt
d = json.load(open(sys.argv[1]))
t = dt.datetime.strptime(d["t"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
age = (dt.datetime.now(dt.timezone.utc) - t).total_seconds() / 60
print(f"  v{d['v']}, {len(d['p'])} providers [{', '.join(p['n'] for p in d['p'])}], generated {age:.0f} min ago")
if age > 30:
    print("  warning: older than 30 min; is the Mac publishing? (see mac/README.md)")
PY
[ "$fail" = 0 ] && echo "OK" || { echo "FAILED" >&2; exit 1; }
