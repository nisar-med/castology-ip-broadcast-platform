/**
 * play.castology.tv — HLS delivery Worker
 *
 * Routes:
 *   GET /health                        — public health check
 *   GET /playlist?token=              — M3U channel list for all broadcaster channels
 *   GET /live/{stream}/index.m3u8     — HLS playlist from R2 (auth required)
 *   GET /live/{stream}/*.ts           — HLS segments from R2 (auth required)
 *

 * Auth: Bearer token in Authorization header or ?token= query param.
 *
 * KV format: token → JSON { broadcaster, channels: [{name, stream}] }
 *
 * Caching:
 *   Playlists — Cache API keyed on token-free URL, TTL=6s.
 *               Stored with STREAM_TOKEN placeholder, swapped per-user on read.
 *   Segments  — Cache API keyed on pathname, TTL=1h. Shared across all users.
 */

const CACHE_TTL_PLAYLIST = 6;
const CACHE_TTL_SEGMENT  = 3600;
const TOKEN_CACHE_TTL_MS = 60_000;
const PLACEHOLDER        = "STREAM_TOKEN";

// Isolate-scoped token cache: token → { broadcaster, channels, expiresAt }
const tokenCache = new Map();

async function resolveToken(token, env) {
  const now = Date.now();
  const cached = tokenCache.get(token);
  if (cached && cached.expiresAt > now) return cached;

  const raw = await env.OPERATOR_TOKENS.get(token);
  if (!raw) return null;

  try {
    const data = JSON.parse(raw);
    const entry = { broadcaster: data.broadcaster, channels: data.channels, expiresAt: now + TOKEN_CACHE_TTL_MS };
    tokenCache.set(token, entry);
    return entry;
  } catch {
    return null;
  }
}

function cacheKey(url) {
  const u = new URL(url.toString());
  u.searchParams.delete("token");
  return u.toString();
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return new Response("ok", { status: 200 });
    }

    const token = extractToken(request, url);
    if (!token) return unauthorized("Missing token");

    const operator = await resolveToken(token, env);
    if (!operator) return unauthorized("Invalid token");

    // --- M3U channel list ---
    if (url.pathname === "/playlist") {
      const baseUrl = `https://${url.host}`;
      const lines = ["#EXTM3U"];
      for (const ch of operator.channels) {
        lines.push(`#EXTINF:-1 tvg-name="${ch.name}",${ch.name}`);
        lines.push(`${baseUrl}/live/${ch.stream}/index.m3u8?token=${token}`);
      }
      return new Response(lines.join("\n") + "\n", {
        headers: {
          "Content-Type":                "application/x-mpegurl",
          "Cache-Control":               "no-store",
          "Access-Control-Allow-Origin": "*",
        },
      });
    }

    if (!url.pathname.startsWith("/live/")) {
      return new Response("Not found", { status: 404 });
    }

    // Broadcaster auth — stream name must start with broadcaster id
    const streamName = url.pathname.split("/")[2] ?? "";
    const broadcaster = streamName.split("+")[0];
    if (!broadcaster || broadcaster !== operator.broadcaster) {
      return unauthorized("Token not authorized for this stream");
    }

    const isPlaylist = url.pathname.endsWith(".m3u8");
    const cache = caches.default;
    const key = cacheKey(url);

    // --- HLS Playlist ---
    if (isPlaylist) {
      const cached = await cache.match(key);
      if (cached) {
        const text = (await cached.text()).replaceAll(PLACEHOLDER, token);
        return new Response(text, {
          headers: {
            "Content-Type":                "application/vnd.apple.mpegurl",
            "Cache-Control":               `public, max-age=${CACHE_TTL_PLAYLIST}`,
            "Access-Control-Allow-Origin": "*",
            "X-Cache":                     "HIT",
          },
        });
      }

      const object = await env.HLS_BUCKET.get(url.pathname.slice(1));
      if (!object) return new Response("Stream not found", { status: 404 });

      const withPlaceholder = (await object.text()).split("\n").map(line => {
        const trimmed = line.trim();
        if (trimmed && !trimmed.startsWith("#")) {
          return trimmed.includes("?")
            ? `${trimmed}&token=${PLACEHOLDER}`
            : `${trimmed}?token=${PLACEHOLDER}`;
        }
        return line;
      }).join("\n");

      ctx.waitUntil(cache.put(key, new Response(withPlaceholder, {
        headers: {
          "Content-Type":  "application/vnd.apple.mpegurl",
          "Cache-Control": `public, max-age=${CACHE_TTL_PLAYLIST}`,
        },
      })));

      return new Response(withPlaceholder.replaceAll(PLACEHOLDER, token), {
        headers: {
          "Content-Type":                "application/vnd.apple.mpegurl",
          "Cache-Control":               `public, max-age=${CACHE_TTL_PLAYLIST}`,
          "Access-Control-Allow-Origin": "*",
          "X-Cache":                     "MISS",
        },
      });
    }

    // --- Segments ---
    const segCacheKey = `https://${url.host}${url.pathname}`;
    const cachedSeg = await cache.match(segCacheKey);
    if (cachedSeg) {
      return new Response(cachedSeg.body, {
        headers: {
          "Content-Type":                "video/mp2t",
          "Cache-Control":               `public, max-age=${CACHE_TTL_SEGMENT}`,
          "Access-Control-Allow-Origin": "*",
          "X-Cache":                     "HIT",
        },
      });
    }

    const object = await env.HLS_BUCKET.get(url.pathname.slice(1));
    if (!object) return new Response("Stream not found", { status: 404 });

    const [body1, body2] = object.body.tee();
    ctx.waitUntil(cache.put(segCacheKey, new Response(body1, {
      headers: {
        "Content-Type":  "video/mp2t",
        "Cache-Control": `public, max-age=${CACHE_TTL_SEGMENT}`,
      },
    })));

    return new Response(body2, {
      headers: {
        "Content-Type":                "video/mp2t",
        "Cache-Control":               `public, max-age=${CACHE_TTL_SEGMENT}`,
        "Access-Control-Allow-Origin": "*",
        "X-Cache":                     "MISS",
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
