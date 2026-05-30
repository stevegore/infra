#!/usr/bin/env python3
"""Reconcile Uptime Kuma monitors and tags into the live SQLite DB.

Mirrors the live setup on https://uptime.stevegore.au (OKE deployment). Old
DNS-style names (e.g. `auth.stevegore.au`) are kept as aliases so the
reconcile renames in place instead of creating duplicates.
"""
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

OPTIONAL_DEFAULTS = {
    "url": None,
    "hostname": None,
    "port": None,
    "accepted_statuscodes_json": ACCEPT_OK,
    "maxredirects": 0,
    "keyword": None,
}

retired_monitor_names = {
    "Ping ampere-ubuntu (WG)",
}

monitors = [
    # hosts
    {"name": "Ping pico", "type": "ping", "kwargs": {"hostname": "pico"}, "tags": ["infra"], "aliases": ["Ping pico.local"]},
    {"name": "TCP pico SSH", "type": "port", "kwargs": {"hostname": "pico", "port": 22}, "tags": ["infra"]},

    # public services (Caddy on OKE)
    {"name": "stevegore.au", "type": "http", "kwargs": {"url": "https://stevegore.au/", "maxredirects": 10, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public"], "aliases": ["stevegore.au (ttyd)"]},
    {"name": "Auth Service", "type": "http", "kwargs": {"url": "https://auth.stevegore.au/", "maxredirects": 10, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public", "infra"], "aliases": ["auth.stevegore.au"]},
    {"name": "Home Assistant", "type": "http", "kwargs": {"url": "https://hass.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["public"], "aliases": ["hass.stevegore.au"]},
    {"name": "Home Assistant (CF Tunnel)", "type": "http", "kwargs": {"url": "https://hass2.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["public"], "aliases": ["hass2.stevegore.au"]},
    {"name": "Immich", "type": "http", "kwargs": {"url": "https://photos.stevegore.au/api/server/ping", "maxredirects": 0, "keyword": "pong", "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public", "photos"], "aliases": ["photos.stevegore.au", "immich.stevegore.au"]},
    {"name": "PhotoPrism", "type": "http", "kwargs": {"url": "https://photoprism.stevegore.au/api/v1/status", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public", "photos"], "aliases": ["photoprism.stevegore.au"]},
    {"name": "Plex", "type": "http", "kwargs": {"url": "https://plex.stevegore.au/identity", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public", "media"], "aliases": ["plex.stevegore.au"]},
    {"name": "Huggin", "type": "http", "kwargs": {"url": "https://huggin.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public"], "aliases": ["huggin.stevegore.au"]},
    {"name": "Portainer", "type": "http", "kwargs": {"url": "https://port.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public", "infra"], "aliases": ["port.stevegore.au"]},
    {"name": "Strava Service", "type": "http", "kwargs": {"url": "https://strava.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["public"], "aliases": ["strava.stevegore.au"]},
    {"name": "Vaultwarden", "type": "http", "kwargs": {"url": "https://bw.stevegore.au/alive", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public"], "aliases": ["bw.stevegore.au"]},
    {"name": "Vaultwarden Replica", "type": "http", "kwargs": {"url": "https://bw2.stevegore.au/alive", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public"], "aliases": ["bw2.stevegore.au"]},
    {"name": "Stirling PDF", "type": "http", "kwargs": {"url": "https://pdf.stevegore.au/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public"], "aliases": ["pdf.stevegore.au"]},
    {"name": "Vault", "type": "http", "kwargs": {"url": "https://vault.stevegore.au/v1/sys/health", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_VAULT}, "tags": ["public", "infra"], "aliases": ["vault.stevegore.au"]},
    {"name": "Argo CD", "type": "http", "kwargs": {"url": "https://argocd.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public", "infra"], "aliases": ["argocd.stevegore.au"]},
    {"name": "Homepage", "type": "http", "kwargs": {"url": "https://homepage.stevegore.au/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_302}, "tags": ["public"], "aliases": ["homepage.stevegore.au"]},
    {"name": "Desk Service", "type": "http", "kwargs": {"url": "https://desk.stevegore.au/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_302}, "tags": ["public"], "aliases": ["desk.stevegore.au"]},
    {"name": "Gym Bookings", "type": "http", "kwargs": {"url": "https://gym.stevegore.au/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_302}, "tags": ["public"], "aliases": ["gym.stevegore.au"]},
    {"name": "OpenClaw", "type": "http", "kwargs": {"url": "https://openclaw.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public"], "aliases": ["openclaw.stevegore.au"]},
    {"name": "Uptime Kuma", "type": "http", "kwargs": {"url": "https://uptime.stevegore.au/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public", "infra"], "aliases": ["uptime.stevegore.au"]},
    {"name": "Stats", "type": "http", "kwargs": {"url": "https://stats.stevegore.au/api/stats", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["public", "infra"], "aliases": ["stats.stevegore.au"]},

    # pico-direct services (Tailscale Operator egress)
    {"name": "Radarr", "type": "http", "kwargs": {"url": "http://pico:7878/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["internal", "media"]},
    {"name": "Sonarr", "type": "http", "kwargs": {"url": "http://pico:8989/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["internal", "media"]},
    {"name": "Jackett", "type": "http", "kwargs": {"url": "http://pico:9117/UI/Dashboard", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_302}, "tags": ["internal", "media"]},
    {"name": "Transmission", "type": "http", "kwargs": {"url": "http://pico:9092/transmission/web/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal", "media"]},
    {"name": "FlareSolverr", "type": "http", "kwargs": {"url": "http://pico:8191/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["internal", "media"]},
    {"name": "Duplicati", "type": "http", "kwargs": {"url": "http://pico:8200/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal", "infra"]},
    {"name": "Stirling PDF (direct)", "type": "http", "kwargs": {"url": "http://pico:8083/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["internal"]},
    {"name": "StravaBot", "type": "port", "kwargs": {"hostname": "pico", "port": 8082}, "tags": ["internal"]},
    {"name": "StravaKeeper", "type": "http", "kwargs": {"url": "http://pico:8180/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal"]},
    {"name": "Immich (direct)", "type": "http", "kwargs": {"url": "http://pico:2283/api/server/ping", "maxredirects": 0, "keyword": "pong", "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["internal", "photos"], "aliases": ["Immich (local)"]},
    {"name": "PhotoPrism (local)", "type": "http", "kwargs": {"url": "http://pico.local:2342/api/v1/status", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["internal", "photos"]},
    {"name": "Huginn (direct)", "type": "http", "kwargs": {"url": "http://pico:3000/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["internal"], "aliases": ["Huginn (local)"]},
    {"name": "Homepage (direct)", "type": "http", "kwargs": {"url": "http://pico:8080/", "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK}, "tags": ["internal", "infra"], "aliases": ["Homepage (local)"]},
    {"name": "Gym Bookings (direct)", "type": "http", "kwargs": {"url": "http://pico:8112/", "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal"], "aliases": ["GymBooking"]},
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
        fields[field] = spec["kwargs"].get(field, OPTIONAL_DEFAULTS[field])

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
