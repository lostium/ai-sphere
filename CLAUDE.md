# AI Sphere

Garmin Connect IQ watch face for the Epix Pro (Gen 2) 51 mm (`epix2pro51mm`, 454 × 454 AMOLED) that shows what is left of the AI provider quotas aggregated by CodexBar on macOS.

Flow: CodexBar CLI → `mac/aisphere_sync.py` (launchd, every 10 min) → compact JSON uploaded through a pluggable target (`mac/targets.py`: Bunny, S3/R2, HTTP/WebDAV, FTPS, SFTP, command, file) → served over HTTPS with an `X-Key` check → the watch face downloads it in the background through the phone (Garmin Connect).

Personal, machine-specific state (accounts, zone ids, dates, pending checks) lives in `CLAUDE.local.md`, which is not committed.

## Layout

| Folder | Component | Docs |
|---|---|---|
| `mac/` | Publisher: `aisphere_sync.py`, LaunchAgent, tests | `mac/README.md` |
| `mac/codexbar-plugins/` | CodexBar plugin for HelmCode credits | `mac/codexbar-plugins/README.md` |
| `hosting/` | Hosting options (Bunny, Cloudflare Worker/R2, S3, web servers), example configs, server snippets, `check.sh`, Docker integration test | `hosting/README.md` |
| `garmin/` | Monkey C watch face, `scripts/build.sh`, `scripts/mtp_send.py` | `garmin/README.md` |
| `prototype/` | HTML prototype of the design | — |
| `docs/` | `json-contract.md` (publisher ↔ watch interface), `design.md` (decisions and platform facts) | — |

Design decisions and verified CodexBar / Connect IQ behaviour are in `docs/design.md`; read it before changing the face or the normaliser.

## Commands

```sh
/usr/bin/python3 -m unittest discover -s mac/tests     # publisher tests
tools/check-private.sh                                 # personal data / secrets scan
node mac/tests/test_helmcode_plugin.mjs                # plugin test
/usr/bin/python3 mac/aisphere_sync.py --dry-run -v     # build the JSON without uploading
hosting/check.sh                                       # hosting end to end (real URL)
hosting/test/integration.sh                            # every target against local Docker servers
node hosting/cloudflare/worker/worker.test.mjs         # Cloudflare Worker
cd garmin && scripts/build.sh                          # build the watch face
/usr/bin/python3 garmin/scripts/mtp_send.py garmin/bin/AISphere.prg   # install over USB
```

## Rules

- Never commit secrets, the CDN host, `garmin/build/`, `garmin/bin/` or the developer key. Secrets live in the macOS Keychain; local config in `~/.config/ai-sphere/`.
- Never publish personal data from CodexBar's output: the normaliser uses an allow-list of fields, and tests enforce it.
- Publisher: Python 3.9-compatible (`/usr/bin/python3`), standard library only. Staying on Python was decided on purpose (fixed interpreter path for launchd, stdlib FTPS); see "Why the publisher is Python" in `docs/design.md` before proposing a port.
- The repository is public: no names, e-mails, account data, plan names, billing dates, real zone/bucket names, host names or device ids. Use `example.com` and `RANDOM` placeholders. Run `tools/check-private.sh` before committing.
- Upload targets live in `mac/targets.py` (stdlib only). A new target needs unit tests in `mac/tests/test_targets.py`, a case in `hosting/test/integration.sh` when a Docker server exists for it, an example in `hosting/examples/` and a row in `hosting/README.md`. Secrets are references (`keychain:`/`env:`), never values in config or argv.
- If the JSON changes, update `docs/json-contract.md`, the normaliser tests and `FaceModel.mc` together. Optional fields keep `v: 1`.
- The LaunchAgent stores the absolute path of `mac/aisphere_sync.py`: after moving or renaming `mac/`, rerun `mac/install.sh`.
- User-facing watch texts go in `garmin/resources/strings/strings.xml` (English) and `garmin/resources-spa/strings/strings.xml` (Spanish), never hard-coded.
- Documentation is in English, next to the component it describes. Use pnpm if Node tooling is ever added.
