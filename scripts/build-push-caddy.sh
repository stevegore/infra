#!/usr/bin/env bash
# Build the custom Caddy image (caddy-security + certmagic-s3) and push it to
# OCI Container Registry, tagged for arm64 (OKE A1.Flex workers).
#
# Runs on either:
#   - pico (x86_64 Ubuntu) — qemu binfmt handlers are installed automatically
#   - Mac (Apple Silicon)  — native arm64, no emulation needed
#
#   bash scripts/build-push-caddy.sh
#
# Behavior:
#   - Reads image.repository + image.tag from apps-oke/caddy/values.yaml (so the
#     tag pushed and the tag ArgoCD pulls always match). Override with --tag.
#   - OCIR creds resolved in this order:
#       1. $OCIR_USER + $OCIR_TOKEN env vars (skip Vault entirely)
#       2. Vault at kv/ocir/credentials with fields `username` + `auth_token`
#          (requires VAULT_TOKEN to be set — `source scripts/vault-env.sh &&
#          vlogin` works on both pico and Mac)
#       3. interactive prompt
#   - On non-arm64 hosts: installs qemu binfmt handlers to emulate arm64.
#     On arm64 hosts (Apple Silicon): native build, no emulation.
#   - Reuses the `multiarch` buildx builder if it exists; creates it otherwise.
#
# To populate the Vault secret (path 2), run once from the Mac:
#   source scripts/vault-env.sh && vlogin
#   bash scripts/provision-ocir-creds.sh
# That uses the OCI CLI to mint a fresh auth token and pushes it to
# kv/ocir/credentials with the correctly-formed docker username.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALUES="$REPO_ROOT/apps-oke/caddy/values.yaml"
DOCKERFILE_DIR="$REPO_ROOT/apps-oke/caddy"
BUILDER_NAME="multiarch"
PLATFORM="linux/arm64"

# --- args ---
TAG_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -euo/{/^set -euo/!p;}' "$0" | sed 's/^# //; s/^#//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- deps ---
for bin in docker yq; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }
done

# --- image ref ---
REPO=$(yq -r '.image.repository' "$VALUES")
TAG=${TAG_OVERRIDE:-$(yq -r '.image.tag' "$VALUES")}
[[ -z "$REPO" || "$REPO" == "null" ]] && { echo "image.repository missing in $VALUES" >&2; exit 1; }
[[ -z "$TAG"  || "$TAG"  == "null" ]] && { echo "image.tag missing in $VALUES" >&2; exit 1; }
IMAGE="${REPO}:${TAG}"
REGISTRY="${REPO%%/*}"
echo "==> building ${IMAGE} for ${PLATFORM}"

# --- credentials ---
get_creds_from_vault() {
  command -v vault >/dev/null || return 1
  [[ -n "${VAULT_TOKEN:-}" ]] || return 1
  local out
  out=$(vault kv get -format=json kv/ocir/credentials 2>/dev/null) || return 1
  OCIR_USER=$(jq -r '.data.data.username'   <<<"$out")
  OCIR_TOKEN=$(jq -r '.data.data.auth_token' <<<"$out")
  [[ -n "$OCIR_USER" && "$OCIR_USER" != "null" ]] || return 1
  [[ -n "$OCIR_TOKEN" && "$OCIR_TOKEN" != "null" ]] || return 1
}

if [[ -z "${OCIR_USER:-}" || -z "${OCIR_TOKEN:-}" ]]; then
  if get_creds_from_vault; then
    echo "    creds: kv/ocir/credentials"
  else
    echo "    creds: interactive (set OCIR_USER + OCIR_TOKEN to skip)"
    read -rp "OCIR user (e.g. sdajdczqv0qo/youruser): " OCIR_USER
    read -rsp "OCIR auth token: " OCIR_TOKEN
    echo
  fi
fi

# --- docker login ---
echo "==> docker login ${REGISTRY}"
echo "$OCIR_TOKEN" | docker login "$REGISTRY" --username "$OCIR_USER" --password-stdin

# --- buildx + (optional) binfmt ---
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
  arm64|aarch64) NEED_QEMU=0; BUILD_MODE="native" ;;
  *)             NEED_QEMU=1; BUILD_MODE="emulated" ;;
esac
echo "==> host: $HOST_ARCH → target: $PLATFORM ($BUILD_MODE)"

if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
  if (( NEED_QEMU )); then
    echo "==> bootstrap qemu binfmt handlers (arm64 emulation)"
    docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null
  fi
  echo "==> create buildx builder: $BUILDER_NAME"
  docker buildx create --name "$BUILDER_NAME" --driver docker-container --bootstrap >/dev/null
fi
docker buildx use "$BUILDER_NAME"

# --- build + push ---
echo "==> docker buildx build --push"
docker buildx build \
  --platform "$PLATFORM" \
  --tag "$IMAGE" \
  --push \
  "$DOCKERFILE_DIR"

echo
echo "✓ pushed ${IMAGE}"
echo "  next: argocd app sync caddy   (or wait for auto-sync)"
