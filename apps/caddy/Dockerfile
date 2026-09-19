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

FROM caddy:2.11-builder@sha256:401121e61853cb9c7df83cba43e532e49a68e30f32921c7bdcb7a4912168c067 AS builder

RUN xcaddy build \
    --with github.com/ss098/certmagic-s3 \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2.11-alpine@sha256:de23def33b17fb5d1290b0f6c2add1d70780e52341896c00a4c8a2a2fe9d355e

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
