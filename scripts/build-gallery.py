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
import pathlib
import shutil
import subprocess
import sys

THUMB_QUALITY = "3"  # ffmpeg -q:v, 2-5 is visually fine for grid thumbs
CAPTION_CHARS = 400


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("source", type=pathlib.Path)
    p.add_argument("output", type=pathlib.Path)
    p.add_argument("--title", default="Instagram Collection")
    p.add_argument("--width", type=int, default=600,
                   help="thumbnail width in px (default 600, ~2x a 300px column)")
    p.add_argument("--jobs", type=int, default=8)
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
            "width": width,
            "height": height,
        })

    # Newest post first; carousel siblings stay in shot order within a post.
    items.sort(key=lambda i: (i["date"], i["shortcode"], i["num"]), reverse=True)
    return items


def thumb_cmd(item, dest, width, seek=None):
    """ffmpeg invocation producing a single JPEG thumbnail."""
    # -vf scale: -2 keeps aspect ratio and forces even dimensions (JPEG-safe).
    scale = f"scale={width}:-2:flags=lanczos"
    cmd = ["ffmpeg", "-nostdin", "-v", "error", "-y"]
    if seek is not None:
        cmd += ["-ss", str(seek)]          # input seek, before -i
    cmd += ["-i", str(item["media"])]
    if item["is_video"]:
        cmd += ["-frames:v", "1"]
    cmd += ["-vf", scale, "-q:v", THUMB_QUALITY, str(dest)]
    return cmd


def run_thumb(item, dest, width, seek):
    result = subprocess.run(thumb_cmd(item, dest, width, seek),
                            capture_output=True, text=True)
    ok = result.returncode == 0 and dest.exists() and dest.stat().st_size > 0
    return ok, result.stderr.strip()


def make_thumb(item, thumbdir, width):
    dest = thumbdir / (item["media"].stem + ".jpg")
    item["thumb"] = f"thumbs/{dest.name}"
    if dest.exists() and dest.stat().st_size > 0:
        return "cached"

    # Videos: seek ~1s in, since the first frame is often black. Clips shorter
    # than that yield no frame, so fall back to seeking from the very start.
    seeks = [1, None] if item["is_video"] else [None]
    for seek in seeks:
        ok, stderr = run_thumb(item, dest, width, seek)
        if ok:
            return "ok"

    print(f"  ! thumbnail failed for {item['media'].name}: {stderr[:200]}",
          file=sys.stderr)
    return "failed"


def render_tile(item):
    desc = item["description"].replace("\r", " ")
    if len(desc) > CAPTION_CHARS:
        desc = desc[:CAPTION_CHARS].rstrip() + "…"

    user = item["username"]
    label = f"Instagram post by @{user}" if user else "Instagram post"
    alt = desc[:120] if desc else label

    caption_parts = []
    if user:
        caption_parts.append(f'<span class="user">@{html.escape(user)}</span>')
    if desc:
        caption_parts.append(f'<span class="desc">{html.escape(desc)}</span>')
    caption = ('<figcaption>' + "".join(caption_parts) + '</figcaption>'
               if caption_parts else '')

    badge = '<span class="badge" aria-hidden="true">▶</span>' if item["is_video"] else ''

    return f'''      <figure class="tile">
        <a href="{html.escape(item['post_url'])}" target="_blank" rel="noopener noreferrer"
           aria-label="{html.escape(label)}">
          <img src="{html.escape(item['thumb'])}" alt="{html.escape(alt)}"
               width="{item['width']}" height="{item['height']}"
               loading="lazy" decoding="async" />
          {badge}
          {caption}
        </a>
      </figure>'''


def render_page(items, title):
    tiles = "\n".join(render_tile(i) for i in items)
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

  /* Masonry via CSS multi-column: no JS, no layout pass. */
  .grid {{
    max-width: 1600px;
    margin: 0 auto;
    column-width: 320px;
    column-gap: var(--gap);
  }}
  .tile {{
    margin: 0 0 var(--gap);
    break-inside: avoid;
    -webkit-column-break-inside: avoid;
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
        futures = {pool.submit(make_thumb, i, thumbdir, args.width): i for i in items}
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
