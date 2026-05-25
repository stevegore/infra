# Custom Caddy build for OKE deployment.
# - caddy-security: GitHub OAuth identity portal + JWT authz (per Caddyfile).
# - certmagic-s3:  ACME storage backed by OCI Object Storage S3-compat endpoint,
#                  so both replicas share cert state without a PVC.
#
# Build + push (multi-arch; OKE workers are arm64):
#   docker buildx build --platform linux/arm64 \
#     -t syd.ocir.io/sdajdczqv0qo/caddy:2.11.2-stevegore.1 \
#     --push apps-oke/caddy/

FROM caddy:2.11-builder AS builder

RUN xcaddy build \
    --with github.com/greenpau/caddy-security \
    --with github.com/ss098/certmagic-s3 \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2.11-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
