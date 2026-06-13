# garmin-mcp

Garmin Connect MCP server for Claude (Desktop, claude.ai web, mobile), deployed on OKE.

- **Server:** [Taxuspt/garmin_mcp](https://github.com/Taxuspt/garmin_mcp) (stdio, built on
  [python-garminconnect](https://github.com/cyberjunky/python-garminconnect) — the maintained
  Garmin auth lib; `garth` is deprecated since Garmin broke its auth flow in early 2026).
- **Bridge:** [mcp-proxy](https://github.com/sparfenyuk/mcp-proxy) exposes it as stateless
  streamable HTTP on `:8080` (`/mcp`, legacy `/sse`, health at `/status`).
- **Image:** `syd.ocir.io/sdajdczqv0qo/garmin-mcp` — built from `images/garmin-mcp/Dockerfile`
  (linux/arm64; push creds in Vault at `kv/oci/ocir`).
- **Exposure:** Caddy serves `garmin.stevegore.au` and proxies only
  `/{$GARMIN_MCP_PATH_SECRET}/*` (404 otherwise). The secret path segment lives in
  `kv/caddy/config` → `garmin_mcp_path_secret`. Connector URL:
  `https://garmin.stevegore.au/<secret>/mcp` — treat the full URL as a credential.

## Claude hookup

Claude Desktop / claude.ai → Settings → Connectors → Add custom connector → paste the
connector URL (no auth — the secret is the URL path):

```bash
echo "https://garmin.stevegore.au/$(vault kv get -field=garmin_mcp_path_secret kv/caddy/config)/mcp"
```

## Garmin token lifecycle

Garmin requires an interactive (MFA) login, so tokens are minted locally and shipped via
Vault; the pod never sees the Garmin password.

1. `uvx --python 3.12 --from git+https://github.com/Taxuspt/garmin_mcp garmin-mcp-auth`
   (prompts email/password/MFA; writes `~/.garminconnect/garmin_tokens.json`).
2. `vault kv put kv/garmin-mcp/config GARMIN_TOKENS_JSON=@"$HOME/.garminconnect/garmin_tokens.json"`
3. VSO syncs it to the `garmin-mcp-config` secret; an init container seeds
   `/data/garmintokens/garmin_tokens.json` on the PVC **only if the file is absent**
   (garminconnect refreshes tokens in place on the PVC, and a stale Vault copy must not
   clobber a newer refreshed token).

**Renewal (~every 6 months, or when the pod logs auth errors):** repeat steps 1–2, then
delete the on-PVC copy so the init container re-seeds:

```bash
export KUBECONFIG=~/.kube/oke-homelab.config
kubectl -n garmin-mcp exec deploy/garmin-mcp -- rm /data/garmintokens/garmin_tokens.json
kubectl -n garmin-mcp rollout restart deploy/garmin-mcp
```

## Bootstrap notes (first deploy)

- OCIR pull secret is manual, once, after the namespace first syncs (see `values.yaml`).
- Vault onboarding (already done 2026-06-13): `garmin-mcp` policy + namespace appended to
  the `vault-secrets-operator` k8s auth role (`vault.md`).
- Rotating the URL secret: write a new `garmin_mcp_path_secret` to `kv/caddy/config`,
  wait for VSO refresh (≤1h) or force it, then restart the Caddy deployment and update
  the connector URL in Claude.
