// Tests the pure part of mac/codexbar-plugins/helmcode-credits.js outside CodexBar.
// Run: node mac/tests/test_helmcode_plugin.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, "..", "codexbar-plugins", "helmcode-credits.js"), "utf8");

let manifest = null;
const load = new Function("defineProvider", `${source}\nreturn helmcodeSnapshot;`);
const helmcodeSnapshot = load((m) => { manifest = m; });

// Manifest shape expected by CodexBar
assert.equal(manifest.id, "helmcode-credits");
assert.match(manifest.id, /^[a-z0-9-]{1,64}$/);
assert.deepEqual(manifest.endpoints, ["https://cloud-api.nan.builders"]);
assert.equal(typeof manifest.fetchUsage, "function");

// Response shape seen on 2026-11-11, with illustrative values (models list trimmed)
const real = {
  enabled: true, tier: "example-tier",
  periodStart: "2026-10-31T00:00:00Z", periodEnd: "2026-12-01T00:00:00Z",
  allowanceCredits: 5000, usedCredits: 0, remainingCredits: 5000,
  packCredits: 0, packExpiresAt: null, frontierPaused: false, frozen: false, models: [],
};
let snap = helmcodeSnapshot(real);
assert.equal(snap.primary.usedPercent, 0);
assert.equal(snap.primary.resetsAt, "2026-12-01T00:00:00Z");
assert.equal(snap.primary.windowMinutes, 44640); // 31 days
assert.equal(snap.dataConfidence, "exact");

// Usage plus a credit pack: the pack adds to the limit
snap = helmcodeSnapshot({ ...real, usedCredits: 1500, remainingCredits: 4500, packCredits: 1000 });
assert.equal(Math.round(snap.primary.usedPercent * 100) / 100, 25);
assert.ok(snap.details[0].rows.some((r) => r.label === "Pack"));

// Over the allowance is clamped
assert.equal(helmcodeSnapshot({ ...real, usedCredits: 9000 }).primary.usedPercent, 100);

// Failure modes surface as errors, never as invented zeros
assert.throws(() => helmcodeSnapshot({ ...real, enabled: false }));
assert.throws(() => helmcodeSnapshot({ ...real, allowanceCredits: 0 }));
assert.throws(() => helmcodeSnapshot(null));

console.log("helmcode-credits plugin: all checks passed");
