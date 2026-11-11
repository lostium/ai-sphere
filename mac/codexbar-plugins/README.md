# CodexBar plugin: HelmCode global credits

Since November 2026, HelmCode (NaN Builders) no longer has a quota per model: there is **one monthly pool of credits** shared by all models. CodexBar 0.84.0 does not know this yet. Its built-in HelmCode provider still reads the old per-model quotas (`/api/usage/quota`), which is why the watch showed `HELM GLM53 0%`.

The fix is a CodexBar user plugin, [`helmcode-credits.js`](helmcode-credits.js), that reads the new endpoint. Its pure logic is tested with `node mac/tests/test_helmcode_plugin.mjs`. It is also a small, working example of how to add your own provider to AI Sphere through CodexBar's plugin system ([CodexBar plugin docs](https://github.com/steipete/CodexBar/blob/main/docs/plugins.md)).

## The endpoint

`GET https://cloud-api.nan.builders/api/usage/credits`, with:

- the header `Cookie: nan_session=<JWT>` from a session signed in at `cloud.nan.builders`;
- the headers `Origin: https://cloud.nan.builders` and `Referer: https://cloud.nan.builders/dashboard`, the same ones the built-in provider sends.

Without the cookie it returns 401. Response (abridged):

```json
{"enabled":true,"tier":"example-tier",
 "periodStart":"2026-10-31T00:00:00Z","periodEnd":"2026-12-01T00:00:00Z",
 "allowanceCredits":5000,"usedCredits":0,"remainingCredits":5000,
 "packCredits":0,"packExpiresAt":null,"frontierPaused":false,"frozen":false,
 "models":[{"model":"glm5.3-flash","approxCreditsPerMTokens":1.415,"creditsThisMonth":0,"tokensThisMonth":0}]}
```

The plugin publishes one window: used = `usedCredits / (allowanceCredits + packCredits)`, reset at `periodEnd`, length `periodEnd − periodStart` (31 days → label `MO`). On the watch it shows as **HELM**.

## Why the cookie is pasted by hand

The built-in HelmCode provider is **bundled** with CodexBar and can read browser cookies, even from the CLI. A **user** plugin cannot: plugins that use browser cookies only work inside the app, and AI Sphere uses the CLI from `launchd`. So this plugin uses `auth: {type: "header", header: "Cookie", secret: "SESSION_COOKIE"}`.

The value lives in the Keychain (`ai-sphere-helmcode-cookie`). On every run, `mac/aisphere_sync.py` passes it to CodexBar in the environment variable `CODEXBAR_PLUGIN_HELMCODE_CREDITS_SESSION_COOKIE`, the documented way to give plugin secrets to the CLI. No file holds the cookie.

## How it reaches the watch

CodexBar 0.84.0 **does not include user plugins in `codexbar usage`**, even when they are enabled. So, after `codexbar usage`, `aisphere_sync.py` runs `codexbar plugins fetch <id> --json` for each id in its `plugins` setting (default `["helmcode-credits"]`) and adds the result as another provider. Once approved, `plugins fetch` works without a terminal, including from `launchd`.

The script also reads `codexbar config providers --json`: a provider **disabled** in CodexBar (such as the built-in HelmCode) disappears from the watch at once, instead of being kept for 24 h as if it had failed.

## Install (once)

1. Put the plugin in place:
   ```sh
   mkdir -p ~/.config/codexbar/providers
   cp mac/codexbar-plugins/helmcode-credits.js ~/.config/codexbar/providers/
   codexbar plugins list        # helmcode-credits should be listed
   ```
2. Store the cookie in the Keychain (see "Renewing the cookie" below).
3. **Approve it, in your own Terminal window** (approval is interactive):
   ```sh
   CODEXBAR_PLUGIN_HELMCODE_CREDITS_SESSION_COOKIE="$(security find-generic-password -s ai-sphere-helmcode-cookie -w)" \
     codexbar plugins fetch helmcode-credits
   ```
   It shows the origin (`https://cloud-api.nan.builders`), the authentication (`Cookie` header) and the secret's name. Approve it; it should print the credits.
   The approval is stored in `~/Library/Application Support/CodexBar/plugin-approvals.json`. Changing the plugin's `id`, origins, authentication or secrets invalidates it.
4. In CodexBar, **disable the built-in HelmCode provider** so it does not show twice.
5. Check: `/usr/bin/python3 mac/aisphere_sync.py --dry-run -v` should list `HELM:100%` (or whatever is left) with label `MO`.

If you do not use HelmCode, set `"plugins": []` in `~/.config/ai-sphere/sync.json`.

## Renewing the cookie (every 14 days)

The `nan_session` cookie is a JWT valid for 14 days. The log warns when less than 3 days are left (`secret ai-sphere-helmcode-cookie expires in …`) and logs an error once it has expired. Meanwhile the watch keeps showing the last credits, marked as stale.

1. Open `https://cloud.nan.builders/dashboard`.
2. Developer tools (⌥⌘I) → Network → any request to `cloud-api.nan.builders` → Request Headers → copy the `Cookie` value (or just `nan_session=…`).
3. Store it without leaving it in your shell history (the command prompts for it):
   ```sh
   security add-generic-password -U -s ai-sphere-helmcode-cookie -a nan.builders -w
   ```

No need to approve the plugin again: the secret's value changes, not its name.

## Proper fix

Have CodexBar's built-in HelmCode provider (`Sources/CodexBarCore/Resources/Plugins/helmcode.ts`) read `/api/usage/credits`. It would then use browser cookies automatically, with no manual renewals, and this plugin would no longer be needed. As of 11 November 2026, neither 0.84.0 nor the 0.84.1 development branch does.
