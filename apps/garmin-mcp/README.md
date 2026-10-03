# garmin-mcp

Garmin Connect MCP server for Claude (Desktop, claude.ai web, mobile), deployed on OKE.

- **Server:** [Taxuspt/garmin_mcp](https://github.com/Taxuspt/garmin_mcp) (stdio, built on
  [python-garminconnect](https://github.com/cyberjunky/python-garminconnect) — the maintained
  Garmin auth lib; `garth` is deprecated since Garmin broke its auth flow in early 2026).
- **Bridge:** [mcp-proxy](https://github.com/sparfenyuk/mcp-proxy) exposes it as stateless
  streamable HTTP on `:8080` (`/mcp`, legacy `/sse`, health at `/status`).
- **Image:** `syd.ocir.io/sdajdczqv0qo/garmin-mcp` — built from `images/garmin-mcp/Dockerfile`
  (linux/arm64; push creds in Vault at `kv/oci/ocir`). `mcp` is pinned to 1.27.2: mcp 2.x
  removed `FastMCP`, which garmin_mcp imports.
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

The account has **no MFA**, so auth is self-healing: `GARMIN_USERNAME` / `GARMIN_PASSWORD`
in `kv/garmin-mcp/config` are mounted into the pod as files, and
`images/garmin-mcp/garmin_mcp_launcher.py` wraps the server:

- **Normal path:** garminconnect refreshes the ~19 h DI access token with the refresh token
  and rewrites `/data/garmintokens/garmin_tokens.json` on the PVC.
- **Refresh token rejected** (`400 invalid_grant` — seen after ~3 months, 2026-07 → 2026-10):
  the launcher's patch on `Client._refresh_di_token` does a full credential login and the
  new tokens are persisted. Happens at startup or mid-request; no restart needed. At most
  one credential login per 15 min, so a wrong password can't hammer Garmin SSO.
- **Token file missing:** startup does a credential login and writes it.

Why a wrapper is needed: upstream garminconnect (checked up to 0.3.17) swallows refresh
failures at DEBUG and never re-logs in, and garmin_mcp's own password fallback is dead
code here. `Garmin(email, password).login()` with no argument falls back to
`$GARMINTOKENS`, reloads the same dead file, and fails again.

Changing the password: update `GARMIN_PASSWORD` in Vault, force a VSO resync (`vault.md`),
then `kubectl -n garmin-mcp rollout restart deploy/garmin-mcp`. Confirm with
`kubectl -n garmin-mcp logs deploy/garmin-mcp | grep garmin-mcp-launcher` (expect
`Garmin auth OK`).

**If MFA is ever enabled**, credential login raises instead of prompting. Fall back to
the manual flow: mint tokens locally with
`uvx --python 3.12 --from git+https://github.com/Taxuspt/garmin_mcp garmin-mcp-auth`,
then `vault kv put kv/garmin-mcp/config ... GARMIN_TOKENS_JSON=@"$HOME/.garminconnect/garmin_tokens.json"`
(`kv put` replaces every field, so pass the others too, or use `kv patch`). Then delete
the on-PVC copy so the init container re-seeds it:

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
