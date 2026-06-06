#!/usr/bin/env python3
"""Create/refresh the public 'homelab' status page with grouped monitors.

Mirrors the live setup on https://uptime.stevegore.au/status/homelab.

Quickest rebuild path:
    VAULT=$(cat ~/Code/Personal/infra/vault-root.token)
    PASS=$(VAULT_ADDR=http://localhost:8201 VAULT_TOKEN=$VAULT vault kv get -field=db_password kv/uptime-kuma/config)
    UPTIME_KUMA_DB_PASSWORD=$PASS python3 scripts/setup_status_page.py
"""
import argparse
import os
import sys

try:
    import mysql.connector
except ImportError:
    try:
        import pymysql
        import pymysql.cursors
        _DRIVER = "pymysql"
    except ImportError:
        print("ERROR: install mysql-connector-python or pymysql", file=sys.stderr)
        sys.exit(1)
else:
    _DRIVER = "mysql.connector"

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

CNAMES = ["status.stevegore.au"]

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
        "Stats",
        "Uptime Kuma",
    ]),
    ("Agents", [
        "Huginn",
        "Huginn (direct)",
    ]),
    ("Photos", [
        "Immich",
        "Immich (direct)",
        "PhotoPrism",
        "PhotoPrism (local)",
    ]),
    ("Media", [
        "Plex",
        "Radarr",
        "Sonarr",
        "Jackett",
        "Transmission",
        "FlareSolverr",
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host",     default=os.environ.get("UPTIME_KUMA_DB_HOST", "heatwave.sub02040931041.nebula.oraclevcn.com"))
    parser.add_argument("--port",     default=os.environ.get("UPTIME_KUMA_DB_PORT", "3306"))
    parser.add_argument("--database", default=os.environ.get("UPTIME_KUMA_DB_NAME", "uptime_kuma"))
    parser.add_argument("--user",     default=os.environ.get("UPTIME_KUMA_DB_USER", "uptime_kuma"))
    parser.add_argument("--password", default=os.environ.get("UPTIME_KUMA_DB_PASSWORD"))
    args = parser.parse_args()

    if not args.password:
        print("ERROR: set UPTIME_KUMA_DB_PASSWORD or pass --password", file=sys.stderr)
        sys.exit(1)

    print(f"Connecting to {args.host}:{args.port}/{args.database} as {args.user}...")
    conn = connect(args.host, args.port, args.database, args.user, args.password)
    cur = conn.cursor()

    cur.execute("SELECT id FROM status_page WHERE slug=%s", (SLUG,))
    row = cur.fetchone()
    if row:
        sp_id = row[0]
        cur.execute("""
            UPDATE status_page
            SET title=%s, description=%s, icon=%s, theme=%s, published=%s,
                search_engine_index=%s, show_tags=%s, show_powered_by=%s, show_certificate_expiry=%s
            WHERE id=%s
        """, (TITLE, DESCRIPTION, ICON, THEME, PUBLISHED,
              SEARCH_ENGINE_INDEX, SHOW_TAGS, SHOW_POWERED_BY, SHOW_CERTIFICATE_EXPIRY, sp_id))
        print(f"Status page '{SLUG}' updated (id={sp_id})")
    else:
        cur.execute("""
            INSERT INTO status_page (slug, title, description, icon, theme, published, search_engine_index, show_tags, show_powered_by, show_certificate_expiry)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        """, (SLUG, TITLE, DESCRIPTION, ICON, THEME, PUBLISHED,
              SEARCH_ENGINE_INDEX, SHOW_TAGS, SHOW_POWERED_BY, SHOW_CERTIFICATE_EXPIRY))
        sp_id = cur.lastrowid
        print(f"Status page created id={sp_id} slug={SLUG}")

    cur.execute("DELETE FROM status_page_cname WHERE status_page_id=%s", (sp_id,))
    for domain in CNAMES:
        cur.execute(
            "INSERT INTO status_page_cname (status_page_id, domain) VALUES (%s, %s)",
            (sp_id, domain),
        )
    if CNAMES:
        print(f"Custom domains: {', '.join(CNAMES)}")

    cur.execute("DELETE FROM `group` WHERE status_page_id=%s", (sp_id,))

    for group_weight, (gname, monitor_names) in enumerate(GROUPS, start=1):
        cur.execute(
            "INSERT INTO `group` (name, public, active, weight, status_page_id) VALUES (%s, 1, 1, %s, %s)",
            (gname, group_weight, sp_id),
        )
        gid = cur.lastrowid
        matched = 0
        for monitor_weight, mname in enumerate(monitor_names, start=1):
            cur.execute("SELECT id FROM monitor WHERE name=%s", (mname,))
            mrow = cur.fetchone()
            if not mrow:
                print(f"  WARN: monitor '{mname}' not found (skipping)")
                continue
            cur.execute(
                "INSERT INTO monitor_group (monitor_id, group_id, weight, send_url) VALUES (%s, %s, %s, 0)",
                (mrow[0], gid, monitor_weight),
            )
            matched += 1
        print(f"  Group '{gname}' (id={gid}) populated with {matched}/{len(monitor_names)} monitors")

    conn.commit()
    conn.close()
    print(f"\nStatus page URL: https://uptime.stevegore.au/status/{SLUG}")
    for domain in CNAMES:
        print(f"Custom-domain URL: https://{domain}/")


if __name__ == "__main__":
    main()
