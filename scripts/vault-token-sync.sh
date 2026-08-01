#!/usr/bin/env bash
# Push every *.token file in TOKEN_DIR to Vault under kv/homelab/<basename>.
# Authenticates via AppRole; Vault sees pico's Tailscale IP (100.98.212.71).
set -euo pipefail

# vault-oke-1, not vault-oke. The 2026-06-06 cluster rebuild left the original
# `vault-oke` tailnet device registered but dead, so when the Tailscale operator
# re-registered the proxy it had to take the next free name. MagicDNS still
# resolves `vault-oke` — to the corpse (100.71.200.112, offline since the
# rebuild) — so the old value failed as a 30s i/o timeout every 15 minutes
# rather than as anything that looked like a name error. Fixed 2026-08-01.
#
# If the stale device is ever deleted and the proxy reclaims `vault-oke`, this
# needs to move back. Verify with `tailscale status | grep vault-oke`.
export VAULT_ADDR="${VAULT_ADDR:-http://vault-oke-1:8200}"
CRED_DIR="${CRED_DIR:-$HOME/.config/vault-token-sync}"
TOKEN_DIR="${TOKEN_DIR:-$HOME/code/infra}"
# Don't sync the bootstrap credential into the thing it bootstraps.
SKIP_NAMES_RE="${SKIP_NAMES_RE:-^(vault-root)$}"

ROLE_ID="$(tr -d '\n' < "$CRED_DIR/role_id")"
SECRET_ID="$(tr -d '\n' < "$CRED_DIR/secret_id")"

VAULT_TOKEN=$(vault write -field=token auth/approle/login \
    role_id="$ROLE_ID" secret_id="$SECRET_ID")
[[ -z "$VAULT_TOKEN" ]] && { echo "approle login failed" >&2; exit 1; }
export VAULT_TOKEN

trap 'vault token revoke -self >/dev/null 2>&1 || true' EXIT

shopt -s nullglob
synced=0
for f in "$TOKEN_DIR"/*.token; do
    name="$(basename "$f" .token)"
    if [[ "$name" =~ $SKIP_NAMES_RE ]]; then
        echo "  skip $name (excluded)"
        continue
    fi

    value="$(tr -d '\n' < "$f")"
    if [[ -z "$value" ]]; then
        echo "  skip $name (empty)"
        continue
    fi

    if vault kv put "kv/homelab/$name" token="$value" >/dev/null; then
        echo "  put kv/homelab/$name"
        synced=$((synced + 1))
    else
        echo "  FAIL kv/homelab/$name" >&2
    fi
done

echo "synced $synced token(s)"
