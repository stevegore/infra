# HashiCorp Vault on OKE

## Overview

HashiCorp Vault deployment on Oracle Kubernetes Engine with:
- OCI KMS auto-unseal (HSM-protected AES-256)
- OCI Object Storage backend (versioned)
- Vault Secrets Operator (VSO) for Kubernetes secret sync
- GitHub OAuth authentication via Caddy Security

**URLs:**
- Web UI: https://vault.stevegore.au
- API: https://vault.stevegore.au/v1/

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      OKE Cluster (homelab)                       │
│                        (Kubernetes 1.36)                         │
│  ┌─────────────────┐      ┌─────────────────────────────────┐  │
│  │  Caddy (TLS)    │      │      vault namespace            │  │
│  │                 │      │  ┌───────────────────────────┐  │  │
│  │ vault.stevegore │──────│▶ │   Vault StatefulSet (1 pod) │  │
│  │ .au:443         │      │  │   Storage: OCI Object Store │  │
│  │                 │      │  │   Unseal: OCI KMS          │  │
│  │ (Caddy proxy)   │      │  └───────────────────────────┘  │  │
│  └─────────────────┘      │                                  │  │
│                           │  ┌─────────────────────────────┐│  │
│                           │  │ vault-secrets-operator ns   ││  │
│                           │  │  ┌───────────────────────┐  ││  │
│                           │  │  │   VSO Controller      │  ││  │
│                           │  │  │   (syncs secrets)     │  ││  │
│                           │  │  └───────────────────────┘  ││  │
│                           │  └─────────────────────────────┘│  │
│                           └─────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                │                              │
                ▼                              ▼
┌───────────────────────────┐    ┌───────────────────────────────┐
│   OCI KMS (Auto-Unseal)   │    │   OCI Object Storage          │
│   Key: vault-unseal-key   │    │   Bucket: vault-storage       │
│   HSM-protected AES-256   │    │   Versioning: enabled         │
└───────────────────────────┘    └───────────────────────────────┘
```

---

## Authentication Methods

### 1. Kubernetes Auth (for VSO and pods)

Used by Vault Secrets Operator and application pods to authenticate.

**Service Account:** `vault-auth` (namespace: vault)
**ClusterRoleBinding:** `vault-auth-tokenreview` → `system:auth-delegator`

**Roles:**
| Role | Bound Service Accounts | Bound Namespaces | Policies |
|------|------------------------|------------------|----------|
| vault-secrets-operator | vault-secrets-operator-controller-manager, default | vault-secrets-operator, caddy, openclaw, hermes, vaultwarden, tailscale-operator, homepage, databases, authentik, adminer, strava-keeper, garmin-mcp, gym-booker | caddy, openclaw, hermes, vaultwarden, tailscale-operator, homepage, pg-backups, authentik, adminer, strava-keeper, garmin-mcp, gym-booker |

To onboard a new app namespace, append it to both `bound_service_account_namespaces` and (after writing the policy) `policies`:
```bash
vault policy write <app> - <<EOF
path "kv/data/<app>/*" { capabilities = ["read"] }
EOF
vault write auth/kubernetes/role/vault-secrets-operator \
  bound_service_account_names=vault-secrets-operator-controller-manager,default \
  bound_service_account_namespaces=<existing list>,<app> \
  policies=<existing list>,<app> ttl=1h
```

### 2. AppRole (for pico → kv/homelab/* token sync)

Used by pico to push `*.token` files in `~/code/infra/` into Vault. No CIDR binding — the Tailscale proxy terminates TCP before Vault, so source-IP restrictions are not enforceable here. Security relies on the role_id + secret_id credentials and the narrow `pico-token-sync` policy scope.

| Role | CIDR | Policies | Token TTL |
|------|------|----------|-----------|
| pico-token-sync | none | pico-token-sync | 10m / 30m max |

**Path:** Pico hits Vault via `http://vault-oke:8200` (Tailscale MagicDNS — `vault-oke.chipmunk-fir.ts.net`). The `vault-tailscale` LoadBalancer Service in the `vault` namespace exposes port 8200 via the Tailscale operator. Traffic stays on the tailnet; does not traverse the public OKE NLB or Caddy.

**Bootstrap (run once with the root token on pico):**
```bash
~/code/infra/scripts/vault-token-sync-setup.sh
```
Drops `role_id` + `secret_id` into `~/.config/vault-token-sync/`. Re-run to rotate the secret_id.

**Sync (one-shot):**
```bash
~/code/infra/scripts/vault-token-sync.sh
```
Walks `~/code/infra/*.token` and writes each to `kv/homelab/<basename>` with a `token` field. Skips `vault-root.token`.

**Recurring:** systemd timer `vault-token-sync.timer` runs every 15 minutes. Install via:
```bash
sudo ~/code/infra/scripts/install-vault-token-sync-timer.sh
```
Tail with `journalctl -u vault-token-sync.service -f`.

### 3. Human UI login

`vault.stevegore.au` is **not** gated by the edge proxy — Vault handles its own
login. Three ways in:

1. **OIDC via Authentik (SSO, preferred)** — UI → method **OIDC** (role `default`)
   → redirects to Authentik → GitHub SSO → back to Vault with the `admin` policy.
   Restricted to Steve by the `allow-stevegore-github` policy on the Vault app.
2. **Userpass** — method **Username**, user `steve` (policy `admin`).
3. **Token** — root token in `~/Code/Personal/infra/vault-root.token` (break-glass).

> Replaced the old caddy-security `caddy-user`/`caddy-admin` JWT method (gone
> with caddy-security on 2026-06-02) — that path no longer exists.

**OIDC setup (2026-06-02).** Two halves; the Authentik half lives in its DB
(covered by pg-shared backups), the Vault half is configured imperatively:

*Authentik:* OAuth2/OIDC Provider **Vault** + application slug `vault`
(`https://auth.stevegore.au/application/o/vault/`), confidential client, signing
key = the self-signed cert, scopes openid/email/profile, redirect URIs =
`https://vault.stevegore.au/ui/vault/auth/oidc/oidc/callback` and
`http://localhost:8250/oidc/callback` (CLI). Client id/secret stored in Vault at
`kv/authentik/config → vault_oidc_client_id / vault_oidc_client_secret`. The
`allow-stevegore-github` policy is bound to the `vault` application.

*Vault:* (re-runnable; client id/secret read from `kv/authentik/config`)
```bash
vault auth enable oidc   # idempotent; ignore "already in use"
vault write auth/oidc/config \
  oidc_discovery_url="https://auth.stevegore.au/application/o/vault/" \
  oidc_client_id="$(vault kv get -field=vault_oidc_client_id kv/authentik/config)" \
  oidc_client_secret="$(vault kv get -field=vault_oidc_client_secret kv/authentik/config)" \
  default_role="default"
vault write auth/oidc/role/default role_type=oidc user_claim=preferred_username \
  oidc_scopes="openid,email,profile" token_policies=admin ttl=1h \
  allowed_redirect_uris="https://vault.stevegore.au/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback"
```
CLI login: `vault login -method=oidc role=default`.

> TODO (optional): persist the Authentik Vault provider/app/binding in the
> `apps/authentik` blueprint (via `!Env` client id/secret from the VSO secret)
> for from-scratch reproducibility, the same way the forward-auth provider is.

---

## Secrets Engines

### KV v2 (kv/)

Key-value secrets engine for application credentials.

**Paths:**
| Path | Description | Access Policies |
|------|-------------|-----------------|
| kv/openclaw | OpenClaw AI assistant credentials | openclaw |
| kv/hermes | Hermes Agent credentials | hermes |
| kv/authentik/config | Authentik: secret_key, username/password (pg-shared role), bootstrap_password/token, github_client_id/secret | authentik (authentik ns), pg-backups+authentik (databases ns) |
| kv/argocd | GitHub OAuth App client secret for Dex SSO | argocd (argocd ns) |
| kv/oci/pg-backups | OCI Customer Secret Key (S3) for pg-shared WAL/base backups | pg-backups (databases ns) |
| kv/homelab/* | Tokens synced from pico (`*.token` files) | pico-token-sync (write) |
| kv/strava-keeper/config | Strava Keeper: STRAVA_CLIENT_ID, STRAVA_CLIENT_SECRET, STRAVA_VERIFY_TOKEN, MYSQL_DSN | strava-keeper |
| kv/gym-booker/config | Gym Booker: USERS_YAML (full users.yaml — gym credentials, swim schedule, pushover tokens) | gym-booker |

**Secrets Structure:**
```
kv/
├── openclaw/
│   ├── ANTHROPIC_API_KEY
│   ├── OPENCLAW_GATEWAY_TOKEN
│   └── TELEGRAM_BOT_TOKEN
└── hermes/
    ├── ANTHROPIC_API_KEY (or OPENROUTER_API_KEY)
    └── TELEGRAM_BOT_TOKEN
```

---

## Policies

### admin
Full access to all Vault operations.
```hcl
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
```

### openclaw
Read-only access to OpenClaw secrets.
```hcl
path "kv/data/openclaw" {
  capabilities = ["read"]
}
path "kv/metadata/openclaw" {
  capabilities = ["read"]
}
```

### hermes
Read-only access to Hermes Agent secrets.
```hcl
path "kv/data/hermes" {
  capabilities = ["read"]
}
path "kv/metadata/hermes" {
  capabilities = ["read"]
}
```

---

## Vault Secrets Operator (VSO)

### Overview

VSO syncs Vault secrets to native Kubernetes Secrets, eliminating the need for sidecar injection.

**Namespace:** vault-secrets-operator
**Helm Chart:** hashicorp/vault-secrets-operator (current version, deployed on OKE)

### Configuration

```yaml
# apps/vault-secrets-operator/values.yaml
vault-secrets-operator:
  defaultVaultConnection:
    enabled: true
    address: "http://vault.vault.svc.cluster.local:8200"
    skipTLSVerify: true
```

Vault is deployed as a StatefulSet in the `vault` namespace and auto-unseals via OCI KMS. VSO in the `vault-secrets-operator` namespace authenticates via Kubernetes service account and syncs `VaultStaticSecret` CRDs into native k8s Secrets across all namespaces.

### CRDs

**VaultAuth** - Defines how to authenticate with Vault
```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: <app-name>
  namespace: <app-namespace>
spec:
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: vault-secrets-operator
    serviceAccount: default
```

**VaultStaticSecret** - Syncs a static secret from Vault
```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: <app-name>-credentials
  namespace: <app-namespace>
spec:
  type: kv-v2
  mount: kv
  path: <secret-path>
  destination:
    name: <k8s-secret-name>
    create: true
  refreshAfter: 1h
  vaultAuthRef: <vault-auth-name>
```

### Auto-restarting pods on secret rotation (`rolloutRestartTargets`)

By default, when VSO writes a new version of the k8s Secret, **running pods keep
the old value** — env vars injected via `secretKeyRef`/`envFrom` are only read at
pod start. Add `rolloutRestartTargets` to a `VaultStaticSecret` and VSO patches
the target workload's pod-template annotation on every secret change, triggering
a normal rolling restart:

```yaml
spec:
  ...
  vaultAuthRef: <vault-auth-name>
  rolloutRestartTargets:
    - kind: Deployment        # or StatefulSet / DaemonSet
      name: <workload-name>
```

VSO's controller ClusterRole already grants cluster-wide `patch` on
deployments/statefulsets/daemonsets, so no extra RBAC is needed.

**Enabled on** (all env-consuming apps): `strava-keeper`, `caddy`,
`vaultwarden`, `adminer`, `homepage` (targets are their own Deployments via
`{{ include "<app>.fullname" . }}`), plus the upstream charts `authentik`
(→ `authentik-server` + `authentik-worker`), `argocd` (→ `argocd-dex-server`),
and `tailscale-operator` (→ `operator`). Upstream target names are hardcoded —
revisit if a chart's `fullnameOverride`/naming changes.

**Deliberately NOT enabled:** `garmin-mcp` — its init container seeds the token
file only when absent because `garminconnect` refreshes tokens in place on the
PVC; a restart-on-change would be pointless churn. Apps consuming secrets purely
as hot-reloaded file mounts don't need it either.

> These Deployments use `strategy: Recreate` (single replica), so a triggered
> restart is a brief down-then-up, not zero-downtime. Note that a rotated Caddy
> secret restarts the edge proxy, briefly dropping all `*.stevegore.au` traffic.

### Verifying VSO Status

```bash
# Set kubeconfig for OKE
export KUBECONFIG=~/.kube/oke-homelab.config

# Check VSO pods
kubectl get pods -n vault-secrets-operator

# Check Vault pod is unsealed and healthy
kubectl get pods -n vault
kubectl logs -n vault vault-0 | tail -20

# Check VaultStaticSecret status
kubectl get vaultstaticsecret -A

# Check synced K8s secret
kubectl get secret <secret-name> -n <namespace> -o yaml
```

---

## Common Operations

### Login (CLI)

```bash
export VAULT_ADDR=https://vault.stevegore.au

# Using JWT from Caddy Security
vault login -method=jwt role=caddy-admin jwt="<your-jwt>"

# Using root token (emergency only)
vault login <root-token>
```

### Store a Secret

```bash
vault kv put kv/<app-name> \
  KEY1="value1" \
  KEY2="value2"
```

### Read a Secret

```bash
vault kv get kv/<app-name>
```

### Add a New Application

1. Create policy:
```bash
vault policy write <app-name> - <<EOF
path "kv/data/<app-name>" {
  capabilities = ["read"]
}
path "kv/metadata/<app-name>" {
  capabilities = ["read"]
}
EOF
```

2. Update VSO role (if needed):
```bash
vault write auth/kubernetes/role/vault-secrets-operator \
  bound_service_account_names=vault-secrets-operator-controller-manager \
  bound_service_account_namespaces=vault-secrets-operator \
  policies="openclaw,hermes,<app-name>" \
  ttl=1h
```

3. Store secrets:
```bash
vault kv put kv/<app-name> API_KEY="xxx"
```

4. Add VaultAuth + VaultStaticSecret to app's Helm templates

---

## Backup & Recovery

### Secrets Backup

Vault data is stored in OCI Object Storage bucket `vault-storage` with versioning enabled.

### Disaster Recovery

1. OCI KMS key is required for auto-unseal
2. Reinstall Vault from ArgoCD
3. Vault auto-unseals using OCI KMS
4. Data restored from Object Storage

### Root Token Recovery

If root token is lost:
```bash
# Generate new root token using recovery keys
vault operator generate-root -init
vault operator generate-root -otp=<otp>
# Enter recovery key shares when prompted
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| VSO can't authenticate | Check vault-secrets-operator role exists, verify service account name |
| Secret not syncing | Check VaultStaticSecret status: `kubectl describe vaultstaticsecret` |
| JWT auth failing | Verify Caddy Security JWT issuer/audience match Vault config |
| Auto-unseal failing | Check OCI instance principal permissions on KMS key |

---

## Infrastructure References

- **OCI Compartment:** root
- **OCI Region:** ap-sydney-1
- **KMS Key OCID:** `ocid1.key.oc1.ap-sydney-1.fnuxtwyhaahla.abzxsljrgzjola7olf2nj27fljzgkqx5vdwq5f44g7n6wse3awmsoee2imfa`
- **Storage Bucket:** `vault-storage`
- **Dynamic Group:** `vault-instances`
- **IAM Policy:** `vault-kms-objectstorage-policy`

---

## Related Documentation

- [hosts.md](hosts.md) - Server and network configuration
- [oracle-cloud.md](oracle-cloud.md) - OCI infrastructure details
- [portainer.md](portainer.md) - Docker services on pico
