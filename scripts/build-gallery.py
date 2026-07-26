#!/usr/bin/env python3
"""Build a static masonry photo grid from a gallery-dl Instagram export.

Reads the <media>.json sidecars gallery-dl writes next to each download and
emits a single self-contained index.html plus a thumbs/ directory. Every tile
links back to its original Instagram post.

No runtime, no JS framework, no external requests -- just files nginx can serve.

Usage:
    build-gallery.py SOURCE_DIR OUTPUT_DIR [--title TITLE] [--width PX] [--jobs N]

Requires ffmpeg on PATH (used for both image resizing and video poster frames).
"""

import argparse
import concurrent.futures
import html
import json
import math
import pathlib
import shutil
import subprocess
import sys

CAPTION_CHARS = 400

# Number of leading tiles loaded eagerly at high priority. Native lazy-loading
# defers everything including the first screenful, which leaves the top of the
# page visibly empty on arrival; these cover roughly one 4-column viewport.
EAGER_TILES = 12

# Masonry geometry. CSS multi-column (`columns: 320px`) cannot be used here: for
# a container this tall the browser *balances* the columns, so column 1 holds
# items 0-742, column 2 holds 743-1462 and so on. That puts four unrelated eras
# side by side in the top row, makes chronological reading require a 97,000px
# scroll down one column, and spreads the lazy-load frontier across four distant
# document regions at once (~250 images fetched on arrival).
#
# CSS Grid with an explicit `grid-row: span N` per tile gives true row-major
# order instead. N is computed here from each image's real aspect ratio, which
# requires the column width to be *fixed* rather than fluid -- a `1fr` column
# would render taller than the span reserved and tiles would overlap.
COLUMN_PX = 320   # exact rendered tile width; span maths depends on it
ROW_UNIT_PX = 2   # grid-auto-rows; finer = tighter packing, more spanned rows
GAP_PX = 14


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("source", type=pathlib.Path)
    p.add_argument("output", type=pathlib.Path)
    p.add_argument("--title", default="Instagram Collection")
    p.add_argument("--width", type=int, default=600,
                   help="thumbnail width in px (default 600, ~2x a 300px column)")
    p.add_argument("--quality", default="6",
                   help="ffmpeg -q:v for thumbnails, lower is bigger/better "
                        "(default 6; q3 is ~35%% larger for no visible gain at "
                        "this display size)")
    p.add_argument("--jobs", type=int, default=8)
    p.add_argument("--force", action="store_true",
                   help="re-encode thumbnails that already exist (needed after "
                        "changing --width or --quality, since existing files are "
                        "otherwise skipped)")
    return p.parse_args()


def load_items(source):
    """One item per downloaded media file, newest post first."""
    items = []
    for sidecar in source.rglob("*.json"):
        media = sidecar.with_suffix("")
        if not media.exists():
            continue
        try:
            meta = json.loads(sidecar.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"  ! skipping unreadable {sidecar.name}: {exc}", file=sys.stderr)
            continue
        if not meta.get("post_url"):
            print(f"  - no post_url in {sidecar.name}, skipping", file=sys.stderr)
            continue

        width = meta.get("width") or 0
        height = meta.get("height") or 0
        if not (width and height):
            print(f"  - no dimensions for {media.name}, skipping", file=sys.stderr)
            continue

        items.append({
            "media": media,
            "is_video": media.suffix.lower() == ".mp4",
            "post_url": meta["post_url"],
            "shortcode": meta.get("post_shortcode", ""),
            "username": meta.get("username", ""),
            "description": (meta.get("description") or "").strip(),
            "date": str(meta.get("post_date") or ""),
            "num": meta.get("num") or 0,
            "count": meta.get("count") or 1,
            "width": width,
            "height": height,
        })

    # Newest post first, but carousel siblings in original shot order (_01 first).
    # These need opposite directions, and a single reverse=True sort would flip
    # `num` too -- which showed image 6 of a carousel before image 1. Python's
    # sort is stable, so sort by num ascending first, then by post descending.
    items.sort(key=lambda i: i["num"])
    items.sort(key=lambda i: (i["date"], i["shortcode"]), reverse=True)
    return items


def thumb_cmd(item, dest, width, quality, seek=None):
    """ffmpeg invocation producing a single JPEG thumbnail."""
    # -vf scale: -2 keeps aspect ratio and forces even dimensions (JPEG-safe).
    scale = f"scale={width}:-2:flags=lanczos"
    cmd = ["ffmpeg", "-nostdin", "-v", "error", "-y"]
    if seek is not None:
        cmd += ["-ss", str(seek)]          # input seek, before -i
    cmd += ["-i", str(item["media"])]
    if item["is_video"]:
        cmd += ["-frames:v", "1"]
    cmd += ["-vf", scale, "-q:v", str(quality), str(dest)]
    return cmd


def run_thumb(item, dest, width, quality, seek):
    result = subprocess.run(thumb_cmd(item, dest, width, quality, seek),
                            capture_output=True, text=True)
    ok = result.returncode == 0 and dest.exists() and dest.stat().st_size > 0
    return ok, result.stderr.strip()


def make_thumb(item, thumbdir, width, quality, force):
    dest = thumbdir / (item["media"].stem + ".jpg")
    item["thumb"] = f"thumbs/{dest.name}"
    if not force and dest.exists() and dest.stat().st_size > 0:
        return "cached"

    # Videos: seek ~1s in, since the first frame is often black. Clips shorter
    # than that yield no frame, so fall back to seeking from the very start.
    seeks = [1, None] if item["is_video"] else [None]
    for seek in seeks:
        ok, stderr = run_thumb(item, dest, width, quality, seek)
        if ok:
            return "ok"

    print(f"  ! thumbnail failed for {item['media'].name}: {stderr[:200]}",
          file=sys.stderr)
    return "failed"


def post_link(item):
    """Deep-link to this exact image, not just the post.

    Instagram's `img_index` is 1-based and counts every carousel slide including
    videos, which is precisely what gallery-dl's `num` is -- so they map
    directly. Only added for real carousels: on a single-image post the
    parameter is noise, and reels have no slides to index.
    """
    if item["count"] > 1 and item["num"]:
        return f"{item['post_url']}?img_index={item['num']}"
    return item["post_url"]


def render_tile(item, index):
    desc = item["description"].replace("\r", " ")
    if len(desc) > CAPTION_CHARS:
        desc = desc[:CAPTION_CHARS].rstrip() + "…"

    user = item["username"]
    label = f"Instagram post by @{user}" if user else "Instagram post"
    if item["count"] > 1 and item["num"]:
        label += f" — image {item['num']} of {item['count']}"
    alt = desc[:120] if desc else label

    caption_parts = []
    if user:
        caption_parts.append(f'<span class="user">@{html.escape(user)}</span>')
    if desc:
        caption_parts.append(f'<span class="desc">{html.escape(desc)}</span>')
    caption = ('<figcaption>' + "".join(caption_parts) + '</figcaption>'
               if caption_parts else '')

    badge = '<span class="badge" aria-hidden="true">▶</span>' if item["is_video"] else ''

    if index < EAGER_TILES:
        loading = 'loading="eager" fetchpriority="high"'
    else:
        loading = 'loading="lazy" fetchpriority="low"'

    # Rows to span = rendered height + the gap that follows it, in row units.
    # Ceil so the track is never shorter than the tile (which would overlap).
    tile_px = COLUMN_PX * item["height"] / item["width"]
    span = math.ceil((tile_px + GAP_PX) / ROW_UNIT_PX)

    return f'''      <figure class="tile" style="grid-row:span {span}">
        <a href="{html.escape(post_link(item))}" target="_blank" rel="noopener noreferrer"
           aria-label="{html.escape(label)}">
          <img src="{html.escape(item['thumb'])}" alt="{html.escape(alt)}"
               width="{item['width']}" height="{item['height']}"
               {loading} decoding="async" />
          {badge}
          {caption}
        </a>
      </figure>'''


def render_page(items, title):
    tiles = "\n".join(render_tile(i, n) for n, i in enumerate(items))
    photos = sum(1 for i in items if not i["is_video"])
    videos = len(items) - photos
    posts = len({i["shortcode"] for i in items})
    summary = f"{photos:,} photos"
    if videos:
        summary += f" · {videos:,} videos"
    summary += f" · {posts:,} posts"

    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta name="robots" content="noindex, nofollow" />
<title>{html.escape(title)}</title>
<style>
  *, *::before, *::after {{ box-sizing: border-box; }}
  :root {{
    --bg: #101013;
    --fg: #ececf1;
    --muted: #9a9aa5;
    --gap: 14px;
  }}
  html {{ background: var(--bg); }}
  body {{
    margin: 0;
    padding: 0 var(--gap) 64px;
    background: var(--bg);
    color: var(--fg);
    font: 15px/1.5 ui-sans-serif, -apple-system, "Segoe UI", Roboto, sans-serif;
    -webkit-font-smoothing: antialiased;
  }}
  header {{
    max-width: 1600px;
    margin: 0 auto;
    padding: 40px 0 28px;
  }}
  h1 {{ margin: 0; font-size: 1.5rem; font-weight: 600; letter-spacing: -0.01em; }}
  .count {{ margin: 6px 0 0; color: var(--muted); font-size: 0.875rem; }}

  /* Masonry via CSS Grid with per-tile row spans (computed from each image's
     aspect ratio at build time). Row-major order, so reading top-to-bottom
     follows date order. Columns are a fixed {COLUMN_PX}px because the span
     maths depends on the exact rendered width. */
  .grid {{
    max-width: 1700px;
    margin: 0 auto;
    display: grid;
    grid-template-columns: repeat(auto-fill, {COLUMN_PX}px);
    justify-content: center;
    grid-auto-rows: {ROW_UNIT_PX}px;
    row-gap: 0;                 /* spacing comes from .tile margin-bottom, so a
                                   spanned track maps to exact pixels */
    column-gap: var(--gap);
  }}
  .tile {{
    margin: 0 0 var(--gap);
    min-width: 0;
  }}

  /* Below two columns the fixed-width grid would leave a lopsided single
     column, so fall back to plain block flow. grid-row spans are inert here,
     and the images go full width. */
  @media (max-width: {COLUMN_PX * 2 + GAP_PX + 40}px) {{
    .grid {{ display: block; max-width: 560px; }}
  }}
  .tile a {{
    position: relative;
    display: block;
    overflow: hidden;
    border-radius: 8px;
    background: #1c1c22;
    text-decoration: none;
    color: inherit;
  }}
  .tile img {{
    display: block;
    width: 100%;
    height: auto;           /* width+height attrs reserve space, so no reflow */
    transition: transform 240ms ease, opacity 240ms ease;
  }}
  .tile a:hover img, .tile a:focus-visible img {{ transform: scale(1.03); opacity: 0.82; }}
  .tile a:focus-visible {{ outline: 2px solid #6ea8ff; outline-offset: 3px; }}

  .badge {{
    position: absolute;
    top: 10px; right: 10px;
    display: grid;
    place-items: center;
    width: 26px; height: 26px;
    border-radius: 50%;
    background: rgba(0,0,0,0.55);
    font-size: 11px;
    padding-left: 2px;
  }}

  figcaption {{
    position: absolute;
    inset: auto 0 0 0;
    padding: 28px 12px 12px;
    background: linear-gradient(to top, rgba(0,0,0,0.88), rgba(0,0,0,0));
    font-size: 0.8125rem;
    opacity: 0;
    transform: translateY(6px);
    transition: opacity 240ms ease, transform 240ms ease;
  }}
  .tile a:hover figcaption, .tile a:focus-visible figcaption {{
    opacity: 1;
    transform: none;
  }}
  .user {{ display: block; font-weight: 600; margin-bottom: 3px; }}
  .desc {{
    display: -webkit-box;
    -webkit-line-clamp: 4;
    line-clamp: 4;
    -webkit-box-orient: vertical;
    overflow: hidden;
    color: #dcdce4;
  }}

  @media (hover: none) {{
    /* Touch devices get no hover, so keep captions visible. */
    figcaption {{ opacity: 1; transform: none; }}
  }}
  @media (prefers-reduced-motion: reduce) {{
    .tile img, figcaption {{ transition: none; }}
    .tile a:hover img {{ transform: none; }}
  }}
</style>
</head>
<body>
  <header>
    <h1>{html.escape(title)}</h1>
    <p class="count">{summary} · tap any image to open the original post</p>
  </header>
  <main class="grid">
{tiles}
  </main>
</body>
</html>
'''


def main():
    args = parse_args()
    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg not found on PATH")
    if not args.source.is_dir():
        sys.exit(f"source directory not found: {args.source}")

    items = load_items(args.source)
    if not items:
        sys.exit("no usable media found -- did gallery-dl write .json sidecars?")
    print(f"found {len(items)} media files")

    thumbdir = args.output / "thumbs"
    thumbdir.mkdir(parents=True, exist_ok=True)

    counts = {"ok": 0, "cached": 0, "failed": 0}
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(make_thumb, i, thumbdir, args.width,
                               args.quality, args.force): i for i in items}
        for n, future in enumerate(concurrent.futures.as_completed(futures), 1):
            counts[future.result()] += 1
            if n % 100 == 0 or n == len(items):
                print(f"  thumbnails {n}/{len(items)}")

    good = [i for i in items if (thumbdir / (i["media"].stem + ".jpg")).exists()]
    index = args.output / "index.html"
    index.write_text(render_page(good, args.title), encoding="utf-8")

    print(f"\nthumbnails: {counts['ok']} new, {counts['cached']} cached, "
          f"{counts['failed']} failed")
    print(f"wrote {index} with {len(good)} tiles")
    return 1 if counts["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
