/**
 * play.castology.tv — HLS delivery Worker
 *
 * Routes:
 *   GET /live/{stream}/index.m3u8   — playlist (auth required, rewrites segment URLs)
 *   GET /live/{stream}/*.ts         — segments  (auth required)
 *   GET /health                     — public health check
 *
 * Auth: Bearer token in Authorization header or ?token= query param.
 * Playlist segment URLs are rewritten to include ?token= so VLC and other
 * players that don't forward auth headers can fetch segments correctly.
 */

const CACHE_TTL_PLAYLIST = 2;    // seconds — short so operators get fresh segment lists
const CACHE_TTL_SEGMENT  = 3600; // seconds — segments are immutable once written

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return new Response("ok", { status: 200 });
    }

    if (!url.pathname.startsWith("/live/")) {
      return new Response("Not found", { status: 404 });
    }

    const token = extractToken(request, url);
    if (!token) {
      return unauthorized("Missing token");
    }

    const operatorId = await env.OPERATOR_TOKENS.get(token);
    if (!operatorId) {
      return unauthorized("Invalid token");
    }

    const key = url.pathname.slice(1); // strip leading slash → R2 key

    const object = await env.HLS_BUCKET.get(key);
    if (!object) {
      return new Response("Stream not found", { status: 404 });
    }

    const isPlaylist = key.endsWith(".m3u8");
    const contentType = isPlaylist ? "application/vnd.apple.mpegurl" : "video/mp2t";
    const cacheTtl = isPlaylist ? CACHE_TTL_PLAYLIST : CACHE_TTL_SEGMENT;

    // Rewrite playlist segment lines to append ?token= so VLC fetches segments with auth
    if (isPlaylist) {
      const text = await object.text();
      const rewritten = text.split("\n").map(line => {
        const trimmed = line.trim();
        if (trimmed && !trimmed.startsWith("#")) {
          return trimmed.includes("?")
            ? `${trimmed}&token=${token}`
            : `${trimmed}?token=${token}`;
        }
        return line;
      }).join("\n");

      return new Response(rewritten, {
        headers: {
          "Content-Type":                contentType,
          "Cache-Control":               `no-store`,
          "Access-Control-Allow-Origin": "*",
          "X-Operator-Id":               operatorId,
        },
      });
    }

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
