#!/usr/bin/env python3
"""Reconcile Uptime Kuma monitors and tags.

Connects directly to the MySQL database (same schema as SQLite). Run from
the Mac with Vault access to read DB credentials:

    python3 scripts/setup_uptime_kuma.py

Credentials are read from environment variables:
    UPTIME_KUMA_DB_HOST      default: heatwave.sub02040931041.nebula.oraclevcn.com
    UPTIME_KUMA_DB_PORT      default: 3306
    UPTIME_KUMA_DB_NAME      default: uptime_kuma
    UPTIME_KUMA_DB_USER      default: uptime_kuma
    UPTIME_KUMA_DB_PASSWORD  required (or pass --password)
    PUSHOVER_APP_TOKEN       required unless --no-notifications
    PUSHOVER_USER_KEY        required unless --no-notifications

The Pushover pair is kv/homelab/pushover. Monitors inserted here get no
notification links from Kuma itself (its "default enabled" flag is applied by
the UI form, not the database), which is how every monitor ran with zero
alerting from 2026-06-06 until 2026-10-22.

On a fresh cluster where the uptime-kuma pod is not yet up, run inside a
MySQL client pod instead:
    kubectl run mysql-setup --rm -it --restart=Never --image=docker.io/mysql:8.0 -- /bin/bash
    pip install ... (not available) — use the direct kubectl approach below.

Quickest rebuild path:
    VAULT=$(cat ~/Code/Personal/infra/vault-root.token)
    PASS=$(VAULT_ADDR=http://localhost:8201 VAULT_TOKEN=$VAULT vault kv get -field=db_password kv/uptime-kuma/config)
    UPTIME_KUMA_DB_PASSWORD=$PASS python3 scripts/setup_uptime_kuma.py
"""
import argparse
import json
import os
import sys

try:
    import mysql.connector
except ImportError:
    # Fall back to pymysql if mysql-connector not available
    try:
        import pymysql
        import pymysql.cursors
        _DRIVER = "pymysql"
    except ImportError:
        print("ERROR: install mysql-connector-python or pymysql", file=sys.stderr)
        print("  pip install mysql-connector-python", file=sys.stderr)
        sys.exit(1)
else:
    _DRIVER = "mysql.connector"

USER_ID = 1

TAGS = {
    "public":   "#dc3545",
    "internal": "#0d6efd",
    "infra":    "#198754",
    "media":    "#ffc107",
    "photos":   "#e83e8c",
}

DEFAULT_INTERVAL = 60
DEFAULT_TIMEOUT  = 16
DEFAULT_RETRIES  = 1
ACCEPT_OK        = '["200-299"]'
ACCEPT_OK_REDIR  = '["200-399"]'
ACCEPT_302       = '["302"]'
# Vault: 200 only. On /v1/sys/health, 501 = uninitialized and 503 = sealed --
# the two states most worth paging for -- so accepting them (as this did until
# 2026-08-18) left the monitor green through exactly the outages it exists to
# catch. 429/473 are HA standby codes and cannot occur: ha.enabled is false.
ACCEPT_VAULT     = '["200-299"]'

NOTIFICATION_NAME = "Pushover"

retired_monitor_names = {
    "Gym Bookings (direct)",
    "Ping ampere-ubuntu (WG)",
    "PhotoPrism",
    "PhotoPrism (local)",
    "StravaKeeper",
}

monitors = [
    # hosts
    {"name": "Ping pico",    "type": "ping", "kwargs": {"hostname": "pico"},           "tags": ["infra"], "aliases": ["Ping pico"]},
    {"name": "TCP pico SSH", "type": "port", "kwargs": {"hostname": "pico", "port": 22}, "tags": ["infra"]},

    # public services (Caddy on OKE)
    {"name": "stevegore.au",               "type": "http", "kwargs": {"url": "https://stevegore.au/",                         "maxredirects": 10, "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["public"],           "aliases": ["stevegore.au (ttyd)"]},
    {"name": "Auth Service",               "type": "http", "kwargs": {"url": "https://auth.stevegore.au/",                    "maxredirects": 10, "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["public", "infra"],  "aliases": ["auth.stevegore.au"]},
    {"name": "Home Assistant",             "type": "http", "kwargs": {"url": "https://hass.stevegore.au/",                    "maxredirects": 5,  "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["public"],           "aliases": ["hass.stevegore.au"]},
    {"name": "Home Assistant (CF Tunnel)", "type": "http", "kwargs": {"url": "https://hass2.stevegore.au/",                   "maxredirects": 5,  "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["public"],           "aliases": ["hass2.stevegore.au"]},
    {"name": "Immich",                     "type": "keyword", "kwargs": {"url": "https://photos.stevegore.au/api/server/ping",   "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_OK,        "keyword": "pong"},            "tags": ["public", "photos"], "aliases": ["photos.stevegore.au", "immich.stevegore.au"]},
    {"name": "Plex",                       "type": "http", "kwargs": {"url": "https://plex.stevegore.au/identity",            "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["public", "media"],  "aliases": ["plex.stevegore.au"]},
    {"name": "Huginn",                     "type": "http", "kwargs": {"url": "https://huginn.stevegore.au/",                  "maxredirects": 5,  "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["public"],           "aliases": ["huginn.stevegore.au"]},
    {"name": "Portainer",                  "type": "http", "kwargs": {"url": "https://port.stevegore.au/",                    "maxredirects": 5,  "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["public", "infra"],  "aliases": ["port.stevegore.au"]},
    {"name": "Strava Service",             "type": "http", "kwargs": {"url": "https://strava.stevegore.au/",                  "maxredirects": 5,  "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["public"],           "aliases": ["strava.stevegore.au"]},
    {"name": "Vaultwarden",                "type": "http", "kwargs": {"url": "https://bw.stevegore.au/alive",                 "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["public"],           "aliases": ["bw.stevegore.au"]},
    {"name": "Vaultwarden Replica",        "type": "http", "kwargs": {"url": "https://bw2.stevegore.au/alive",                "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["public"],           "aliases": ["bw2.stevegore.au"]},
    {"name": "Stirling PDF",               "type": "http", "kwargs": {"url": "https://pdf.stevegore.au/",                     "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["public"],           "aliases": ["pdf.stevegore.au"]},
    {"name": "Vault",                      "type": "http", "kwargs": {"url": "https://vault.stevegore.au/v1/sys/health",      "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_VAULT},    "tags": ["public", "infra"],  "aliases": ["vault.stevegore.au"]},
    {"name": "Argo CD",                    "type": "http", "kwargs": {"url": "https://argocd.stevegore.au/",                  "maxredirects": 5,  "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["public", "infra"],  "aliases": ["argocd.stevegore.au"]},
    {"name": "Headlamp",                   "type": "http", "kwargs": {"url": "https://headlamp.stevegore.au/",                "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_302},      "tags": ["public", "infra"]},
    {"name": "Hubble UI",                  "type": "http", "kwargs": {"url": "https://hubble.stevegore.au/",                  "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_302},      "tags": ["public", "infra"],  "aliases": ["hubble.stevegore.au"]},
    {"name": "Homepage",                   "type": "http", "kwargs": {"url": "https://homepage.stevegore.au/",                "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_302},      "tags": ["public"],           "aliases": ["homepage.stevegore.au"]},
    {"name": "Adminer",                    "type": "http", "kwargs": {"url": "https://adminer.stevegore.au/",                  "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_302},      "tags": ["public", "infra"],  "aliases": ["adminer.stevegore.au"]},
    {"name": "Desk Service",               "type": "http", "kwargs": {"url": "https://desk.stevegore.au/",                    "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_302},      "tags": ["public"],           "aliases": ["desk.stevegore.au"]},
    {"name": "Gym Bookings",               "type": "http", "kwargs": {"url": "https://gym.stevegore.au/",                     "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_302},      "tags": ["public"],           "aliases": ["gym.stevegore.au"]},
    # /index, not /: Caddy redirects the bare root to /admin without consulting
    # the backend, so a 302 there would stay green with Gokapi completely down.
    # /index is served by Gokapi itself and returns 200.
    {"name": "Send (Gokapi)",              "type": "http", "kwargs": {"url": "https://send.stevegore.au/index",               "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["public"],           "aliases": ["send.stevegore.au"]},
    {"name": "Status Page",                "type": "http", "kwargs": {"url": "https://status.stevegore.au/status/homelab",    "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["public"]},
    {"name": "Uptime Kuma",                "type": "http", "kwargs": {"url": "https://uptime.stevegore.au/",                  "maxredirects": 5,  "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["public", "infra"],  "aliases": ["uptime.stevegore.au"]},
    {"name": "Stats",                      "type": "http", "kwargs": {"url": "https://stats.stevegore.au/api/stats",          "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["public", "infra"],  "aliases": ["stats.stevegore.au"]},
    {"name": "Instagram Gallery",          "type": "http", "kwargs": {"url": "https://gallery.stevegore.au/",                "maxredirects": 0,  "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["public", "photos"], "aliases": ["gallery.stevegore.au"]},

    # OKE backends, probed in-cluster. The public monitors for Authentik-gated
    # hosts only see the 302 to the login page, which Caddy serves whether or
    # not the backend is alive: Adminer fatalled on every page on 2026-10-22
    # while "Adminer" stayed green. Keyword monitors also catch a 200 error page.
    {"name": "Adminer (in-cluster)",    "type": "keyword", "kwargs": {"url": "http://adminer.adminer.svc.cluster.local/",          "keyword": "Select a database"},                                                "tags": ["internal", "infra"]},
    {"name": "Gym Bookings (in-cluster)","type": "http",   "kwargs": {"url": "http://gym-booker.gym-booker.svc.cluster.local:5000/"},                                                                                  "tags": ["internal"]},
    # Homepage rejects requests whose Host is not in HOMEPAGE_ALLOWED_HOSTS.
    {"name": "Homepage (in-cluster)",   "type": "http",    "kwargs": {"url": "http://homepage.homepage.svc.cluster.local:3000/",    "headers": '{"Host": "homepage.stevegore.au"}'},                               "tags": ["internal"]},
    {"name": "Hubble UI (in-cluster)",  "type": "http",    "kwargs": {"url": "http://hubble-ui.kube-system.svc.cluster.local/"},                                                                                       "tags": ["internal", "infra"]},
    {"name": "Headlamp (in-cluster)",   "type": "http",    "kwargs": {"url": "http://headlamp.headlamp.svc.cluster.local/"},                                                                                           "tags": ["internal", "infra"]},
    # The public URL needs the secret path, so probe the backend directly: a
    # plain GET on /mcp gets 406 (no event-stream Accept) from a live server.
    {"name": "Garmin MCP (in-cluster)", "type": "http",    "kwargs": {"url": "http://garmin-mcp.garmin-mcp.svc.cluster.local:8080/mcp", "accepted_statuscodes_json": '["406"]'},                                  "tags": ["internal"]},
    {"name": "pg-shared",               "type": "port",    "kwargs": {"hostname": "pg-shared-rw.databases.svc.cluster.local", "port": 5432},                                                                  "tags": ["internal", "infra"]},

    # pico-direct services (Tailscale Operator egress)
    {"name": "Radarr",              "type": "http", "kwargs": {"url": "http://pico:7878/",                     "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["internal", "media"]},
    {"name": "Sonarr",              "type": "http", "kwargs": {"url": "http://pico:8989/",                     "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["internal", "media"]},
    {"name": "Jackett",             "type": "http", "kwargs": {"url": "http://pico:9117/UI/Dashboard",         "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_302},      "tags": ["internal", "media"]},
    {"name": "Transmission",        "type": "http", "kwargs": {"url": "http://pico:9092/transmission/web/",    "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal", "media"]},
    {"name": "FlareSolverr",        "type": "http", "kwargs": {"url": "http://pico:8191/",                     "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["internal", "media"]},
    {"name": "Duplicati",           "type": "http", "kwargs": {"url": "http://pico:8200/",                     "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal", "infra"]},
    {"name": "Stirling PDF (direct)","type":"http", "kwargs": {"url": "http://pico:8083/",                     "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["internal"]},
    {"name": "StravaBot",           "type": "port", "kwargs": {"hostname": "pico", "port": 8082},                                                                                "tags": ["internal"]},
    {"name": "Immich (direct)",     "type": "keyword", "kwargs": {"url": "http://pico:2283/api/server/ping",      "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK,        "keyword": "pong"}, "tags": ["internal", "photos"], "aliases": ["Immich (local)"]},
    {"name": "Huginn (direct)",     "type": "http", "kwargs": {"url": "http://pico:3000/",                     "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["internal"],           "aliases": ["Huginn (local)"]},
    {"name": "Homepage (direct)",   "type": "http", "kwargs": {"url": "http://pico:8080/",                     "maxredirects": 0, "accepted_statuscodes_json": ACCEPT_OK},       "tags": ["internal", "infra"],  "aliases": ["Homepage (local)"]},
    {"name": "NuraSpace",           "type": "http", "kwargs": {"url": "http://pico:8111/",                     "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal"]},
    {"name": "Portainer (direct)",  "type": "http", "kwargs": {"url": "http://pico:9000/",                     "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal", "infra"],  "aliases": ["Portainer (local)"]},
    {"name": "phpMyAdmin",          "type": "http", "kwargs": {"url": "http://pico:3011/",                     "maxredirects": 5, "accepted_statuscodes_json": ACCEPT_OK_REDIR}, "tags": ["internal", "infra"]},
]

OPTIONAL_FIELDS = ["url", "hostname", "port", "accepted_statuscodes_json", "maxredirects", "keyword", "headers"]
OPTIONAL_DEFAULTS = {"url": None, "hostname": None, "port": None,
                     "accepted_statuscodes_json": ACCEPT_OK, "maxredirects": 0, "keyword": None, "headers": None}


def connect(host, port, database, user, password):
    if _DRIVER == "mysql.connector":
        return mysql.connector.connect(
            host=host, port=int(port), database=database,
            user=user, password=password, autocommit=False)
    else:
        return pymysql.connect(
            host=host, port=int(port), database=database,
            user=user, password=password, autocommit=False,
            cursorclass=pymysql.cursors.Cursor)


def fetch_monitor_id(cur, names):
    placeholders = ",".join(["%s"] * len(names))
    cur.execute(
        f"SELECT id, name FROM monitor WHERE name IN ({placeholders}) "
        f"ORDER BY CASE WHEN name=%s THEN 0 ELSE 1 END, id LIMIT 1",
        (*names, names[0]))
    return cur.fetchone()


def reconcile_monitor(cur, spec, tag_ids):
    desired_name = spec["name"]
    aliases = spec.get("aliases", [])
    existing = fetch_monitor_id(cur, [desired_name, *aliases])

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
        monitor_id = existing[0]
        assignments = ", ".join(f"`{col}`=%s" for col in fields)
        cur.execute(f"UPDATE monitor SET {assignments} WHERE id=%s", (*fields.values(), monitor_id))
        cur.execute("DELETE FROM monitor_tag WHERE monitor_id=%s", (monitor_id,))
    else:
        columns = list(fields.keys())
        placeholders = ",".join(["%s"] * len(columns))
        col_list = ",".join(f"`{c}`" for c in columns)
        cur.execute(
            f"INSERT INTO monitor ({col_list}) VALUES ({placeholders})",
            tuple(fields[col] for col in columns))
        monitor_id = cur.lastrowid

    for tag_name in spec.get("tags", []):
        cur.execute("INSERT INTO monitor_tag (monitor_id, tag_id) VALUES (%s, %s)",
                    (monitor_id, tag_ids[tag_name]))


def reconcile_notification(cur, app_token, user_key):
    """Upsert the managed Pushover provider; return its id.

    config mirrors what Kuma's UI saves (Notification.save stores the whole
    form as JSON), so the provider is editable in the UI afterwards -- but
    the next reconcile overwrites it.
    """
    config = json.dumps({
        "name": NOTIFICATION_NAME,
        "type": "pushover",
        "isDefault": True,
        "applyExisting": False,
        "pushoverapptoken": app_token,
        "pushoveruserkey": user_key,
        # Normal priority: the monitors include flappy pico media services,
        # and high priority bypasses quiet hours.
        "pushoverpriority": "0",
        "pushovertitle": "Uptime Kuma",
    })
    cur.execute("SELECT id FROM notification WHERE name=%s ORDER BY id LIMIT 1", (NOTIFICATION_NAME,))
    row = cur.fetchone()
    if row:
        cur.execute(
            "UPDATE notification SET config=%s, active=1, is_default=1, user_id=%s WHERE id=%s",
            (config, USER_ID, row[0]))
        return row[0]
    cur.execute(
        "INSERT INTO notification (name, config, active, is_default, user_id) VALUES (%s, %s, 1, 1, %s)",
        (NOTIFICATION_NAME, config, USER_ID))
    return cur.lastrowid


def link_notification(cur, notification_id):
    """Attach the notification to every managed monitor, exactly once each."""
    names = [spec["name"] for spec in monitors]
    placeholders = ",".join(["%s"] * len(names))
    cur.execute(f"SELECT id FROM monitor WHERE name IN ({placeholders})", names)
    monitor_ids = [row[0] for row in cur.fetchall()]
    for monitor_id in monitor_ids:
        cur.execute(
            "DELETE FROM monitor_notification WHERE monitor_id=%s AND notification_id=%s",
            (monitor_id, notification_id))
        cur.execute(
            "INSERT INTO monitor_notification (monitor_id, notification_id) VALUES (%s, %s)",
            (monitor_id, notification_id))
    return len(monitor_ids)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host",     default=os.environ.get("UPTIME_KUMA_DB_HOST", "heatwave.sub02040931041.nebula.oraclevcn.com"))
    parser.add_argument("--port",     default=os.environ.get("UPTIME_KUMA_DB_PORT", "3306"))
    parser.add_argument("--database", default=os.environ.get("UPTIME_KUMA_DB_NAME", "uptime_kuma"))
    parser.add_argument("--user",     default=os.environ.get("UPTIME_KUMA_DB_USER", "uptime_kuma"))
    parser.add_argument("--password", default=os.environ.get("UPTIME_KUMA_DB_PASSWORD"))
    parser.add_argument("--no-notifications", action="store_true",
                        help="leave notification config untouched (local runs without Pushover creds)")
    args = parser.parse_args()

    if not args.password:
        print("ERROR: set UPTIME_KUMA_DB_PASSWORD or pass --password", file=sys.stderr)
        sys.exit(1)

    # Fail rather than skip: a reconcile that "succeeds" without alerting is
    # the silent failure this exists to prevent.
    pushover_token = os.environ.get("PUSHOVER_APP_TOKEN")
    pushover_user = os.environ.get("PUSHOVER_USER_KEY")
    if not args.no_notifications and not (pushover_token and pushover_user):
        print("ERROR: set PUSHOVER_APP_TOKEN and PUSHOVER_USER_KEY, or pass --no-notifications",
              file=sys.stderr)
        sys.exit(1)

    print(f"Connecting to {args.host}:{args.port}/{args.database} as {args.user}...")
    conn = connect(args.host, args.port, args.database, args.user, args.password)
    cur = conn.cursor()

    tag_ids = {}
    for name, color in TAGS.items():
        cur.execute("SELECT id FROM tag WHERE name=%s", (name,))
        row = cur.fetchone()
        if row:
            tag_ids[name] = row[0]
        else:
            cur.execute("INSERT INTO tag (name, color, created_date) VALUES (%s, %s, NOW())", (name, color))
            tag_ids[name] = cur.lastrowid

    for spec in monitors:
        reconcile_monitor(cur, spec, tag_ids)

    for retired_name in retired_monitor_names:
        cur.execute("UPDATE monitor SET active=0 WHERE name=%s", (retired_name,))

    linked = None
    if not args.no_notifications:
        notification_id = reconcile_notification(cur, pushover_token, pushover_user)
        linked = link_notification(cur, notification_id)

    conn.commit()
    cur.execute("SELECT COUNT(*) FROM monitor")
    total = cur.fetchone()[0]
    print(f"Tags ready: {list(tag_ids.keys())}")
    print(f"Managed monitors: {len(monitors)}, Total in DB: {total}")
    if linked is not None:
        print(f"{NOTIFICATION_NAME} notification linked to {linked} monitors")
    conn.close()


if __name__ == "__main__":
    main()
