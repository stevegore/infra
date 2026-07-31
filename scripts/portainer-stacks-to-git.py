#!/usr/bin/env python3
"""Convert pico's Portainer stacks from file-editor to git-backed.

Why this script exists
----------------------
Portainer has no in-place "convert to git" operation — not in the UI and not in
the API. `PUT /api/stacks/{id}` only accepts inline StackFileContent for a
file-based stack. The only route is delete + recreate from the repository.

What "delete" does and does not touch
-------------------------------------
`DELETE /api/stacks/{id}` runs the equivalent of `docker compose down`. That
stops and removes the CONTAINERS. It does NOT remove named volumes, external
volumes, or bind mounts — every stack on pico keeps its data in one of those
three, so the data survives. The cost is downtime per stack, measured in the
seconds it takes to pull and start again.

That still makes this a destructive-looking operation on live services, so:
  * --dry-run is the default. You must pass --apply to change anything.
  * --stack may be repeated; start with a throwaway one (pdf, goldenboards)
    and work up to Plex/Immich once you trust it.
  * Every stack's pre-conversion definition and env is written to a rollback
    directory before anything is deleted, and --rollback replays it.

Secrets
-------
The compose files in git use ${VAR} placeholders. The real values become stack
Env entries, which live in Portainer's own database and never touch the repo
(which is public).

You do not normally have to supply those values. The script recovers each one
from the stack's CURRENT inline definition — the very file being replaced still
contains every secret the git version placeholders out. Values already set as
stack Env are kept as-is.

--env-file overrides that, for rotating a credential during the move:
  {"transmission": {"OPENVPN_USERNAME": "...", "OPENVPN_PASSWORD": "..."}}
--dump-env prints the skeleton. Values are never echoed, only name and length.

Usage
-----
  ./scripts/portainer-stacks-to-git.py --stack pdf              # dry run
  ./scripts/portainer-stacks-to-git.py --stack pdf --apply
  ./scripts/portainer-stacks-to-git.py                          # dry run, all 15
  ./scripts/portainer-stacks-to-git.py --rollback /tmp/portainer-rollback/pdf.json --apply

  # only when rotating a value as part of the conversion:
  ./scripts/portainer-stacks-to-git.py --dump-env > /tmp/stack-env.json
  ./scripts/portainer-stacks-to-git.py --env-file /tmp/stack-env.json --stack transmission --apply
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("PORTAINER_URL", "http://pico.local:9000/api")
ENDPOINT_ID = int(os.environ.get("PORTAINER_ENDPOINT_ID", "1"))
REPO_URL = "https://github.com/stevegore/infra"
REPO_REF = "refs/heads/main"
# Portainer re-polls the repo on this interval and redeploys when the commit
# changes. forcePullImage makes it re-pull floating tags (:latest, :release)
# on every redeploy, which is what keeps the images Renovate cannot pin fresh.
AUTO_UPDATE = {"interval": "5m", "forcePullImage": True}

ROLLBACK_DIR = os.environ.get("PORTAINER_ROLLBACK_DIR", "/tmp/portainer-rollback")

# Stacks whose compose file references ${VAR}. Converting one of these without
# supplying its env would start the containers with empty passwords.
REQUIRED_ENV = {
    "transmission": ["OPENVPN_USERNAME", "OPENVPN_PASSWORD"],
    "huggin": ["MYSQL_ROOT_PASSWORD", "APP_SECRET_TOKEN"],
    "immich": ["DB_PASSWORD"],
    "stravakeeper": [
        "MYSQL_ROOT_PASSWORD",
        "MYSQL_PASSWORD",
        "STRAVA_CLIENT_SECRET",
        "STRAVA_VERIFY_TOKEN",
    ],
    "plex": ["PLEX_CLAIM"],
    "icloudpd": ["ICLOUD_USERNAME"],
    "icloudpd-kellesi": ["ICLOUD_USERNAME"],
    "ig-gallery": ["GALLERY_ADMIN_KEY"],
}


def token() -> str:
    path = os.path.join(os.path.dirname(__file__), "..", "portainer.token")
    with open(os.path.abspath(path)) as fh:
        return fh.read().strip()


def api(method: str, path: str, body=None, timeout: int = 120):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path,
        data=data,
        method=method,
        headers={"X-API-Key": token(), "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode()[:400]
        raise SystemExit(f"HTTP {exc.code} on {method} {path}\n{detail}") from exc


def stacks_by_name() -> dict:
    return {s["Name"]: s for s in api("GET", "/stacks")}


# A couple of values are not `VAR=value` in the old compose — they are CLI flags
# on the container command. Pull those out by their own pattern.
CLI_DERIVED = {
    "ICLOUD_USERNAME": r"--username\s+(\S+)",
}


def derive_env(stack: str, old_compose: str) -> dict:
    """Recover each required value from the stack's PRE-conversion compose file.

    We are converting away from exactly that file, so it already holds every
    secret the git version replaced with ${VAR}. Reading them back beats making
    the operator hand-maintain a JSON of credentials that already exist.
    """
    found = {}
    for var in REQUIRED_ENV.get(stack, []):
        if var in CLI_DERIVED:
            m = re.search(CLI_DERIVED[var], old_compose)
            if m:
                found[var] = m.group(1)
            continue

        # env-list form:  - VAR=value        (may carry a trailing # comment)
        m = re.search(rf"^\s*-\s*{re.escape(var)}=(.*)$", old_compose, re.M)
        if not m:
            # mapping form:  VAR: value
            m = re.search(rf"^\s*{re.escape(var)}:\s*(.*)$", old_compose, re.M)
        if not m:
            continue

        val = re.sub(r"\s+#.*$", "", m.group(1)).strip().strip("\"'")
        # Skip a value that is already a placeholder — that means this stack was
        # converted before and there is nothing real left to recover here.
        if val and not val.startswith("${"):
            found[var] = val
    return found


def env_pairs(stack: str, meta: dict, env_file: dict, old_compose: str) -> tuple:
    # Precedence, lowest to highest:
    #   1. values recovered from the pre-conversion compose file
    #   2. env already set on the live stack (ig-gallery holds GALLERY_ADMIN_KEY)
    #   3. --env-file, so an operator can always override or supply a rotated value
    derived = derive_env(stack, old_compose)
    merged = dict(derived)
    merged.update({e["name"]: e["value"] for e in (meta.get("Env") or [])})
    merged.update(env_file.get(stack, {}))

    missing = [k for k in REQUIRED_ENV.get(stack, []) if not merged.get(k)]
    if missing:
        raise SystemExit(
            f"{stack}: missing required env {missing}.\n"
            f"Could not recover them from the current stack definition either.\n"
            f"Supply them via --env-file (see --dump-env), or the stack would "
            f"come up with empty credentials."
        )
    placeholder = [k for k, v in merged.items() if v == "CHANGEME"]
    if placeholder:
        raise SystemExit(f"{stack}: --env-file still has CHANGEME for {placeholder}")

    pairs = [{"name": k, "value": v} for k, v in sorted(merged.items())]
    return pairs, set(derived)


def save_rollback(stack: str, meta: dict, body: str) -> str:
    os.makedirs(ROLLBACK_DIR, exist_ok=True)
    snapshot = {
        "Name": stack,
        "Env": meta.get("Env") or [],
        "EndpointId": meta.get("EndpointId", ENDPOINT_ID),
        "StackFileContent": body,
        "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    path = os.path.join(ROLLBACK_DIR, f"{stack}.json")
    with open(path, "w") as fh:
        json.dump(snapshot, fh, indent=2)
    os.chmod(path, 0o600)  # may contain the pre-migration inline secrets
    return path


def convert(stack: str, meta: dict, env_file: dict, apply: bool) -> None:
    compose_path = f"pico/{stack}/compose.yaml"
    if not os.path.exists(os.path.join(os.path.dirname(__file__), "..", compose_path)):
        raise SystemExit(f"{stack}: {compose_path} not found in the repo")

    old_compose = api("GET", f"/stacks/{meta['Id']}/file")["StackFileContent"]
    env, derived = env_pairs(stack, meta, env_file, old_compose)

    print(f"\n=== {stack} (id={meta['Id']})")
    print(f"    compose : {compose_path}")
    if env:
        for e in env:
            # Never print the value — this runs on a laptop and scrolls into
            # terminal history. Source + length is enough to sanity-check.
            src = "recovered from current stack" if e["name"] in derived else "already set / --env-file"
            print(f"    env     : {e['name']:<22} ({len(e['value'])} chars, {src})")
    else:
        print("    env     : (none)")

    if not apply:
        print("    DRY RUN — would snapshot, delete, and recreate from git")
        return

    path = save_rollback(stack, meta, old_compose)
    print(f"    rollback snapshot -> {path}")

    api("DELETE", f"/stacks/{meta['Id']}?endpointId={meta['EndpointId']}")
    print("    deleted (containers down; named/external volumes and binds kept)")

    created = api(
        "POST",
        f"/stacks/create/standalone/repository?endpointId={meta['EndpointId']}",
        {
            "name": stack,
            "repositoryURL": REPO_URL,
            "repositoryReferenceName": REPO_REF,
            "composeFile": compose_path,
            "repositoryAuthentication": False,
            "env": env,
            "autoUpdate": AUTO_UPDATE,
        },
    )
    print(f"    recreated from git as id={created.get('Id')} (autoUpdate {AUTO_UPDATE['interval']})")


def rollback(path: str, apply: bool) -> None:
    with open(path) as fh:
        snap = json.load(fh)
    stack = snap["Name"]
    print(f"=== rollback {stack} from {path}")
    if not apply:
        print("    DRY RUN — would delete the git stack and restore the inline definition")
        return
    existing = stacks_by_name().get(stack)
    if existing:
        api("DELETE", f"/stacks/{existing['Id']}?endpointId={existing['EndpointId']}")
        print("    removed git-backed stack")
    api(
        "POST",
        f"/stacks/create/standalone/string?endpointId={snap['EndpointId']}",
        {
            "name": stack,
            "stackFileContent": snap["StackFileContent"],
            "env": snap["Env"],
        },
    )
    print("    restored pre-migration stack")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stack", action="append", default=[], help="stack name; repeatable. default: all")
    ap.add_argument("--env-file", help="JSON of {stack: {VAR: value}}")
    ap.add_argument("--dump-env", action="store_true", help="print an env-file skeleton and exit")
    ap.add_argument("--rollback", help="path to a rollback snapshot JSON")
    ap.add_argument("--apply", action="store_true", help="actually make changes (default: dry run)")
    args = ap.parse_args()

    if args.dump_env:
        json.dump({s: {k: "CHANGEME" for k in v} for s, v in sorted(REQUIRED_ENV.items())},
                  sys.stdout, indent=2)
        print()
        return

    if args.rollback:
        rollback(args.rollback, args.apply)
        return

    env_file = {}
    if args.env_file:
        with open(args.env_file) as fh:
            env_file = json.load(fh)

    live = stacks_by_name()
    targets = args.stack or sorted(live)
    unknown = [s for s in targets if s not in live]
    if unknown:
        raise SystemExit(f"unknown stack(s): {unknown}\nknown: {sorted(live)}")

    if not args.apply:
        print("DRY RUN — nothing will change. Re-run with --apply to convert.\n")

    for stack in targets:
        convert(stack, live[stack], env_file, args.apply)

    print(f"\n{len(targets)} stack(s) processed.")
    if args.apply:
        print(f"Rollback snapshots in {ROLLBACK_DIR}/ — keep until you are happy.")


if __name__ == "__main__":
    main()
