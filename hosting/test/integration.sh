#!/bin/sh
# End-to-end test of every upload target against local servers in Docker:
#
#   s3       → Versity S3 gateway (S3-compatible, same API as Cloudflare R2 / AWS S3 / Backblaze B2)
#   sftp     → OpenSSH (atmoz/sftp)   → served by nginx with hosting/web-server/nginx.conf
#   ftp      → Pure-FTPd with TLS     → served by Apache with hosting/web-server/apache.htaccess
#   webdav   → Apache WebDAV (PUT + MOVE), Basic auth
#   command  → `cp` into the nginx folder
#   file     → local copy into the nginx folder
#
# Everything binds to 127.0.0.1, uses throwaway credentials and keys created in a temporary folder,
# and is removed at the end (KEEP=1 leaves them running for debugging). Nothing touches your Keychain, ~/.ssh or ~/.config/ai-sphere.
# Usage: hosting/test/integration.sh            (needs Docker; first run pulls the images)
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PY=/usr/bin/python3
W="$(mktemp -d)"
P=ais-it
NET=$P-net
NAMES="$P-nginx $P-apache $P-sftp $P-ftp $P-s3 $P-webdav"

cleanup() {
  [ "${KEEP:-}" = 1 ] && { echo "KEEP=1: containers and $W left in place"; return; }
  for n in $NAMES; do docker rm -f "$n" >/dev/null 2>&1 || true; done
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$W"
}
# Leftovers from an earlier KEEP=1 run
for n in $NAMES; do docker rm -f "$n" >/dev/null 2>&1 || true; done
docker network rm "$NET" >/dev/null 2>&1 || true
trap cleanup EXIT INT TERM

rand() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }
export AIS_WATCH_KEY="$(rand 32)" AIS_FTP_PASS="$(rand 20)" AIS_S3_KEY="ais$(rand 12)" AIS_S3_SECRET="$(rand 32)" AIS_DAV_PASS="$(rand 20)"

mkdir -p "$W/www-nginx" "$W/www-apache" "$W/ftp" "$W/conf"
chmod 777 "$W/www-nginx" "$W/www-apache"
docker network create "$NET" >/dev/null

# ---- nginx with the repo's snippet
sed "s/CHANGE_ME/$AIS_WATCH_KEY/" "$ROOT/hosting/web-server/nginx.conf" > "$W/conf/snippet.inc"
cat > "$W/conf/default.conf" <<EOF
server { listen 80; root /srv/www; include /etc/nginx/conf.d/snippet.inc; }
EOF
docker run -d --name $P-nginx --network $NET -p 127.0.0.1:18080:80 \
  -v "$W/www-nginx:/srv/www:ro" -v "$W/conf/default.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$W/conf/snippet.inc:/etc/nginx/conf.d/snippet.inc:ro" nginx:1.27-alpine >/dev/null

# ---- Apache with the repo's .htaccess
sed "s/CHANGE_ME/$AIS_WATCH_KEY/" "$ROOT/hosting/web-server/apache.htaccess" > "$W/www-apache/.htaccess"
docker run -d --name $P-apache --network $NET -p 127.0.0.1:18081:80 \
  -v "$W/www-apache:/usr/local/apache2/htdocs" httpd:2.4-alpine \
  sh -c "sed -i -e 's/AllowOverride None/AllowOverride All/' -e 's/^#LoadModule headers_module/LoadModule headers_module/' conf/httpd.conf && httpd-foreground" >/dev/null

# ---- SFTP (key only), writing into the nginx folder
ssh-keygen -q -t ed25519 -N "" -C ais-test -f "$W/id_test"
docker run -d --name $P-sftp --network $NET -p 127.0.0.1:12222:22 \
  -v "$W/id_test.pub:/home/ais/.ssh/keys/id_test.pub:ro" -v "$W/www-nginx:/home/ais/www" \
  --platform linux/amd64 atmoz/sftp:alpine ais::1001 >/dev/null

# ---- FTPS (Pure-FTPd, TLS required), writing into the Apache folder
docker run -d --name $P-ftp --network $NET -p 127.0.0.1:12121:21 -p 127.0.0.1:30000-30009:30000-30009 \
  -e PUBLICHOST=127.0.0.1 -e FTP_USER_NAME=ais -e FTP_USER_PASS="$AIS_FTP_PASS" -e FTP_USER_HOME=/home/ais \
  -e ADDED_FLAGS="--tls=2" -e TLS_CN=localhost -e TLS_ORG=ais-test -e TLS_C=ES -e TLS_USE_DSAPRAM=true \
  -v "$W/www-apache:/home/ais" --platform linux/amd64 stilliard/pure-ftpd >/dev/null

# ---- S3-compatible server (Versity gateway over a plain folder; buckets are folders)
docker run -d --name $P-s3 --network $NET -p 127.0.0.1:19000:7070 \
  -e ROOT_ACCESS_KEY="$AIS_S3_KEY" -e ROOT_SECRET_KEY="$AIS_S3_SECRET" \
  --entrypoint sh versity/versitygw:latest -c "mkdir -p /data/ais-test && exec versitygw --port :7070 posix /data" >/dev/null

# ---- WebDAV
docker run -d --name $P-webdav --network $NET -p 127.0.0.1:18082:80 \
  -e AUTH_TYPE=Basic -e USERNAME=ais -e PASSWORD="$AIS_DAV_PASS" --platform linux/amd64 bytemark/webdav >/dev/null

echo "waiting for the servers…"
wait_port() { i=0; until nc -z 127.0.0.1 "$1" 2>/dev/null; do i=$((i+1)); [ $i -lt 60 ] || { echo "port $1 never opened" >&2; exit 1; }; sleep 1; done; }
for port in 18080 18081 12222 12121 19000 18082; do wait_port $port; done
# A published port accepts connections before the server inside is ready: wait for real HTTP answers.
wait_http() { i=0; until [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$1")" != 000 ]; do i=$((i+1)); [ $i -lt 60 ] || { echo "$1 never answered" >&2; exit 1; }; sleep 1; done; }
for u in http://127.0.0.1:18080/ http://127.0.0.1:18081/ http://127.0.0.1:19000/ http://127.0.0.1:18082/; do wait_http $u; done
# Pure-FTPd generates its TLS certificate on start: wait for its 220 greeting, not just the open port.
i=0; until $PY -c "import socket,sys;s=socket.create_connection(('127.0.0.1',12121),3);s.settimeout(3);sys.exit(0 if s.recv(64).startswith(b'220') else 1)" 2>/dev/null; do
  i=$((i+1)); [ $i -lt 90 ] || { echo "FTP server never greeted" >&2; exit 1; }; sleep 1; done
sleep 2
ssh-keyscan -p 12222 127.0.0.1 2>/dev/null > "$W/known_hosts"
docker exec $P-ftp sh -c "cat /etc/ssl/private/pure-ftpd.pem" | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > "$W/ftp-ca.pem"

t() { printf '%s' "$2" > "$W/$1.json"; }
t s3      '{"type":"s3","endpoint":"http://127.0.0.1:19000","region":"us-east-1","bucket":"ais-test","key":"usage.json","accessKeyId":"env:AIS_S3_KEY","secretAccessKey":"env:AIS_S3_SECRET"}'
t sftp    "{\"type\":\"sftp\",\"host\":\"127.0.0.1\",\"port\":12222,\"user\":\"ais\",\"path\":\"www/usage.json\",\"identityFile\":\"$W/id_test\",\"knownHostsFile\":\"$W/known_hosts\"}"
t ftp     "{\"type\":\"ftp\",\"host\":\"localhost\",\"port\":12121,\"user\":\"ais\",\"password\":\"env:AIS_FTP_PASS\",\"path\":\"usage.json\",\"caFile\":\"$W/ftp-ca.pem\"}"
t webdav  '{"type":"http","url":"http://127.0.0.1:18082/usage.json","username":"ais","password":"env:AIS_DAV_PASS","webdavMove":true}'
t command "{\"type\":\"command\",\"command\":[\"cp\",\"{file}\",\"$W/www-nginx/usage.json\"]}"
t file    "{\"type\":\"file\",\"path\":\"$W/www-nginx/usage.json\"}"

fail=0
run() { $PY "$ROOT/hosting/test/roundtrip.py" "$@" || fail=1; }
run --name "s3 (Versity)"         --target "$W/s3.json" --read-s3
run --name "sftp -> nginx"         --target "$W/sftp.json"    --read-url http://127.0.0.1:18080/usage.json --watch-key env:AIS_WATCH_KEY
run --name "ftps -> apache"        --target "$W/ftp.json"     --read-url http://127.0.0.1:18081/usage.json --watch-key env:AIS_WATCH_KEY
run --name "webdav (PUT + MOVE)"   --target "$W/webdav.json"
run --name "command (cp) -> nginx" --target "$W/command.json" --settle 3 --read-url http://127.0.0.1:18080/usage.json --watch-key env:AIS_WATCH_KEY
run --name "file -> nginx"         --target "$W/file.json"    --settle 3 --read-url http://127.0.0.1:18080/usage.json --watch-key env:AIS_WATCH_KEY

# WebDAV read-back (the server checks Basic auth, not X-Key)
code=$(curl -s -o "$W/dav.json" -w '%{http_code}' -u "ais:$AIS_DAV_PASS" http://127.0.0.1:18082/usage.json)
if [ "$code" = 200 ] && grep -q '"run":2' "$W/dav.json"; then echo "  ok   webdav GET returns the second upload"; else echo "  FAIL webdav GET ($code)"; fail=1; fi

echo
[ $fail = 0 ] && echo "ALL TARGETS OK" || { echo "SOME TARGETS FAILED" >&2; exit 1; }
