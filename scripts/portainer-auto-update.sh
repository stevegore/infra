#!/usr/bin/env bash
# Reconcile the Portainer control plane on pico to whatever
# pico/portainer/compose.yaml pins in stevegore/infra@main.
#
#   portainer-auto-update.sh            reconcile (backup + upgrade if needed)
#   portainer-auto-update.sh --dry-run  report what would happen, change nothing
#
# Why this exists rather than Portainer's own auto-patch:
#
#   Portainer EE ships AutoPatchSettings, and it was enabled (daily 04:00). It
#   upgrades the control plane in place without telling git, which is how the
#   host reached 2.39.7 while this repo still pinned 2.39.5. A stale 2.33.6
#   compose file in /opt/portainer then turned an ordinary `docker compose up
#   -d` into a downgrade against an already-migrated database on 2026-09-05,
#   and the UI 502'd until it was redeployed by hand. Two writers, one
#   database, no shared record.
#
#   Auto-patch was switched off on 2026-09-28 and this is now the single
#   writer: Renovate bumps the pin, CI validates it, it automerges, and this
#   reconciles the host to it. Every upgrade is a commit, and every upgrade has
#   a cold backup taken seconds before it.
#
# Safety properties:
#   - Never moves the version backwards. Portainer fails closed on a schema
#     mismatch, but a crash-looping control plane is still an outage.
#   - Pulls the new image BEFORE stopping anything, so a registry failure
#     leaves the running control plane untouched.
#   - Takes and verifies a cold backup of portainer_data before every deploy.
#   - Fails loudly (non-zero exit -> OnFailure Pushover alert) if the new
#     version does not come up healthy with its endpoint intact. It does not
#     try to roll the binary back: once the new version has migrated the
#     database, the old binary refuses to start against it. Recovery is a
#     restore of the backup tarball named in the failure; see portainer.md.
#   - Deploys from a dedicated clone, never from a developer working copy.
#
# Installed by scripts/install-portainer-auto-update.sh.

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

REPO_URL="https://github.com/stevegore/infra.git"
STATE_DIR="${PORTAINER_AUTO_UPDATE_STATE:-$HOME/.local/state/portainer-auto-update}"
CLONE_DIR="$STATE_DIR/infra"
COMPOSE_REL="pico/portainer/compose.yaml"
PROJECT="portainer"
CONTAINER="portainer-portainer-1"
VOLUME="portainer_data"
BACKUP_DIR="/opt/portainer/backups"
BACKUP_KEEP=5
API="http://localhost:9000/api"
HEALTH_TIMEOUT=180
TOKEN_FILE="${PORTAINER_TOKEN_FILE:-$HOME/code/infra/portainer.token}"

log() { printf '%s %s\n' "$(date -Is)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
api_version() {
  curl -fsS --max-time 5 "$API/system/status" 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["Version"])' 2>/dev/null || true
}

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || die "another run holds $STATE_DIR/lock"

# --- 1. Sync the deploy clone -------------------------------------------------
if [[ ! -d "$CLONE_DIR/.git" ]]; then
  log "cloning $REPO_URL -> $CLONE_DIR"
  git clone --quiet --depth 1 --branch main "$REPO_URL" "$CLONE_DIR"
fi
git -C "$CLONE_DIR" fetch --quiet --depth 1 origin main
git -C "$CLONE_DIR" reset --quiet --hard FETCH_HEAD
COMMIT=$(git -C "$CLONE_DIR" rev-parse --short HEAD)
COMPOSE_FILE="$CLONE_DIR/$COMPOSE_REL"
[[ -f "$COMPOSE_FILE" ]] || die "$COMPOSE_REL missing at $COMMIT"

# --- 2. What does git want, and what is running? ------------------------------
DESIRED_IMAGE=$(grep -oP '^\s*image:\s*\K\S+' "$COMPOSE_FILE" | head -1)
[[ -n "$DESIRED_IMAGE" ]] || die "no image: line in $COMPOSE_REL"
DESIRED_TAG=${DESIRED_IMAGE#*:}; DESIRED_TAG=${DESIRED_TAG%@*}
RUNNING_IMAGE=$(docker inspect "$CONTAINER" --format '{{.Config.Image}}' 2>/dev/null || true)
RUNNING_VER=$(api_version)

log "git @$COMMIT pins: $DESIRED_IMAGE"
log "running:           ${RUNNING_IMAGE:-<none>} (API version ${RUNNING_VER:-unknown})"

if [[ "$DESIRED_IMAGE" == "$RUNNING_IMAGE" ]]; then
  log "already reconciled; nothing to do"
  exit 0
fi

# --- 3. Never move backwards --------------------------------------------------
if [[ -n "$RUNNING_VER" ]]; then
  python3 - "$RUNNING_VER" "$DESIRED_TAG" <<'PY' || die "refusing to downgrade Portainer: running $RUNNING_VER, git pins $DESIRED_TAG. A deliberate rollback means restoring a portainer_data backup first and deploying by hand."
import sys
def parse(v): return tuple(int(x) for x in v.split("-")[0].split("."))
sys.exit(0 if parse(sys.argv[2]) >= parse(sys.argv[1]) else 1)
PY
else
  log "WARNING: API not answering; cannot compare versions. Proceeding only because the"
  log "         pin differs and a broken control plane is not worth protecting."
fi

if (( DRY_RUN )); then
  log "dry run: would back up $VOLUME and upgrade ${RUNNING_VER:-?} -> $DESIRED_TAG"
  exit 0
fi

log "upgrading Portainer: ${RUNNING_VER:-unknown} -> $DESIRED_TAG"

# --- 4. Pull first: a registry failure must not cost us the running instance --
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" pull --quiet \
  || die "pull of $DESIRED_IMAGE failed; Portainer left running at ${RUNNING_VER:-?}"

# --- 5. Cold backup -----------------------------------------------------------
# Cold, not hot: Portainer writes BoltDB pages continuously and a tar of a live
# /data can capture a torn page. ~20s of UI downtime buys a restorable artifact.
mkdir -p "$BACKUP_DIR"
NAME="${VOLUME}-${RUNNING_VER:-unknown}-pre-${DESIRED_TAG}-$(date +%Y%m%d-%H%M%S).tar.gz"
BACKUP="$BACKUP_DIR/$NAME"

log "stopping $CONTAINER for cold backup"
docker stop "$CONTAINER" >/dev/null 2>&1 || true

log "backing up $VOLUME -> $BACKUP"
if ! docker run --rm -v "$VOLUME:/data:ro" -v "$BACKUP_DIR:/backup" alpine:3 \
     sh -c "tar czf '/backup/$NAME' -C /data . && gzip -t '/backup/$NAME' && tar tzf '/backup/$NAME' | grep -qx './portainer.db'"; then
  docker start "$CONTAINER" >/dev/null 2>&1 || true
  die "backup failed verification; restarted Portainer at ${RUNNING_VER:-?} without upgrading"
fi
log "backup verified ($(du -h "$BACKUP" | cut -f1))"

# --- 6. Deploy ----------------------------------------------------------------
log "deploying $DESIRED_IMAGE"
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d \
  || die "compose up failed. Restore with the backup at $BACKUP (see portainer.md)"

# --- 7. Health gate -----------------------------------------------------------
log "waiting up to ${HEALTH_TIMEOUT}s for the API to report $DESIRED_TAG"
deadline=$((SECONDS + HEALTH_TIMEOUT)); NEW_VER=""
while (( SECONDS < deadline )); do
  NEW_VER=$(api_version)
  [[ "$NEW_VER" == "$DESIRED_TAG" ]] && break
  sleep 5
done
if [[ "$NEW_VER" != "$DESIRED_TAG" ]]; then
  docker logs --tail 40 "$CONTAINER" 2>&1 || true
  die "API did not reach $DESIRED_TAG (last saw '${NEW_VER:-nothing}'). Backup: $BACKUP"
fi

# --- 8. Verify the control plane still controls things ------------------------
if [[ -r "$TOKEN_FILE" ]]; then
  TOK=$(<"$TOKEN_FILE")
  ENDPOINTS=$(curl -fsS --max-time 10 "$API/endpoints" -H "X-API-Key: $TOK" \
    | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
  STACKS=$(curl -fsS --max-time 10 "$API/stacks" -H "X-API-Key: $TOK" \
    | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
  (( ENDPOINTS > 0 )) || die "upgraded to $NEW_VER but no endpoints visible. Backup: $BACKUP"
  (( STACKS > 0 ))    || die "upgraded to $NEW_VER but no stacks visible. Backup: $BACKUP"
  log "upgraded to $NEW_VER: $ENDPOINTS endpoint(s), $STACKS stack(s)"
else
  log "upgraded to $NEW_VER (WARNING: $TOKEN_FILE unreadable; endpoint/stack check skipped)"
fi

# --- 9. Prune old backups -----------------------------------------------------
ls -1t "$BACKUP_DIR/${VOLUME}"-*.tar.gz 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) \
  | while read -r f; do log "pruning $(basename "$f")"; rm -f "$f"; done

log "done"
