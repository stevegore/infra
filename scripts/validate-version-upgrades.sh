#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
helm_bin="${HELM_BIN:-helm}"

echo "Validating Renovate configuration"
jq empty renovate.json

echo "Validating stateful version guards"
if ! grep -Eq '^[[:space:]]+image:[[:space:]]+mysql:5\.7([.][0-9]+)?@sha256:[0-9a-f]{64}[[:space:]]*$' pico/huggin/compose.yaml; then
  echo "Huginn must remain on a digest-pinned MySQL 5.7 image until its staged logical migration is performed" >&2
  exit 1
fi

echo "Validating Helm charts"
chart_repositories=(
  "goauthentik=https://charts.goauthentik.io"
  "cnpg=https://cloudnative-pg.github.io/charts"
  "headlamp=https://kubernetes-sigs.github.io/headlamp/"
  "metrics-server=https://kubernetes-sigs.github.io/metrics-server/"
  "tailscale=https://pkgs.tailscale.com/helmcharts"
  "hashicorp=https://helm.releases.hashicorp.com"
  "cilium=https://helm.cilium.io/"
)

for repository in "${chart_repositories[@]}"; do
  name="${repository%%=*}"
  url="${repository#*=}"
  for attempt in 1 2 3; do
    if "$helm_bin" repo add "$name" "$url" --force-update; then
      break
    fi
    if [[ "$attempt" == 3 ]]; then
      echo "Unable to refresh Helm repository $name after three attempts" >&2
      exit 1
    fi
    sleep "$attempt"
  done
done

while IFS= read -r chart_yaml; do
  chart_dir="${chart_yaml%/Chart.yaml}"
  echo "  $chart_dir"

  if [[ -f "$chart_dir/Chart.lock" ]]; then
    "$helm_bin" dependency build --skip-refresh "$chart_dir"
    dependency_output="$("$helm_bin" dependency list "$chart_dir")"
    printf '%s\n' "$dependency_output"
    if ! awk 'NR == 1 { next } NF && $4 != "ok" { exit 1 }' <<<"$dependency_output"; then
      echo "Helm dependencies are missing or do not match Chart.lock in $chart_dir" >&2
      exit 1
    fi
  fi

  "$helm_bin" lint "$chart_dir"
  "$helm_bin" template upgrade-validation "$chart_dir" >/dev/null
done < <(find apps cilium -path '*/charts' -prune -o -name Chart.yaml -type f -print | sort)

echo "Validating Docker Compose definitions"
export HA_DB_NAME="homeassistant"
export HA_DB_USER="homeassistant"
export HA_DB_PASSWORD="validation-only"
export HA_DB_ROOT_PASSWORD="validation-only"
export HOME_LATITUDE="-33.8688"
export HOME_LONGITUDE="151.2093"
export HOME_ELEVATION="10"
export HOME_TIME_ZONE="Australia/Sydney"
export MATTER_VENDOR_ID="65521"
export MATTER_FABRIC_ID="1"
export MATTER_STORAGE_KEY="validation-only"

while IFS= read -r compose_file; do
  echo "  $compose_file"
  docker compose -f "$compose_file" config --quiet
done < <(find pico -name compose.yaml -type f | sort)

echo "Version-upgrade validation passed"
