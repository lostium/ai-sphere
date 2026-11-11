// AI Sphere on Cloudflare Workers + KV.
//
//   PUT /usage.json   Authorization: Bearer <UPLOAD_TOKEN>   body: the JSON   (from the Mac, target "http")
//   GET /usage.json   X-Key: <WATCH_KEY>                                         (from the watch)
//
// Secrets (wrangler secret put …): UPLOAD_TOKEN, WATCH_KEY. KV namespace binding: AISPHERE.
// KV is eventually consistent (changes can take up to ~60 s to reach every location), which is fine
// for data refreshed every 10 minutes.

const PATH = "/usage.json";
const MAX_BYTES = 16 * 1024;

function timingSafeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function text(status, body) {
  return new Response(body + "\n", { status, headers: { "Content-Type": "text/plain" } });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== PATH) return text(404, "not found");

    if (request.method === "PUT") {
      const auth = request.headers.get("Authorization") || "";
      if (!env.UPLOAD_TOKEN || !timingSafeEqual(auth, `Bearer ${env.UPLOAD_TOKEN}`)) return text(401, "unauthorized");
      const body = await request.text();
      if (body.length > MAX_BYTES) return text(413, "too large");
      try {
        const parsed = JSON.parse(body);
        if (typeof parsed !== "object" || parsed === null || parsed.v === undefined) throw new Error("no v");
      } catch {
        return text(400, "not an AI Sphere payload");
      }
      await env.AISPHERE.put("usage.json", body);
      return text(201, "stored");
    }

    if (request.method === "GET" || request.method === "HEAD") {
      if (!env.WATCH_KEY || !timingSafeEqual(request.headers.get("X-Key") || "", env.WATCH_KEY)) return text(403, "forbidden");
      const body = await env.AISPHERE.get("usage.json");
      if (body === null) return text(404, "nothing published yet");
      return new Response(request.method === "HEAD" ? null : body, {
        headers: {
          "Content-Type": "application/json",
          "Cache-Control": "private, max-age=60",
          "X-Content-Type-Options": "nosniff",
        },
      });
    }

    return text(405, "method not allowed");
  },
};
