#!/usr/bin/env python3
"""Create a public status page 'homelab' with grouped monitors."""
import sqlite3

DB = "/app/data/kuma.db"
SLUG = "homelab"
TITLE = "Steve's Homelab"
ICON = "/icon.svg"
THEME = "dark"

# group_name -> list of monitor name regexes (using LIKE patterns)
GROUPS = [
    ("Public Services",   ["%.stevegore.au"]),
    ("Internal",          ["Radarr","Sonarr","Jackett","Transmission","FlareSolverr",
                           "Duplicati","Stirling PDF","StravaBot","StravaKeeper",
                           "PhotoPrism (local)","Immich (local)","Huginn (local)",
                           "Homepage (local)","GymBooking","NuraSpace","Portainer (local)"]),
    ("Infrastructure",    ["Ping pico.local","Ping ampere-ubuntu (WG)","TCP pico SSH"]),
]

conn = sqlite3.connect(DB)
cur = conn.cursor()

# upsert status page
cur.execute("SELECT id FROM status_page WHERE slug=?", (SLUG,))
row = cur.fetchone()
if row:
    sp_id = row[0]
    print(f"Status page '{SLUG}' already exists (id={sp_id})")
else:
    cur.execute("""
        INSERT INTO status_page (slug, title, description, icon, theme, published, search_engine_index, show_tags, show_powered_by, show_certificate_expiry)
        VALUES (?, ?, ?, ?, ?, 1, 0, 1, 1, 0)
    """, (SLUG, TITLE, "Personal homelab uptime", ICON, THEME))
    sp_id = cur.lastrowid
    print(f"Status page created id={sp_id} slug={SLUG}")

# clear existing groups for this status page (idempotent rebuild)
cur.execute("DELETE FROM `group` WHERE status_page_id=?", (sp_id,))

weight = 0
for gname, patterns in GROUPS:
    weight += 100
    cur.execute("INSERT INTO `group` (name, public, active, weight, status_page_id) VALUES (?, 1, 1, ?, ?)",
                (gname, weight, sp_id))
    gid = cur.lastrowid
    mweight = 0
    for pat in patterns:
        if "%" in pat:
            cur.execute("SELECT id, name FROM monitor WHERE name LIKE ? ORDER BY name", (pat,))
        else:
            cur.execute("SELECT id, name FROM monitor WHERE name=?", (pat,))
        for mid, mname in cur.fetchall():
            mweight += 100
            cur.execute("INSERT INTO monitor_group (monitor_id, group_id, weight, send_url) VALUES (?, ?, ?, 0)",
                        (mid, gid, mweight))
    print(f"  Group '{gname}' (id={gid}) populated")

conn.commit()
conn.close()
print(f"\nStatus page URL: http://pico.local:3001/status/{SLUG}")
