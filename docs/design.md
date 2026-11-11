# Design notes

Why AI Sphere looks and works the way it does: the platform limits it was designed around, the data CodexBar actually returns, and the decisions behind the watch face. Verified in November 2026 with CodexBar 0.84.0 and the Connect IQ SDK 9.3.0 on an Epix Pro (Gen 2) 51 mm.

## Architecture constraints

**Nothing listens at home.** The Mac only makes outgoing requests: it runs a short script every few minutes and uploads a static file. A CDN serves that file to the watch. There is no local server, no tunnel and no companion phone app.

**The watch can only reach the internet through the phone.** A Connect IQ watch face can make HTTPS requests only from a background `ServiceDelegate` (permissions `Background` and `Communications`). The request goes over Bluetooth to Garmin Connect on the phone. Without the phone it fails with `BLE_CONNECTION_UNAVAILABLE (-104)`. Watch Wi-Fi APIs are for audio apps, so Wi-Fi cannot be relied on.

**Connect IQ limits that shaped the data format:**

| Limit | Value | Consequence |
|---|---|---|
| Background event frequency | `registerForTemporalEvent` at most every 5 minutes | The watch polls every 15 min by default (5 at the fastest). On error it waits for the next cycle; no retries. |
| Background → foreground | `Background.exit()` carries about 8 KB | The published JSON is 1–2 KB, not CodexBar's ~6 KB raw output. |
| Background memory | 64 KB (128 KB for the face) | The JSON must parse comfortably inside the background process. |
| Response type | `makeWebRequest` needs `Content-Type: application/json` to parse JSON | The CDN must serve the file with that type. |
| Always-on (AMOLED) | Redraw once a minute, at most 10 % of pixels lit, burn-in protection | Thin arcs, thin time, small periodic shift. |

The last good data is kept in `Application.Storage` and is never replaced by zeros.

Things that could not be confirmed from the documentation and depend on the real device: whether iOS delays Garmin Connect in the background, and whether the temporal event fires when the face is not active.

## What CodexBar returns

- `codexbar usage --format json` returns one entry per enabled provider. Windows are in `usage.primary`, `usage.secondary` and `usage.tertiary` (any of them may be `null`) plus `usage.extraRateWindows[]` (`id`, `title`, `window`). Labels are separate, in `rateWindowLabels`.
- Each window has `usedPercent` (may have decimals), `resetsAt` (ISO UTC), usually `windowMinutes`, and `resetDescription`.
- `pace.<window>` has `stage`, `deltaPercent`, `expectedUsedPercent`, `willLastToReset` and `etaSeconds` (when it will not last). Currently only Codex and Claude provide it.
- **There is no fixed 5-hour window.** Codex and Claude now only have weekly limits (`primary` is `null`); Claude adds a weekly window scoped to one model. The normaliser cannot assume `primary` exists or is the main one: it collects every window and sorts by what is left.
- **Antigravity** reports quotas per model group in `extraRateWindows` (Gemini 5 h and weekly, Claude/GPT 5 h and weekly, Gemini Argon weekly). Its `primary` and `secondary` duplicate the two 5-hour ones, so identical standard windows are dropped. With 0 % usage its resets fall exactly at query time + 5 h or + 7 d: they seem to be rolling windows that start on first use.
- **User plugins** (JavaScript providers in `~/.config/codexbar/providers/`) are not included in `codexbar usage`; they are fetched one by one with `codexbar plugins fetch <id> --json`.
- The raw output includes e-mail addresses, organisation and plan, so the normaliser uses an **allow-list** of fields.

## Watch face

- **Bezel:** one arc per provider over 280°, with the gap at the bottom for the sync status, in the JSON's fixed order so each provider always sits in the same place. Each arc shows the percentage **left** (100 − used) of its most used window: full and green at 100 %, shrinking as it is used.
- **Colours by what is left:** green above 40 %, amber 16–40 %, red 15 % or less.
- **Thin inner line:** what is left of the provider's second window.
- **Pace tick:** a radial mark at `100 − pace.expectedUsedPercent`. If the arc does not reach the tick, you are using the quota faster than it lasts. Drawn only when CodexBar gives `pace`; it is never estimated for other providers.
- **Providers with many quotas** (Antigravity has five): still one arc. The arc shows the most used window and the inner line the second one. Critical lines use short labels that name the group: `GEM 5H`, `GEM WK`, `C/G 5H`, `C/G WK`, `ARGON`.
- **Centre:** battery with an icon at the top, date, large time, steps and temperature with icons.
- **Critical lines:** at most two short lines under the time, such as `CODEX WK 1% ↻49m`. They appear only when a quota has 40 % or less left or will run out before its reset; otherwise the face reads "all quotas OK". A quota that will run out goes first, in red, with `out in 3d` instead of the reset time.
- **Offline:** the last values stay (never zeros), the footer turns amber, and a window whose reset has already passed is drawn dotted.
- **Always-on:** thin time, 3 px arcs without track, one critical line, and a shift of a few pixels every minute.
- No animations; one redraw per minute.
- The face is not interactive: whatever does not fit on the bezel is grouped, not navigated.

## Language

The watch face follows the watch's language: Spanish if the watch is set to Spanish, English otherwise (`garmin/resources-spa/` and `garmin/resources/`). Window labels come from the Mac and are English by default (`WK`, `MO`, `DAY`); `"labelLanguage": "es"` in `sync.json` switches them to Spanish (`SEM`, `MES`, `DÍA`).

## Security model

- The hosting (Bunny, Cloudflare, S3 + CDN or your own server) serves the file from a hard-to-guess URL and rejects (403) any request without the secret `X-Key` header. Connect IQ can send custom headers, so no URL signing is needed on the watch. See `hosting/README.md` for the contract every host must meet.
- Upload and admin credentials live in the macOS Keychain, never in files.
- Personal builds of the watch face embed the URL and key; `garmin/build/` and `garmin/bin/` are ignored by git.
- The published JSON contains only quota percentages, reset times and short labels.

## Why the publisher is Python

The publisher runs from `launchd` every 10 minutes for months, so the deciding factor is that it keeps working without attention. Node 24 can run TypeScript files directly (type stripping, no flags), and a TypeScript publisher was considered in November 2026, because the CodexBar plugin and the Cloudflare Worker are already JavaScript. Python stayed:

| | Python (`/usr/bin/python3`) | Node 24 + TypeScript |
|---|---|---|
| Interpreter path for `launchd` | Fixed. It ships with the Xcode Command Line Tools, which Homebrew already requires. | Varies. Version managers such as fnm and nvm put `node` on per-shell paths that disappear, so a LaunchAgent would silently stop. It needs a pinned path and a version check. |
| Dependencies | None. FTPS (`ftplib`), HTTP, HMAC and SigV4 are all in the standard library. | None for HTTP and SigV4. There is no FTP client in the standard library, so it would need about 150 lines over `node:tls`, a package, or dropping FTPS. |
| Overlapping runs | `fcntl.flock`. | A lock file with a PID check. |
| TypeScript support | — | Erasable syntax only: no `enum`, `namespace` or parameter properties, and imports need the `.ts` extension. |
| Shared code with the plugin and Worker | No. | Yes, one language. |

If the project moves to TypeScript later, the plan is: port the tests to `node:test` first, require byte-identical `usage.json` output from the test fixture, keep `hosting/test/integration.sh` passing, pin the `node` path in `install.sh`, and retire Python only then.

## Privacy

The repository is meant to be public, so it contains nothing that identifies the owner, their watch or their accounts:

- **No secrets or host names.** The CDN host, upload credentials, `X-Key`, session cookies and the developer key live in the Keychain and `~/.config`. Builds that embed them (`garmin/build/`, `garmin/bin/`) are ignored by git.
- **Illustrative test data.** The CodexBar fixture is a real output with the e-mail, organisation, plan names, billing dates and credits replaced. Examples use `example.com` and placeholders such as `ais-RANDOM`. Bunny storage zone names are globally unique, so the real one is never written down.
- **No device identifiers.** No watch serial, unit id or MTP object ids. `mtp_send.py` looks the folder up at run time.
- **Personal notes** (`CLAUDE.local.md`, `local/`) are ignored by git.
- **Check before every push:** `tools/check-private.sh` greps the files git would publish for your user name, full name, git e-mail, home path, hosting host name, e-mail addresses outside the example domains, JWTs, AWS keys and private keys. `--secrets` also looks for the Keychain values.
