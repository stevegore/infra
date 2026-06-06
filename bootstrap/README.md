# Bootstrap — OKE / Terraform

How to provision this homelab from scratch, or rebuild after a cluster change.

## Architecture overview

```
OCI Resource Manager  →  Terraform  →  OKE cluster + VCN + NLB IP + KMS + Object Storage
                                                    ↓
                                             argocd-init.sh
                                                    ↓
                                           ArgoCD (self-managed)
                                                    ↓
                                            apps/  (Vault, Caddy, VSO, Vaultwarden, …)
```

All day-to-day infra changes go through:
```
edit locally → push to GitHub → ORM job applies (Terraform) or ArgoCD syncs (Kubernetes)
```

See [ARGOCD_WORKFLOW.md](../ARGOCD_WORKFLOW.md) and [terraform/README.md](../terraform/README.md).

---

## Cluster rebuild vs fresh install

| Scenario | Vault data | Terraform state | CNPG data |
|----------|-----------|-----------------|-----------|
| **Fresh install** | Empty — must init + provision all secrets | New | Empty |
| **Cluster rebuild** (e.g. BASIC→ENHANCED downgrade) | Pre-existing (persists in OCI Object Storage) | Existing (restore backup) | Recover from barman backup in OCI Object Storage |

A rebuild skips all secret-provisioning steps and goes straight to cluster recreation → ArgoCD bootstrap → CNPG recovery.

---

## Rebuild runbook (cluster replace, data preserved)

Use this when you need to destroy and recreate the OKE cluster (e.g. switching cluster type, which OCI doesn't support in-place).

### 0. Pre-flight

```bash
export KUBECONFIG=~/.kube/oke-homelab.config
source scripts/vault-env.sh && vlogin    # needs VAULT_TOKEN for later steps
```

Uptime-kuma data is stored in MySQL HeatWave (external to the cluster) — **no snapshot needed**. Monitor data survives cluster rebuilds automatically.

### 1. Terraform — change cluster type and apply

Edit `terraform/oke-cluster.tf`, change `type = "ENHANCED_CLUSTER"` to `type = "BASIC_CLUSTER"` (or vice versa). OCI does **not** support in-place downgrade — you must destroy and recreate.

```bash
cd terraform
source scripts/tf-env.sh          # sets TF_VAR_* and pulls state from ORM
terraform init -reconfigure
terraform plan                     # verify only the cluster resource is changing
terraform apply                    # destroys old cluster, creates new one
```

The node pool takes ~10 min to provision.

### 2. Clean up orphaned NLB

When the old cluster is destroyed, the NLB that Kubernetes CCM created for the Caddy service is **not** automatically deleted (it's not Terraform-managed). It holds the reserved IP `159.13.44.68`, blocking the new cluster's CCM from creating a new NLB.

```bash
# Check whether the reserved IP is still assigned
oci network public-ip get --public-ip-address 159.13.44.68 --region ap-sydney-1 \
  | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d['lifecycle-state'], d.get('assigned-entity-id','none'))"
# → if "ASSIGNED" and entity-id is set, find and delete the old NLB:

oci nlb network-load-balancer list \
  --compartment-id $(grep compartment_ocid terraform/vars-imported.tf | grep -o '"[^"]*"' | tr -d '"') \
  --region ap-sydney-1 --all \
  | python3 -c "
import sys,json
for n in json.load(sys.stdin)['data']['items']:
    if any(ip.get('ip-address')=='159.13.44.68' for ip in n.get('ip-addresses',[])):
        print('DELETE:', n['id'], n['display-name'])
"
# Then delete it:
oci nlb network-load-balancer delete --network-load-balancer-id <ID-from-above> \
  --region ap-sydney-1 --force
```

Wait ~30s for the IP to show `lifecycle-state: AVAILABLE`, then continue.

### 3. Bootstrap ArgoCD

```bash
bash bootstrap/argocd-init.sh
```

This script is idempotent. It:
1. Regenerates kubeconfig for the new cluster OCID
2. Installs ArgoCD
3. Applies the `infra-apps` ApplicationSet (deploying all `apps/`)
4. Creates the `ocir-creds` docker-registry secret in `caddy` namespace (reads from Vault)

> **Note:** The ApplicationSet (`argocd/applicationset.yaml`) is **not** managed by ArgoCD itself. Any changes to it must be applied manually:
> ```bash
> kubectl apply --server-side --force-conflicts -f argocd/applicationset.yaml
> ```

Wait ~5 min for ArgoCD to sync all apps. Vault auto-unseals via OCI KMS (no manual unseal needed on rebuild).

### 4. Recover CNPG database (pg-shared)

The CNPG cluster starts with `recovery.enabled: true` in git (this is the permanent state). It will try to restore from barman backup in `s3://pg-backups/pg-shared`. However, there's a CNPG safety check that blocks recovery when `spec.backup` is also set (it rejects recovery into a non-empty WAL archive destination).

**Temporarily disable backup to allow recovery:**

```bash
# Edit apps/databases/values.yaml:
#   backup:
#     enabled: false   ← add this line
git add apps/databases/values.yaml
git commit -m "databases: disable backup during recovery (WAL archive check bypass)"
git push
```

ArgoCD syncs. CNPG creates a fresh PVC and recovery job. If recovery pods fail before VSO has synced the `pg-backups-s3` secret (race condition), delete the cluster + PVC and re-trigger:

```bash
kubectl delete cluster pg-shared -n databases & kubectl delete pvc pg-shared-1 -n databases &
wait
kubectl patch application databases -n argocd --type=merge \
  -p '{"operation":{"sync":{"syncStrategy":{"hook":{}}}}}'
```

Monitor until healthy:
```bash
kubectl get cluster pg-shared -n databases -w
# Wait for: "Cluster in healthy state"
```

**Re-enable backup:**
```bash
# Edit apps/databases/values.yaml: backup.enabled: true
git add apps/databases/values.yaml
git commit -m "databases: re-enable backup after recovery"
git push
```

CNPG restarts the pod to add the AWS checksum env vars (~2 min).

> **Important:** After recovery, `recovery.enabled: true` is the **permanent** state in git.
> The live cluster has `bootstrap.recovery` (immutable). Changing `recovery.enabled: false`
> would generate `bootstrap.initdb`, which CNPG's webhook rejects with
> "only one bootstrap method at a time."

### 5. Verify

```bash
# All apps Synced + Healthy
kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

# External access
for d in argocd.stevegore.au vault.stevegore.au auth.stevegore.au homepage.stevegore.au; do
  echo "$d: $(curl -skL --max-time 5 https://$d -o /dev/null -w '%{http_code}')"
done
```

---

## Fresh install runbook (no prior Vault data)

### Step 1 — OCI prerequisites (one-time)

OCI CLI credentials live in Vault at `kv/oci/api-key`. On a fresh machine:

```bash
# Install oci CLI, then:
source scripts/vault-env.sh && vlogin
bash scripts/restore-oci-creds.sh   # writes ~/.oci/config + ~/oci.pem
```

### Step 2 — Provision infrastructure via Terraform / ORM

The ORM stack (`homelab-tf`) pulls from `github.com/stevegore/infra`, directory `terraform/`, branch `main`.

```bash
# Create or update the ORM stack (idempotent):
source scripts/vault-env.sh && vlogin
bash scripts/provision-orm-stack.sh
```

Then approve and apply the job in the OCI Console or via CLI. This provisions:

- VCN `nebula` (subnets, security lists, NSGs, gateways)
- OKE cluster `homelab` (2 nodes, 2 fault domains, Always Free A1)
- Reserved public IP `159.13.44.68` (`oci_core_public_ip.caddy_nlb`)
- KMS vault + `vault-auto-unseal` key
- Object Storage buckets (`vault-storage`, `infra-tfstate`, `caddy-acme`)
- IAM dynamic group + policy for Vault's OCI KMS auto-unseal

ORM stack OCID: `ocid1.ormstack.oc1.ap-sydney-1.amaaaaaaxbp2yoqaytua3d676bavg2kdjw6oud5srw7egs3iea7q7ppiydoq`

### Step 3 — Bootstrap ArgoCD onto OKE

```bash
bash bootstrap/argocd-init.sh
```

> On first run `VAULT_TOKEN` won't be set (Vault isn't up yet).
> The script prints instructions; re-run after Vault is deployed and unsealed.

### Step 4 — Post-init (first install only)

```bash
# Init Vault (OCI KMS handles unseal, but init must run once):
export KUBECONFIG=~/.kube/oke-homelab.config
kubectl exec -n vault vault-0 -- vault operator init \
  -recovery-shares=1 -recovery-threshold=1
# Save the recovery key in 1Password.

# Login and provision credentials:
source scripts/vault-env.sh && vlogin
bash scripts/provision-caddy-acme-creds.sh   # Cloudflare token for DNS-01 ACME
bash scripts/publish-mysql-creds.sh           # Vaultwarden MySQL creds
# Tailscale auth key:
vault kv put kv/tailscale/authkey value=<key>
# OCIR auth token (for caddy image pull):
bash scripts/provision-ocir-creds.sh         # mints token, stores in Vault
# ArgoCD GitHub OAuth client secret (github.com/settings/developers,
# client ID Ov23lilY1eXJlOXH0Dej — generate a new secret if needed):
vault kv put kv/argocd github_client_secret=<github-oauth-client-secret>
# Re-run argocd-init.sh — picks up VAULT_TOKEN and handles all missing
# secrets (ocir-creds, argocd dex.github.clientSecret) idempotently:
bash bootstrap/argocd-init.sh

# ArgoCD GitHub OAuth client secret (breaks circular bootstrap dependency).
# VSO syncs kv/argocd → argocd-github-oauth k8s Secret, but VSO must be
# running first. Patch argocd-secret directly so Dex can authenticate while
# VSO comes up. The GitHub OAuth App is at github.com/settings/developers
# (client ID Ov23lilY1eXJlOXH0Dej).
vault kv put kv/argocd github_client_secret=<github-oauth-client-secret>
kubectl patch secret argocd-secret -n argocd \
  --type=json \
  -p='[{"op":"add","path":"/data/dex.github.clientSecret","value":"'$(vault kv get -field=github_client_secret kv/argocd | base64)'"}]'
```

> **Note (rebuild vs fresh install):** On a cluster rebuild, Vault data persists in OCI
> Object Storage — `kv/argocd` is already populated and VSO will sync the secret automatically.
> The `kubectl patch` above is only needed on a fresh install before VSO is running.

---

## Ongoing workflow

| Task | How |
|------|-----|
| Change Kubernetes workloads | Edit `apps/` Helm charts, push to `main` → ArgoCD auto-syncs |
| Change OCI infra | Edit `terraform/`, push to `main` → ORM job applies |
| Local Terraform plan | `source scripts/tf-env.sh && terraform init -reconfigure && terraform plan` |
| Get kubeconfig | `oci ce cluster create-kubeconfig --cluster-id <id> --file ~/.kube/oke-homelab.config --region ap-sydney-1 --token-version 2.0.0` |
| Access ArgoCD | `https://argocd.stevegore.au` (GitHub SSO) |
| Update ApplicationSet | `kubectl apply --server-side --force-conflicts -f argocd/applicationset.yaml` |

---

## Secrets model

All secrets live in Vault (`vault.stevegore.au`). The Vault Secrets Operator (VSO) syncs them into Kubernetes `Secret` objects consumed by each app. No secrets are committed to this repo.

**Exception:** `ocir-creds` docker-registry secret in `caddy` namespace is created by `argocd-init.sh` from Vault `kv/oci/ocir`. VSO doesn't support `kubernetes.io/dockerconfigjson` type secrets directly.
