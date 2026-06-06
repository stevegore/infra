#!/usr/bin/env python3
"""Reconcile Uptime Kuma monitors and tags via the REST API.

Works with any database backend (SQLite or MySQL). Run from outside the pod:

    python3 scripts/setup_uptime_kuma.py

Credentials are read from environment variables:
    UPTIME_KUMA_URL      default: https://uptime.stevegore.au
    UPTIME_KUMA_USER     default: admin
    UPTIME_KUMA_PASSWORD required

Or pass --password on the command line.
"""
import argparse
import json
import os
import sys
import urllib.request
import urllib.error

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TAGS = {
    "public":   "#dc3545",  # red
    "internal": "#0d6efd",  # blue
    "infra":    "#198754",  # green
    "media":    "#ffc107",  # amber
    "photos":   "#e83e8c",  # pink
}

DEFAULT_INTERVAL = 60
DEFAULT_TIMEOUT  = 16
DEFAULT_RETRIES  = 1
ACCEPT_OK        = ["200-299"]
ACCEPT_OK_REDIR  = ["200-399"]
ACCEPT_302       = ["302"]
ACCEPT_VAULT     = ["200-299", "429", "473", "501", "503"]

retired_monitor_names = {
    "Ping ampere-ubuntu (WG)",
}

monitors = [
    # hosts
    {"name": "Ping pico",    "type": "ping", "hostname": "pico",  "tags": ["infra"], "aliases": ["Ping pico.local"]},
    {"name": "TCP pico SSH", "type": "port", "hostname": "pico",  "port": 22, "tags": ["infra"]},

    # public services (Caddy on OKE)
    {"name": "stevegore.au",              "type": "http", "url": "https://stevegore.au/",                          "maxredirects": 10, "accepted_statuscodes": ACCEPT_OK,       "tags": ["public"],          "aliases": ["stevegore.au (ttyd)"]},
    {"name": "Auth Service",              "type": "http", "url": "https://auth.stevegore.au/",                     "maxredirects": 10, "accepted_statuscodes": ACCEPT_OK,       "tags": ["public", "infra"], "aliases": ["auth.stevegore.au"]},
    {"name": "Home Assistant",            "type": "http", "url": "https://hass.stevegore.au/",                     "maxredirects": 5,  "accepted_statuscodes": ACCEPT_OK_REDIR, "tags": ["public"],          "aliases": ["hass.stevegore.au"]},
    {"name": "Home Assistant (CF Tunnel)","type": "http", "url": "https://hass2.stevegore.au/",                    "maxredirects": 5,  "accepted_statuscodes": ACCEPT_OK_REDIR, "tags": ["public"],          "aliases": ["hass2.stevegore.au"]},
    {"name": "Immich",                    "type": "http", "url": "https://photos.stevegore.au/api/server/ping",    "maxredirects": 0,  "accepted_statuscodes": ACCEPT_OK,       "tags": ["public", "photos"], "keyword": "pong", "aliases": ["photos.stevegore.au", "immich.stevegore.au"]},
    {"name": "PhotoPrism",                "type": "http", "url": "https://photoprism.stevegore.au/api/v1/status",  "maxredirects": 0,  "accepted_statuscodes": ACCEPT_OK,       "tags": ["public", "photos"], "aliases": ["photoprism.stevegore.au"]},
    {"name": "Plex",                      "type": "http", "url": "https://plex.stevegore.au/identity",             "maxredirects": 0,  "accepted_statuscodes": ACCEPT_OK,       "tags": ["public", "media"], "aliases": ["plex.stevegore.au"]},
    {"name": "Huginn",                    "type": "http", "url": "https://huginn.stevegore.au/",                   "maxredirects": 5,  "accepted_statuscodes": ACCEPT_OK,       "tags": ["public"],          "aliases": ["huginn.stevegore.au"]},
    {"name": "Portainer",                 "type": "http", "url": "https://port.stevegore.au/",                     "maxredirects": 5,  "accepted_statuscodes": ACCEPT_OK,       "tags": ["public", "infra"], "aliases": ["port.stevegore.au"]},
    {"name": "Strava Service",            "type": "http", "url": "https://strava.stevegore.au/",                   "maxredirects": 5,  "accepted_statuscodes": ACCEPT_OK_REDIR, "tags": ["public"],          "aliases": ["strava.stevegore.au"]},
    {"name": "Vaultwarden",               "type": "http", "url": "https://bw.stevegore.au/alive",                  "maxredirects": 0,  "accepted_statuscodes": ACCEPT_OK,       "tags": ["public"],          "aliases": ["bw.stevegore.au"]},
    {"name": "Vaultwarden Replica",       "type": "http", "url": "https://bw2.stevegore.au/alive",                 "maxredirects": 0,  "accepted_statuscodes": ACCEPT_OK,       "tags": ["public"],          "aliases": ["bw2.stevegore.au"]},
    {"name": "Stirling PDF",              "type": "http", "url": "https://pdf.stevegore.au/",                      "maxredirects": 0,  "accepted_statuscodes": ACCEPT_OK,       "tags": ["public"],          "aliases": ["pdf.stevegore.au"]},
    {"name": "Vault",                     "type": "http", "url": "https://vault.stevegore.au/v1/sys/health",       "maxredirects": 0,  "accepted_statuscodes": ACCEPT_VAULT,    "tags": ["public", "infra"], "aliases": ["vault.stevegore.au"]},
    {"name": "Argo CD",                   "type": "http", "url": "https://argocd.stevegore.au/",                   "maxredirects": 5,  "accepted_statuscodes": ACCEPT_OK,       "tags": ["public", "infra"], "aliases": ["argocd.stevegore.au"]},
    {"name": "Homepage",                  "type": "http", "url": "https://homepage.stevegore.au/",                 "maxredirects": 0,  "accepted_statuscodes": ACCEPT_302,      "tags": ["public"],          "aliases": ["homepage.stevegore.au"]},
    {"name": "Desk Service",              "type": "http", "url": "https://desk.stevegore.au/",                     "maxredirects": 0,  "accepted_statuscodes": ACCEPT_302,      "tags": ["public"],          "aliases": ["desk.stevegore.au"]},
    {"name": "Gym Bookings",              "type": "http", "url": "https://gym.stevegore.au/",                      "maxredirects": 0,  "accepted_statuscodes": ACCEPT_302,      "tags": ["public"],          "aliases": ["gym.stevegore.au"]},
    {"name": "OpenClaw",                  "type": "http", "url": "https://openclaw.stevegore.au/",                 "maxredirects": 5,  "accepted_statuscodes": ACCEPT_OK,       "tags": ["public"],          "aliases": ["openclaw.stevegore.au"]},
    {"name": "Uptime Kuma",               "type": "http", "url": "https://uptime.stevegore.au/",                   "maxredirects": 5,  "accepted_statuscodes": ACCEPT_OK,       "tags": ["public", "infra"], "aliases": ["uptime.stevegore.au"]},
    {"name": "Stats",                     "type": "http", "url": "https://stats.stevegore.au/api/stats",           "maxredirects": 0,  "accepted_statuscodes": ACCEPT_OK,       "tags": ["public", "infra"], "aliases": ["stats.stevegore.au"]},

    # pico-direct services (Tailscale Operator egress)
    {"name": "Radarr",             "type": "http", "url": "http://pico:7878/",                       "maxredirects": 5, "accepted_statuscodes": ACCEPT_OK,       "tags": ["internal", "media"]},
    {"name": "Sonarr",             "type": "http", "url": "http://pico:8989/",                       "maxredirects": 5, "accepted_statuscodes": ACCEPT_OK,       "tags": ["internal", "media"]},
    {"name": "Jackett",            "type": "http", "url": "http://pico:9117/UI/Dashboard",           "maxredirects": 0, "accepted_statuscodes": ACCEPT_302,      "tags": ["internal", "media"]},
    {"name": "Transmission",       "type": "http", "url": "http://pico:9092/transmission/web/",      "maxredirects": 5, "accepted_statuscodes": ACCEPT_OK_REDIR, "tags": ["internal", "media"]},
    {"name": "FlareSolverr",       "type": "http", "url": "http://pico:8191/",                       "maxredirects": 0, "accepted_statuscodes": ACCEPT_OK,       "tags": ["internal", "media"]},
    {"name": "Duplicati",          "type": "http", "url": "http://pico:8200/",                       "maxredirects": 0, "accepted_statuscodes": ACCEPT_OK_REDIR, "tags": ["internal", "infra"]},
    {"name": "Stirling PDF (direct)","type":"http", "url": "http://pico:8083/",                      "maxredirects": 5, "accepted_statuscodes": ACCEPT_OK,       "tags": ["internal"]},
    {"name": "StravaBot",          "type": "port", "hostname": "pico", "port": 8082,                                                                              "tags": ["internal"]},
    {"name": "StravaKeeper",       "type": "http", "url": "http://pico:8180/",                       "maxredirects": 0, "accepted_statuscodes": ACCEPT_OK_REDIR, "tags": ["internal"]},
    {"name": "Immich (direct)",    "type": "http", "url": "http://pico:2283/api/server/ping",        "maxredirects": 0, "accepted_statuscodes": ACCEPT_OK,       "tags": ["internal", "photos"], "keyword": "pong", "aliases": ["Immich (local)"]},
    {"name": "PhotoPrism (local)", "type": "http", "url": "http://pico.local:2342/api/v1/status",   "maxredirects": 0, "accepted_statuscodes": ACCEPT_OK,       "tags": ["internal", "photos"]},
    {"name": "Huginn (direct)",    "type": "http", "url": "http://pico:3000/",                       "maxredirects": 5, "accepted_statuscodes": ACCEPT_OK,       "tags": ["internal"],           "aliases": ["Huginn (local)"]},
    {"name": "Homepage (direct)",  "type": "http", "url": "http://pico:8080/",                       "maxredirects": 0, "accepted_statuscodes": ACCEPT_OK,       "tags": ["internal", "infra"],  "aliases": ["Homepage (local)"]},
    {"name": "Gym Bookings (direct)","type":"http", "url": "http://pico:8112/",                      "maxredirects": 5, "accepted_statuscodes": ACCEPT_OK_REDIR, "tags": ["internal"],           "aliases": ["GymBooking"]},
    {"name": "NuraSpace",          "type": "http", "url": "http://pico:8111/",                       "maxredirects": 5, "accepted_statuscodes": ACCEPT_OK_REDIR, "tags": ["internal"]},
    {"name": "Portainer (direct)", "type": "http", "url": "http://pico:9000/",                       "maxredirects": 5, "accepted_statuscodes": ACCEPT_OK_REDIR, "tags": ["internal", "infra"],  "aliases": ["Portainer (local)"]},
    {"name": "phpMyAdmin",         "type": "http", "url": "http://pico:3011/",                       "maxredirects": 5, "accepted_statuscodes": ACCEPT_OK_REDIR, "tags": ["internal", "infra"]},
]

# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------

def api(method, path, body=None, *, token=None, base_url=None):
    url = f"{base_url}{path}"
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        raise RuntimeError(f"HTTP {e.code} {method} {path}: {body}") from None


def login(base_url, username, password):
    resp = api("POST", "/api/v1/auth/login",
               {"username": username, "password": password, "token": ""},
               base_url=base_url)
    if not resp.get("ok"):
        raise RuntimeError(f"Login failed: {resp}")
    return resp["token"]


def get_tags(base_url, token):
    return {t["name"]: t["id"] for t in api("GET", "/api/v1/tags", token=token, base_url=base_url)["tags"]}


def ensure_tag(base_url, token, name, color):
    tags = get_tags(base_url, token)
    if name in tags:
        return tags[name]
    resp = api("POST", "/api/v1/tags", {"name": name, "color": color}, token=token, base_url=base_url)
    return resp["tag"]["id"]


def get_monitors(base_url, token):
    return api("GET", "/api/v1/monitors", token=token, base_url=base_url)["monitors"]


def build_payload(spec, tag_ids):
    payload = {
        "type":             spec["type"],
        "name":             spec["name"],
        "interval":         spec.get("interval", DEFAULT_INTERVAL),
        "retryInterval":    spec.get("retry_interval", 60),
        "maxretries":       spec.get("maxretries", DEFAULT_RETRIES),
        "timeout":          spec.get("timeout", DEFAULT_TIMEOUT),
        "accepted_statuscodes": spec.get("accepted_statuscodes", ACCEPT_OK),
        "tags": [{"id": tag_ids[t], "value": ""} for t in spec.get("tags", [])],
    }
    for field in ("url", "hostname", "port", "keyword", "maxredirects"):
        if field in spec:
            payload[field] = spec[field]
    return payload


def reconcile(base_url, token, spec, existing_by_name, tag_ids):
    all_names = [spec["name"]] + spec.get("aliases", [])
    existing = next((existing_by_name[n] for n in all_names if n in existing_by_name), None)

    payload = build_payload(spec, tag_ids)

    if existing:
        mid = existing["id"]
        api("PUT", f"/api/v1/monitors/{mid}", payload, token=token, base_url=base_url)
        return "updated", mid
    else:
        resp = api("POST", "/api/v1/monitors", payload, token=token, base_url=base_url)
        return "created", resp["monitor"]["id"]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Reconcile Uptime Kuma monitors via REST API")
    parser.add_argument("--url",      default=os.environ.get("UPTIME_KUMA_URL", "https://uptime.stevegore.au"))
    parser.add_argument("--user",     default=os.environ.get("UPTIME_KUMA_USER", "admin"))
    parser.add_argument("--password", default=os.environ.get("UPTIME_KUMA_PASSWORD"))
    args = parser.parse_args()

    if not args.password:
        print("ERROR: set UPTIME_KUMA_PASSWORD or pass --password", file=sys.stderr)
        sys.exit(1)

    base_url = args.url.rstrip("/")
    print(f"Connecting to {base_url} as {args.user}...")
    token = login(base_url, args.user, args.password)
    print("  logged in")

    # Ensure all tags exist
    tag_ids = {}
    for name, color in TAGS.items():
        tag_ids[name] = ensure_tag(base_url, token, name, color)
    print(f"Tags ready: {list(tag_ids.keys())}")

    # Fetch current monitors indexed by name
    existing_by_name = {m["name"]: m for m in get_monitors(base_url, token)}

    created = updated = 0
    for spec in monitors:
        action, _ = reconcile(base_url, token, spec, existing_by_name, tag_ids)
        if action == "created":
            created += 1
        else:
            updated += 1

    # Pause retired monitors
    for name in retired_monitor_names:
        if name in existing_by_name:
            mid = existing_by_name[name]["id"]
            api("PATCH", f"/api/v1/monitors/{mid}/pause", token=token, base_url=base_url)

    print(f"Done: {created} created, {updated} updated, {len(monitors)} total")
    print(f"Retired monitors paused: {sorted(retired_monitor_names)}")


if __name__ == "__main__":
    main()
