#!/usr/bin/env bash
# Install the Portainer reconciler timer on pico. Run ON pico from ~/code/infra:
#
#     sudo bash scripts/install-portainer-auto-update.sh
#
# The reconciler itself runs as steve (docker group); root is only needed to
# place the units. pushover-failure@.service must already be installed (it is,
# by scripts/install-vw-sync.sh) for the OnFailure alert to fire.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
[[ -f /etc/systemd/system/pushover-failure@.service ]] \
  || echo "WARNING: pushover-failure@.service not installed; failures will not page"

install -o steve -g steve -m 755 "$SCRIPT_DIR/portainer-auto-update.sh" /home/steve/.local/bin/portainer-auto-update
install -m 644 "$SCRIPT_DIR/portainer-auto-update.service" /etc/systemd/system/
install -m 644 "$SCRIPT_DIR/portainer-auto-update.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now portainer-auto-update.timer

echo "== first run (no-op unless git is ahead of the host) =="
systemctl start portainer-auto-update.service || true
journalctl -u portainer-auto-update.service -n 15 --no-pager
systemctl list-timers portainer-auto-update.timer --no-pager
