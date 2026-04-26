#!/usr/bin/env bash
# Install the vault-token-sync systemd service + timer.
# Run with sudo. Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -m 0644 "$SCRIPT_DIR/vault-token-sync.service" /etc/systemd/system/
install -m 0644 "$SCRIPT_DIR/vault-token-sync.timer"   /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now vault-token-sync.timer

systemctl status --no-pager vault-token-sync.timer
echo
echo "Tail logs with: journalctl -u vault-token-sync.service -f"
