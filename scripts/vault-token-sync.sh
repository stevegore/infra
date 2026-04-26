#!/usr/bin/env bash
# Push every *.token file in TOKEN_DIR to Vault under kv/homelab/<basename>.
# Authenticates via AppRole over WireGuard (Vault sees source IP 10.20.30.1).
set -euo pipefail

export VAULT_ADDR="${VAULT_ADDR:-http://10.20.30.2:30820}"
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
