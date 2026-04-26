# HashiCorp Vault on ampere-ubuntu

## Overview

HashiCorp Vault deployment on MicroK8s with:
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
│                        ampere-ubuntu                             │
│  ┌─────────────────┐      ┌─────────────────────────────────┐  │
│  │  Caddy (TLS)    │      │         MicroK8s Cluster        │  │
│  │                 │      │  ┌─────────────────────────────┐│  │
│  │ vault.stevegore │──────│▶ │      vault namespace        ││  │
│  │ .au:443         │      │  │  ┌───────────────────────┐  ││  │
│  │                 │      │  │  │   Vault Server        │  ││  │
│  │ (GitHub OAuth)  │      │  │  │   NodePort: 30820     │  ││  │
│  └─────────────────┘      │  │  └───────────────────────┘  ││  │
│                           │  └─────────────────────────────┘│  │
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
| Role | Service Account | Namespace | Policies |
|------|-----------------|-----------|----------|
| vault-secrets-operator | vault-secrets-operator-controller-manager | vault-secrets-operator | openclaw |

### 2. AppRole (for pico → kv/homelab/* token sync)

Used by pico to push `*.token` files in `~/code/infra/` into Vault. Bound to pico's WireGuard IP so leaked credentials are useless from anywhere else.

| Role | CIDR (secret_id + token) | Policies | Token TTL |
|------|---------------------------|----------|-----------|
| pico-token-sync | 10.20.30.1/32 | pico-token-sync | 10m / 30m max |

**Path:** Pico hits Vault directly over WireGuard at `http://10.20.30.2:30820` (NodePort, plaintext over the encrypted WG tunnel). The Service runs `externalTrafficPolicy: Local` so kube-proxy doesn't SNAT — Vault sees the real source IP. The listener also trusts `X-Forwarded-For` from Caddy (`127.0.0.0/8`, `10.0.0.0/8`) so the public path through `vault.stevegore.au` produces accurate source IPs too.

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

### 3. JWT Auth (for human users via Caddy Security)

Used by administrators via GitHub OAuth through Caddy Security.

**How it works:**
1. Access https://vault.stevegore.au
2. Caddy redirects you to GitHub OAuth
3. After login, you can access the Vault UI
4. In the Vault UI, select "JWT" method and use your cookie token

**JWT Key:** RSA keypair stored at `/etc/caddy/keys/jwt-*.pem`

**Roles:**
| Role | Bound Claims | Policies |
|------|--------------|----------|
| caddy-user | (any authenticated) | default |
| caddy-admin | sub=github.com/stevegore | admin |

**To get your JWT token** (for CLI use):
1. Login at https://auth.stevegore.au
2. Open browser dev tools → Application → Cookies
3. Copy the `access_token` cookie value

---

## Secrets Engines

### KV v2 (kv/)

Key-value secrets engine for application credentials.

**Paths:**
| Path | Description | Access Policies |
|------|-------------|-----------------|
| kv/openclaw | OpenClaw AI assistant credentials | openclaw |
| kv/homelab/* | Tokens synced from pico (`*.token` files) | pico-token-sync (write) |

**Secrets Structure:**
```
kv/
└── openclaw/
    ├── ANTHROPIC_API_KEY
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

---

## Vault Secrets Operator (VSO)

### Overview

VSO syncs Vault secrets to native Kubernetes Secrets, eliminating the need for sidecar injection.

**Namespace:** vault-secrets-operator
**Helm Chart:** hashicorp/vault-secrets-operator v0.9.0

### Configuration

```yaml
# apps/vault-secrets-operator/values.yaml
vault-secrets-operator:
  defaultVaultConnection:
    enabled: true
    address: "http://vault.vault.svc.cluster.local:8200"
    skipTLSVerify: true
```

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

### Verifying VSO Status

```bash
# Check VSO pods
microk8s kubectl get pods -n vault-secrets-operator

# Check VaultStaticSecret status
microk8s kubectl get vaultstaticsecret -A

# Check synced K8s secret
microk8s kubectl get secret <secret-name> -n <namespace> -o yaml
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
  policies="openclaw,<app-name>" \
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
