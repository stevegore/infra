#!/usr/bin/env bash
#
# Source me (don't execute me) to set Terraform s3-backend env vars from Vault.
#
# Usage:
#   source scripts/vault-env.sh && vlogin   # so VAULT_TOKEN is set
#   source scripts/tf-env.sh
#   cd terraform && terraform plan
#
# Idempotent: re-sourcing just refreshes the values.

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "VAULT_TOKEN not set — run: source scripts/vault-env.sh && vlogin" >&2
  return 1 2>/dev/null || exit 1
fi

for bin in vault jq; do
  command -v "$bin" >/dev/null || { echo "Missing required binary: $bin" >&2; return 1 2>/dev/null || exit 1; }
done

_tf_secret=$(vault kv get -format=json kv/oci/tf-state-s3) || {
  echo "Failed to read kv/oci/tf-state-s3 from Vault" >&2
  return 1 2>/dev/null || exit 1
}

export AWS_ACCESS_KEY_ID=$(jq -r '.data.data.access_key' <<<"$_tf_secret")
export AWS_SECRET_ACCESS_KEY=$(jq -r '.data.data.secret_key' <<<"$_tf_secret")
export AWS_REGION=$(jq -r '.data.data.region' <<<"$_tf_secret")

unset _tf_secret

echo "✓ Terraform s3-backend env loaded (access_key=${AWS_ACCESS_KEY_ID:0:8}…, region=$AWS_REGION)"
