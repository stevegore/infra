#!/usr/bin/env bash
# Provision an OCI Customer Secret Key (HMAC) for the caddy-acme bucket and
# push it to Vault for VSO to mount into the Caddy pods.
#
# OCI Object Storage's S3-compat endpoint requires an HMAC key pair tied to
# an IAM user — instance principals cannot use the S3 API, and Terraform
# would persist `secret_key` in state, so this is minted out-of-band.
#
# Run once (from the Mac with ~/.oci/config configured):
#   source scripts/vault-env.sh && vlogin
#   bash scripts/provision-caddy-acme-creds.sh
#
# Output:
#   1. Local backup at ~/.config/caddy-acme/credentials.json (mode 600) —
#      OCI shows the secret_key value exactly once.
#   2. Vault entry at kv/oci/caddy-acme with fields:
#        access_key, secret_key, customer_secret_key_id,
#        s3_host, bucket, description, created
#      The Caddy chart's VaultStaticSecret pulls from this path.
#
# OCI limits a user to 2 Customer Secret Keys. If you already have 2, this
# script lists them and asks which to delete before creating a new one.
set -euo pipefail

for bin in oci vault jq; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }
done
[[ -n "${VAULT_TOKEN:-}" ]] || {
  echo "VAULT_TOKEN not set — run: source scripts/vault-env.sh && vlogin" >&2
  exit 1
}

VAULT_PATH="kv/oci/caddy-acme"
LOCAL_BACKUP="${HOME}/.config/caddy-acme/credentials.json"
BUCKET="caddy-acme"
DESCRIPTION="caddy-acme S3 from $(hostname -s) ($(date -u +%Y-%m-%d))"

echo "==> reading ~/.oci/config"
USER_OCID=$(oci iam user list --query 'data[0].id' --raw-output 2>/dev/null || true)
[[ -z "$USER_OCID" ]] && USER_OCID=$(awk -F= '/^[[:space:]]*user[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' ~/.oci/config)
[[ -n "$USER_OCID" ]] || { echo "couldn't determine OCI user OCID" >&2; exit 1; }

USER_NAME=$(oci iam user get --user-id "$USER_OCID" --query 'data.name' --raw-output)
echo "    user: $USER_NAME"
echo "    ocid: $USER_OCID"

NAMESPACE=$(oci os ns get --query 'data' --raw-output)
REGION=$(awk -F= '/^[[:space:]]*region[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' ~/.oci/config)
S3_HOST="${NAMESPACE}.compat.objectstorage.${REGION}.oraclecloud.com"
echo "    object-storage namespace: $NAMESPACE"
echo "    S3 host: $S3_HOST"

echo "==> existing Customer Secret Keys for this user"
EXISTING=$(oci iam customer-secret-key list --user-id "$USER_OCID")
COUNT=$(jq '.data | length' <<<"$EXISTING")
echo "    count: $COUNT/2"
jq -r '.data[] | "      [\(."lifecycle-state")]  \(.id)  — \(."display-name" // "(no name)")"' <<<"$EXISTING" || true

if (( COUNT >= 2 )); then
  read -rp "OCID of key to delete (paste from above, or Ctrl-C to abort): " DELETE_OCID
  [[ -n "$DELETE_OCID" ]] || { echo "nothing entered, aborting"; exit 1; }
  oci iam customer-secret-key delete --user-id "$USER_OCID" --customer-secret-key-id "$DELETE_OCID" --force >/dev/null
  echo "    deleted $DELETE_OCID"
fi

echo "==> creating new Customer Secret Key (display-name: $DESCRIPTION)"
# Note: --query / --raw-output cause OCI CLI to emit FutureWarning to stderr
# AND drop the secret_key from the rendered shape (since it's only present on
# the create response). Capture the full JSON and parse with jq instead.
NEW_JSON=$(oci iam customer-secret-key create \
  --user-id "$USER_OCID" \
  --display-name "$DESCRIPTION" 2>/dev/null)

ACCESS_KEY=$(jq -r '.data.id' <<<"$NEW_JSON")
SECRET_KEY=$(jq -r '.data.key' <<<"$NEW_JSON")
KEY_OCID=$(jq -r '.data.id' <<<"$NEW_JSON")

[[ -n "$SECRET_KEY" && "$SECRET_KEY" != "null" ]] || {
  echo "customer-secret-key create returned no .data.key — full response:" >&2
  echo "$NEW_JSON" >&2
  exit 1
}
echo "    access_key (id): $ACCESS_KEY"
echo "    secret_key:      ${SECRET_KEY:0:6}…${SECRET_KEY: -4} (full value below)"

echo "==> writing local backup to $LOCAL_BACKUP"
install -d -m 700 "$(dirname "$LOCAL_BACKUP")"
umask 077
jq -n \
  --arg access_key "$ACCESS_KEY" \
  --arg secret_key "$SECRET_KEY" \
  --arg id "$KEY_OCID" \
  --arg s3_host "$S3_HOST" \
  --arg bucket "$BUCKET" \
  --arg description "$DESCRIPTION" \
  --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{access_key:$access_key, secret_key:$secret_key, customer_secret_key_id:$id,
    s3_host:$s3_host, bucket:$bucket, description:$description, created:$created}' \
  > "$LOCAL_BACKUP"
chmod 600 "$LOCAL_BACKUP"

echo "==> pushing to Vault at $VAULT_PATH"
vault kv put "$VAULT_PATH" \
  access_key="$ACCESS_KEY" \
  secret_key="$SECRET_KEY" \
  customer_secret_key_id="$KEY_OCID" \
  s3_host="$S3_HOST" \
  bucket="$BUCKET" \
  description="$DESCRIPTION" \
  >/dev/null

echo
echo "✓ done"
echo "  vault:  vault kv get $VAULT_PATH"
echo "  local:  $LOCAL_BACKUP"
echo "  next:   deploy apps-oke/caddy — VSO will mount these into the pod"
