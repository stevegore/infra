#!/usr/bin/env bash
# Build and push the vault-kv-export tooling image to OCIR.
#
# The cluster is ARM (VM.Standard.A1.Flex), so this MUST be built for
# linux/arm64. Building on an Apple Silicon Mac gets that by default; building
# anywhere else needs buildx.
#
#   bash scripts/build-vault-kv-export-image.sh [tag]
#
# Requires a docker login to OCIR:
#   docker login syd.ocir.io -u '<tenancy-ns>/<user>' -p '<auth-token>'
set -euo pipefail

TAG="${1:-0.1.0}"
IMAGE="syd.ocir.io/sdajdczqv0qo/vault-kv-export:${TAG}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/apps/vault-kv-export/docker"

echo "==> building ${IMAGE} (linux/arm64)"
docker buildx build --platform linux/arm64 -t "$IMAGE" --load "$DIR"

echo "==> smoke test"
docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
  'vault version && age --version && jq --version && curl --version | head -1'

echo "==> pushing"
docker push "$IMAGE"

echo
echo "Pushed ${IMAGE}."
echo "Bump image.tag in apps/vault-kv-export/values.yaml to match, then commit."
