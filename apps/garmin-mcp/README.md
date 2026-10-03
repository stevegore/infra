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

`images/garmin-mcp/garmin_mcp_launcher.py` wraps the server so auth stays up without
manual renewal:

- **Refresh:** garminconnect refreshes the ~19 h DI access token with the refresh token
  (which rotates on every use) and rewrites `/data/garmintokens/garmin_tokens.json`.
- **Keepalive:** a background thread refreshes the live client every 12 h. The original
  outage (refresh token last used 2026-07-14, rejected with `400 invalid_grant` by
  2026-10-03) was an idle refresh token. Upstream garminconnect, checked up to 0.3.17,
  swallows that error at DEBUG.
- **Credential fallback:** if a refresh is rejected, the launcher logs in with
  `GARMIN_USERNAME` / `GARMIN_PASSWORD` from `kv/garmin-mcp/config`, mounted as files.
  **Caveat:** on 2026-10-04 Garmin answered that login from the cluster with an MFA
  challenge, even though the account has no MFA (probably a risk check on a new
  device/IP). The fallback is a bonus; keepalive is what keeps auth up.
- **Rate limiting:** credential attempts are recorded in
  `/data/garmintokens/.credential_login_state.json`, which survives restarts. At most one
  attempt per 15 min, and none for 24 h after an MFA challenge, so a crash-looping pod
  can't spam logins or verification emails.
- garmin_mcp's own password fallback never fires here. `Garmin(email, password).login()`
  with no argument falls back to `$GARMINTOKENS` and reloads the same dead file.

**Re-minting tokens** (logs show `Garmin wants MFA`, or after a long outage):

```bash
uvx --python 3.12 --from git+https://github.com/Taxuspt/garmin_mcp garmin-mcp-auth   # email/password/code
vault kv patch kv/garmin-mcp/config GARMIN_TOKENS_JSON=@"$HOME/.garminconnect/garmin_tokens.json"
# force VSO resync (vault.md), confirm the Secret updated, then:
kubectl -n garmin-mcp rollout restart deploy/garmin-mcp
```

The `seed-tokens` init container re-seeds the PVC whenever the Vault seed differs from the
last one it seeded (tracked in `.seed.sha256`), and clears the login backoff. An unchanged
seed never clobbers tokens refreshed on the PVC. Check health with
`kubectl -n garmin-mcp logs deploy/garmin-mcp | grep garmin-mcp-launcher`.

## Bootstrap notes (first deploy)

- OCIR pull secret is manual, once, after the namespace first syncs (see `values.yaml`).
- Vault onboarding (already done 2026-06-13): `garmin-mcp` policy + namespace appended to
  the `vault-secrets-operator` k8s auth role (`vault.md`).
- Rotating the URL secret: write a new `garmin_mcp_path_secret` to `kv/caddy/config`,
  wait for VSO refresh (≤1h) or force it, then restart the Caddy deployment and update
  the connector URL in Claude.
