#!/usr/bin/env bash
# Provision OCI Container Registry (OCIR) docker credentials.
#
# Run this once (from the Mac with ~/.oci/config configured) to:
#   1. Mint a new IAM auth token via `oci iam auth-token create`.
#   2. Construct the OCIR docker username (handles federated / IDCS users).
#   3. Save a local backup at ~/.config/ocir/credentials.json (mode 600)
#      — OCI only ever shows an auth token once, so this is your only copy
#      outside Vault.
#   4. Push the pair to Vault at kv/oci/ocir (fields:
#      `username`, `auth_token`) for scripts/build-push-caddy.sh to consume.
#
# Usage:
#   source scripts/vault-env.sh && vlogin   # so VAULT_TOKEN is set
#   bash scripts/provision-ocir-creds.sh
#
# OCI limits a user to 2 auth tokens. If you already have 2, this script will
# list them and ask which to delete before creating a new one.
set -euo pipefail

# --- deps ---
for bin in oci vault jq; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }
done
[[ -n "${VAULT_TOKEN:-}" ]] || {
  echo "VAULT_TOKEN not set — run: source scripts/vault-env.sh && vlogin" >&2
  exit 1
}

VAULT_PATH="kv/oci/ocir"
LOCAL_BACKUP="${HOME}/.config/ocir/credentials.json"
DESCRIPTION="OCIR push from $(hostname -s) ($(date -u +%Y-%m-%d))"

# --- discover OCI identity ---
echo "==> reading ~/.oci/config"
USER_OCID=$(oci iam user list --query 'data[0].id' --raw-output 2>/dev/null || true)
# Fall back to the config file's user field if list isn't permitted.
[[ -z "$USER_OCID" ]] && USER_OCID=$(awk -F= '/^[[:space:]]*user[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' ~/.oci/config)
[[ -n "$USER_OCID" ]] || { echo "couldn't determine OCI user OCID" >&2; exit 1; }

USER_JSON=$(oci iam user get --user-id "$USER_OCID")
USER_NAME=$(jq -r '.data.name' <<<"$USER_JSON")
echo "    user: $USER_NAME"
echo "    ocid: $USER_OCID"

NAMESPACE=$(oci os ns get --query 'data' --raw-output)
echo "    object-storage namespace: $NAMESPACE"

# OCIR docker username conventions:
#   - Local IAM user:        <namespace>/<user-name>
#   - Federated / IDCS user: <namespace>/oracleidentitycloudservice/<email>
# `oci iam user get` returns .data.name already including the IDCS prefix
# when applicable, so concatenation works for both cases.
DOCKER_USER="${NAMESPACE}/${USER_NAME}"
echo "    docker username: $DOCKER_USER"

# --- check token quota ---
EXISTING=$(oci iam auth-token list --user-id "$USER_OCID")
COUNT=$(jq '.data | length' <<<"$EXISTING")
echo "==> existing auth tokens for this user: $COUNT/2"

if (( COUNT >= 2 )); then
  echo "    OCI caps users at 2 auth tokens. Existing:"
  jq -r '.data[] | "      [\(."lifecycle-state")]  \(.id)  — \(.description // "(no description)")"' <<<"$EXISTING"
  read -rp "OCID of token to delete (paste from above, or Ctrl-C to abort): " DELETE_OCID
  [[ -n "$DELETE_OCID" ]] || { echo "nothing entered, aborting"; exit 1; }
  oci iam auth-token delete --user-id "$USER_OCID" --auth-token-id "$DELETE_OCID" --force >/dev/null
  echo "    deleted $DELETE_OCID"
fi

# --- mint new token ---
echo "==> creating new auth token (description: $DESCRIPTION)"
NEW_JSON=$(oci iam auth-token create --user-id "$USER_OCID" --description "$DESCRIPTION")
AUTH_TOKEN=$(jq -r '.data.token' <<<"$NEW_JSON")
TOKEN_OCID=$(jq -r '.data.id' <<<"$NEW_JSON")
[[ -n "$AUTH_TOKEN" && "$AUTH_TOKEN" != "null" ]] || {
  echo "auth-token create returned no .data.token — full response:" >&2
  echo "$NEW_JSON" >&2
  exit 1
}
echo "    token id: $TOKEN_OCID"

# --- local backup (only copy of the token value outside Vault) ---
echo "==> writing local backup to $LOCAL_BACKUP"
install -d -m 700 "$(dirname "$LOCAL_BACKUP")"
umask 077
jq -n \
  --arg user "$DOCKER_USER" \
  --arg token "$AUTH_TOKEN" \
  --arg token_id "$TOKEN_OCID" \
  --arg description "$DESCRIPTION" \
  --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{username:$user, auth_token:$token, token_id:$token_id, description:$description, created:$created}' \
  > "$LOCAL_BACKUP"
chmod 600 "$LOCAL_BACKUP"

# --- push to Vault ---
echo "==> pushing to Vault at $VAULT_PATH"
vault kv put "$VAULT_PATH" \
  username="$DOCKER_USER" \
  auth_token="$AUTH_TOKEN" \
  token_id="$TOKEN_OCID" \
  description="$DESCRIPTION" \
  >/dev/null

echo
echo "✓ done"
echo "  vault:  vault kv get $VAULT_PATH"
echo "  local:  $LOCAL_BACKUP"
echo "  next:   on pico, run scripts/build-push-caddy.sh — it will read from Vault"
