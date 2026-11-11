#!/bin/sh
# Look for personal or secret data in the files git would publish (tracked + new, not ignored).
# Run it before every push. Prints file:line for each hit, never the matched secret itself.
#
#   tools/check-private.sh            names, e-mail, home path, your CDN host, common secret formats
#   tools/check-private.sh --secrets  also the values of the Keychain items (asks macOS for access)
set -eu
cd "$(dirname "$0")/.."

FILES="$(mktemp)"; trap 'rm -f "$FILES"' EXIT
git ls-files -co --exclude-standard -z > "$FILES"
hits=0

scan() {  # scan <label> <fixed string>
  [ -n "$2" ] || return 0
  out="$(xargs -0 grep -nIF -e "$2" -- < "$FILES" 2>/dev/null | cut -d: -f1,2 || true)"
  if [ -n "$out" ]; then echo "[$1]"; echo "$out" | sed 's/^/  /'; hits=1; fi
}
scan_re() {  # scan_re <label> <extended regex>
  out="$(xargs -0 grep -nIE -e "$2" -- < "$FILES" 2>/dev/null | cut -d: -f1,2 || true)"
  if [ -n "$out" ]; then echo "[$1]"; echo "$out" | sed 's/^/  /'; hits=1; fi
}

scan "macOS user name" "$(id -un)"
scan "full name" "$(id -F 2>/dev/null || true)"
scan "git e-mail" "$(git config user.email 2>/dev/null || true)"
scan "home folder" "$HOME"
URL="$(/usr/bin/python3 mac/aisphere_sync.py --public-url 2>/dev/null || true)"
HOST="$(printf '%s' "$URL" | sed -E 's#^[a-z]+://([^/]+).*#\1#')"
scan "hosting host name" "$HOST"

# E-mail addresses, except the reserved example domains used in docs and fixtures.
out="$(xargs -0 grep -noIE -e '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}' -- < "$FILES" 2>/dev/null \
  | grep -vE '@([a-z0-9-]+\.)*example\.(com|org|net)$' | cut -d: -f1,2 || true)"
if [ -n "$out" ]; then echo "[e-mail address]"; echo "$out" | sed 's/^/  /'; hits=1; fi
scan_re "JWT" 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.'
scan_re "AWS access key id" 'AKIA[0-9A-Z]{16}'
scan_re "private key" 'BEGIN [A-Z ]*PRIVATE KEY'
scan_re "Bunny/API key shape" '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[0-9a-f-]{20,}'

if [ "${1:-}" = "--secrets" ]; then
  # Each secret goes to grep in a pattern file (mode 600), never on a command line.
  PAT="$(mktemp)"; chmod 600 "$PAT"; trap 'rm -f "$FILES" "$PAT"' EXIT
  for item in ai-sphere-watch-key ai-sphere-bunny-storage ai-sphere-helmcode-cookie bunny-access-key; do
    /usr/bin/security find-generic-password -s "$item" -w 2>/dev/null | head -c 24 > "$PAT" || true
    [ -s "$PAT" ] || continue
    out="$(xargs -0 grep -nIF -f "$PAT" -- < "$FILES" 2>/dev/null | cut -d: -f1,2 || true)"
    if [ -n "$out" ]; then echo "[Keychain $item]"; echo "$out" | sed 's/^/  /'; hits=1; fi
  done
fi

if [ $hits = 0 ]; then echo "No personal data or secrets found."; else
  echo; echo "Review the hits above. Example domains (example.com…) are already allowed." >&2; exit 1; fi
