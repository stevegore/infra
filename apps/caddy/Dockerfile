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

FROM caddy:2.11-builder@sha256:bf6a7d38add2508b7d2e3e3f40cf2af399214f143c0fa3daa51f254e01f8d293 AS builder

RUN xcaddy build \
    --with github.com/ss098/certmagic-s3 \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2.11-alpine@sha256:eb4d35b7452d1ab6171fbdbe8d9275b2301dad6dad92115d91e19fb9b24d510f

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
