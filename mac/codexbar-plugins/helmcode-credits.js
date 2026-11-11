// CodexBar provider plugin: HelmCode (NaN Builders) global monthly credits.
//
// HelmCode moved from per-model token quotas to one monthly credit allowance. CodexBar 0.84.0's
// built-in "helmcode" provider still reads the old per-model quotas, so this plugin reads
// https://cloud-api.nan.builders/api/usage/credits instead and reports a single window.
//
// Install: copy this file to ~/.config/codexbar/providers/ and approve it once
// (CodexBar → Settings → Plugins, or `codexbar plugins fetch helmcode-credits` in a terminal).
// Docs: https://github.com/steipete/CodexBar/blob/main/docs/plugins.md

defineProvider({
  id: "helmcode-credits",
  name: "HelmCode",
  icon: { monogram: "HC", tint: "#4CD99A" },
  endpoints: ["https://cloud-api.nan.builders"],
  // Same session as CodexBar's bundled HelmCode plugin, but pasted by hand: user plugins cannot read
  // browser cookies from the CLI, and our launchd job uses the CLI. Copy the request's Cookie header
  // from https://cloud.nan.builders/dashboard (browser dev tools → Network) into this setting.
  auth: { type: "header", header: "Cookie", secret: "SESSION_COOKIE" },
  dashboardURL: "https://cloud.nan.builders/dashboard",
  settings: [
    {
      key: "SESSION_COOKIE",
      title: "Cookie header",
      subtitle: "Cookie header of a logged-in request to cloud.nan.builders.",
      type: "secure",
    },
  ],

  async fetchUsage(ctx) {
    // Same Origin/Referer as the bundled HelmCode plugin sends.
    const response = await ctx.http.getJSON("https://cloud-api.nan.builders/api/usage/credits", {
      headers: {
        Origin: "https://cloud.nan.builders",
        Referer: "https://cloud.nan.builders/dashboard",
      },
    });
    return helmcodeSnapshot(response.json);
  },
});

// Pure function so it can be tested outside CodexBar (see mac/tests/test_helmcode_plugin.mjs).
function helmcodeSnapshot(data) {
  const d = data || {};
  const num = (v) => (typeof v === "number" && isFinite(v) ? v : 0);

  if (d.enabled === false) {
    throw new Error("HelmCode: the plan is not enabled");
  }
  const limit = num(d.allowanceCredits) + num(d.packCredits);
  if (!(limit > 0)) {
    throw new Error("HelmCode: no credit allowance in the response");
  }
  const used = num(d.usedCredits);
  const usedPercent = Math.max(0, Math.min(100, (used / limit) * 100));

  const primary = { title: "Credits", usedPercent };
  if (typeof d.periodEnd === "string") {
    primary.resetsAt = d.periodEnd;
  }
  const start = Date.parse(d.periodStart);
  const end = Date.parse(d.periodEnd);
  if (isFinite(start) && isFinite(end) && end > start) {
    primary.windowMinutes = Math.round((end - start) / 60000);
  }

  const rows = [
    { label: "Used", value: String(Math.round(used)) + " / " + String(Math.round(limit)) },
    { label: "Remaining", value: String(Math.round(num(d.remainingCredits))) },
  ];
  if (num(d.packCredits) > 0) {
    rows.push({ label: "Pack", value: String(Math.round(num(d.packCredits))), secondaryValue: d.packExpiresAt || "" });
  }
  if (d.frozen === true || d.frontierPaused === true) {
    rows.push({ label: "Status", value: d.frozen ? "Frozen" : "Frontier models paused" });
  }

  return {
    primary,
    dataConfidence: "exact",
    details: [{ title: "Monthly credits", rows }],
  };
}
