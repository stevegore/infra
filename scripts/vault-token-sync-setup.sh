#!/usr/bin/env bash
# One-time bootstrap. Uses the root token to:
#   - enable the approle auth method
#   - install the pico-token-sync policy
#   - create a CIDR-bound role
#   - emit role_id + secret_id into ~/.config/vault-token-sync/
# Re-running rotates the secret_id.
set -euo pipefail

export VAULT_ADDR="${VAULT_ADDR:-http://10.20.30.2:30820}"
ROOT_TOKEN_FILE="${ROOT_TOKEN_FILE:-$HOME/code/infra/vault-root.token}"
PICO_CIDR="${PICO_CIDR:-10.20.30.1/32}"
ROLE_NAME="pico-token-sync"
POLICY_NAME="pico-token-sync"
CRED_DIR="${CRED_DIR:-$HOME/.config/vault-token-sync}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VAULT_TOKEN="$(tr -d '\n' < "$ROOT_TOKEN_FILE")"
[[ -z "$VAULT_TOKEN" ]] && { echo "empty root token at $ROOT_TOKEN_FILE" >&2; exit 1; }
export VAULT_TOKEN

echo ">> Enabling approle auth (idempotent)"
if vault auth list -format=json | jq -e '."approle/"' >/dev/null 2>&1; then
    echo "   already enabled"
else
    vault auth enable approle
fi

echo ">> Writing policy $POLICY_NAME"
vault policy write "$POLICY_NAME" "$SCRIPT_DIR/vault-token-sync.policy.hcl" >/dev/null

echo ">> Upserting role $ROLE_NAME (CIDR $PICO_CIDR)"
vault write "auth/approle/role/$ROLE_NAME" \
    secret_id_bound_cidrs="$PICO_CIDR" \
    token_bound_cidrs="$PICO_CIDR" \
    token_policies="$POLICY_NAME" \
    token_ttl=10m \
    token_max_ttl=30m \
    secret_id_ttl=0 >/dev/null

echo ">> Fetching role_id"
role_id=$(vault read -field=role_id "auth/approle/role/$ROLE_NAME/role-id")

echo ">> Generating secret_id"
secret_id=$(vault write -force -field=secret_id "auth/approle/role/$ROLE_NAME/secret-id")

[[ -z "$role_id" ]] && { echo "no role_id returned" >&2; exit 1; }
[[ -z "$secret_id" ]] && { echo "no secret_id returned" >&2; exit 1; }

mkdir -p "$CRED_DIR"
chmod 700 "$CRED_DIR"
umask 077
printf '%s\n' "$role_id"   > "$CRED_DIR/role_id"
printf '%s\n' "$secret_id" > "$CRED_DIR/secret_id"
chmod 600 "$CRED_DIR/role_id" "$CRED_DIR/secret_id"

echo
echo "Done. Credentials at $CRED_DIR/"
echo "Next: $SCRIPT_DIR/vault-token-sync.sh"
