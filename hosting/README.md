# Hosting: where `usage.json` lives

The Mac uploads a small JSON file somewhere; the watch downloads it over HTTPS through the phone. Any place that meets the contract below works. The upload side is pluggable (`mac/targets.py`); the serving side is the host's configuration.

## The contract

Whatever you choose, the URL the watch downloads must:

| Requirement | Why |
|---|---|
| **HTTPS with a valid certificate** | Connect IQ refuses plain HTTP (the watch shows "needs HTTPS"). |
| **403 unless the `X-Key` header equals your secret** | The file is not public. A long random path or host name helps too. |
| **`Content-Type: application/json`** | Connect IQ only parses JSON responses with this type (otherwise "not JSON"). |
| **A short cache (≤ 60 s)** | The Mac uploads every 10 min; a long cache would show old data. |
| **Atomic replacement** | The watch must never read half a file. All targets upload to a temporary name and rename, or use a store that replaces objects atomically. |

`hosting/check.sh` tests the first four against your real URL.

## Options

| Option | Upload target | Who checks `X-Key` | Setup effort | Cost | Tested here |
|---|---|---|---|---|---|
| [Bunny CDN](bunny.md) | `bunny` | Edge rule | Low | Cents/month | **In daily use** |
| [Cloudflare Worker + KV](cloudflare/README.md#option-a-worker--kv-recommended) | `http` | The Worker | Low | Free tier | Worker code tested with Node; not deployed |
| [Cloudflare R2 + custom domain](cloudflare/README.md#option-b-r2--custom-domain--waf-rule) | `s3` | WAF custom rule | Medium (needs a domain on Cloudflare) | Free tier | S3 upload tested; R2 and WAF not |
| [S3-compatible + CDN](s3.md) (AWS S3 + CloudFront, Backblaze B2, Wasabi, DigitalOcean Spaces, Scaleway, Hetzner, MinIO…) | `s3` | CDN function/rule in front | Medium–high | Low | S3 upload tested against an S3-compatible server |
| [Your web server over SFTP](web-server/README.md) | `sftp` | nginx or Apache | Low if you have a server | Whatever you pay | **End to end** (SFTP → nginx) |
| [Shared hosting over FTPS](web-server/README.md) | `ftp` | `.htaccess` | Low | Whatever you pay | **End to end** (FTPS → Apache) |
| [WebDAV](web-server/README.md#webdav) (Nextcloud, Apache, nginx) | `webdav` | The web server | Low | — | Upload end to end |
| Anything [rclone](https://rclone.org) supports | `command` | Whatever serves it | Varies | Varies | `command` target tested with `cp` |
| A folder served by a local web server | `file` | The web server | Low | — | End to end (→ nginx) |

**Not suitable:** GitHub Pages, public Gists, a public bucket URL or Dropbox/Drive share links. They cannot require a header, and most cannot set the content type.

Recommendation: keep Bunny if you already have it. Without an account anywhere, a **Cloudflare Worker + KV** is free, needs no domain, and the Worker itself does the `X-Key` check. With your own server, **SFTP + nginx** is the simplest.

## Configuration

`~/.config/ai-sphere/publish.json` (mode `600`). Ready-made examples per provider are in [`examples/`](examples/).

```json
{
  "publicUrl": "https://ais-RANDOM.example.com/usage.json",
  "watchKey": "keychain:ai-sphere-watch-key",
  "target": { "type": "s3", "...": "target-specific fields" }
}
```

| Key | Meaning |
|---|---|
| `publicUrl` | What the watch downloads. Used by `garmin/scripts/build.sh` and `hosting/check.sh`. Must be `https://`. |
| `watchKey` | Secret reference for the `X-Key` value (default `keychain:ai-sphere-watch-key`). |
| `target` | Where the Mac uploads. `type` is one of `bunny`, `s3`, `http`/`webdav`, `ftp`, `sftp`, `command`, `file`. |

**Secrets are references, never values:** `"keychain:NAME"` (or just `"NAME"`) reads the macOS Keychain item with service `NAME`; `"env:NAME"` reads an environment variable. Store a Keychain secret without leaving it in your shell history:

```sh
security add-generic-password -U -s ai-sphere-ftp-password -a ai-sphere -w     # prompts for the value
```

Create the `X-Key` once (all options use it):

```sh
security add-generic-password -U -s ai-sphere-watch-key -a ai-sphere -w "$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
```

If `publish.json` does not exist, the publisher reads the older Bunny-only `~/.config/ai-sphere/bunny.json`, so existing installs keep working.

### Target fields

| `type` | Fields | Notes |
|---|---|---|
| `bunny` | `storageZone`, `storageHost` (default `storage.bunnycdn.com`), `path` (default `usage.json`), `password` (secret, default `ai-sphere-bunny-storage`) | HTTP `PUT` with the zone password. |
| `s3` | `endpoint`, `region` (`auto` for R2), `bucket`, `key`, `accessKeyId` (secret), `secretAccessKey` (secret), `virtualHosted` (default `false`), `cacheControl` (default `public, max-age=60`) | AWS Signature V4 `PUT`; stores `Content-Type: application/json` and the cache header with the object. Use an access key limited to this bucket. |
| `http` / `webdav` | `url`, `token` (secret, sent as `Bearer`) **or** `username` + `password` (secret, Basic), `headers` (extra, not secret), `webdavMove` | Plain `PUT`. With `webdavMove: true`, uploads to `usage.json.tmp` and `MOVE`s it over the real file. |
| `ftp` | `host`, `port` (21), `user`, `password` (secret), `path`, `tls` (default `true`), `passive` (default `true`), `caFile`, `verifyTls` | FTPS with certificate verification by default. Plain FTP sends the password in clear: only with `"tls": false`, on a network you trust. |
| `sftp` | `host`, `port` (22), `user`, `path`, `identityFile`, `knownHostsFile`, `strictHostKeyChecking` (default `yes`) | Uses the system `sftp` in batch mode: **key authentication only** (launchd cannot answer prompts). Add the server to `known_hosts` once: `ssh-keyscan -p 22 ssh.example.com >> ~/.ssh/known_hosts`, and use a key without a passphrase dedicated to this upload. |
| `command` | `command` (list of arguments; `{file}` is the JSON's path), `timeoutSeconds` (60) | No shell is involved. Put secrets in the tool's own config (e.g. `rclone config`), not in the arguments. |
| `file` | `path`, `mode` (default `644`) | Atomic copy to a local path. |

## Trying an option without touching your setup

The LaunchAgent keeps using `~/.config/ai-sphere/publish.json` (or `bunny.json`). To try another host, write its config anywhere else and pass it explicitly:

```sh
cp hosting/examples/cloudflare-worker.json ~/ais-try.json      # edit it
/usr/bin/python3 mac/aisphere_sync.py --publish-config ~/ais-try.json -v   # one real upload
hosting/check.sh ~/ais-try.json                                            # X-Key, type, cache, age
```

When it works, move it to `~/.config/ai-sphere/publish.json`, then rebuild and reinstall the watch face (the URL and key are part of the build; see `garmin/README.md`).

## Testing every option locally

```sh
hosting/test/integration.sh                       # needs Docker; first run pulls the images
node hosting/cloudflare/worker/worker.test.mjs    # the Cloudflare Worker, with an in-memory KV
/usr/bin/python3 -m unittest discover -s mac/tests   # target unit tests, no network
```

`integration.sh` starts, on `127.0.0.1` only and with throwaway credentials: an S3-compatible server, an SFTP server feeding nginx (with [`web-server/nginx.conf`](web-server/nginx.conf)), an FTPS server feeding Apache (with [`web-server/apache.htaccess`](web-server/apache.htaccess)) and a WebDAV server. For each target it uploads twice, then reads the file back like the watch: 403 without or with a wrong `X-Key`, 200 with the right one, `application/json`, `max-age=60`, the second upload's content, and the temporary file not served. Everything is removed at the end (`KEEP=1` keeps it for debugging). Last run: all targets OK.

To run the same checks against a real host: `hosting/test/roundtrip.py --target target.json --read-url https://…/usage.json --watch-key keychain:ai-sphere-watch-key` (the target file holds just the `target` object). It replaces the published file with a test payload, so run the publisher again afterwards.
