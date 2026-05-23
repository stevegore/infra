#!/usr/bin/env python3
"""Insert monitor + tag records into Uptime Kuma's SQLite DB."""
import json, sqlite3, sys

DB_PATH = "/app/data/kuma.db"  # path inside container
USER_ID = 1

# tag definitions: name -> color
TAGS = {
    "public":   "#dc3545",  # red
    "internal": "#0d6efd",  # blue
    "infra":    "#198754",  # green
    "media":    "#ffc107",  # amber
    "photos":   "#e83e8c",  # pink
}

# monitors: (name, type, kwargs, [tags])
# kwargs may include: url, hostname, port, accepted_statuscodes_json, maxredirects,
#                     interval, retry_interval, maxretries, keyword, timeout
DEFAULT_INTERVAL = 60
DEFAULT_TIMEOUT = 16
DEFAULT_RETRIES = 1
ACCEPT_OK = '["200-299"]'
ACCEPT_OK_REDIR = '["200-399"]'
ACCEPT_302 = '["302"]'

monitors = [
    # === Infrastructure ===
    ("Ping pico.local",          "ping",    {"hostname": "pico.local"},               ["infra"]),
    ("Ping ampere-ubuntu (WG)",  "ping",    {"hostname": "10.20.30.2"},               ["infra"]),
    ("TCP pico SSH",             "port",    {"hostname": "pico.local", "port": 22},   ["infra"]),

    # === Public (Caddy-fronted, open) ===
    ("stevegore.au (ttyd)",      "http", {"url": "https://stevegore.au/", "maxredirects": 10, "accepted_statuscodes_json": ACCEPT_OK}, ["public"]),
    ("auth.stevegore.au",        "http", {"url": "https://auth.stevegore.au/", "maxredirects": 10, "accepted_statuscodes_json": ACCEPT_OK}, ["public","infra"]),
    ("hass.stevegore.au",        "http", {"url": "https://hass.stevegore.au/", "maxredirects": 5,  "accepted_statuscodes_json": ACCEPT_OK_REDIR}, ["public"]),
    ("immich.stevegore.au",      "http", {"url": "https://immich.stevegore.au/api/server/ping", "maxredirects": 0, "keyword": "pong", "accepted_statuscodes_json": ACCEPT_OK}, ["public","photos"]),
    ("photos.stevegore.au",      "http", {"url": "https://photos.stevegore.au/api/v1/status", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, ["public","photos"]),
    ("plex.stevegore.au",        "http", {"url": "https://plex.stevegore.au/identity", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, ["public","media"]),
    ("huggin.stevegore.au",      "http", {"url": "https://huggin.stevegore.au/", "maxredirects": 5,  "accepted_statuscodes_json": ACCEPT_OK}, ["public"]),
    ("port.stevegore.au",        "http", {"url": "https://port.stevegore.au/", "maxredirects": 5,  "accepted_statuscodes_json": ACCEPT_OK}, ["public","infra"]),
    ("strava.stevegore.au",      "http", {"url": "https://strava.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, ["public"]),
    ("bw.stevegore.au",          "http", {"url": "https://bw.stevegore.au/alive", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, ["public"]),
    ("pdf.stevegore.au",         "http", {"url": "https://pdf.stevegore.au/", "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_OK}, ["public"]),
    ("vault.stevegore.au",       "http", {"url": "https://vault.stevegore.au/v1/sys/health", "maxredirects": 0, "accepted_statuscodes_json": '["200-299","429","473","501","503"]'}, ["public","infra"]),
    ("argocd.stevegore.au",      "http", {"url": "https://argocd.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, ["public","infra"]),

    # === Public (Caddy-fronted, GitHub-auth protected) — expect 302 redirect to auth ===
    ("homepage.stevegore.au",    "http", {"url": "https://homepage.stevegore.au/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_302}, ["public"]),
    ("desk.stevegore.au",        "http", {"url": "https://desk.stevegore.au/",     "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_302}, ["public"]),
    ("gym.stevegore.au",         "http", {"url": "https://gym.stevegore.au/",      "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_302}, ["public"]),

    # === Internal pico.local services (direct port checks) ===
    ("Radarr",          "http", {"url": "http://pico.local:7878/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, ["internal","media"]),
    ("Sonarr",          "http", {"url": "http://pico.local:8989/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, ["internal","media"]),
    ("Jackett",         "http", {"url": "http://pico.local:9117/UI/Dashboard", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, ["internal","media"]),
    ("Transmission",    "http", {"url": "http://pico.local:9092/transmission/web/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, ["internal","media"]),
    ("FlareSolverr",    "http", {"url": "http://pico.local:8191/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, ["internal","media"]),
    ("Duplicati",       "http", {"url": "http://pico.local:8200/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, ["internal","infra"]),
    ("Stirling PDF",    "http", {"url": "http://pico.local:8083/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, ["internal"]),
    ("StravaBot",       "http", {"url": "http://pico.local:8082/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, ["internal"]),
    ("StravaKeeper",    "http", {"url": "http://pico.local:8180/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, ["internal"]),
    ("PhotoPrism (local)","http",{"url": "http://pico.local:2342/api/v1/status", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, ["internal","photos"]),
    ("Immich (local)",  "http", {"url": "http://pico.local:2283/api/server/ping", "maxredirects": 0, "keyword": "pong", "accepted_statuscodes_json": ACCEPT_OK}, ["internal","photos"]),
    ("Huginn (local)",  "http", {"url": "http://pico.local:3000/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, ["internal"]),
    ("Homepage (local)","http", {"url": "http://pico.local:8080/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, ["internal","infra"]),
    ("GymBooking",      "http", {"url": "http://pico.local:8112/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, ["internal"]),
    ("NuraSpace",       "http", {"url": "http://pico.local:8111/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, ["internal"]),
    ("Portainer (local)","http",{"url": "http://pico.local:9000/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, ["internal","infra"]),
]

conn = sqlite3.connect(DB_PATH)
cur = conn.cursor()

# upsert tags
tag_ids = {}
for name, color in TAGS.items():
    cur.execute("SELECT id FROM tag WHERE name=?", (name,))
    row = cur.fetchone()
    if row:
        tag_ids[name] = row[0]
    else:
        cur.execute("INSERT INTO tag (name, color, created_date) VALUES (?, ?, DATETIME('now'))", (name, color))
        tag_ids[name] = cur.lastrowid

inserted = 0
for name, mtype, kwargs, tags in monitors:
    cur.execute("SELECT id FROM monitor WHERE name=?", (name,))
    if cur.fetchone():
        continue
    cols = ["name","type","user_id","active","interval","retry_interval","maxretries","timeout"]
    vals = [name, mtype, USER_ID, 1, kwargs.pop("interval", DEFAULT_INTERVAL),
            kwargs.pop("retry_interval", 60), kwargs.pop("maxretries", DEFAULT_RETRIES),
            kwargs.pop("timeout", DEFAULT_TIMEOUT)]
    for k, v in kwargs.items():
        cols.append(k); vals.append(v)
    placeholders = ",".join("?" for _ in cols)
    cur.execute(f"INSERT INTO monitor ({','.join(cols)}) VALUES ({placeholders})", vals)
    monitor_id = cur.lastrowid
    for tg in tags:
        cur.execute("INSERT INTO monitor_tag (monitor_id, tag_id) VALUES (?, ?)", (monitor_id, tag_ids[tg]))
    inserted += 1

conn.commit()
print(f"Tags ready: {list(tag_ids.keys())}")
print(f"Monitors inserted: {inserted} (skipped if already present)")
cur.execute("SELECT COUNT(*) FROM monitor")
print(f"Total monitors in DB: {cur.fetchone()[0]}")
conn.close()
