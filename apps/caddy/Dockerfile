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

FROM caddy:2.11-builder@sha256:d842facfd63b960922e57444ff76fd8f0793a66dfdcf481af8026e1f4e6a39b4 AS builder

RUN xcaddy build \
    --with github.com/ss098/certmagic-s3 \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2.11-alpine@sha256:d8542f48d34a9cf4e4c11a478865229840e87e4c96ea3f439101f31a5d35f75f

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
