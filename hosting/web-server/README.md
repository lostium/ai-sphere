# Your own web server (SFTP, FTPS, WebDAV)

If you have a server or shared hosting with HTTPS, the Mac can upload the file over SFTP, FTPS or WebDAV, and the web server enforces the [contract](../README.md#the-contract) with a few lines of configuration.

Status: tested end to end in `hosting/test/integration.sh`. SFTP feeds nginx with [`nginx.conf`](nginx.conf), FTPS feeds Apache with [`apache.htaccess`](apache.htaccess), and the WebDAV upload is tested with `PUT` + `MOVE`. Each case checks 403 without or with a wrong key, 200 with the right key, `application/json`, `max-age=60`, and that the temporary file is not served.

Use a folder with a random name (e.g. `/ais-3kq9…/usage.json`) so the path cannot be guessed, in addition to the key.

## Fail-safe checks

Both snippets match the file name case-insensitively (so `/USAGE.JSON` cannot slip past on a case-insensitive file system) and send `Cache-Control: private` with `Vary: X-Key`, so a shared cache in front never hands the keyed response to someone else. A server that ignores the snippet (for example Apache with `AllowOverride None`) serves the file to anyone, so **run `hosting/check.sh` after every change**: it must report 403 without the key.

## nginx

Add [`nginx.conf`](nginx.conf) inside your HTTPS `server { … }` block, replace `CHANGE_ME` with your `X-Key`, and adjust the `location` path if you use a folder. Reload with `nginx -t && nginx -s reload`.

## Apache (including most shared hosting)

Copy [`apache.htaccess`](apache.htaccess) as `.htaccess` into the folder that holds `usage.json`, and replace `CHANGE_ME`. Requirements: Apache 2.4, `AllowOverride` allowing `AuthConfig` and `FileInfo`, and `mod_headers` (usually enabled).

> If the same folder is also served by another server that ignores `.htaccess`, that server would expose the file and the key in it. Keep this folder Apache-only.

## Uploading

### SFTP (recommended)

Key authentication only: `launchd` cannot type passwords or answer host-key questions.

```sh
ssh-keygen -t ed25519 -N "" -C ai-sphere-upload -f ~/.ssh/ai-sphere-upload   # dedicated key, no passphrase
ssh-copy-id -i ~/.ssh/ai-sphere-upload.pub deploy@ssh.example.com
ssh-keyscan -p 22 ssh.example.com >> ~/.ssh/known_hosts                       # check the fingerprint
```

On the server you can restrict that key to SFTP in `authorized_keys` (`restrict,command="internal-sftp" ssh-ed25519 …`) or with a chrooted SFTP-only user. Config: [`../examples/sftp.json`](../examples/sftp.json). The upload goes to `usage.json.tmp` and is renamed over `usage.json` (atomic with OpenSSH servers).

### FTPS

For hosting that only offers FTP. The target uses explicit TLS and verifies the certificate by default. For a self-signed certificate, point `caFile` at it rather than turning verification off. Store the password in the Keychain:

```sh
security add-generic-password -U -s ai-sphere-ftp-password -a ai-sphere -w
```

Config: [`../examples/ftps.json`](../examples/ftps.json). Plain FTP (`"tls": false`) sends the password in clear text: avoid it.

### WebDAV

Nextcloud, Apache `mod_dav`, nginx `dav` module, many NAS devices. With `"webdavMove": true` the file is uploaded to `usage.json.tmp` and moved over the real one. Config: [`../examples/webdav-nextcloud.json`](../examples/webdav-nextcloud.json).

The WebDAV URL is for uploading. The watch must read through a web server that applies the `X-Key` rule, which is not Nextcloud's WebDAV endpoint itself. Point that web server at the same folder.
