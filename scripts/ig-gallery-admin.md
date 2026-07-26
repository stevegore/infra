# ig-gallery: hide-list admin

**Status: deployed 2026-07-26.** Stack 64 is running the nginx gallery and
`gallery-admin` sidecar; the live public and admin views use the hide list.

Goal: a per-image **Hide** button on an admin-only view of `gallery.stevegore.au`. Clicking
it dims the tile in the admin view and removes it from the public page. No database — one
text file. Admin access by client IP (home = admin) or by a query-param key.

---

## 1. What exists today (verified, 2026-07-26)

| Thing | Value |
| --- | --- |
| Site files | `/media/m2/ig-gallery/` on pico — `index.html` (3.0 MB), `admin.html` (3.5 MB) + `thumbs/` (137 MB, 3,110 files) |
| Containers | `ig-gallery` (`nginx:1.31.3-alpine`) + `gallery-admin` (`python:3.13.14-alpine`), stack ID **64** |
| Mounts | Generated site is nginx RO; state is nginx RO/sidecar RW; sidecar/config source is RO |
| nginx config | Rendered from `/media/m2/ig-gallery-admin/nginx.conf.template` with `NGINX_ENVSUBST_FILTER=^GALLERY_` |
| Direct client address | Docker currently preserves the LAN source (for example `192.168.4.23`); `172.19.0.1` remains trusted for bridge-SNAT deployments |
| Exposure | Caddy vhost `gallery.stevegore.au` → `pico:8090`, public, no Authentik |
| Generator | `scripts/build-gallery.py` (389 lines), runs on the **Mac** |
| Home public IP | `159.196.97.38` (residential, dynamic) |

Two facts that the whole design rests on, both confirmed from `docker logs ig-gallery`:

1. **Caddy forwards the true client IP.** A browser request from home logged
   `"159.196.97.38"` in the `$http_x_forwarded_for` field. Caddy *appends* to
   `X-Forwarded-For`, so with `real_ip_recursive off` the **last** entry is authoritative and
   a client cannot spoof its way in by sending its own header.
2. **Direct LAN/tailnet hits have no `X-Forwarded-For` at all.** Docker currently preserves
   the client address (`192.168.0.0/16` on the LAN, `100.64.0.0/10` on Tailscale); the Docker
   gateway range remains trusted for installations that SNAT port-published traffic. So
   "reached pico:8090 directly" is distinguishable from "came in over the internet" — and
   reaching that port already requires being on the LAN or the tailnet. That is what makes
   *home = admin* work without tracking the dynamic public IP.

**pico cannot regenerate the page.** The gallery-dl originals and their `.json` sidecars live
on the Mac (`~/Pictures/ig-export`); pico only has the built output. So hiding must be applied
at *serve* time, not by re-rendering.

---

## 2. Decision

Hide state is written **on pico**, by a small sidecar in the `ig-gallery` stack.

Considered and rejected:

- **Write from the Mac only** (local admin server, bake exclusions in at rebuild, rsync).
  Zero new infra and hidden images would be absent from the public HTML entirely — but admin
  only works at the Mac, only while it is awake, and each change costs an rsync. Loses the
  remote/phone access that the IP-or-key requirement implies.
- **Regenerate `index.html` on pico per click.** Impossible without shipping the metadata
  sidecars to pico.
- **nginx SSI** to inline the hide list. Re-parses a 3 MB document on every request and
  defeats static serving, for no gain over a stylesheet.
- **Client-side filter in JS.** Would leave hidden thumbnails in the DOM and fetch them.

---

## 3. How hiding works

`hidden.txt` holds one media id per line. A **generated `hidden.css`** turns it into

```css
[data-id="DbJlL2Sk-Gu_04"],
[data-id="DXvlk_4lt-M_02"] { display: none !important; }
```

The public `index.html` loads it as a normal blocking `<link>` in `<head>`, so:

- hidden tiles never render, and because they are `display:none` their **lazy images are never
  fetched** — no wasted bytes, no flash of hidden content;
- the CSS Grid reflows on its own. The per-tile `grid-row: span N` is inline and inert for a
  removed item, so no rebuild is needed to close the gap;
- the file is tiny (~30 bytes per hidden id) and served statically by nginx, so **the public
  page keeps hiding correctly even if the sidecar is down** — it fails closed.

The id is the media filename stem (`<shortcode>_<NN>`), which is stable across rebuilds and
maps 1:1 to `thumbs/<id>.jpg`.

The admin page deliberately does **not** load `hidden.css`. It asks `/api/hidden` and applies
its own `.is-hidden` class, so there is one source of truth for button state.

### State lives outside the site directory

```
/media/m2/ig-gallery-state/     hidden.txt, hidden.css        (rw for sidecar, ro for nginx)
/media/m2/ig-gallery-admin/     gallery-admin.py, nginx.conf.template   (ro everywhere)
/media/m2/ig-gallery/           generated site — rsync target
```

`hidden.txt` **must not** sit under `/media/m2/ig-gallery`, or an `rsync --delete` of a rebuild
would erase the curation. Keeping code out of the writable directory also means the sidecar
cannot overwrite its own source.

---

## 4. Authentication

All of it lives in nginx. There is exactly **one** secret, in **one** place (the Portainer
stack environment). The sidecar has no auth logic and no published port.

```nginx
set_real_ip_from 172.16.0.0/12;
real_ip_header    X-Forwarded-For;
real_ip_recursive off;          # take the LAST hop — the one Caddy added
map_hash_bucket_size 128;       # 48-char key does not fit the default 64-byte bucket

geo $gallery_admin_ip {
    default         0;
    172.16.0.0/12   1;   # Docker bridge/SNAT
    192.168.0.0/16  1;   # direct LAN
    100.64.0.0/10   1;   # direct Tailscale
    159.196.97.38   1;   # home public IP as Caddy sees it
}

map $arg_key $gallery_admin_key {
    default                 0;
    ""                      0;   # see note below
    "${GALLERY_ADMIN_KEY}"  1;
}

map $gallery_admin_ip$gallery_admin_key $gallery_admin {
    "00"     0;
    default  1;
}
```

`geo`/`map` are `http`-context directives; `conf.d/*.conf` is included inside `http`, so they
go at the top of the same file, above `server {}`.

**The `"" 0;` line is a fail-closed guard.** If `GALLERY_ADMIN_KEY` were empty, the template
would render `"" 1;` and *every* request without a `key` param would authenticate as admin.
With the explicit `"" 0;` above it the file instead contains a duplicate `map` key, which
nginx should reject at parse time — the container refuses to start rather than silently
opening up. **Verify this actually errors** on first deploy (`docker logs ig-gallery`); if
nginx tolerates the duplicate, fall back to asserting the variable in compose.

Gated locations return **404, not 403**, so the admin surface is not advertised:

```nginx
location = /admin      { return 302 /admin.html$is_args$args; }
location = /admin.html { if ($gallery_admin = 0) { return 404; }
                         add_header Cache-Control "no-store" always; }
location /api/         { if ($gallery_admin = 0) { return 404; }
                         proxy_pass http://gallery-admin:8080;
                         proxy_set_header X-Gallery-Auth ok; }
location = /hidden.css { alias /state/hidden.css;
                         default_type text/css;
                         add_header Cache-Control "no-cache" always; }
```

`location =` is an exact match and outranks `location /`, so `/admin.html` cannot be reached
through the ungated static handler. `proxy_set_header X-Gallery-Auth ok` **overwrites** any
value a client sent, and the sidecar requires that header — which keeps a future stray
`ports:` entry from quietly exposing a write endpoint.

The template is rendered by the nginx image's own entrypoint from
`/etc/nginx/templates/default.conf.template`. It needs
`NGINX_ENVSUBST_FILTER: "^GALLERY_"` — without the filter, `envsubst` also expands nginx's
own `$remote_addr`, `$arg_key`, `$is_args` to empty strings and the config is nonsense.

### The key

Generate one (`openssl rand -hex 24`), set it as `GALLERY_ADMIN_KEY` in the **Portainer stack
environment**, and store it in Vaultwarden. It must not be committed — `portainer.md` shows
`${GALLERY_ADMIN_KEY}` only.

Tradeoff worth stating: a key in a query string lands in browser history. The referrer path is
already covered — every outbound tile link carries `rel="noopener noreferrer"`, so Instagram
never sees the admin URL. The key exists mainly as the fallback for when the residential IP
changes, or for admin from mobile data.

---

## 5. File-by-file changes

### New: `scripts/gallery-admin.py`

Stdlib-only `ThreadingHTTPServer`, ~150 lines.

- `GET  /healthz` — ungated, for the container healthcheck.
- `GET  /api/hidden` → `{"hidden": [...], "count": n}`
- `POST /api/hide` `{"id": "...", "hidden": true}` → `{"id":…, "hidden":…, "count": n}`
- Requires `X-Gallery-Auth: ok`; anything else gets 404 to match nginx.

Points that matter:

- **Id validation is a security control, not hygiene.** `^[A-Za-z0-9_-]{1,64}$`, rejected
  rather than escaped: these strings are interpolated into a CSS attribute selector, and a
  stray quote would let a caller write arbitrary rules into a stylesheet every visitor loads.
- **Edit `hidden.txt` line-wise, don't rewrite it.** Removal filters out matching lines,
  adding appends one. Comments and blank lines survive, so the file stays genuinely
  hand-editable — which was the point of not using a database.
- **Atomic writes** (`write temp` + `os.replace`) so nginx never serves a half-written
  `hidden.css`.
- One `threading.Lock` around every read-modify-write.
- A ~5s **mtime watcher thread** regenerates `hidden.css` when `hidden.txt` changes
  underneath us. This is the cost of letting nginx serve the stylesheet statically: hand
  edits would otherwise never reach a visitor. The watcher must regenerate the **CSS only** —
  if it called the full save path it would rewrite `hidden.txt`, change its own mtime, and
  spin.
- Create `hidden.txt` (header comment) and `hidden.css` at startup so `/hidden.css` is a
  clean 200 rather than a 404 on a fresh deploy.

### New: `scripts/ig-gallery-nginx.conf.template`

Section 4, plus the existing static `location /`. Deployed to
`/media/m2/ig-gallery-admin/nginx.conf.template`.

### Changed: `scripts/build-gallery.py`

1. `load_items` — add `"id": media.stem`.
2. `render_tile(item, index, admin=False)` — add `data-id="{id}"` to the `<figure>`; when
   `admin`, append a `<button class="hide-btn">` **as a sibling of the `<a>`, not inside it**
   (interactive elements cannot nest).
3. `render_page(items, title, admin=False)` —
   - public: add `<link rel="stylesheet" href="hidden.css" />`;
   - admin: `<body class="admin">`, a toolbar (hidden count, "show only hidden" checkbox, a
     status line), the admin CSS, and ~40 lines of inline JS.
4. `main` — also write `admin.html`.
5. New `--hidden-list PATH` (optional): drop those ids from `index.html` **entirely** rather
   than CSS-hiding them, while `admin.html` still renders them dimmed so they can be
   unhidden. Lets a rebuild bake the curation in permanently.

Admin CSS notes: `.tile` needs `position: relative` (currently only `.tile a` has it). Dim
the `<a>`, not the `.tile` — `.tile.is-hidden > a { opacity:.22; filter:grayscale(1) }` — or
the button dims along with the image and becomes unreadable. Buttons sit at `opacity:.55`,
rising to `1` on tile hover/focus-within, and always `1` on a hidden tile.

Admin JS: read `key` from `location.search` and append it to every API call; update the tile
optimistically so the dim feels instant, and revert it plus show the error if the write fails.
Derive the count from `document.querySelectorAll('.tile.is-hidden').length` rather than the
server's total, so the two can't disagree.

### Changed: `apps/caddy/templates/configmap.yaml`

Only the no-cache matcher, from

```
@html path / /index.html
```

to

```
@nocache path / /index.html /admin.html /hidden.css
```

`/hidden.css` **must** be no-cache or hiding won't take effect until the browser revalidates.
No auth changes here — nginx owns that, and `reverse_proxy` already passes POST through.

### Changed: `portainer.md`

New compose for stack 64 (below), the admin runbook, and the key stored as
`${GALLERY_ADMIN_KEY}`.

Also fix stale content already in that section: it claims *"211 MB of thumbnails, 2.8 MB
index.html"*, but the q6 re-encode landed and the real figures are **137 MB and 3.0 MB**.

```yaml
services:
  ig-gallery:
    image: nginx:1.31.3-alpine
    container_name: ig-gallery
    restart: unless-stopped
    ports:
      - "8090:80"
    volumes:
      - /media/m2/ig-gallery:/usr/share/nginx/html:ro
      - /media/m2/ig-gallery-state:/state:ro
      - /media/m2/ig-gallery-admin/nginx.conf.template:/etc/nginx/templates/default.conf.template:ro
    environment:
      TZ: Australia/Sydney
      NGINX_ENVSUBST_FILTER: "^GALLERY_"
      GALLERY_ADMIN_KEY: ${GALLERY_ADMIN_KEY}
    depends_on:
      - gallery-admin
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost/index.html"]
      interval: 30s
      timeout: 5s
      retries: 3

  gallery-admin:
    image: python:3.13.14-alpine
    container_name: gallery-admin
    restart: unless-stopped
    user: "1000:1000"
    # No `ports:` on purpose — nginx is the only route in, and nginx is where the
    # authentication lives.
    volumes:
      - /media/m2/ig-gallery-admin/gallery-admin.py:/app/gallery-admin.py:ro
      - /media/m2/ig-gallery-state:/state
    environment:
      TZ: Australia/Sydney
      GALLERY_STATE_DIR: /state
      PYTHONUNBUFFERED: "1"
    command: ["python3", "/app/gallery-admin.py"]
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8080/healthz', timeout=3)"]
      interval: 30s
      timeout: 5s
      retries: 3
```

Unverified: whether Portainer's compose interpolation supports the `${VAR:?message}` error
form. Plain `${GALLERY_ADMIN_KEY}` above is the safe version; the nginx duplicate-map-key
guard is the real backstop.

---

## 6. Deploy sequence

```sh
# 1. state + code dirs on pico
ssh pico.local 'mkdir -p /media/m2/ig-gallery-state /media/m2/ig-gallery-admin'

# 2. ship sidecar + nginx template (pico's repo clone is stranded at b6d2097 and
#    cannot `git pull` — credential failure — so scp, don't rely on ~/code/infra)
scp scripts/gallery-admin.py pico.local:/media/m2/ig-gallery-admin/
scp scripts/ig-gallery-nginx.conf.template \
    pico.local:/media/m2/ig-gallery-admin/nginx.conf.template

# 3. rebuild the site so index.html carries data-id + the hidden.css link, and
#    admin.html exists at all
python3 scripts/build-gallery.py ~/Pictures/ig-export ~/Pictures/ig-gallery \
  --title "Renovation"
rsync -a ~/Pictures/ig-gallery/ pico.local:/media/m2/ig-gallery/

# 4. redeploy stack 64 via the Portainer API with GALLERY_ADMIN_KEY in Env
#    (see portainer.md for the token/endpoint)

# 5. Caddy: commit + push the @nocache change; ArgoCD syncs on merge
```

All existing thumbnails are reused in step 3 — the rebuild only re-renders HTML.

## 7. Verification

- `docker logs ig-gallery` — config parsed, no envsubst damage (`$remote_addr` intact).
- Empty-key guard: temporarily deploy with `GALLERY_ADMIN_KEY=""` and confirm nginx **refuses
  to start**. This is the single most important check in the list.
- `curl -sI https://gallery.stevegore.au/admin.html` from a non-home network → **404**.
- Same URL with `?key=…` → 200.
- From home → 200 with no key.
- `http://pico.local:8090/admin.html` on the LAN → 200 with no key.
- `curl -X POST .../api/hide` without a key from off-network → 404, and `hidden.txt`
  unchanged.
- Click Hide on a tile → dims immediately; the id appears in `hidden.txt`; a public reload no
  longer shows it and its thumbnail is **not** in the network log.
- Hand-add an id to `hidden.txt`, wait ~5s, confirm `hidden.css` regenerated.
- Grid still has no overlapping tiles or horizontal overflow after tiles are removed.

## 8. Open items

- `portainer.md` TOC still mislabels `homepage` as "(Portainer-managed)" though it runs on
  OKE. Pre-existing, unrelated, still unfixed.
- Gallery is intentionally absent from the public `status.stevegore.au` page.
- `scripts/__pycache__` is not in `.gitignore`.
- Orphaned pico volume `uptime-kuma_uptime-kuma_data`.
- Commit `5b23a77`'s message body contains a stray non-English word ("build-time计算"). Fixing
  it needs a force-push to `main`.
- `hidden.txt` is authoritative only on pico. Worth adding a `scp` of it into the rebuild
  runbook as a backup once there is curation worth losing.
