#!/usr/bin/env bash
# Install the Vaultwarden warm-standby sync timer on pico.
# Run from ~/code/infra/ after setting up Tailscale subnet routing.
#
# Prerequisites:
#   - Tailscale oke-connector advertising 10.0.1.0/24 (enabled in tailscale-operator values.yaml)
#   - Route approved in Tailscale admin console **against the live connector
#     device**. After a cluster rebuild the operator registers a new device
#     (oke-connector-1, -2, ...) and the approval does NOT carry over — the
#     stale device keeps the primary route and traffic blackholes. See
#     architecture-proposal.md §7.1.1.
#   - pymysql installed for the steve user: pip3 install --user pymysql
#     (the sync is pure Python + stdlib sqlite3; mysql-client/mysql2sqlite
#     are NOT used)
#   - MySQL password written to /home/steve/.vw-mysql-sync.pass (chmod 600,
#     owned steve — the unit runs as User=steve)
#   - pico-token-sync AppRole credentials in ~/.config/vault-token-sync/
#     (role_id + secret_id) for the Pushover failure alerts — see vault.md §2.
#     Without them the sync still runs; it just fails silently again.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Installing vaultwarden MySQL→sqlite sync on pico ==="

# 1. Copy the sync script and the Pushover notifier. Destinations must match
# ExecStart in the .service units — both run as User=steve out of that user's
# ~/.local/bin, so no sudo.
scp "${SCRIPT_DIR}/vw-mysql-to-sqlite.sh" pico.local:/home/steve/.local/bin/vw-mysql-to-sqlite.sh
scp "${SCRIPT_DIR}/pushover-notify.sh" pico.local:/home/steve/.local/bin/pushover-notify.sh
ssh pico.local "chmod +x /home/steve/.local/bin/vw-mysql-to-sqlite.sh /home/steve/.local/bin/pushover-notify.sh"

# 2. Copy systemd units. pushover-failure@.service is the generic OnFailure=
# target referenced from vw-mysql-to-sqlite.service.
scp "${SCRIPT_DIR}/vw-mysql-to-sqlite.service" pico.local:/tmp/
scp "${SCRIPT_DIR}/vw-mysql-to-sqlite.timer" pico.local:/tmp/
scp "${SCRIPT_DIR}/pushover-failure@.service" pico.local:/tmp/
ssh pico.local "sudo mv /tmp/vw-mysql-to-sqlite.service /etc/systemd/system/ && \
  sudo mv /tmp/vw-mysql-to-sqlite.timer /etc/systemd/system/ && \
  sudo mv '/tmp/pushover-failure@.service' /etc/systemd/system/"

# 3. Enable and start the timer
ssh pico.local "sudo systemctl daemon-reload && \
  sudo systemctl enable vw-mysql-to-sqlite.timer && \
  sudo systemctl start vw-mysql-to-sqlite.timer && \
  sudo systemctl status vw-mysql-to-sqlite.timer --no-pager"

echo "=== Done. Verify with: ssh pico.local 'sudo systemctl status vw-mysql-to-sqlite.timer' ==="
echo "=== Run a one-shot sync with: ssh pico.local 'sudo systemctl start vw-mysql-to-sqlite.service' ==="
