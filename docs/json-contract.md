# JSON contract (`usage.json`, version 1)

This is the interface between the publisher and the watch face. `mac/aisphere_sync.py` builds it from CodexBar (`codexbar usage` plus user plugins), the hosting serves it (`hosting/`), and the watch face reads it (`garmin/source/QuotaStore.mc` and `FaceModel.mc`). UTF-8, no whitespace, usually well under 1 KB.

## Example

A real payload (610 bytes, 4 providers), pretty-printed:

```json
{"v":1,"t":"2026-11-11T13:52:30Z","p":[
 {"id":"codex","n":"CODEX","w":[
   {"l":"WK","u":0,"r":"2026-11-18T13:52:29Z","m":10080}]},
 {"id":"claude","n":"CLAUDE","w":[
   {"l":"WK","u":30,"r":"2026-11-12T01:00:00Z","m":10080,"pc":{"e":93,"ok":true}},
   {"l":"FABLE WK","u":6,"r":"2026-11-12T01:00:00Z","m":10080}]},
 {"id":"antigravity","n":"AGY","w":[
   {"l":"GEM 5H","u":0,"r":"2026-11-11T18:52:27Z","m":300},
   {"l":"C/G 5H","u":0,"r":"2026-11-11T18:52:27Z","m":300},
   {"l":"GEM WK","u":0,"r":"2026-11-18T13:52:27Z","m":10080}]},
 {"id":"helmcode-credits","n":"HELM","w":[
   {"l":"MO","u":0,"r":"2026-12-01T00:00:00Z","m":44640}]}
]}
```

A provider with no fresh data also carries `"err":1` and repeats its last known values.

## Fields

| Field | Type | Always | Meaning |
|---|---|---|---|
| `v` | integer | yes | Schema version. Currently 1. |
| `t` | ISO 8601 UTC string | yes | When the file was generated. The watch uses it for "updated X ago". |
| `p` | list | yes | Providers, in CodexBar's order (stable, so each arc keeps its place on the bezel). May be empty. |
| `p[].id` | string | yes | CodexBar identifier (`codex`, `claude`, `antigravity`, `helmcode-credits`…). |
| `p[].n` | string | yes | Short name for the bezel (about 7 characters max). |
| `p[].w` | list | yes | Quota windows, **most used first** (the first one drives the arc, the second the thin inner line). Up to 3 by default. |
| `p[].err` | 1 | no | CodexBar gave no data for this provider this time; the windows are the last good values. |
| `w[].l` | string | yes | Short label (`WK`, `5H`, `MO`, `GEM 5H`, `C/G WK`, `FABLE WK`…). 10 characters max. |
| `w[].u` | integer 0–100 | yes | Percentage **used**, rounded. The watch shows what is left: `100 − u`. |
| `w[].r` | ISO 8601 UTC string | no | When the window resets. |
| `w[].m` | integer | no | Window length in minutes (300, 10080, 44640…). Omitted if CodexBar does not give it. |
| `w[].pc` | object | no | Pace computed by CodexBar, only when it provides one (currently Codex and Claude). |
| `pc.e` | integer 0–100 | yes | `expectedUsedPercent`: what you would have used at a constant rate. The pace tick on the bezel sits at `100 − e`. |
| `pc.ok` | boolean | yes | `willLastToReset`: whether the quota lasts until the reset. |
| `pc.eta` | integer | no | Seconds until it runs out, only when `ok` is `false`. |

## Rules

- **Nothing personal:** the normaliser copies only the fields in this table (an allow-list). E-mail addresses, organisations, plans, balances, costs and CodexBar's descriptions never leave the Mac. The tests check this.
- **Nothing invented:** if CodexBar does not give a value, the field is omitted. If a provider fails, its last good values are repeated with `err: 1`; zeros are never published. A provider that never had data is left out.
- **Duplicate windows:** if `primary`, `secondary` or `tertiary` match one of the `extraRateWindows` exactly (usage, reset and length), the standard one is dropped (Antigravity does this).
- **No fixed 5-hour window is assumed:** every window is collected, because Codex and Claude currently only have weekly ones.
- **Compatibility:** adding optional fields does not change `v`; the watch ignores what it does not know. An incompatible change bumps `v`, and a watch that does not understand it keeps the previous data.

## How labels are built

1. Length from `windowMinutes`: 300 → `5H`, 1440 → `DAY`, 10080 → `WK`, 28–31 days → `MO`; otherwise `nH` or `nD`. With the setting `"labelLanguage": "es"` the words are `DÍA`, `SEM` and `MES`.
2. Group from the CodexBar title, after removing length and filler words (`weekly`, `5-hour`, `only`, `models`, `quota`…): `Gemini` → `GEM`, `Claude/GPT` and `Claude and GPT` → `C/G`, `Gemini 4 Argon` → `ARGON`. Anything else: first word in upper case, 6 characters max (`deepseek-v4-flash` → `DEEPSE`).
3. If there is neither a group nor a length, the first part of `resetDescription` is used (e.g. `glm5.3-flash · …` → `GLM53`).
4. Any label can be forced in `~/.config/ai-sphere/sync.json` with the key `provider/windowId` (see `mac/README.md`).
