#!/usr/bin/env bash
# deconz-gitops.sh — keep the Pi's containers in step with this repo.
#
# The Pi's equivalent of Portainer's 5-minute Git poll on pico. Renovate
# merges a tag bump to main; within 5 minutes this fast-forwards the checkout
# and `docker compose up -d` recreates whatever changed. Idempotent: with no
# change it is a no-op.
#
# Portainer was not used here: its agent would need a LAN-reachable Docker
# control port on the Pi and a version kept in lockstep with pico's server,
# all to manage one container.
#
# Runs as root from deconz-gitops.service. Installed by
# raspberrypi/bootstrap.sh; the checkout is a sparse clone at /opt/infra.

set -euo pipefail

REPO=/opt/infra
COMPOSE=$REPO/raspberrypi/deconz/compose.yaml

git -C "$REPO" fetch --quiet origin main
if [[ $(git -C "$REPO" rev-parse HEAD) != $(git -C "$REPO" rev-parse origin/main) ]]; then
    echo "updating checkout to $(git -C "$REPO" rev-parse --short origin/main)"
    git -C "$REPO" reset --quiet --hard origin/main
fi

# --pull missing: images are digest-pinned, so a changed digest is a new
# image reference and gets pulled; an unchanged one never hits the registry.
docker compose -f "$COMPOSE" up -d --pull missing --remove-orphans --quiet-pull

# Old images pile up on a 32-64 GB card otherwise.
docker image prune -f --filter "until=168h" >/dev/null
