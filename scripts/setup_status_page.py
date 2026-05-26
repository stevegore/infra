#!/usr/bin/env python3
"""Create/refresh the public 'homelab' status page with grouped monitors.

Mirrors the live setup on https://uptime.stevegore.au/status/homelab.
"""
import sqlite3

DB = "/app/data/kuma.db"
SLUG = "homelab"
TITLE = "Home Lab"
DESCRIPTION = "Steve's Public Status Page"
ICON = "/icon.svg"
THEME = "auto"
PUBLISHED = 1
SEARCH_ENGINE_INDEX = 1
SHOW_TAGS = 0
SHOW_POWERED_BY = 0
SHOW_CERTIFICATE_EXPIRY = 0

# Custom domains that serve this status page at /. Caddy reverse-proxies
# each one to uptime-kuma; Kuma picks the right page based on Host header.
CNAMES = ["status.stevegore.au"]

# group_name -> ordered list of exact monitor names
GROUPS = [
    ("Home", [
        "stevegore.au",
        "Homepage",
    ]),
    ("Infrastructure", [
        "Argo CD",
        "Auth Service",
        "Duplicati",
        "Home Assistant",
        "Home Assistant (CF Tunnel)",
        "Homepage (direct)",
        "Portainer",
        "Portainer (direct)",
        "Uptime Kuma",
    ]),
    ("Agents", [
        "OpenClaw",
        "Huggin",
        "Huginn (direct)",
    ]),
    ("Photos", [
        "Immich",
        "PhotoPrism",
    ]),
    ("Security", [
        "Vault",
        "Vaultwarden",
        "Vaultwarden Replica",
    ]),
    ("Tools", [
        "Stirling PDF",
        "Stirling PDF (direct)",
        "phpMyAdmin",
    ]),
    ("Custom Apps", [
        "Desk Service",
        "NuraSpace",
        "Gym Bookings",
        "Gym Bookings (direct)",
        "Strava Service",
        "StravaKeeper",
        "StravaBot",
    ]),
    ("Hosts", [
        "Ping pico",
        "TCP pico SSH",
    ]),
]

conn = sqlite3.connect(DB)
cur = conn.cursor()

# upsert status page (reconcile metadata on every run)
cur.execute("SELECT id FROM status_page WHERE slug=?", (SLUG,))
row = cur.fetchone()
if row:
    sp_id = row[0]
    cur.execute("""
        UPDATE status_page
        SET title=?, description=?, icon=?, theme=?, published=?,
            search_engine_index=?, show_tags=?, show_powered_by=?, show_certificate_expiry=?
        WHERE id=?
    """, (TITLE, DESCRIPTION, ICON, THEME, PUBLISHED,
          SEARCH_ENGINE_INDEX, SHOW_TAGS, SHOW_POWERED_BY, SHOW_CERTIFICATE_EXPIRY, sp_id))
    print(f"Status page '{SLUG}' updated (id={sp_id})")
else:
    cur.execute("""
        INSERT INTO status_page (slug, title, description, icon, theme, published, search_engine_index, show_tags, show_powered_by, show_certificate_expiry)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (SLUG, TITLE, DESCRIPTION, ICON, THEME, PUBLISHED,
          SEARCH_ENGINE_INDEX, SHOW_TAGS, SHOW_POWERED_BY, SHOW_CERTIFICATE_EXPIRY))
    sp_id = cur.lastrowid
    print(f"Status page created id={sp_id} slug={SLUG}")

# reconcile custom-domain aliases (idempotent: drop+reinsert for this page)
cur.execute("DELETE FROM status_page_cname WHERE status_page_id=?", (sp_id,))
for domain in CNAMES:
    cur.execute(
        "INSERT INTO status_page_cname (status_page_id, domain) VALUES (?, ?)",
        (sp_id, domain),
    )
if CNAMES:
    print(f"Custom domains: {', '.join(CNAMES)}")

# clear existing groups for this status page (idempotent rebuild)
cur.execute("DELETE FROM `group` WHERE status_page_id=?", (sp_id,))

for group_weight, (gname, monitor_names) in enumerate(GROUPS, start=1):
    cur.execute(
        "INSERT INTO `group` (name, public, active, weight, status_page_id) VALUES (?, 1, 1, ?, ?)",
        (gname, group_weight, sp_id),
    )
    gid = cur.lastrowid
    matched = 0
    for monitor_weight, mname in enumerate(monitor_names, start=1):
        cur.execute("SELECT id FROM monitor WHERE name=?", (mname,))
        mrow = cur.fetchone()
        if not mrow:
            print(f"  WARN: monitor '{mname}' not found (skipping)")
            continue
        cur.execute(
            "INSERT INTO monitor_group (monitor_id, group_id, weight, send_url) VALUES (?, ?, ?, 0)",
            (mrow[0], gid, monitor_weight),
        )
        matched += 1
    print(f"  Group '{gname}' (id={gid}) populated with {matched}/{len(monitor_names)} monitors")

conn.commit()
conn.close()
print(f"\nStatus page URL: https://uptime.stevegore.au/status/{SLUG}")
for domain in CNAMES:
    print(f"Custom-domain URL: https://{domain}/")
