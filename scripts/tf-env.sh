#!/usr/bin/env bash
#
# Activate local-backend mode for the homelab-tf stack.
#
#   1. Pulls fresh state from the ORM stack into terraform/.tfstate-cache/
#   2. Renames terraform/backend_override.tf.local → terraform/backend_override.tf
#      (terraform auto-loads *_override.tf; the .local suffix hides it)
#
# Usage:
#   source scripts/tf-env.sh
#   cd terraform && terraform init -reconfigure && terraform plan
#
# Deactivate with scripts/tf-env-off.sh — rename the file back so the
# untracked-file noise doesn't accidentally get committed.
#
# ORM is the source of truth — local can `plan`, never `apply`. If you push
# state from local (`terraform state push`) you bypass ORM's job history;
# don't do that for real apply, only for emergencies.

# Don't use `set -euo pipefail` — this script is meant to be SOURCED, and
# those options would leak into the user's interactive shell.

_tfenv_script_path() {
  if [ -n "${BASH_VERSION:-}" ]; then
    printf '%s' "${BASH_SOURCE[0]}"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    printf '%s' "${(%):-%x}"
  else
    printf '%s' "$0"
  fi
}

_tfenv_main() {
  local script_path script_dir tf_dir
  script_path=$(_tfenv_script_path)
  script_dir=$(cd "$(dirname "$script_path")" && pwd) || { echo "tf-env: cannot locate script dir" >&2; return 1; }
  tf_dir="${HOMELAB_TF_DIR:-$(cd "$script_dir/.." && pwd)/terraform}"

  local stack_ocid="${HOMELAB_TF_STACK_OCID:-ocid1.ormstack.oc1.ap-sydney-1.amaaaaaaxbp2yoqaytua3d676bavg2kdjw6oud5srw7egs3iea7q7ppiydoq}"
  local state_dir="$tf_dir/.tfstate-cache"
  local state_file="$state_dir/homelab-tf.tfstate"
  local override_active="$tf_dir/backend_override.tf"
  local override_dormant="$tf_dir/backend_override.tf.local"

  local bin
  for bin in oci jq; do
    command -v "$bin" >/dev/null || { echo "tf-env: missing required binary: $bin" >&2; return 1; }
  done

  [ -f "$override_dormant" ] || [ -f "$override_active" ] \
    || { echo "tf-env: neither $override_dormant nor $override_active found" >&2; return 1; }

  mkdir -p "$state_dir" || return 1

  echo "→ Pulling state from ORM stack $stack_ocid..."
  oci resource-manager stack get-stack-tf-state \
    --stack-id "$stack_ocid" \
    --file "$state_file" 2>/dev/null || { echo "tf-env: state pull failed" >&2; return 1; }

  if [ -f "$override_dormant" ]; then
    mv "$override_dormant" "$override_active" || { echo "tf-env: rename failed" >&2; return 1; }
    echo "✓ Activated: $override_active"
  else
    echo "✓ Already active: $override_active"
  fi

  local n serial
  n=$(jq '.resources | length' "$state_file")
  serial=$(jq -r '.serial' "$state_file")
  echo "  State: $state_file ($n resources, serial $serial)"
  echo "  Next:  cd $tf_dir && terraform init -reconfigure && terraform plan"
  echo "  Done:  bash $script_dir/tf-env-off.sh"
}

_tfenv_main
unset -f _tfenv_main _tfenv_script_path
