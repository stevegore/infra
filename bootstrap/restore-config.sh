#!/bin/bash
# Decrypt config/secrets.sops.yaml and render templates into /etc/...
#
# Tries OCI KMS first (works automatically on ampere-ubuntu via instance
# principal). Falls back to age passphrase prompt (works anywhere — laptop,
# fresh VM, disaster recovery).
#
# All cleartext lives in a tmpfs workdir that's shredded on exit.
#
# Run AFTER bootstrap/install.sh has installed Caddy, WireGuard, etc.
# install.sh calls this automatically as its final step.

set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$0")/../config" && pwd)"
WRAPPED_KEY_AGE="${CONFIG_DIR}/age-identity.txt.age"
WRAPPED_KEY_KMS="${CONFIG_DIR}/age-identity.txt.kms"
SECRETS_FILE="${CONFIG_DIR}/secrets.sops.yaml"

OCI_KMS_KEY_OCID="ocid1.key.oc1.ap-sydney-1.fnuxtwyhaahla.abzxsljrgzjola7olf2nj27fljzgkqx5vdwq5f44g7n6wse3awmsoee2imfa"
OCI_KMS_CRYPTO="https://fnuxtwyhaahla-crypto.kms.ap-sydney-1.oraclecloud.com"

[[ -f "$SECRETS_FILE" ]] || { echo "no $SECRETS_FILE — see config/secrets.sops.yaml.example"; exit 1; }
for bin in sops age yq envsubst; do
  command -v "$bin" >/dev/null || { echo "missing required tool: $bin"; exit 1; }
done

# ---- tmpfs workdir, shredded on exit ----
WORKDIR=$(mktemp -d -p /dev/shm bootstrap.XXXXXX 2>/dev/null \
       || mktemp -d -t bootstrap)
trap 'find "$WORKDIR" -type f -exec shred -u {} + 2>/dev/null; rm -rf "$WORKDIR"' EXIT INT TERM
chmod 700 "$WORKDIR"

KEY="$WORKDIR/age-identity.txt"
SECRETS="$WORKDIR/secrets.yaml"

# ---- 1. Unwrap age identity (OCI KMS, else passphrase) ----
if [[ -f "$WRAPPED_KEY_KMS" ]] && command -v oci >/dev/null && \
   oci kms crypto decrypt \
     --key-id "$OCI_KMS_KEY_OCID" \
     --endpoint "$OCI_KMS_CRYPTO" \
     --auth instance_principal \
     --ciphertext "$(cat "$WRAPPED_KEY_KMS")" \
     --query 'data.plaintext' --raw-output 2>/dev/null \
   | base64 -d > "$KEY" && [[ -s "$KEY" ]]; then
  echo "✓ age identity unwrapped via OCI KMS"
elif [[ -f "$WRAPPED_KEY_AGE" ]]; then
  echo "Enter passphrase for age identity:"
  age -d "$WRAPPED_KEY_AGE" > "$KEY"
  echo "✓ age identity unwrapped via passphrase"
else
  echo "no wrapped age identity found at:"
  echo "  $WRAPPED_KEY_AGE  (passphrase)"
  echo "  $WRAPPED_KEY_KMS  (OCI KMS)"
  echo "create with: age-keygen -o key.txt && age -p -o $WRAPPED_KEY_AGE key.txt"
  exit 1
fi
chmod 600 "$KEY"

# ---- 2. Decrypt secrets bundle ----
SOPS_AGE_KEY_FILE="$KEY" sops -d "$SECRETS_FILE" > "$SECRETS"
chmod 600 "$SECRETS"

# ---- 3. Export single-line scalar secrets as UPPER_SNAKE_CASE env vars ----
# Multi-line values (PEM blocks) are skipped here and dumped to files in step 5.
for k in $(yq -r 'keys | .[]' "$SECRETS"); do
  v=$(yq -r ".${k}" "$SECRETS")
  if [[ "$v" != *$'\n'* ]]; then
    export "${k^^}"="$v"
  fi
done

# ---- 4. Render templates ----
render() {
  local tmpl="$1" dest="$2" mode="$3" owner="$4"
  local vars
  # Restrict envsubst to declared placeholders so Caddy's {$VAR} / {env.VAR}
  # syntax (which uses single dollar inside braces) is left untouched.
  vars=$(grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' "$tmpl" | sort -u | tr '\n' ' ')
  sudo install -d -m 755 "$(dirname "$dest")"
  envsubst "$vars" < "$tmpl" \
    | sudo install -m "$mode" -o "${owner%:*}" -g "${owner#*:}" /dev/stdin "$dest"
  echo "✓ $dest"
}

render "$CONFIG_DIR/caddy/Caddyfile.tmpl"    /etc/caddy/Caddyfile       644 caddy:caddy
render "$CONFIG_DIR/caddy/caddy.env.tmpl"    /etc/caddy/caddy.env       600 caddy:caddy
render "$CONFIG_DIR/wireguard/wg0.conf.tmpl" /etc/wireguard/wg0.conf    600 root:root

# ---- 5. Multi-line secrets → files (PEM keys etc.) ----
sudo install -d -m 700 -o caddy -g caddy /etc/caddy/keys
yq -r '.jwt_private_key' "$SECRETS" \
  | sudo install -m 600 -o caddy -g caddy /dev/stdin /etc/caddy/keys/jwt-private.pem
echo "✓ /etc/caddy/keys/jwt-private.pem"

# ---- 6. Plain files (no secrets) ----
sudo install -m 644 -o caddy -g caddy "$CONFIG_DIR/caddy/keys/jwt-public.pem" /etc/caddy/keys/jwt-public.pem
echo "✓ /etc/caddy/keys/jwt-public.pem"

# ---- 7. Reload services ----
sudo systemctl reload caddy 2>/dev/null || sudo systemctl restart caddy
sudo systemctl restart wg-quick@wg0
echo "✓ caddy + wg-quick@wg0 reloaded"
