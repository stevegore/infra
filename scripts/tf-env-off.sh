#!/usr/bin/env bash
#
# Deactivate local-backend mode for the homelab-tf stack.
#
#   1. Renames terraform/backend_override.tf → terraform/backend_override.tf.local
#      so terraform stops auto-loading it (and so the repo is clean to commit).
#   2. Removes the state cache + .terraform/ so the next `terraform init` is
#      fresh (skip with --keep-cache).
#
# Usage: bash scripts/tf-env-off.sh [--keep-cache]
#
# Run this when you're done with local plans. It's a normal script (not
# sourced) — no shell state to unset.

set -euo pipefail

KEEP_CACHE=0
for arg in "$@"; do
  case "$arg" in
    --keep-cache) KEEP_CACHE=1 ;;
    -h|--help) sed -n '2,/^set -euo/{/^set -euo/!p;}' "$0" | sed 's/^# //; s/^#//'; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="${HOMELAB_TF_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)/terraform}"
OVERRIDE_ACTIVE="$TF_DIR/backend_override.tf"
OVERRIDE_DORMANT="$TF_DIR/backend_override.tf.local"

if [ -f "$OVERRIDE_ACTIVE" ]; then
  if [ -f "$OVERRIDE_DORMANT" ]; then
    echo "tf-env-off: both $OVERRIDE_ACTIVE and $OVERRIDE_DORMANT exist; refusing to overwrite" >&2
    exit 1
  fi
  mv "$OVERRIDE_ACTIVE" "$OVERRIDE_DORMANT"
  echo "✓ Deactivated: $OVERRIDE_DORMANT"
else
  echo "✓ Already deactivated"
fi

if [ "$KEEP_CACHE" -eq 0 ]; then
  # Keep .terraform.lock.hcl — it's committed (pins provider versions across
  # local + ORM). Drop the cached state + .terraform/ working dir only.
  rm -rf "$TF_DIR/.tfstate-cache" "$TF_DIR/.terraform"
  echo "  Cleaned: .tfstate-cache/, .terraform/"
fi
