#!/usr/bin/env python3
"""Reconcile Uptime Kuma monitors and tags into the live SQLite DB."""
import sqlite3

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

DEFAULT_INTERVAL = 60
DEFAULT_TIMEOUT = 16
DEFAULT_RETRIES = 1
ACCEPT_OK = '["200-299"]'
ACCEPT_OK_REDIR = '["200-399"]'
ACCEPT_302 = '["302"]'
ACCEPT_VAULT = '["200-299","429","473","501","503"]'

OPTIONAL_FIELDS = [
    "url",
    "hostname",
    "port",
    "accepted_statuscodes_json",
    "maxredirects",
    "keyword",
]

retired_monitor_names = {
    "Ping ampere-ubuntu (WG)",
    "photos.stevegore.au",
    "PhotoPrism (local)",
}

monitors = [
    {"name": "Ping pico", "type": "ping", "kwargs": {"hostname": "pico"}, "tags": ["infra"], "aliases": ["Ping pico.local"]},
    {"name": "TCP pico SSH", "type": "port", "kwargs": {"hostname": "pico", "port": 22}, "tags": ["infra"]},

    {"name": "stevegore.au (ttyd)", "type": "http", "kwargs": {"url": "https://stevegore.au/", "maxredirects": 10, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public"]},
    {"name": "auth.stevegore.au", "type": "http", "kwargs": {"url": "https://auth.stevegore.au/", "maxredirects": 10, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public", "infra"]},
    {"name": "hass.stevegore.au", "type": "http", "kwargs": {"url": "https://hass.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["public"]},
    {"name": "hass2.stevegore.au", "type": "http", "kwargs": {"url": "https://hass2.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["public"]},
    {"name": "immich.stevegore.au", "type": "http", "kwargs": {"url": "https://immich.stevegore.au/api/server/ping", "maxredirects": 0, "keyword": "pong", "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public", "photos"]},
    {"name": "plex.stevegore.au", "type": "http", "kwargs": {"url": "https://plex.stevegore.au/identity", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public", "media"]},
    {"name": "huggin.stevegore.au", "type": "http", "kwargs": {"url": "https://huggin.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public"]},
    {"name": "port.stevegore.au", "type": "http", "kwargs": {"url": "https://port.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public", "infra"]},
    {"name": "strava.stevegore.au", "type": "http", "kwargs": {"url": "https://strava.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["public"]},
    {"name": "bw.stevegore.au", "type": "http", "kwargs": {"url": "https://bw.stevegore.au/alive", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public"]},
    {"name": "bw2.stevegore.au", "type": "http", "kwargs": {"url": "https://bw2.stevegore.au/alive", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public"]},
    {"name": "pdf.stevegore.au", "type": "http", "kwargs": {"url": "https://pdf.stevegore.au/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public"]},
    {"name": "vault.stevegore.au", "type": "http", "kwargs": {"url": "https://vault.stevegore.au/v1/sys/health", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_VAULT}, "tags": ["public", "infra"]},
    {"name": "argocd.stevegore.au", "type": "http", "kwargs": {"url": "https://argocd.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public", "infra"]},
    {"name": "homepage.stevegore.au", "type": "http", "kwargs": {"url": "https://homepage.stevegore.au/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_302}, "tags": ["public"]},
    {"name": "desk.stevegore.au", "type": "http", "kwargs": {"url": "https://desk.stevegore.au/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_302}, "tags": ["public"]},
    {"name": "gym.stevegore.au", "type": "http", "kwargs": {"url": "https://gym.stevegore.au/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_302}, "tags": ["public"]},
    {"name": "openclaw.stevegore.au", "type": "http", "kwargs": {"url": "https://openclaw.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public"]},
    {"name": "uptime.stevegore.au", "type": "http", "kwargs": {"url": "https://uptime.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public", "infra"]},

    {"name": "Radarr", "type": "http", "kwargs": {"url": "http://pico:7878/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["internal", "media"]},
    {"name": "Sonarr", "type": "http", "kwargs": {"url": "http://pico:8989/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["internal", "media"]},
    {"name": "Jackett", "type": "http", "kwargs": {"url": "http://pico:9117/UI/Dashboard", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["internal", "media"]},
    {"name": "Transmission", "type": "http", "kwargs": {"url": "http://pico:9092/transmission/web/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal", "media"]},
    {"name": "FlareSolverr", "type": "http", "kwargs": {"url": "http://pico:8191/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["internal", "media"]},
    {"name": "Duplicati", "type": "http", "kwargs": {"url": "http://pico:8200/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal", "infra"]},
    {"name": "Stirling PDF", "type": "http", "kwargs": {"url": "http://pico:8083/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["internal"]},
    {"name": "StravaBot", "type": "http", "kwargs": {"url": "http://pico:8082/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal"]},
    {"name": "StravaKeeper", "type": "http", "kwargs": {"url": "http://pico:8180/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal"]},
    {"name": "Immich (direct)", "type": "http", "kwargs": {"url": "http://pico:2283/api/server/ping", "maxredirects": 0, "keyword": "pong", "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["internal", "photos"], "aliases": ["Immich (local)"]},
    {"name": "Huginn (direct)", "type": "http", "kwargs": {"url": "http://pico:3000/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["internal"], "aliases": ["Huginn (local)"]},
    {"name": "Homepage (direct)", "type": "http", "kwargs": {"url": "http://pico:8080/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["internal", "infra"], "aliases": ["Homepage (local)"]},
    {"name": "GymBooking", "type": "http", "kwargs": {"url": "http://pico:8112/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal"]},
    {"name": "NuraSpace", "type": "http", "kwargs": {"url": "http://pico:8111/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal"]},
    {"name": "Portainer (direct)", "type": "http", "kwargs": {"url": "http://pico:9000/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal", "infra"], "aliases": ["Portainer (local)"]},
    {"name": "phpMyAdmin", "type": "http", "kwargs": {"url": "http://pico:3011/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal", "infra"]},
]


def fetch_monitor_id(names):
    placeholders = ",".join("?" for _ in names)
    cur.execute(f"SELECT id, name FROM monitor WHERE name IN ({placeholders}) ORDER BY CASE WHEN name=? THEN 0 ELSE 1 END, id LIMIT 1", (*names, names[0]))
    return cur.fetchone()


def reconcile_monitor(spec):
    desired_name = spec["name"]
    aliases = spec.get("aliases", [])
    existing = fetch_monitor_id([desired_name, *aliases])

    fields = {
        "name": desired_name,
        "type": spec["type"],
        "user_id": USER_ID,
        "active": 1,
        "interval": spec["kwargs"].get("interval", DEFAULT_INTERVAL),
        "retry_interval": spec["kwargs"].get("retry_interval", 60),
        "maxretries": spec["kwargs"].get("maxretries", DEFAULT_RETRIES),
        "timeout": spec["kwargs"].get("timeout", DEFAULT_TIMEOUT),
    }
    for field in OPTIONAL_FIELDS:
        fields[field] = spec["kwargs"].get(field)

    if existing:
        monitor_id, _ = existing
        assignments = ", ".join(f"{column}=?" for column in fields)
        cur.execute(f"UPDATE monitor SET {assignments} WHERE id=?", (*fields.values(), monitor_id))
        cur.execute("DELETE FROM monitor_tag WHERE monitor_id=?", (monitor_id,))
    else:
        columns = list(fields.keys())
        placeholders = ",".join("?" for _ in columns)
        cur.execute(f"INSERT INTO monitor ({','.join(columns)}) VALUES ({placeholders})", tuple(fields[column] for column in columns))
        monitor_id = cur.lastrowid

    for tag_name in spec["tags"]:
        cur.execute("INSERT INTO monitor_tag (monitor_id, tag_id) VALUES (?, ?)", (monitor_id, tag_ids[tag_name]))

    return monitor_id

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

managed_names = set()
for monitor in monitors:
    reconcile_monitor(monitor)
    managed_names.add(monitor["name"])
    managed_names.update(monitor.get("aliases", []))

for retired_name in retired_monitor_names:
    cur.execute("UPDATE monitor SET active=0 WHERE name=?", (retired_name,))

conn.commit()
print(f"Tags ready: {list(tag_ids.keys())}")
print(f"Managed monitors: {len(monitors)}")
print(f"Retired monitors deactivated: {sorted(retired_monitor_names)}")
cur.execute("SELECT COUNT(*) FROM monitor")
print(f"Total monitors in DB: {cur.fetchone()[0]}")
conn.close()
