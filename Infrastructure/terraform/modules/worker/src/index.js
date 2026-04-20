/**
 * play.castology.tv — HLS delivery Worker
 *
 * Routes:
 *   GET /live/{stream}/index.m3u8   — playlist (short cache, auth required)
 *   GET /live/{stream}/*.ts         — segments  (long cache, auth required)
 *   GET /health                     — public health check
 *
 * Auth: Bearer token in Authorization header or ?token= query param.
 * Tokens are stored in the OPERATOR_TOKENS KV namespace as key=token, value=operator_id.
 */

const CACHE_TTL_PLAYLIST = 2;    // seconds — short so operators get fresh segment lists
const CACHE_TTL_SEGMENT  = 3600; // seconds — segments are immutable once written

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return new Response("ok", { status: 200 });
    }

    // Only serve /live/* paths from R2
    if (!url.pathname.startsWith("/live/")) {
      return new Response("Not found", { status: 404 });
    }

    // Auth — Bearer token or ?token= query param
    const token = extractToken(request, url);
    if (!token) {
      return unauthorized("Missing token");
    }

    const operatorId = await env.OPERATOR_TOKENS.get(token);
    if (!operatorId) {
      return unauthorized("Invalid token");
    }

    // Strip leading slash — R2 key matches the path without it
    const key = url.pathname.slice(1); // e.g. "live/geo-news/index.m3u8"

    const object = await env.HLS_BUCKET.get(key);
    if (!object) {
      return new Response("Stream not found", { status: 404 });
    }

    const isPlaylist = key.endsWith(".m3u8");
    const contentType = isPlaylist ? "application/vnd.apple.mpegurl" : "video/mp2t";
    const cacheTtl = isPlaylist ? CACHE_TTL_PLAYLIST : CACHE_TTL_SEGMENT;

    return new Response(object.body, {
      headers: {
        "Content-Type":                contentType,
        "Cache-Control":               `public, max-age=${cacheTtl}`,
        "Access-Control-Allow-Origin": "*",
        "X-Operator-Id":               operatorId,
      },
    });
  },
};

function extractToken(request, url) {
  const auth = request.headers.get("Authorization") ?? "";
  if (auth.startsWith("Bearer ")) return auth.slice(7).trim();
  return url.searchParams.get("token") ?? "";
}

function unauthorized(message) {
  return new Response(JSON.stringify({ error: message }), {
    status: 401,
    headers: { "Content-Type": "application/json" },
  });
}
