# Bunny CDN

The publisher uploads `usage.json` to a Bunny **storage zone**, and a **pull zone** (the CDN) serves it to the watch. The zones are created once, by hand or with Bunny's API; this is the setup guide. Status: in daily use since November 2026.

```
Mac (script) ── PUT + AccessKey ──▶ Storage zone
                                          │
                                          ▼
Watch ── GET + X-Key ──▶ Pull zone <random-name>.b-cdn.net ── 403 without X-Key
```

## Why this design

- **Outgoing connections only:** the Mac uploads with a `PUT`; nothing listens at home.
- **Random host plus a secret header:** a long random host name means nobody stumbles on the file. The `X-Key` header means it cannot be read even if the host is known. Connect IQ can send custom headers with `Communications.makeWebRequest`, so no URL signing is needed on the watch.
- **60 s cache:** the Mac uploads every 10 minutes and the watch polls every 15, so one minute of delay is invisible and no cache purge is needed after each upload (a purge would need the account API key on every run).
- **If the Mac is off,** the CDN keeps serving the last file.
- **Cost:** a standard storage zone without replicas plus a 1–2 KB file requested 100–150 times a day is negligible.

## Setup

The steps below use the Bunny API with your account API key (Account → API). Everything can also be done in the Bunny dashboard. If your account has other zones, only touch the ones you create here.

```sh
API=$(security find-generic-password -s bunny-access-key -w)   # your account API key, stored once in the Keychain
```

### 1. Storage zone

```sh
curl -s -X POST https://api.bunny.net/storagezone -H "AccessKey: $API" -H "Content-Type: application/json" \
  -d '{"Name":"ais-<random>","Region":"DE","ZoneTier":0}'
```

Storage zone names are unique across all of Bunny, so pick a random one (e.g. `ais-` plus a few random characters).

Note the `Id` and `Password` in the response. Store the password (used for uploads) in the Keychain:

```sh
security add-generic-password -U -s ai-sphere-bunny-storage -a ai-sphere -w   # paste the storage zone password
```

Use a different region if you prefer; the upload host changes accordingly (`storage.bunnycdn.com` for DE, `<region>.storage.bunnycdn.com` otherwise).

### 2. Pull zone with a random name

```sh
NAME="as-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 32)"
curl -s -X POST https://api.bunny.net/pullzone -H "AccessKey: $API" -H "Content-Type: application/json" \
  -d "{\"Name\":\"$NAME\",\"OriginType\":2,\"StorageZoneId\":<storage zone id>}"
```

The CDN host is `$NAME.b-cdn.net`. Keep it out of the repository (it goes in the local config below). Then set the cache to 60 s:

```sh
curl -s -X POST https://api.bunny.net/pullzone/<pull zone id> -H "AccessKey: $API" -H "Content-Type: application/json" \
  -d '{"CacheControlMaxAgeOverride":60,"CacheControlPublicMaxAgeOverride":60}'
```

### 3. The `X-Key` rule

Generate the secret and keep it in the Keychain:

```sh
security add-generic-password -U -s ai-sphere-watch-key -a ai-sphere -w "$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
```

In the dashboard: Pull zone → Edge Rules → Add rule, named for example "ai-sphere: require X-Key header":

- **Action:** Block request.
- **Condition:** Request Header, header name `X-Key`, matching type **Match None**, value `<your secret>` (so any request whose `X-Key` is not the secret is blocked).

(The same rule can be created with `POST /pullzone/<id>/edgerules/addOrUpdate`.)

### 4. Local config

Copy [`examples/bunny.json`](examples/bunny.json) to `~/.config/ai-sphere/publish.json`, fill in your values and protect it:

```sh
mkdir -p ~/.config/ai-sphere
cp hosting/examples/bunny.json ~/.config/ai-sphere/publish.json
chmod 600 ~/.config/ai-sphere/publish.json
```

| Key | Meaning |
|---|---|
| `publicUrl` | `https://<random-name>.b-cdn.net/usage.json`: what the watch downloads. |
| `target.storageZone` | Storage zone name (upload path prefix). |
| `target.storageHost` | Upload host for the zone's region. |
| `target.path` | File name in the zone (`usage.json`). |
| `target.password` | Keychain item holding the storage zone password. |
| `watchKey` | Keychain item holding the `X-Key`. |

Older installs may have `~/.config/ai-sphere/bunny.json` instead (`storageZone`, `storageHost`, `cdnHost`, `remotePath`, `keychain.storagePassword`, `keychain.watchKey`). It is still read when `publish.json` does not exist.

### 5. Check

Upload once (`/usr/bin/python3 mac/aisphere_sync.py -v`), then:

```sh
hosting/check.sh
```

It checks that a request with no key or a wrong key gets 403, and that one with the key gets 200 with `application/json` and `max-age=60`. It also shows the published providers and the file's age. It never prints the host or the key.

```
no key:     403 (expected 403)
wrong key:  403 (expected 403)
right key:  200 (expected 200)
  content-type: application/json
  cache-control: public, max-age=60
  v1, 4 providers [CODEX, CLAUDE, AGY, HELM], generated 7 min ago
OK
```

Manual upload (what the script does):

```sh
SP=$(security find-generic-password -s ai-sphere-bunny-storage -w)
curl -X PUT -H "AccessKey: $SP" -H "Content-Type: application/json" \
     --data-binary @usage.json https://storage.bunnycdn.com/<storage-zone>/usage.json
```

## Secrets

None are stored in files or in the repository. They all live in the macOS Keychain (service `-s`):

| Service | Purpose | Used by |
|---|---|---|
| `bunny-access-key` | Bunny account API: create, change or delete zones | Admin only, never by the periodic script |
| `ai-sphere-bunny-storage` | Storage zone password: upload `usage.json` | Mac publisher |
| `ai-sphere-watch-key` | Value of the `X-Key` header | `garmin/scripts/build.sh`, which embeds it in the watch face build |

## Operations

### Rotate the `X-Key`

1. Generate and store a new one (the `security add-generic-password -U …` command in step 3).
2. Update the edge rule's value in the pull zone.
3. Rebuild and reinstall the watch face (`garmin/README.md`). Watch faces installed over USB cannot be configured from Garmin Connect: the key is part of the build.

Until step 3 the watch gets 403 and keeps showing its last data.

### Change the random host

A pull zone cannot be renamed. Create another one with a random name on the same storage zone, repeat the cache settings and the `X-Key` rule, delete the old one, update `publicUrl` in `~/.config/ai-sphere/publish.json`, and rebuild and reinstall the watch face.

### Use your own subdomain

Add a hostname to the pull zone with a CNAME record pointing to the `b-cdn.net` host, and enable Bunny's free certificate. Requires access to the domain's DNS.

### Tear down

Delete the pull zone and the storage zone (dashboard, or `DELETE /pullzone/<id>` and `DELETE /storagezone/<id>`), and remove the Keychain items `ai-sphere-bunny-storage` and `ai-sphere-watch-key`.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Upload returns 401 | Wrong or rotated storage zone password; check `ai-sphere-bunny-storage`. |
| CDN returns 403 with the right key | The rule has another `X-Key` value, or the value has extra spaces. |
| CDN returns 404 | `usage.json` has not been uploaded yet, or the path does not match. |
| Data a few minutes old | Normal: 60 s cache plus the upload (10 min) and poll (15 min) intervals. |
| Data more than 30 min old | The Mac is not publishing: see the log in `mac/README.md`. |
| Watch shows error -400 or cannot parse | The file is not served as `application/json`, or it is not valid JSON. |
