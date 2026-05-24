#!/usr/bin/env bash
#
# Restore the OCI CLI credentials from Vault to a fresh machine.
#
# Reads kv/oci/api-key and writes:
#   ~/.oci/config   (mode 600) — DEFAULT profile
#   ~/oci.pem       (mode 400) — private API key
#
# Pre-existing files are renamed to *.bak before being overwritten.
#
# Usage:
#   source scripts/vault-env.sh && vlogin
#   bash scripts/restore-oci-creds.sh
#
# After running, `oci iam region list` should work without further setup.

set -euo pipefail

VAULT_PATH="kv/oci/api-key"
CONFIG_PATH="$HOME/.oci/config"
KEY_PATH="$HOME/oci.pem"

for bin in vault jq oci; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }
done
[[ -n "${VAULT_TOKEN:-}" ]] || {
  echo "VAULT_TOKEN not set — run: source scripts/vault-env.sh && vlogin" >&2
  exit 1
}

echo "==> reading $VAULT_PATH"
DATA=$(vault kv get -format=json "$VAULT_PATH")

USER_OCID=$(jq -r '.data.data.user_ocid'    <<<"$DATA")
TENANCY=$(jq -r   '.data.data.tenancy_ocid' <<<"$DATA")
FINGERPRINT=$(jq -r '.data.data.fingerprint' <<<"$DATA")
REGION=$(jq -r    '.data.data.region'       <<<"$DATA")
PRIVATE_KEY=$(jq -r '.data.data.private_key' <<<"$DATA")

for var in USER_OCID TENANCY FINGERPRINT REGION PRIVATE_KEY; do
  [[ -n "${!var}" && "${!var}" != "null" ]] || { echo "missing field: $var" >&2; exit 1; }
done

mkdir -p "$(dirname "$CONFIG_PATH")"

if [[ -e "$KEY_PATH" ]]; then
  mv "$KEY_PATH" "$KEY_PATH.bak"
  echo "    backed up existing $KEY_PATH → $KEY_PATH.bak"
fi
if [[ -e "$CONFIG_PATH" ]]; then
  mv "$CONFIG_PATH" "$CONFIG_PATH.bak"
  echo "    backed up existing $CONFIG_PATH → $CONFIG_PATH.bak"
fi

umask 077
printf '%s\n' "$PRIVATE_KEY" > "$KEY_PATH"
chmod 400 "$KEY_PATH"

cat > "$CONFIG_PATH" <<EOF
[DEFAULT]
user=$USER_OCID
fingerprint=$FINGERPRINT
tenancy=$TENANCY
region=$REGION
key_file=$KEY_PATH
EOF
chmod 600 "$CONFIG_PATH"

# Sanity check: hash the local key, compare to stored fingerprint.
LOCAL_FP=$(openssl rsa -in "$KEY_PATH" -pubout -outform DER 2>/dev/null | openssl md5 -c | awk '{print $NF}')
if [[ "$LOCAL_FP" != "$FINGERPRINT" ]]; then
  echo "WARNING: fingerprint mismatch — stored=$FINGERPRINT, computed=$LOCAL_FP" >&2
  exit 1
fi

echo "==> wrote $CONFIG_PATH + $KEY_PATH"
echo "    fingerprint: $FINGERPRINT (verified)"
echo
echo "==> smoke test: oci iam region list"
oci iam region list --query 'data[?key==`SYD`]' --output table 2>/dev/null
