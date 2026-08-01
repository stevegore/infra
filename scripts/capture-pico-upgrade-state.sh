#!/usr/bin/env bash
# Capture pico's private pre-release-upgrade baseline outside the public repo.

set -euo pipefail

if [[ $(hostname -s) != "pico" ]]; then
    echo "error: run this on pico" >&2
    exit 1
fi

state_root=${XDG_STATE_HOME:-"$HOME/.local/state"}/infra
timestamp=$(date +%Y%m%dT%H%M%S)
target=${1:-"$state_root/upgrade-26.04-state-$timestamp"}

if [[ -e $target ]]; then
    echo "error: target already exists: $target" >&2
    exit 1
fi

umask 077
install -d -m 700 "$target"

apt-mark showmanual > "$target/apt-manual.txt"
dpkg --get-selections > "$target/dpkg-selections.txt"
df -h > "$target/df.txt"
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' > "$target/docker-containers.txt"
sort -o "$target/docker-containers.txt" "$target/docker-containers.txt"
docker volume ls -q > "$target/docker-volumes.txt"
sort -o "$target/docker-volumes.txt" "$target/docker-volumes.txt"
ip -br addr > "$target/net-addr.txt"
ip route > "$target/net-routes.txt"
pro status > "$target/pro-status.txt"
snap list --all > "$target/snap-list.txt"
systemctl list-unit-files --state=enabled --no-legend > "$target/systemd-enabled.txt"
systemctl list-units --type=service --state=running --no-legend > "$target/systemd-running.txt"
systemctl --failed --no-pager > "$target/systemd-failed.txt" || true

git -C "$HOME/code/infra" status --short --branch > "$target/infra-git.txt"
git -C "$HOME/code/infra" rev-parse HEAD >> "$target/infra-git.txt"

echo "$target"
