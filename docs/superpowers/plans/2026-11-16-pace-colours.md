# Pace-based colours Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Colour every quota on the watch face by pace (run-out time vs time to reset) instead of by percentage left.

**Architecture:** `FaceModel.quota()` fills each `Quota` with pace facts: CodexBar's `pc` (with `eta` aged by `now − t`) or an on-watch estimate from `u`, `m`, `r`. `Quota.color()` turns them into green/amber/red through `Theme.pace()`. The view replaces every `Theme.level(q.left)` with `q.color()`. The pace tick already draws whenever `paceExpected` is set, so estimates make it appear for every provider.

**Tech Stack:** Monkey C (Connect IQ SDK, device `epix2pro51mm`), Connect IQ unit tests in the simulator; plain JS in `prototype/index.html`.

**Spec:** `docs/superpowers/specs/2026-11-16-pace-colours-design.md`

## Global Constraints

- No change to the JSON contract (`docs/json-contract.md`), `mac/` or `v: 1`.
- Ratio → colour: `≥ 1` green (`Theme.OK`), `≥ 0.8` amber (`Theme.WARN`), `< 0.8` red (`Theme.CRIT`).
- Estimate only when `m` and `r` exist and `elapsed ≥ 10 %` of the window; otherwise colour by percentage left (`Theme.level`).
- Colour is pace only (option A): a quota that lasts is green whatever is left; `left = 0` is always red.
- Critical-line trigger unchanged (`runsOut() || left <= 40`).
- Integer seconds can reach ~2.7 M (31 days) and CodexBar `eta` is unbounded: multiply in `Long`.
- User-facing text only in `strings.xml` (this change adds none). Docs in English. Run `tools/check-private.sh` before committing.

## Review Focus

1. Watch clock behind the payload (`now < t`): the age is clamped to 0, `eta` never grows.
2. CodexBar `eta` already exhausted by ageing (`eta − age ≤ 0`): `eta = 0`, red, line shows "out in 0m"-style text without crashing.
3. Huge `eta` or a 1-year `m`: no overflow, still the right colour.
4. Reset further away than the window length (`toReset > total`, negative elapsed): fallback, no estimate, no tick.
5. Expired windows and `err` providers keep today's look (dotted / dimmed), and expired never counts as running out.

Each has a test in Task 1.

---

### Task 1: Pace model in `FaceModel` and `Theme`

**Files:**
- Modify: `garmin/source/Theme.mc`
- Modify: `garmin/source/FaceModel.mc`
- Create: `garmin/tests/FaceModelTest.mc`

**Interfaces:**
- Produces:
  - `Theme.pace(outIn as Number, toReset as Number) as Number` → `OK` if `outIn ≥ toReset`, `WARN` if `outIn × 10 ≥ toReset × 8`, else `CRIT` (Long arithmetic; `toReset ≤ 0` → `OK`).
  - New `Quota` fields: `toReset as Number or Null` (seconds from `now` to reset), `paceKnown as Boolean = false`. `eta` now means *seconds from now* until it runs out.
  - `Quota.color() as Number`, in this order: `left == 0` → `CRIT`; `expired` or `!paceKnown` → `Theme.level(left)`; `lasts` → `OK`; `eta == null || toReset == null` → `WARN`; else `Theme.pace(eta, toReset)`.
  - `FaceModel.quota(w, providerName as String, now as Number, generated as Number or Null) as Quota or Null` (new 4th parameter). `FaceModel.providers(now)` passes `QuotaStore.generatedAt()`.
  - `FaceModel.estimate(q as Quota, used as Number, minutes, now as Number) as Void` (fills `paceExpected`, `lasts`, `eta`, `paceKnown` when no `pc`).

- [ ] **Step 1: Write the failing tests** in `garmin/tests/FaceModelTest.mc`, each `(:test)` returning `true`. Fixture: `now = QuotaStore.parseIso("2026-11-16T00:00:00Z")`, reset `"2026-11-21T00:00:00Z"` (5 d), `m = 10080` (elapsed 2 d), `generated = now` unless stated. Helper `q(w, generated)` = `FaceModel.quota(w, "CODEX", now, generated) as Quota`.

| Test | Window `w` | Assertions |
|---|---|---|
| `codexbarOutIn3dOf5IsRed` | `u 50, pc {e 28, ok false, eta 259200}` | `color() == CRIT`, `runsOut()` |
| `codexbarOutIn4_5dOf5IsAmber` | `eta 388800` | `color() == WARN` |
| `codexbarEtaAgesWithPayload` | `eta 388800`, generated `"2026-11-15T00:00:00Z"` | `eta == 302400`, `color() == CRIT` |
| `codexbarEtaNeverBelowZero` | `eta 3600`, generated `"2026-11-15T00:00:00Z"` | `eta == 0`, `color() == CRIT` |
| `clockBehindPayloadDoesNotGrowEta` | `eta 388800`, generated `"2026-11-17T00:00:00Z"` | `eta == 388800` |
| `codexbarLastsIsGreenEvenNearlyEmpty` | `u 95, pc {e 28, ok true}` | `color() == OK` |
| `emptyIsAlwaysRed` | `u 100, pc {e 28, ok true}` | `color() == CRIT` |
| `codexbarWontLastWithoutEtaIsAmber` | `u 50, pc {e 28, ok false}` | `color() == WARN` |
| `hugeEtaDoesNotOverflow` | `pc {e 28, ok false, eta 2000000000}` | `color() == OK` |
| `estimateOnPaceIsGreenWithTick` | `u 20`, no `pc` | `color() == OK`, `paceExpected == 28`, `!runsOut()` |
| `estimateOutIn3dIsRed` | `u 40` | `eta == 259200`, `runsOut()`, `color() == CRIT` |
| `estimateSlightlyFastIsAmber` | `u 31` | `color() == WARN` |
| `estimateUnusedIsGreen` | `u 0` | `color() == OK`, `!runsOut()` |
| `estimateTooEarlyFallsBackToLeft` | `u 70`, reset `"2026-11-22T12:00:00Z"` (elapsed 0.5 d < 0.7 d) | `paceExpected == null`, `!runsOut()`, `color() == WARN` (left 30) |
| `estimateResetBeyondWindowFallsBack` | `u 70`, `m 300` (toReset 5 d > 5 h) | `paceExpected == null`, `color() == WARN` |
| `estimateWithoutMinutesFallsBack` | `u 90`, no `m` | `color() == CRIT` (left 10), `!runsOut()` |
| `yearLongWindowDoesNotOverflow` | `u 40`, `m 527040`, reset `"2026-12-16T00:00:00Z"` | no exception, `color()` is one of `OK/WARN/CRIT` |
| `expiredKeepsPercentColourAndNeverRunsOut` | `u 40`, reset `"2026-11-15T00:00:00Z"`, `pc {e 28, ok false, eta 100}` | `expired`, `!runsOut()`, `color() == OK` (left 60) |
| `estimatedRunOutGoesFirstInCriticalLines` | provider A `u 40` (estimated run-out, left 60), provider B `u 80` lasting (`pc ok true`, left 20) | `FaceModel.critical([A, B], 2)[0].left == 60` |

For the last test, build `ProviderModel`s by hand and add the quotas from `q(...)`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `garmin/scripts/test.sh`
Expected: build error on the 4-argument `FaceModel.quota` / missing `color`, `Theme.pace`.

- [ ] **Step 3: Implement `Theme.pace`, the `Quota` fields and `color()`, the new `quota()` parameter and `estimate()`.**

In `quota()`: set `toReset = reset − now` when `reset` exists. With a valid `pc`: `paceKnown = true`; `eta = max(0, eta − max(0, now − generated))` (age 0 when `generated` is null). Without `pc` and not expired: call `estimate`. Estimate algorithm (all products in `Long`, results back to `Number`):

```
total = minutes * 60; elapsed = total - toReset
if minutes == null || reset == null || elapsed * 10 < total: return   // fallback
paceKnown = true; paceExpected = elapsed * 100 / total
if used == 0 || used * total <= elapsed * 100: lasts = true; return
lasts = false; eta = (100 - used) * elapsed / used
```

Update the `Quota` and `Theme.level` doc comments (level is now the fallback).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `garmin/scripts/test.sh`
Expected: every test PASS, including the existing `QuotaStoreTest` ones.

- [ ] **Step 5: Commit**

```bash
git add garmin/source/Theme.mc garmin/source/FaceModel.mc garmin/tests/FaceModelTest.mc
git commit -m "Compute quota pace on the watch and colour by it"
```

### Task 2: Use pace colours in the view and update the docs

**Files:**
- Modify: `garmin/source/AISphereView.mc:176,202,209,321,439`
- Modify: `docs/design.md:38,40,43`, `garmin/README.md:7,32`

**Interfaces:**
- Consumes: `Quota.color() as Number` (Task 1).

- [ ] **Step 1: Replace every `Theme.level(q1.left)`, `Theme.level(q2.left)` and `Theme.level(q.left)` in `AISphereView.mc` with `q1.color()`, `q2.color()`, `q.color()`.** Dimming and dotted drawing stay as they are. The pace-tick code needs no change.

- [ ] **Step 2: Build**

Run: `cd garmin && scripts/build.sh`
Expected: `BUILD SUCCESSFUL`, no new warnings.

- [ ] **Step 3: Run the unit tests**

Run: `garmin/scripts/test.sh`
Expected: all PASS.

- [ ] **Step 4: Update the docs.** `docs/design.md`: replace "Colours by what is left" with the pace rule (ratio thresholds, estimate and its 10 % guard, fallback, option A, `eta` aged by `t`). Replace "never estimated for other providers" in the pace-tick bullet with: estimated from `m`/`r` when CodexBar gives no pace. Add one line to "Critical lines" saying that estimated run-outs count. `garmin/README.md`: same in the bezel bullet and the `Theme.mc` row.

- [ ] **Step 5: Check the simulator visually.** Run the face in the simulator with the current published data. Expected: Codex/Claude coloured from `pc`, Antigravity/HelmCode with a pace tick, and no crash. Ask the user for a screenshot (the assistant cannot capture the screen).

- [ ] **Step 6: Commit**

```bash
tools/check-private.sh
git add garmin/source/AISphereView.mc docs/design.md garmin/README.md
git commit -m "Draw arcs, labels and critical lines with pace colours"
```

### Task 3: Prototype

**Files:**
- Modify: `prototype/index.html` (data at 244–253, `level` at 262, uses at 364, 377, 382, 436; legend at 209, 215–216; intro at 158)

- [ ] **Step 1: Add `m` (window minutes) to every example window in `BASE`, and add a JS `paceColour(w, now)` that mirrors `Quota.color()`.** Use the same thresholds, 10 % guard and fallback to `level`. The prototype's `eta` is in minutes and has no ageing. Use it at the four colour sites. Draw the notch from the estimate when `w.p` is absent.

- [ ] **Step 2: Rewrite the legend and intro text.** Colour now means pace: green lasts, amber runs out shortly before the reset, red well before. The notch appears for every provider with a known window length. Replace the `> 40 % / 16–40 %` swatches with `lasts / out ≥ 80 % of the time left / sooner`.

- [ ] **Step 3: Open the file in a browser and check all three scenarios (today, calm, offline).** Expected: no console errors. Cursor (out in ~3 d of 12) is red, and Codex at 1 % left but lasting is green.

- [ ] **Step 4: Commit**

```bash
git add prototype/index.html
git commit -m "Show pace colours in the prototype"
```

Do not republish the artifact; that is the user's call.

### Task 4: Install on the watch

- [ ] **Step 1:** With the user's go-ahead and the watch connected, run `/usr/bin/python3 garmin/scripts/mtp_send.py garmin/bin/AISphere.prg`. Expected: the transfer reports the new byte size.
- [ ] **Step 2:** Ask the user to confirm colours and ticks on the real watch. Update the install log in `CLAUDE.local.md`.
