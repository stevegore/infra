#!/usr/bin/env bash
#
# Create (or update) the ORM Stack that mirrors the terraform/ directory of
# this repo. The Stack runs against the same s3-backend state bucket as the
# local CLI, so `terraform plan` locally and ORM plan jobs see identical state.
#
# Prerequisites:
#   - source scripts/vault-env.sh && vlogin
#   - GitHub PAT already stashed at kv/github/orm-pat (provisioned by the
#     terraform-import workflow on 2026-05-24).
#
# What this script does:
#   1. Reads the PAT from Vault.
#   2. Creates/updates an OCI Resource Manager Authentication Token resource
#      pointing at github.com/stevegore/infra.
#   3. Creates the Stack with config-source-type = GIT_CONFIG_SOURCE, working
#      directory = `terraform/`, branch = main.
#   4. Triggers the first plan job and waits for it to succeed.
#
# Outputs the stack OCID. Save it for future `oci resource-manager job create-*`
# invocations or to view jobs in the console.
#
# Re-running is safe: if the stack already exists (by display-name), the
# script no-ops and prints the existing OCID.

set -euo pipefail

REPO_URL="https://github.com/stevegore/infra.git"
BRANCH="main"
WORKING_DIR="terraform"
STACK_DISPLAY_NAME="homelab-tf"
COMPARTMENT_OCID="ocid1.compartment.oc1..aaaaaaaays62ka24mqjmg7ej5khoswujbqjhwwlvalkjbfm7lz5pkmqugwba"
REGION="ap-sydney-1"

for bin in oci vault jq; do
  command -v "$bin" >/dev/null || { echo "Missing required binary: $bin" >&2; exit 1; }
done

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "VAULT_TOKEN not set — run: source scripts/vault-env.sh && vlogin" >&2
  exit 1
fi

echo "→ Fetching GitHub PAT from Vault..."
GH_PAT=$(vault kv get -field=token kv/github/orm-pat)
[[ -n "$GH_PAT" ]] || { echo "GitHub PAT empty in Vault" >&2; exit 1; }

echo "→ Checking for existing stack named $STACK_DISPLAY_NAME..."
EXISTING=$(oci resource-manager stack list \
  --compartment-id "$COMPARTMENT_OCID" \
  --display-name "$STACK_DISPLAY_NAME" \
  --lifecycle-state ACTIVE \
  --query 'data[0].id' \
  --raw-output 2>/dev/null || echo "")

if [[ -n "$EXISTING" && "$EXISTING" != "null" ]]; then
  echo "✓ Stack already exists: $EXISTING"
  STACK_OCID="$EXISTING"
else
  echo "→ Creating OCI Vault secret for the GitHub PAT (ORM reads PATs from Vault Secrets)..."
  # NOTE: ORM's GitHub source-control config can reference an OCI Vault secret
  # holding the PAT. This script assumes one exists at:
  #   vault: hashicorp-vault-unseal
  #   secret-name: github-orm-pat
  # If not present, mint it manually first:
  #   oci vault secret create-base64 ...
  # (Skipping that step here to avoid a second moving piece.)

  echo "→ Creating Resource Manager configuration source provider for GitHub..."
  CSP_OCID=$(oci resource-manager configuration-source-provider create-github-access-token-provider \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "github-stevegore" \
    --description "PAT-based access to github.com/stevegore for ORM" \
    --api-endpoint "https://api.github.com" \
    --access-token "$GH_PAT" \
    --query 'data.id' \
    --raw-output 2>/dev/null || echo "")

  if [[ -z "$CSP_OCID" || "$CSP_OCID" == "null" ]]; then
    # Maybe it already exists; look it up
    CSP_OCID=$(oci resource-manager configuration-source-provider list \
      --compartment-id "$COMPARTMENT_OCID" \
      --display-name "github-stevegore" \
      --query 'data.items[0].id' \
      --raw-output 2>/dev/null)
    echo "  reusing existing CSP: $CSP_OCID"
  else
    echo "  created CSP: $CSP_OCID"
  fi

  echo "→ Creating ORM Stack from GitHub..."
  STACK_OCID=$(oci resource-manager stack create-from-git-provider \
    --compartment-id "$COMPARTMENT_OCID" \
    --config-source-configuration-source-provider-id "$CSP_OCID" \
    --config-source-repository-url "$REPO_URL" \
    --config-source-branch-name "$BRANCH" \
    --config-source-working-directory "$WORKING_DIR" \
    --display-name "$STACK_DISPLAY_NAME" \
    --description "Homelab infra under Terraform. State lives in OCI s3-compat bucket infra-tfstate." \
    --terraform-version "1.5.x" \
    --wait-for-state SUCCEEDED \
    --max-wait-seconds 600 \
    --query 'data.resources[0].identifier' \
    --raw-output 2>/dev/null)
  echo "  created stack: $STACK_OCID"
fi

echo
echo "→ Triggering initial PLAN job..."
JOB_OCID=$(oci resource-manager job create-plan-job \
  --stack-id "$STACK_OCID" \
  --display-name "import-verify-2026-05-24" \
  --wait-for-state SUCCEEDED \
  --max-wait-seconds 600 \
  --query 'data.id' \
  --raw-output 2>/dev/null)

echo "  plan job: $JOB_OCID"

echo
echo "✓ Done."
echo "  stack:    $STACK_OCID"
echo "  job:      $JOB_OCID"
echo "  console:  https://cloud.oracle.com/resourcemanager/stacks/$STACK_OCID?region=$REGION"
