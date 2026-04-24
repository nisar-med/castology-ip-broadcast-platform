#!/usr/bin/env python3
"""
HLS load tester — simulates N operators each polling a playlist every 6s
and fetching new segments as they appear, exactly like a real HLS player.

Usage:
  python3 hls-loadtest.py --operators 50 --duration 3600 --stream geo+news --token geo-token
"""
import asyncio, aiohttp, argparse, time, statistics
from datetime import datetime

BASE_URL = "https://play.castology.tv"

stats = {
    "playlist_miss": [], "playlist_hit": [], "playlist_err": 0,
    "segment_miss":  [], "segment_hit":  [], "segment_err":  0,
}

def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)

async def operator(session, operator_id, stream, token, duration):
    """Simulates one HLS operator: poll playlist every 6s, fetch new segments."""
    seen_segments = set()
    end = time.time() + duration
    playlist_url = f"{BASE_URL}/live/{stream}/index.m3u8?token={token}"

    while time.time() < end:
        poll_start = time.time()

        # --- Fetch playlist ---
        try:
            async with session.get(playlist_url) as resp:
                ttfb = time.time() - poll_start
                xcache = resp.headers.get("x-cache", "MISS").upper()
                text = await resp.text()

                if resp.status == 200:
                    if xcache == "HIT":
                        stats["playlist_hit"].append(ttfb)
                    else:
                        stats["playlist_miss"].append(ttfb)

                    # Parse new segments
                    segments = [l.strip() for l in text.splitlines()
                                if l.strip() and not l.startswith("#")]
                    new_segs = [s for s in segments if s not in seen_segments]
                    seen_segments.update(segments)
                else:
                    stats["playlist_err"] += 1
        except Exception as e:
            stats["playlist_err"] += 1
            await asyncio.sleep(6)
            continue

        # --- Fetch new segments concurrently ---
        async def fetch_seg(seg_url):
            seg_start = time.time()
            full_url = f"{BASE_URL}/live/{stream}/{seg_url}"
            try:
                async with session.get(full_url) as r:
                    ttfb = time.time() - seg_start
                    xcache = r.headers.get("x-cache", "MISS").upper()
                    await r.read()
                    if r.status == 200:
                        if xcache == "HIT":
                            stats["segment_hit"].append(ttfb)
                        else:
                            stats["segment_miss"].append(ttfb)
                    else:
                        stats["segment_err"] += 1
            except:
                stats["segment_err"] += 1

        if new_segs:
            await asyncio.gather(*[fetch_seg(s) for s in new_segs])

        # Sleep until next 6s poll
        elapsed = time.time() - poll_start
        await asyncio.sleep(max(0, 6 - elapsed))

def summarise():
    def fmt(samples, label):
        if not samples:
            return f"  {label}: no data"
        return (f"  {label}: count={len(samples):,}  "
                f"avg={statistics.mean(samples)*1000:.0f}ms  "
                f"p50={statistics.median(samples)*1000:.0f}ms  "
                f"p95={sorted(samples)[int(len(samples)*.95)]*1000:.0f}ms  "
                f"min={min(samples)*1000:.0f}ms  max={max(samples)*1000:.0f}ms")

    print("\n" + "="*60)
    print("RESULTS")
    print("="*60)
    print("PLAYLISTS")
    print(fmt(stats["playlist_hit"],  "HIT "))
    print(fmt(stats["playlist_miss"], "MISS"))
    print(f"  errors: {stats['playlist_err']}")
    total_pl = len(stats["playlist_hit"]) + len(stats["playlist_miss"])
    if total_pl:
        hit_pct = len(stats["playlist_hit"]) / total_pl * 100
        print(f"  cache hit rate: {hit_pct:.1f}%")
    print("SEGMENTS")
    print(fmt(stats["segment_hit"],  "HIT "))
    print(fmt(stats["segment_miss"], "MISS"))
    print(f"  errors: {stats['segment_err']}")
    total_seg = len(stats["segment_hit"]) + len(stats["segment_miss"])
    if total_seg:
        hit_pct = len(stats["segment_hit"]) / total_seg * 100
        print(f"  cache hit rate: {hit_pct:.1f}%")
    print("="*60)

async def progress_reporter(duration):
    start = time.time()
    while True:
        await asyncio.sleep(30)
        elapsed = time.time() - start
        if elapsed > duration:
            break
        pl_hits  = len(stats["playlist_hit"])
        pl_miss  = len(stats["playlist_miss"])
        seg_hits = len(stats["segment_hit"])
        seg_miss = len(stats["segment_miss"])
        pl_total = pl_hits + pl_miss
        seg_total = seg_hits + seg_miss
        log(f"[{elapsed/60:.1f}min] "
            f"playlist: {pl_hits}/{pl_total} hits ({pl_hits/pl_total*100:.0f}% cache)  "
            f"segment: {seg_hits}/{seg_total} hits ({seg_hits/seg_total*100:.0f}% cache)"
            if pl_total and seg_total else f"[{elapsed/60:.1f}min] warming up...")

async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--operators", type=int, default=50)
    parser.add_argument("--duration",  type=int, default=3600, help="seconds")
    parser.add_argument("--stream",    default="geo+news")
    parser.add_argument("--token",     default="geo-token")
    args = parser.parse_args()

    log(f"Starting load test: {args.operators} operators × {args.duration}s on {args.stream}")

    connector = aiohttp.TCPConnector(limit=200)
    timeout   = aiohttp.ClientTimeout(total=30)

    async with aiohttp.ClientSession(connector=connector, timeout=timeout) as session:
        tasks = [operator(session, i, args.stream, args.token, args.duration)
                 for i in range(args.operators)]
        tasks.append(progress_reporter(args.duration))
        await asyncio.gather(*tasks)

    summarise()

if __name__ == "__main__":
    asyncio.run(main())
