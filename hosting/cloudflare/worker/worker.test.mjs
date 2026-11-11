// Tests worker.js with Node's built-in fetch classes and an in-memory KV. Run: node hosting/cloudflare/worker/worker.test.mjs
import assert from "node:assert/strict";
import worker from "./worker.js";

const store = new Map();
const env = {
  UPLOAD_TOKEN: "upload-secret",
  WATCH_KEY: "watch-secret",
  AISPHERE: { get: async (k) => (store.has(k) ? store.get(k) : null), put: async (k, v) => void store.set(k, v) },
};
const url = "https://ai-sphere.example.workers.dev/usage.json";
const call = (init, u = url) => worker.fetch(new Request(u, init), env);
const payload = JSON.stringify({ v: 1, t: "2026-11-11T13:52:30Z", p: [] });

assert.equal((await call({ headers: { "X-Key": "watch-secret" } })).status, 404, "nothing published yet");
assert.equal((await call({ method: "PUT", body: payload })).status, 401, "PUT without token");
assert.equal((await call({ method: "PUT", body: payload, headers: { Authorization: "Bearer nope" } })).status, 401);
assert.equal((await call({ method: "PUT", body: "hello", headers: { Authorization: "Bearer upload-secret" } })).status, 400);
assert.equal((await call({ method: "PUT", body: "x".repeat(20000), headers: { Authorization: "Bearer upload-secret" } })).status, 413);
assert.equal((await call({ method: "PUT", body: payload, headers: { Authorization: "Bearer upload-secret" } })).status, 201);

assert.equal((await call({})).status, 403, "GET without X-Key");
assert.equal((await call({ headers: { "X-Key": "watch-secreT" } })).status, 403, "wrong X-Key");
const ok = await call({ headers: { "X-Key": "watch-secret" } });
assert.equal(ok.status, 200);
assert.equal(ok.headers.get("Content-Type"), "application/json");
assert.equal(await ok.text(), payload);
assert.equal((await call({ headers: { "X-Key": "watch-secret" } }, "https://x.workers.dev/other")).status, 404);
assert.equal((await call({ method: "DELETE", headers: { "X-Key": "watch-secret" } })).status, 405);
console.log("cloudflare worker: all checks passed");
