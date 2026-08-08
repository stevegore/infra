# Custom Caddy build for OKE deployment.
# - certmagic-s3:  ACME storage backed by OCI Object Storage S3-compat endpoint,
#                  so both replicas share cert state without a PVC.
# - caddy-dns/cloudflare: DNS-01 ACME challenge.
# (caddy-security removed 2026-06-02 — auth moved to Authentik forward_auth,
#  which uses Caddy's built-in forward_auth directive, no plugin needed.)
#
# Build + push (multi-arch; OKE workers are arm64), then bump the tag in
# values.yaml to match AFTER the push succeeds:
#   docker buildx build --platform linux/arm64 \
#     -t syd.ocir.io/sdajdczqv0qo/caddy:2.11.3-stevegore.2 \
#     --push apps/caddy/

FROM caddy:2.11-builder@sha256:198d47eaee306d4d0c38a9960c89ff2c959aa29ad51d3e2dafa3e93ac961782a AS builder

RUN xcaddy build \
    --with github.com/ss098/certmagic-s3 \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2.11-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
