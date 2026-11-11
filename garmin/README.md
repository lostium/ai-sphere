# Watch face (Garmin Connect IQ)

Watch face for the **Epix Pro (Gen 2) 51 mm** (`epix2pro51mm`, 454 × 454 AMOLED, Connect IQ 5.2). SDK 9.3.0, `minApiLevel` 3.2.0. It reads the `usage.json` published on the CDN (format in [`docs/json-contract.md`](../docs/json-contract.md)) and draws what is left of each quota. The design comes from the prototype in [`prototype/index.html`](../prototype/index.html); the reasoning behind it is in [`docs/design.md`](../docs/design.md).

## What it shows

- **Bezel:** one arc per provider (280°, gap at the bottom), in the JSON's order. Each arc is the percentage **left** of its most used window: green above 40 %, amber 16–40 %, red 15 % or less. A thin inner line shows the second window. The **pace tick** marks where the arc would be at a constant rate (only when CodexBar provides `pace`). Name and percentage are drawn as curved text.
- **Centre:** battery with icon at the top, date, large time, steps and temperature with icons.
- **Critical lines:** at most two, only for quotas with 40 % or less left or that will run out before the reset (`CODEX WK 1% ↻49m`, `out in 3d` in red). If there are none, the Lostium logo is drawn in its place, in orange and white (`drawLogo`, built from rectangles so it stays sharp at any size).
- **Footer:** "updated X ago", or in amber "no phone · data X ago" and "Mac not publishing · X ago" when the data gets old. Offline, the last values stay (never zeros) and a window whose reset has passed is drawn dotted.
- **Always-on:** thin time, 3 px arcs without track, one critical line, and a shift of a few pixels per minute (Connect IQ allows at most 10 % lit pixels).

One redraw per minute, no animations. Memory: about 18 KB of 124 KB.

## Languages

Texts are in `resources/strings/strings.xml` (English, the default) and `resources-spa/strings/strings.xml` (Spanish, used when the watch is set to Spanish). `$1$` and `$2$` are filled in by the code. Dates come from the watch's own locale. Window labels (`WK`, `SEM`…) come from the Mac; see `labelLanguage` in [`mac/README.md`](../mac/README.md).

To add a language, create `resources-<code>/strings/strings.xml` with the same ids, add `base.lang.<code> = resources-<code>` to `monkey.jungle` and the language to `manifest.xml`.

## Layout

| Path | What it is |
|---|---|
| `manifest.xml` | Type `watchface`, permissions `Background` and `Communications`, target devices and languages. |
| `monkey.jungle` | Adds `build/resources` (generated) and the Spanish resources. |
| `source/AISphereApp.mc` | Schedules background events and receives their results. |
| `source/SyncService.mc` | Background process: `makeWebRequest` with the `X-Key` header. Returns the result with `Background.exit()`; does not write to `Storage`. |
| `source/QuotaStore.mc` | Stores the last valid JSON, the time of the last success and the code of the last attempt. A failure never erases good data. |
| `source/FaceModel.mc` | Turns the JSON into providers and quotas (`ProviderModel`, `Quota`) and picks the critical lines. |
| `source/AISphereView.mc` | Drawing: bezel, centre, critical lines, footer and always-on mode. |
| `source/Theme.mc` | Colours and the green/amber/red thresholds. |
| `source/Geo.mc` | Bezel geometry: angles, arcs, dotted arcs and the pace tick. |
| `resources/`, `resources-spa/` | Strings, icon and settings (`dataUrl`, `accessKey`, `refreshMinutes`). |
| `scripts/build.sh` | Builds. Generates `build/resources/properties.xml` with the URL and key. |
| `scripts/mtp_send.py` | Copies the `.prg` to the watch over USB. |
| `build/`, `bin/` | Generated, ignored by git (they contain the URL and key). |

## Developer key and app id

Builds are signed with your Connect IQ developer key, by default `~/.config/connectiq/developer_key.der` (override with `CIQ_DEVELOPER_KEY`). If you do not have one:

```sh
mkdir -p ~/.config/connectiq
openssl genrsa -out /tmp/ciq.pem 4096
openssl pkcs8 -topk8 -inform PEM -outform DER -in /tmp/ciq.pem -out ~/.config/connectiq/developer_key.der -nocrypt
rm /tmp/ciq.pem
```

**Back it up:** a watch only accepts an update signed with the same key as the installed version.

The application id in `manifest.xml` identifies the app on the watch. If you fork the project to publish your own version, generate a new id (any 32-hex-digit UUID without dashes).

## Build

```sh
cd garmin
scripts/build.sh            # personal build: embeds the CDN URL and X-Key
scripts/build.sh release    # empty URL and key (for a store build, set from Garmin Connect)
DEVICE=epix2pro47mm scripts/build.sh   # another device (it must be listed in manifest.xml)
```

The URL (`publicUrl`) and the key reference (`watchKey`) come from the publisher's config, `~/.config/ai-sphere/publish.json` (see `hosting/README.md`); the build refuses non-HTTPS URLs. Output: `bin/AISphere.prg`.

## Syncing on the watch

- After installing, or after a settings change, the face asks for data as soon as Connect IQ allows it. Then every `refreshMinutes`: 15, set in `scripts/build.sh`. Connect IQ does not allow less than 5.
- The request goes over Bluetooth to Garmin Connect on the phone. iOS may delay it a little if the app has been in the background for a while. Without the phone the code is -104 and the footer shows "no phone · data X ago".
- The footer names the usual hosting mistakes: "needs HTTPS" (`-1001`), "not JSON" (`-1002`, wrong `Content-Type`), "X-Key rejected" (401/403), "file not found" (404); anything else shows "error <code>".
- Custom codes: -2001 no URL set; -2002 response too large for `Background.exit()` (~8 KB); -2003 JSON with an unknown schema version. (They avoid -1000…-1004, which Connect IQ uses.)

## Simulator

```sh
SDK="$(cat ~/Library/Application\ Support/Garmin/ConnectIQ/current-sdk.cfg)"
open "$SDK/bin/ConnectIQ.app"
"$SDK/bin/monkeydo" bin/AISphere.prg epix2pro51mm
```

In the simulator, requests go straight out from the Mac. To force a download: **Simulation → Background Events → Temporal Event**. For always-on mode: **Settings → Low Power Mode**. To see the Spanish texts: **Settings → Language → Spanish**.

## Install on the watch (sideload)

1. `scripts/build.sh`
2. Connect the watch to the Mac by USB and quit Garmin Express and OpenMTP, which lock the device.
3. `/usr/bin/python3 scripts/mtp_send.py bin/AISphere.prg` (requires `brew install libmtp`). The script finds the `GARMIN/Apps` folder by id and sends the file. `mtp-sendfile` does not work, because it cannot resolve Garmin's folders by path. Manual alternative: [OpenMTP](https://openmtp.ganeshrvel.com) (`brew install --cask openmtp`), dragging the `.prg` into `GARMIN/Apps`.
4. Disconnect the watch and choose **AI Sphere** in the watch face list.

To update, repeat the same steps. When disconnected, the watch installs the `.prg` and removes it from `GARMIN/Apps`. The new version replaces the old one and keeps its stored data, because it has the same app id and developer key.

Notes:
- Watch faces installed over USB cannot be configured from Garmin Connect. To change the URL, key or interval, rebuild and copy the `.prg` again.
- They survive firmware updates, although a major update may require a rebuild.
- Alternative: publish it on the Connect IQ Store as a private beta (visible only to you). It can then be configured from the phone and updated automatically, but every version has to be uploaded to Garmin's developer portal.
