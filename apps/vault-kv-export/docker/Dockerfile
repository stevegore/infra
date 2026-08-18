# Tooling image for the nightly Vault kv export. Contains no application logic
# — the script lives in a ConfigMap so it stays pure GitOps — so this only ever
# needs rebuilding to move tool versions.
#
# Based on hashicorp/vault purely for the `vault` CLI: it is Alpine, it is
# already pulled onto both nodes for the Vault StatefulSet, and pinning it to
# the same tag as apps/vault/values.yaml keeps client and server in step.
FROM docker.io/hashicorp/vault:2.0.4

USER root
# age  — asymmetric encryption to the offline recipient key
# jq   — JSON assembly
# curl — PAR upload + Pushover
RUN apk add --no-cache age jq curl

# The base image's entrypoint is Vault's server wrapper; this image only ever
# runs a script, so clear it rather than fighting it with `command`.
ENTRYPOINT []

# uid 100 / gid 1000 is `vault` in the base image, matched by the pod's
# securityContext.
USER 100:1000
