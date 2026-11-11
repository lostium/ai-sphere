# Cloudflare

Two ways to host `usage.json` on Cloudflare. Both fit in the free plan.

## Option A: Worker + KV (recommended)

A tiny Worker ([`worker/worker.js`](worker/worker.js)) stores the JSON in Workers KV and serves it. It does every part of the [contract](../README.md#the-contract) itself: HTTPS on `*.workers.dev`, the `X-Key` check, `application/json`, a 60 s cache header, and it rejects uploads without the upload token. No domain needed.

```
Mac ── PUT + Bearer <UPLOAD_TOKEN> ──▶ Worker ──▶ KV
Watch ── GET + X-Key ─────────────────▶ Worker ◀── KV        (403 without the right X-Key)
```

Status: the Worker's logic is tested with Node and an in-memory KV (`node hosting/cloudflare/worker/worker.test.mjs`); the `http` target is tested against a local server. A deployment on a real Cloudflare account has not been tested yet.

### Setup

Needs a Cloudflare account and Node (run Wrangler with pnpm, no global install):

```sh
cd hosting/cloudflare/worker
pnpm dlx wrangler login
pnpm dlx wrangler kv namespace create AISPHERE        # note the id it prints
cp wrangler.toml.example wrangler.toml                # paste the id; wrangler.toml is ignored by git
```

Secrets: the watch key you already have, and a new upload token for the Mac. Each is piped from the Keychain, so it never appears on screen or in your shell history:

```sh
printf 'add-generic-password -U -s ai-sphere-worker-upload-token -a ai-sphere -w %s\n' "$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')" | security -i
security find-generic-password -s ai-sphere-worker-upload-token -w | pnpm dlx wrangler secret put UPLOAD_TOKEN
security find-generic-password -s ai-sphere-watch-key -w          | pnpm dlx wrangler secret put WATCH_KEY
pnpm dlx wrangler deploy                              # prints https://ai-sphere.<subdomain>.workers.dev
```

Then use [`../examples/cloudflare-worker.json`](../examples/cloudflare-worker.json) as `publish.json` (target `http` with `token`), upload once and run `hosting/check.sh`.

Notes:
- KV is eventually consistent: a new value can take up to about 60 s to reach every location. Irrelevant for data refreshed every 10 minutes.
- Free plan limits (100 000 requests/day, 1 000 KV writes/day) are far above what this uses (about 150 uploads and 100–150 reads a day).
- To hide the `workers.dev` name, rename the Worker to something random (`name` in `wrangler.toml`) or add a route on your own domain.

## Option B: R2 + custom domain + WAF rule

The Mac uploads to an R2 bucket with the `s3` target; Cloudflare serves the bucket on a custom domain and a WAF rule blocks requests without the `X-Key`.

Status: the `s3` target is tested against an S3-compatible server; R2 itself, the custom domain and the WAF rule have not been tested here.

Needs a domain whose DNS is on Cloudflare (R2's `r2.dev` URLs cannot have WAF rules and are rate-limited).

1. **Bucket:** R2 → Create bucket (e.g. `ai-sphere`). Leave public access off.
2. **Custom domain:** bucket → Settings → Custom Domains → connect a long random subdomain, e.g. `ais-<random>.example.com`.
3. **API token for the Mac:** R2 → Manage API tokens → Create → *Object Read & Write*, limited to this bucket. Store both values:
   ```sh
   security add-generic-password -U -s ai-sphere-r2-access-key-id -a ai-sphere -w
   security add-generic-password -U -s ai-sphere-r2-secret-access-key -a ai-sphere -w
   ```
4. **WAF custom rule** (zone → Security → WAF → Custom rules), action *Block*:
   ```
   (http.host eq "ais-<random>.example.com" and not any(http.request.headers["x-key"][*] eq "<your X-Key>"))
   ```
5. **Cache:** the `s3` target stores `Cache-Control: private, max-age=60` and `Content-Type: application/json` with the object, so Cloudflare does not keep a shared copy; with a few hundred requests a day nothing needs caching. Do not add a "Cache Everything" rule.
6. Use [`../examples/cloudflare-r2.json`](../examples/cloudflare-r2.json) (`endpoint` is `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`, `region` is `auto`), upload once and run `hosting/check.sh`.

Rotating the `X-Key` means editing the WAF rule (option B) or `wrangler secret put WATCH_KEY` (option A), then rebuilding the watch face.
