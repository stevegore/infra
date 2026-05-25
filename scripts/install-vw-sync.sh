#!/usr/bin/env bash
# Install the Vaultwarden warm-standby sync timer on pico.
# Run from ~/code/infra/ after setting up Tailscale subnet routing.
#
# Prerequisites:
#   - Tailscale oke-connector advertising 10.0.1.0/24 (enabled in tailscale-operator values.yaml)
#   - Route approved in Tailscale admin console
#   - mysql-client installed: sudo apt-get install -y mysql-client
#   - mysql2sqlite installed: https://github.com/dumblob/mysql2sqlite
#   - MySQL password written to /etc/vw-mysql-sync.pass (chmod 600, owned root)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Installing vaultwarden MySQL→sqlite sync on pico ==="

# 1. Copy the sync script
scp "${SCRIPT_DIR}/vw-mysql-to-sqlite.sh" pico.local:/tmp/vw-mysql-to-sqlite.sh
ssh pico.local "sudo mv /tmp/vw-mysql-to-sqlite.sh /usr/local/bin/vw-mysql-to-sqlite.sh && sudo chmod +x /usr/local/bin/vw-mysql-to-sqlite.sh"

# 2. Copy systemd units
scp "${SCRIPT_DIR}/vw-mysql-to-sqlite.service" pico.local:/tmp/
scp "${SCRIPT_DIR}/vw-mysql-to-sqlite.timer" pico.local:/tmp/
ssh pico.local "sudo mv /tmp/vw-mysql-to-sqlite.service /etc/systemd/system/ && \
  sudo mv /tmp/vw-mysql-to-sqlite.timer /etc/systemd/system/"

# 3. Enable and start the timer
ssh pico.local "sudo systemctl daemon-reload && \
  sudo systemctl enable vw-mysql-to-sqlite.timer && \
  sudo systemctl start vw-mysql-to-sqlite.timer && \
  sudo systemctl status vw-mysql-to-sqlite.timer --no-pager"

echo "=== Done. Verify with: ssh pico.local 'sudo systemctl status vw-mysql-to-sqlite.timer' ==="
echo "=== Run a one-shot sync with: ssh pico.local 'sudo systemctl start vw-mysql-to-sqlite.service' ==="
