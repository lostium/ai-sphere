# AI Sphere

A Garmin watch face that shows how much is left of your AI coding quotas (Codex, Claude, Antigravity, HelmCode… anything [CodexBar](https://github.com/steipete/CodexBar) tracks), right on your wrist.

Built for the **Epix Pro (Gen 2) 51 mm** (454 × 454 AMOLED). The layout scales with the screen, so other round Connect IQ 5 watches should only need to be added to `garmin/manifest.xml`.

## How it works

```
┌──────────────── Mac ─────────────────┐ upload ┌───────── Hosting ─────────┐      ┌──── Watch ────┐
│ CodexBar (CLI)                       │ ─────▶ │ Bunny · Cloudflare · S3 · │ GET  │ AI Sphere     │
│   └─▶ mac/aisphere_sync.py           │        │ your server (SFTP/FTPS/   │◀─────│ watch face    │
│       (launchd, every 10 min)        │        │ WebDAV) · …               │X-Key │ (via phone,   │
│       normalise → usage.json (~600 B)│        │ HTTPS, 403 without X-Key, │      │ every 15 min) │
└──────────────────────────────────────┘        │ JSON, 60 s cache          │      └───────────────┘
                                                └───────────────────────────┘
```

1. **Publisher (Mac):** a script started by `launchd` reads quotas from CodexBar, keeps only what the watch needs (nothing personal) and uploads a small JSON file. Nothing listens on your network.
2. **Hosting (pluggable):** stores the file and serves it over HTTPS, only to requests carrying a secret `X-Key` header. Bunny CDN, a Cloudflare Worker or R2, any S3-compatible store, or your own web server fed over SFTP, FTPS or WebDAV. See [`hosting/README.md`](hosting/README.md).
3. **Watch face (Garmin):** downloads the JSON in the background through Garmin Connect on the phone and draws one arc per provider with what is left of each quota.

The JSON format, the only thing the three parts share, is described in [`docs/json-contract.md`](docs/json-contract.md).

## What the face shows

- **Bezel:** one arc per provider. A full green arc means the quota is untouched; it shrinks and turns amber (≤ 40 %) and red (≤ 15 %) as you use it. A thin inner line shows the provider's second window.
- **Pace tick:** where the arc should be if you used the quota at a constant rate until it resets. If the arc falls short of the tick, you are burning through it faster than it lasts. Shown when CodexBar provides pace data (Codex and Claude).
- **Centre:** battery, date, time, steps and temperature.
- **Critical lines:** up to two short lines (`CODEX WK 12% ↻2d`, or `out in 3d` in red) only when a quota is low or will run out before its reset; otherwise the Lostium logo, in its orange and white.
- **Footer:** how old the data is, and whether the phone or the Mac is not delivering.
- **Always-on mode:** a dimmed, thin version within the AMOLED 10 % lit-pixel limit.
- **Languages:** English, and Spanish when the watch is set to Spanish.

Design rationale and platform limits: [`docs/design.md`](docs/design.md).

## Repository layout

| Folder | What it is | Docs |
|---|---|---|
| [`mac/`](mac/) | Publisher: reads CodexBar and uploads through a pluggable target. Python 3 (standard library only) + LaunchAgent. | [`mac/README.md`](mac/README.md) |
| [`mac/codexbar-plugins/`](mac/codexbar-plugins/) | A CodexBar plugin for HelmCode's global credits (example of adding your own provider). | [`mac/codexbar-plugins/README.md`](mac/codexbar-plugins/README.md) |
| [`hosting/`](hosting/) | Where the JSON is served: guides for Bunny, Cloudflare, S3-compatible stores and web servers, example configs, server snippets, a check script and a Docker test of every option. | [`hosting/README.md`](hosting/README.md) |
| [`garmin/`](garmin/) | Connect IQ watch face in Monkey C, plus build and USB install scripts. | [`garmin/README.md`](garmin/README.md) |
| [`prototype/`](prototype/) | Interactive HTML prototype of the design. Open `prototype/index.html` in a browser. | — |
| [`docs/`](docs/) | JSON contract and design notes (including why the publisher is Python, and the privacy rules). | — |
| [`tools/`](tools/) | `check-private.sh`: scans the files git would publish for personal data and secrets. | — |

## Requirements

- macOS with [CodexBar](https://github.com/steipete/CodexBar) and its `codexbar` CLI (tested with 0.84.0).
- Somewhere to host one small file over HTTPS behind a secret header: Bunny, Cloudflare (free tier), an S3-compatible store with a CDN, or your own web server. Options in [`hosting/README.md`](hosting/README.md).
- The [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) (tested with 9.3.0) and a developer key.
- A Garmin watch paired with a phone running Garmin Connect.
- For USB installs: `brew install libmtp`.

## Setup

1. **Hosting:** pick an option, set it up and write `~/.config/ai-sphere/publish.json`, then run `hosting/check.sh` → [`hosting/README.md`](hosting/README.md).
2. **Publisher:** `mac/install.sh` → [`mac/README.md`](mac/README.md). Optionally install the HelmCode plugin → [`mac/codexbar-plugins/README.md`](mac/codexbar-plugins/README.md).
3. **Watch face:** `garmin/scripts/build.sh`, connect the watch by USB and run `garmin/scripts/mtp_send.py` → [`garmin/README.md`](garmin/README.md).

## How fresh is the data?

| Step | How often | Where to change it |
|---|---|---|
| Mac reads CodexBar and uploads | 10 min | `mac/install.sh <seconds>` (minimum 300) |
| Hosting cache | up to 60 s | Your host's settings (`hosting/README.md`) |
| Watch downloads the JSON (via phone) | 15 min | `refreshMinutes` in `garmin/scripts/build.sh` (minimum 5) |
| Face redraw | every minute | — |

What you see is usually 5–15 minutes old, about 26 minutes in the worst case. The footer always shows the real age.

## Secrets and local files

None of these are in the repository:

| Where | What |
|---|---|
| Keychain `ai-sphere-watch-key` | The `X-Key` value the watch sends. |
| Keychain, per hosting option | Upload credentials: e.g. `ai-sphere-bunny-storage`, R2/S3 keys, FTP password, Worker token. SFTP uses an SSH key file instead. |
| Keychain `ai-sphere-helmcode-cookie` | HelmCode session cookie (only with the HelmCode plugin). |
| `~/.config/ai-sphere/publish.json` | Public URL, upload target and Keychain item names ([examples](hosting/examples/)). |
| `~/.config/ai-sphere/sync.json` | Optional publisher settings. |
| `~/.config/connectiq/developer_key.der` | Your Garmin developer key. Back it up: without it you cannot update an installed build. |
| `garmin/build/`, `garmin/bin/` | Build output; personal builds embed the CDN URL and key. |

## Quick checks

```sh
tail -n 3 ~/Library/Logs/AI-Sphere/sync.log           # is the Mac publishing?
hosting/check.sh                                       # is the file served, protected, JSON, fresh?
/usr/bin/python3 -m unittest discover -s mac/tests     # publisher tests
node mac/tests/test_helmcode_plugin.mjs                # HelmCode plugin test
hosting/test/integration.sh                            # every upload target against local servers (Docker)
tools/check-private.sh                                 # before pushing: no personal data or secrets in the repo
```

## Status

A personal project, in daily use on one watch. It is not on the Connect IQ Store; you install it from source with your own developer key.

## Disclaimer

AI Sphere is an independent personal project, provided as is, without warranty. It is not affiliated with or endorsed by Garmin, CodexBar, Bunny.net, Cloudflare or any AI provider; all trademarks belong to their owners. Quota figures may be delayed or inaccurate, so do not use them for billing decisions. Some integrations rely on unofficial endpoints, and you are responsible for complying with each provider's terms and for the security and cost of your own hosting. Read the full [disclaimer](DISCLAIMER.md).

## License

[MIT](LICENSE).
