# Pace-based colours — design

Date: 2026-11-16. Size: small change.

## Intent

The arc colour should answer "am I going faster than the quota allows before it resets?", not "how much is left?". Example: Codex resets in 5 days; at the current rate it runs out in 3 days → red; in 4.5 days → amber; lasts to the reset → green.

## Goals

- Colour every quota window by pace: the ratio `run-out time / time to reset`.
- Work for every provider: CodexBar's pace for Codex and Claude, an on-watch estimate for the rest (Antigravity, HelmCode…).

## Non-goals

- No change to the JSON contract, the publisher or its tests.
- No change to what triggers a critical line (still: runs out, or 40 % or less left).

## Anti-goals

- False alarms right after a window starts (a few minutes of use extrapolated over a week).
- Colouring by remaining percentage when pace is known (decided: pace only, option A). The arc length already shows how much is left.

## Approaches

1. **On the watch (chosen).** The face computes the ratio every minute from `pc` (Codex, Claude) or from `u`, `m`, `r` (others). No contract change; the colour keeps up as the reset approaches, even while the Mac is offline.
2. Estimate on the Mac and publish a synthetic `pc`. Rejected: the value ages between downloads, it needs a contract change, and it mixes CodexBar facts with estimates in the publisher.

## Rules

Let `toReset = r − now` (seconds) and `total = m × 60`.

| Source | Condition | Colour |
|---|---|---|
| any | window expired | unchanged (dimmed, as today) |
| any | `u ≥ 100` | red |
| CodexBar `pc` | `ok = true` | green |
| CodexBar `pc` | `ok = false`, `eta` present | ratio = `(eta − (now − t)) / toReset` |
| CodexBar `pc` | `ok = false`, no `eta` | amber (my call: will not last, margin unknown) |
| estimate | `u = 0` | green |
| estimate | `m` or `r` missing, or `elapsed < 10 % of total` | fallback: colour by percentage left (today's rule) |
| estimate | `u ≤ elapsed / total × 100` | green |
| estimate | otherwise | ratio = `((100 − u) × elapsed / u) / toReset` |

where `elapsed = total − toReset`, and `t` is the payload's generation time (clamped so `now − t ≥ 0`).

Ratio → colour: `≥ 1` green, `0.8 – 1` amber, `< 0.8` red (5 d reset: out in 4.5 d → 0.9 amber; out in 3 d → 0.6 red).

## Also decided

- **Pace tick on every provider** with `m` and `r`: it sits at `100 − elapsed/total × 100`, which is a fact, not an estimate. CodexBar's `e` is still used when present.
- **Same rule everywhere a quota is coloured:** main arc, thin inner line, bezel label, critical-line value.
- **Critical lines:** a window whose estimate says it runs out counts as "runs out" (goes first, red, `out in Xd` with the estimated time).

## Touches

`garmin/source/FaceModel.mc` (pace fields, ratio, estimate, `runsOut`), `garmin/source/Theme.mc` (colour by ratio), `garmin/source/AISphereView.mc` (use it, tick for all), `garmin/tests/` (rules table above), `docs/design.md` (replace "Colours by what is left" and "never estimated"), `prototype/index.html` (same colours).

## Left to the builder

Integer vs float arithmetic in Monkey C (avoid overflow on `eta × u`), where the `t` timestamp is read from, and the exact test layout.
