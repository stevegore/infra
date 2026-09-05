#!/usr/bin/env bash
# One-time (and re-runnable) setup for the nightly Vault kv export.
#
# Creates:
#   1. policy  vault-kv-export-read  — read+list all of kv/, plus policy and
#      mount metadata. This is the broadest read grant in the cluster.
#   2. k8s auth role vault-kv-export — bound to SA vault-kv-export in namespace
#      vault-kv-export only.
#   3. policy  vault-kv-export       — lets VSO read the PAR and the Pushover
#      credentials into the namespace.
#   4. Adds the namespace + policy to the shared vault-secrets-operator role,
#      preserving the existing lists (see vault.md — `vault write` REPLACES a
#      role wholesale, so both lists must be restated in full).
#   5. Mints a write-only PAR on the vault-kms-key-backup bucket and stores it
#      at kv/oci/vault-kv-export.
#
# Run from the Mac:
#   source scripts/vault-env.sh && vlogin
#   bash scripts/vault-kv-export-setup.sh
#
# Re-run to rotate the PAR (the old one is deleted).
set -euo pipefail

for bin in oci vault jq; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }
done
[[ -n "${VAULT_TOKEN:-}" ]] || {
  echo "VAULT_TOKEN not set — run: source scripts/vault-env.sh && vlogin" >&2
  exit 1
}

NS=vault-kv-export
SA=vault-kv-export
BUCKET=vault-kms-key-backup
OS_NAMESPACE=sdajdczqv0qo
REGION=ap-sydney-1
VAULT_PAR_PATH="kv/oci/vault-kv-export"

echo "==> 1/5 policy vault-kv-export-read"
# Reading every secret is the point of a backup, but it is still the widest
# read privilege here — hence its own policy on its own role, not an addition
# to an existing one.
vault policy write vault-kv-export-read - <<'EOF'
# Every secret under the kv v2 mount.
path "kv/data/*" {
  capabilities = ["read"]
}
path "kv/metadata/*" {
  capabilities = ["read", "list"]
}

# Policy bodies, so a restore can rebuild authz rather than just values.
path "sys/policies/acl" {
  capabilities = ["list"]
}
path "sys/policies/acl/*" {
  capabilities = ["read"]
}

# Mount topology. sys/auth is root-protected, so it needs sudo even for a
# plain read; scoped to these two paths only.
path "sys/mounts" {
  capabilities = ["read", "sudo"]
}
path "sys/auth" {
  capabilities = ["read", "sudo"]
}
EOF

echo "==> 2/5 k8s auth role ${SA}"
vault write auth/kubernetes/role/vault-kv-export \
  bound_service_account_names="${SA}" \
  bound_service_account_namespaces="${NS}" \
  policies="vault-kv-export-read" \
  ttl=15m \
  max_ttl=30m >/dev/null

echo "==> 3/5 policy vault-kv-export (for VSO)"
vault policy write vault-kv-export - <<'EOF'
path "kv/data/oci/vault-kv-export" {
  capabilities = ["read"]
}
path "kv/data/homelab/pushover" {
  capabilities = ["read"]
}
EOF

echo "==> 4/5 adding ${NS} to the vault-secrets-operator role"
# vault write REPLACES the role, so read the current lists and append.
CUR=$(vault read -format=json auth/kubernetes/role/vault-secrets-operator)
CUR_NS=$(jq -r '.data.bound_service_account_namespaces | join(",")' <<<"$CUR")
CUR_POL=$(jq -r '(.data.token_policies // .data.policies) | join(",")' <<<"$CUR")
CUR_SA=$(jq -r '.data.bound_service_account_names | join(",")' <<<"$CUR")

NEW_NS="$CUR_NS"; NEW_POL="$CUR_POL"
grep -q "\b${NS}\b" <<<"$CUR_NS"            || NEW_NS="${CUR_NS},${NS}"
grep -q "\bvault-kv-export\b" <<<"$CUR_POL" || NEW_POL="${CUR_POL},vault-kv-export"

if [[ "$NEW_NS" != "$CUR_NS" || "$NEW_POL" != "$CUR_POL" ]]; then
  echo "    namespaces: ${NEW_NS}"
  echo "    policies:   ${NEW_POL}"
  vault write auth/kubernetes/role/vault-secrets-operator \
    bound_service_account_names="$CUR_SA" \
    bound_service_account_namespaces="$NEW_NS" \
    policies="$NEW_POL" \
    ttl=1h >/dev/null
else
  echo "    already present, unchanged"
fi

echo "==> 5/5 minting write-only PAR on ${BUCKET}"
# AnyObjectWrite: can create objects, cannot read, list or delete them. That is
# the whole privilege an append-only backup job needs, and it means a leaked
# PAR cannot be used to read back a single secret.
if date -u -v+1y +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
  EXPIRES=$(date -u -v+1y +%Y-%m-%dT%H:%M:%SZ)   # BSD/macOS
else
  EXPIRES=$(date -u -d '+1 year' +%Y-%m-%dT%H:%M:%SZ)  # GNU
fi

# Drop any previous PAR for this job so rotation doesn't leave live credentials.
OLD=$(oci os preauth-request list --namespace "$OS_NAMESPACE" --bucket-name "$BUCKET" \
        --query "data[?contains(name,'vault-kv-export')].id" --raw-output 2>/dev/null || echo '[]')
for id in $(jq -r '.[]?' <<<"$OLD"); do
  echo "    deleting previous PAR"
  oci os preauth-request delete --namespace "$OS_NAMESPACE" --bucket-name "$BUCKET" \
    --par-id "$id" --force >/dev/null
done

ACCESS_URI=$(oci os preauth-request create \
  --namespace "$OS_NAMESPACE" --bucket-name "$BUCKET" \
  --name "vault-kv-export $(date -u +%Y-%m-%d)" \
  --access-type AnyObjectWrite \
  --time-expires "$EXPIRES" \
  --query 'data."access-uri"' --raw-output)

PAR_URL="https://objectstorage.${REGION}.oraclecloud.com${ACCESS_URI}"

vault kv put "$VAULT_PAR_PATH" \
  par_url="$PAR_URL" \
  bucket="$BUCKET" \
  access_type="AnyObjectWrite" \
  expires="$EXPIRES" \
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  note="Write-only PAR for the nightly kv export. Re-run scripts/vault-kv-export-setup.sh to rotate." >/dev/null

echo
echo "Done. PAR expires ${EXPIRES}."
echo "An expired PAR surfaces as an upload failure and pages via Pushover — it"
echo "does not fail silently. Rotate by re-running this script."
