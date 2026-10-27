#!/usr/bin/env bash
# install-pico-guards.sh — install the two units added after the 2026-10-27
# Plex compromise (pico/plex/INCIDENT-2026-10-27.md):
#
#   plex-wan-block.service   drops internet traffic to Plex's TCP ports
#   pico-load-watch.timer    Pushover alert on abnormal sustained load
#
# Run on pico from the git checkout. It needs sudo, and sudo on pico needs a
# password, so this can't be driven over non-interactive SSH:
#   sudo ~/code/infra/scripts/install-pico-guards.sh
#
# Re-running is safe; it also picks up edits to plex-wan-block.sh, whose
# root-owned copy in /usr/local/sbin would otherwise go stale.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)

install -o root -g root -m 0755 "$here/plex-wan-block.sh" /usr/local/sbin/plex-wan-block
install -o root -g root -m 0644 -t /etc/systemd/system \
  "$here/plex-wan-block.service" \
  "$here/pico-load-watch.service" \
  "$here/pico-load-watch.timer"

systemctl daemon-reload
systemctl enable plex-wan-block.service pico-load-watch.timer
systemctl restart plex-wan-block.service
systemctl start pico-load-watch.timer pico-load-watch.service

echo
/usr/local/sbin/plex-wan-block status
echo
systemctl --no-pager --lines=3 status pico-load-watch.service | sed -n '1,4p;/load /p'
