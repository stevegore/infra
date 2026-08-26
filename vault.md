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
| vault-secrets-operator | vault-secrets-operator-controller-manager, default | vault-secrets-operator, caddy, vaultwarden, tailscale-operator, homepage, databases, authentik, adminer, strava-keeper, garmin-mcp, gym-booker, argocd, uptime-kuma | caddy, vaultwarden, tailscale-operator, homepage, pg-backups, authentik, adminer, strava-keeper, garmin-mcp, gym-booker, argocd, uptime-kuma |

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

**Path:** Pico hits Vault via `http://vault-oke:8200` (Tailscale MagicDNS — `vault-oke.chipmunk-fir.ts.net`, 100.69.225.0). Was `vault-oke-1` between the 2026-06-06 rebuild and 2026-08-02, while a dead device squatted the clean name; `vault-token-sync.sh` no longer trusts either name, resolving via tailscaled and health-checking before it commits. The `vault-tailscale` LoadBalancer Service in the `vault` namespace exposes port 8200 via the Tailscale operator. Traffic stays on the tailnet; does not traverse the public OKE NLB or Caddy.

> **Why `-1`.** The 2026-06-06 cluster rebuild left the original `vault-oke`
> device registered on the tailnet but dead (100.71.200.112, offline since), so
> the re-registered proxy had to take the next free name. MagicDNS kept
> resolving `vault-oke` — to the corpse — so `vault-token-sync.service` failed as
> a silent 30-second i/o timeout every 15 minutes rather than as a name error,
> and `kv/homelab/*` went stale unnoticed until 2026-08-01. Deleting the stale
> device would free the name back up, at which point this needs to move back;
> check with `tailscale status | grep vault-oke`.
>
> The old WireGuard-to-NodePort path (`http://10.20.30.2:30820`) died in the same
> rebuild and now times out from pico. `vault-token-sync-setup.sh` was still
> pointing at it, so a secret_id rotation would have failed before it started.
>
> That script also used to assert `secret_id_bound_cidrs`/`token_bound_cidrs` of
> `10.20.30.1/32`, which no longer matches anything — the Tailscale proxy
> terminates TCP inside the cluster, so Vault sees the proxy, never pico. The
> live role has had empty bindings since the tailnet cutover; since `vault write`
> replaces a role wholesale, re-running the old script would have silently
> re-bound the role to a dead CIDR and broken the sync. Both fixed 2026-08-01.

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
3. **Token** — root token in `~/Code/Personal/infra/vault-root.token`, mode `600`
   (break-glass; gitignored via `*.token`, never committed). Also in Vaultwarden —
   see [Where the break-glass credentials live](#where-the-break-glass-credentials-live).

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
| kv/authentik/config | Authentik: secret_key, username/password (pg-shared role), bootstrap_password/token, github_client_id/secret | authentik (authentik ns), pg-backups+authentik (databases ns) |
| kv/argocd | GitHub OAuth App client secret for Dex SSO | argocd (argocd ns) |
| kv/oci/pg-backups | OCI Customer Secret Key (S3) for pg-shared WAL/base backups | pg-backups (databases ns) |
| kv/oci/vault-kv-export | Write-only PAR for the nightly kv export upload. Written by `scripts/vault-kv-export-setup.sh`; rotate by re-running it. | vault-kv-export (vault-kv-export ns) |
| kv/homelab/* | Tokens synced from pico (`*.token` files) | pico-token-sync (write) |
| kv/homelab/pushover | Pushover "Homelab notification" app: `app_token`, `user_key`, `app_name`. Written by hand, **not** by `vault-token-sync.sh` (that script only walks `*.token` files and writes a single `token` field). Read by `scripts/arr-malware-watchdog.sh` and `scripts/pushover-notify.sh` (the generic systemd `OnFailure=` alerter) via the same AppRole. | pico-token-sync |
| kv/homelab/renovate | GitHub fine-grained PAT for the Renovate workflow: `token`, plus `purpose`/`scopes`/`consumer`/`created` metadata. Scoped to `stevegore/infra` only (contents, pull requests, workflows — all read+write). Written by hand. **Vault is the origin of record; GitHub Actions holds a copy as the repo secret `RENOVATE_TOKEN`.** Nothing reads this path automatically — on rotation, re-push it with:<br>`vault kv get -field=token kv/homelab/renovate \| gh secret set RENOVATE_TOKEN --repo stevegore/infra`<br>See [`AUTO_UPDATES.md`](AUTO_UPDATES.md). | pico-token-sync |
| kv/strava-keeper/config | Strava Keeper: STRAVA_CLIENT_ID, STRAVA_CLIENT_SECRET, STRAVA_VERIFY_TOKEN, MYSQL_DSN | strava-keeper |
| kv/gym-booker/config | Gym Booker: USERS_YAML (full users.yaml — gym credentials, swim schedule, pushover tokens) | gym-booker |

> **This table is not exhaustive.** A walk of the live mount on 2026-08-18 found
> 25 paths, including several never documented here (`cloudflare`, `github/orm-pat`,
> `oci/api-key`, `oci/ocir`, `mysql/heatwave-admin`, `tailscale/operator_oauth`,
> `homelab/cloudflare-ro`, `homelab/home-assistant`, `homelab/portainer`,
> `homepage/*`, `adminer/*`). The nightly export walks the tree rather than
> reading this list, so it captures them regardless — but don't treat the table
> as a manifest.

> **Decommissioned:** `kv/openclaw` and `kv/hermes` (plus their `openclaw` /
> `hermes` policies and the matching VSO namespace bindings) were removed
> 2026-07-25 — both services are gone (hermes since 2026-06-06). See
> "Removing a decommissioned app" below.

---

## Policies

### admin
Full access to all Vault operations.
```hcl
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
```

### Removing a decommissioned app

When an app is retired, its Vault footprint is three things — the kv path, the
policy, and the VSO role binding. Miss the third and the role keeps granting a
policy that no longer exists. Full removal (example: `hermes`):

```bash
export VAULT_ADDR=https://vault.stevegore.au
export VAULT_TOKEN=$(cat vault-root.token)

vault kv get -format=json kv/hermes > /tmp/vault-backup-hermes.json   # back up first
vault kv metadata delete kv/hermes
vault policy delete hermes

# Re-write the VSO role WITHOUT the dead namespace and policy. `vault write`
# replaces the whole role, so both lists must be restated in full.
vault read auth/kubernetes/role/vault-secrets-operator   # copy current lists
vault write auth/kubernetes/role/vault-secrets-operator \
  bound_service_account_names="vault-secrets-operator-controller-manager,default" \
  bound_service_account_namespaces="<list minus the dead ns>" \
  policies="<list minus the dead policy>" \
  ttl=1h
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

### Forcing an immediate resync (don't wait out `refreshAfter`)

`refreshAfter: 1h` means a value written to Vault can take up to an hour to
appear in the k8s Secret. Editing the `VaultStaticSecret` to hurry it along is a
trap — every VSS is ArgoCD-managed, so selfHeal reverts the edit. Restart the
controller instead; it reconciles every `VaultStaticSecret` on startup:

```bash
kubectl delete pod -n vault-secrets-operator \
  -l app.kubernetes.io/name=vault-secrets-operator
kubectl wait --for=condition=Ready pod -n vault-secrets-operator \
  -l app.kubernetes.io/name=vault-secrets-operator --timeout=180s
```

Safe: VSO is a leader-elected singleton that holds no state of its own, and it
re-derives every destination Secret from Vault. Resync lands within ~10 s.

**This ordering matters** when a workload is about to consume a brand-new field.
Write to Vault → force the resync → *confirm the field is in the Secret* → only
then let the deploy roll. Confirm with:

```bash
kubectl get secret <name> -n <ns> -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
```

Getting this backwards is how the Vaultwarden JWT key change (2026-07-26) would
have logged every device out on the very rollout that was meant to stop it.

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

2. Update VSO role (if needed). `vault write` **replaces** the role, so read the
   current lists first and restate them in full plus your additions — otherwise
   you silently revoke every other app:
```bash
vault read auth/kubernetes/role/vault-secrets-operator   # copy the current lists

vault write auth/kubernetes/role/vault-secrets-operator \
  bound_service_account_names="vault-secrets-operator-controller-manager,default" \
  bound_service_account_namespaces="<current list>,<app-namespace>" \
  policies="<current list>,<app-name>" \
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

**This sequence needs no Vault token, which is the point.** `auth/kubernetes/config`
is self-discovering — `kubernetes_host = https://kubernetes.default.svc`,
`disable_local_ca_jwt = false`, no pinned CA cert and no reviewer JWT — so Vault
re-derives cluster auth against whatever cluster it lands in. A from-scratch rebuild
therefore bootstraps itself: Vault starts → OCI KMS unseals it → k8s auth works
untouched → VSO syncs every secret → the apps that hold your credentials come back.
There is no chicken-and-egg problem, provided the KMS key and the bucket survive.

### The single point of failure is the KMS key

The recovery shares **cannot unseal this Vault** — with `seal "ocikms"` they only
re-root a Vault that is already unsealing itself. Everything in `vault-storage` is
encrypted under the master key, which is encrypted under OCI KMS key
`vault-auto-unseal`. Lose that key and the bucket is permanently undecryptable, with
or without recovery shares. It is `protection_mode = "HSM"`, so the raw material can
never leave OCI — there is no offline copy and no way to make one.

Guards in place: `prevent_destroy` on both `oci_kms_vault` and `oci_kms_key` in
[`terraform/kms.tf`](terraform/kms.tf) (added 2026-08-01), plus OCI's own
scheduled-deletion window. Note `kms.tf` is Resource-Discovery-generated — if that
file ever gets regenerated, **re-add the lifecycle blocks**.

**The key cannot be backed up at all — this was tried on 2026-08-18 and the
platform refuses it.** An earlier version of this section claimed
`oci kms management key backup` worked for HSM keys and only *vault-level* backup
needed a virtual private vault. That is wrong: **key backup also requires a Virtual
Private Vault.** `hashicorp-vault-unseal` is `vault_type = "DEFAULT"`, and the API
rejects the call outright:

```
$ oci kms management key backup --key-id <ocid> --endpoint <mgmt-endpoint> --uri <par>
ServiceError: InvalidParameter (400)
  vaultType Invalid vault type VIRTUAL. Valid values are [VirtualPrivate]
```

(A DEFAULT/shared vault reports as `VIRTUAL` internally.) Moving to a Virtual
Private Vault is a paid, non-trivial change — it means a new key and a full Vault
seal-migration to re-wrap the master key — so it is not on the table for a
free-tier homelab. **Treat the KMS key as genuinely unbackuppable.** The only
guards are `prevent_destroy` and OCI's scheduled-deletion window.

The corollary matters more than the key backup would have: **a `vault-storage`
bucket backup is worthless without the key**, since every object in it is encrypted
under the master key that only this KMS key can unwrap. Bucket backups protect
against bucket corruption and nothing else. The only backup that survives loss of
the KMS key is a **logical export of the secrets themselves** — which is what
`apps/vault-kv-export` does. See [The nightly kv export](#the-nightly-kv-export).

### The nightly kv export

`apps/vault-kv-export` runs a CronJob at 03:20 UTC that walks the whole `kv/`
tree, adds every policy body and the auth/secrets mount listings, encrypts the
bundle to an **offline age key**, and PUTs it into the `vault-kms-key-backup`
bucket. It is the only artefact in this homelab that survives loss of the KMS
key.

**Encryption is asymmetric, and that is the entire point.** The pod holds only
the age *public* recipient — which is why it sits in plain sight in
`values.yaml` in a public repo. The private key lives offline and exists nowhere
in the cluster, in Vault, in Vaultwarden or in OCI. Consequences:

- Compromising the cluster does not expose one byte of any past export.
- Decryption depends on nothing inside OCI — not Vault, not KMS, not the tenancy.
- **Lose the private key and every export ever written is permanently unreadable.**
  There is no second factor and no recovery path. This is the one artefact where
  "stored only in Vaultwarden" is not good enough, given its 24-hour window.

**Where the private key lives** (as of 2026-08-26): `~/.config/vault-kv-export/vault-export.key`
on the Mac, mode 600, plus a copy in **OneDrive Personal Vault**. Note Personal
Vault does not sync to the macOS filesystem — it is reachable only via
onedrive.live.com or the mobile app, so don't go looking for it under
`~/Library/CloudStorage/`. Both copies are currently Microsoft- or Mac-bound; a
third copy on offline media would remove that dependency.

Decrypt with:

```bash
age -d -i ~/.config/vault-kv-export/vault-export.key kv-export-YYYYMMDD-HHMMSS.json.age | jq .
```

**Upload uses a write-only PAR, not an S3 HMAC key.** OCI caps a user at 2
Customer Secret Keys and both are spent (`caddy-acme`, `pg-backups`) — taking one
would have broken Caddy's ACME store or CNPG's WAL archiving. A PAR is also
better scoped: `AnyObjectWrite` can create objects but cannot read, list or
delete, so a leaked upload credential still cannot read back a single secret.
The PAR expires annually; rotate by re-running the setup script. Expiry surfaces
as an upload failure that pages, not as silence.

Two guards exist specifically against *silent* success, the failure mode that
left the bw2 sync dead for two months:

- exporting 0 secrets is a hard failure, never an upload;
- the output is checked for the `age-encryption.org` header before upload, so a
  broken `age` can never ship plaintext.

Failures page via Pushover. The credentials come from a VSO-synced k8s Secret
rather than being read from Vault at runtime — a job that could only alert when
Vault was healthy would go quiet during exactly the outage worth hearing about.

**Setup (in order — the Vault side must exist before ArgoCD syncs the app):**

```bash
# 1. Generate the keypair OUTSIDE the repo — never into the working tree, even
#    though *.key is gitignored. Mirrors ~/.config/vault-token-sync/ and
#    ~/.config/caddy-acme/.
mkdir -p ~/.config/vault-kv-export && chmod 700 ~/.config/vault-kv-export
age-keygen -o ~/.config/vault-kv-export/vault-export.key
chmod 600 ~/.config/vault-kv-export/vault-export.key
age-keygen -y ~/.config/vault-kv-export/vault-export.key   # the age1... recipient

# 2. Vault policies, k8s auth role, VSO binding, and the upload PAR
source scripts/vault-env.sh && vlogin
bash scripts/vault-kv-export-setup.sh

# 3. Build + push the ARM image (cluster is A1/aarch64)
bash scripts/build-vault-kv-export-image.sh

# 3b. OCIR pull secret — namespace-scoped, in NO chart, so a new namespace
#     never has it. Missing it shows up only as ImagePullBackOff.
kubectl create secret docker-registry ocir-creds -n vault-kv-export \
  --docker-server=syd.ocir.io \
  --docker-username="$(vault kv get -field=username kv/oci/ocir)" \
  --docker-password="$(vault kv get -field=auth_token kv/oci/ocir)" \
  --docker-email=steve.j.gore@gmail.com

# 4. Set age.recipient in apps/vault-kv-export/values.yaml, commit, push.
#    The chart refuses to render with an empty recipient rather than writing
#    plaintext secrets to object storage.

# 5. Force a first run instead of waiting for 03:20
kubectl -n vault-kv-export create job --from=cronjob/vault-kv-export manual-1
kubectl -n vault-kv-export logs job/manual-1
```

> The export reads **every** secret in `kv/`, which is the broadest read grant in
> the cluster. It therefore gets its own ServiceAccount and its own Vault role
> (`vault-kv-export` → policy `vault-kv-export-read`) rather than borrowing the
> shared VSO role, so it is not reachable by anything that merely lands in the
> namespace.

### Where the break-glass credentials live

Root token and recovery share are both in the Vaultwarden entry for Vault. *(The item
name is deliberately not recorded here — this repo is public.)* Two consequences worth
understanding:

- **Same blast radius.** One item holds both factors, so a single loss takes out both.
  The mitigating fact is that `userpass/steve` and OIDC both carry the `admin` policy
  (`path "*"` with `sudo`), which does everything the root token does — so losing both
  is recoverable as long as one admin login works.
- **Vaultwarden's database is MySQL HeatWave, not pg-shared** — the CNPG daily backups
  do *not* cover it. The HeatWave system is a `MySQL.Free` shape, whose backup policy
  is `retention-in-days: 1` with PITR disabled and soft-delete disabled, and per
  [`terraform/mysql.tf`](terraform/mysql.tf) that is a platform constraint, not a
  setting we chose. Recovery window for anything stored only in Vaultwarden is
  therefore **24 hours**.

Keeping a copy of the recovery share outside that loop — offline, or in a second
password manager — is the cheap fix, and is worth more than any amount of rekeying.

### Root Token Recovery

If root token is lost:
```bash
# Generate new root token using recovery keys
vault operator generate-root -init
vault operator generate-root -otp=<otp>
# Enter recovery key shares when prompted
```

> **Vault 2.0 change — this is no longer a pure break-glass path.** `sys/generate-root`,
> `sys/rekey` and the DR operation-token endpoints now require **both** recovery key
> shares **and** a valid Vault token. With `Total Recovery Shares 1` that means the
> recovery key alone will not get you back in. Working alternates, in order: the OIDC
> login (`vault login -method=oidc role=default`, Authentik → `admin` policy), then
> `userpass/`. If every token path is dead, the escape hatch is the
> `enable_unauthenticated_access` config parameter, which restores 1.x behaviour —
> that requires editing `standalone.config` in `apps/vault/values.yaml` and rolling
> the pod, which is possible without a Vault token.

---

## Upgrades

**Vault version is pinned in two places** — `apps/vault/values.yaml`
(`vault.server.image.tag`, the one that matters) and `apps/vault/Chart.yaml`
(`appVersion`, cosmetic). Keep them in step. Renovate raises the tag bump; the
`critical` + `manual-review` labels mean it never automerges.

**The StatefulSet uses `updateStrategy: OnDelete`** (vault-helm default). Merging a
tag bump and letting ArgoCD sync updates the STS spec but **does not restart Vault** —
`currentRevision` and `updateRevision` simply diverge and the old pod keeps running.
This is easy to miss: the 1.21.2 → 1.21.4 bump sat unapplied for a day this way. The
upgrade only happens on an explicit pod delete, which is the one sanctioned use of
direct `kubectl` against this app.

```bash
export KUBECONFIG=~/.kube/oke-homelab.config

# 0. Back up the bucket first — Vault does NOT support downgrades.
oci os object bulk-download -bn vault-storage --namespace sdajdczqv0qo \
  --download-dir ~/backups/vault-storage-$(date +%Y%m%d-%H%M%S)

# 1. Merge the tag bump, wait for ArgoCD, then confirm the new tag is staged
kubectl -n argocd get app vault -o jsonpath='{.status.sync.status}{"\n"}'
kubectl -n vault get sts vault -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

# 2. Trigger it
kubectl -n vault delete pod vault-0

# 3. Verify — OCI KMS auto-unseals, no key entry needed
kubectl -n vault logs vault-0 | grep -iE "mlock|unseal|post-unseal"
kubectl -n vault exec vault-0 -- vault status

# 4. Confirm consumers: restart VSO and check every VSS is Healthy
kubectl delete pod -n vault-secrets-operator \
  -l app.kubernetes.io/name=vault-secrets-operator
kubectl get vaultstaticsecret -A -o json | jq -r \
  '.items[] | "\(.metadata.namespace)/\(.metadata.name) \(
     [.status.conditions[]? | select(.type=="Healthy") | .status] | first)"'
```

> Don't verify with `.status.currentRevision` vs `.status.updateRevision`. Under
> `OnDelete` the controller never advances `currentRevision`, so those two stay
> divergent *forever*, before and after a successful roll — they tell you nothing.
> Check the pod instead: `kubectl -n vault get pod vault-0 -o jsonpath='{.metadata.labels.controller-revision-hash} {.spec.containers[0].image}'`,
> or just read the version off `vault status`.

Downgrade is **not supported** by Vault. Rolling back means restoring the bucket
backup *and* reverting the tag, so take the backup before every major bump.

### Container capabilities / mlock

`standalone.config` deliberately omits `disable_mlock`, so vault-helm appends
`disable_mlock = true` — the sanctioned Kubernetes setting, since kubelet runs with
swap off. Vault logs `Mlock: supported: true, enabled: false` and never calls
`mlock()`, so the pod needs no `IPC_LOCK` capability and runs with the chart default
container context (`allowPrivilegeEscalation: false`, `CapEff 0x0`, uid 100 non-root).

A `server.containerSecurityContext:` block granting `IPC_LOCK` sat in `values.yaml`
from Jan–Aug 2026 doing nothing at all — vault-helm reads
`server.statefulSet.securityContext.container`, so the key was never consumed. It was
removed 2026-08-01. If you ever do need that key, restate
`allowPrivilegeEscalation: false` alongside it: setting it replaces the chart default
wholesale rather than merging.

Neither Vault 2.0 container regression ([#31919](https://github.com/hashicorp/vault/issues/31919))
bites here:

- `unable to set CAP_SETFCAP` — the 2.0.2+ entrypoint detects the non-root user and
  skips `setcap` on its own. On the 2.0.3 roll it logged
  `Container is running as non-root user, ignoring SKIP_SETCAP`, i.e. the chart's
  `SKIP_SETCAP=true` env var was belt-and-braces, not the thing that saved it.
- `Failed to lock memory` — covered by the `disable_mlock = true` above.

### 2.0.4: duplicate HCL attributes are now fatal

2.0.4 removed duplicate-attribute support in HCL **entirely**, along with the env-var
escape hatch that used to re-enable it. A config that declares the same attribute
twice no longer warns — Vault refuses to start. Check the *rendered* config before
any bump at or past 2.0.4, not just `values.yaml`, because vault-helm appends to it:

```bash
kubectl -n vault get cm vault-config -o jsonpath='{.data.extraconfig-from-values\.hcl}'
```

The live config is clean (verified 2026-08-08). The one to watch is `disable_mlock` —
the chart appends it precisely because `standalone.config` omits it, so adding it back
to `values.yaml` by hand would produce a duplicate and **brick the pod on next roll**.

2.0.4 also drops `gnupg`, `openssl` and `procps` from the UBI base images. Harmless
here: `docker.io/hashicorp/vault` is Alpine, so the `pidof` in the chart's preStop hook
still resolves (busybox provides it). `openssl` is genuinely gone from the image —
don't reach for it in a probe or hook.

### Version history

| Date | Version | Chart | Notes |
|------|---------|-------|-------|
| 2026-08-08 | 2.0.4 | 0.34.0 | Patch. Rolled in ~24 s, auto-unsealed clean (`unsealed with stored key`). Renovate bumped `values.yaml` only — `Chart.yaml` appVersion was left on 2.0.3 and had to be caught by hand; check both on every bump. See the 2.0.4 HCL note below. |
| 2026-08-01 | 2.0.3 | 0.34.0 | Major bump. Chart 0.34.0 already defaulted to 2.0.3 — the pin was holding the image *behind* the chart. Storage `oci` + `seal ocikms` unaffected. See the root-token warning above. |
| 2026-08-01 | 1.21.4 | 0.34.0 | Staged by Renovate but never rolled (OnDelete); superseded same day. |
| 2026-06-03 | 1.21.2 | 0.32.0 | |
| 2026-01-28 | 1.18.1 | 0.28.1 | Initial deployment. |

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| VSO can't authenticate | Check vault-secrets-operator role exists, verify service account name |
| Secret not syncing | Check VaultStaticSecret status: `kubectl describe vaultstaticsecret` |
| JWT auth failing | Verify Caddy Security JWT issuer/audience match Vault config |
| Auto-unseal failing | Check OCI instance principal permissions on KMS key |
| Tag bump merged but `vault status` shows the old version | Expected — STS is `OnDelete`. `kubectl -n vault delete pod vault-0` to apply. See [Upgrades](#upgrades) |
| `unable to set CAP_SETFCAP` / `Failed to lock memory` on 2.0+ | Chart already sets `SKIP_SETCAP=true` and appends `disable_mlock = true`; check they survived a values.yaml edit |
| 404 / `invalid path` on a request that used to work | Vault 2.0 rejects non-canonical paths (e.g. double slashes). Fix the caller's URL |

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
