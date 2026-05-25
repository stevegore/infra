# Bootstrap — OKE / Terraform

How to provision this homelab from scratch.

## Architecture overview

```
OCI Resource Manager  →  Terraform  →  OKE cluster + VCN + NLB + KMS + Object Storage
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

## Step 1 — OCI prerequisites (one-time)

OCI CLI credentials live in Vault at `kv/oci/api-key`. On a fresh machine:

```bash
# Install oci CLI, then:
source scripts/vault-env.sh && vlogin
bash scripts/restore-oci-creds.sh   # writes ~/.oci/config + ~/oci.pem
```

---

## Step 2 — Provision infrastructure via Terraform / ORM

The ORM stack (`homelab-tf`) pulls from `github.com/stevegore/infra`, directory `terraform/`, branch `main`.

```bash
# Create or update the ORM stack (idempotent):
source scripts/vault-env.sh && vlogin
bash scripts/provision-orm-stack.sh
```

Then approve and apply the job in the OCI Console or via CLI. This provisions:

- VCN `nebula` (subnets, security lists, NSGs, gateways)
- OKE cluster `homelab` (2 nodes, 2 fault domains, Always Free A1)
- NLB with reserved IP `159.13.44.68`
- KMS vault + `vault-auto-unseal` key
- Object Storage buckets (`vault-storage`, `infra-tfstate`, `caddy-acme`)
- IAM dynamic group + policy for Vault's OCI KMS auto-unseal

ORM stack OCID: `ocid1.ormstack.oc1.ap-sydney-1.amaaaaaaxbp2yoqaytua3d676bavg2kdjw6oud5srw7egs3iea7q7ppiydoq`

---

## Step 3 — Bootstrap ArgoCD onto OKE

Run once after ORM has finished:

```bash
bash bootstrap/argocd-init.sh
```

This:
1. Writes `~/.kube/oke-homelab.config`
2. Installs ArgoCD from upstream manifests
3. Applies the `infra-apps` ApplicationSet (covers all `apps/` charts)
4. Provisions the OCIR pull secret (requires Vault login)

After this step ArgoCD manages itself and deploys everything else.

---

## Step 4 — Post-init (first install only)

If Vault has no prior data (truly fresh install):

```bash
# Unseal Vault — OCI KMS handles the unseal key, but init must run once:
export KUBECONFIG=~/.kube/oke-homelab.config
kubectl exec -n vault vault-0 -- vault operator init \
  -recovery-shares=1 -recovery-threshold=1
# Save the recovery key in 1Password.

# Provision app credentials into Vault:
source scripts/vault-env.sh && vlogin
bash scripts/provision-caddy-acme-creds.sh   # Cloudflare token for DNS-01 ACME
bash scripts/publish-mysql-creds.sh           # Vaultwarden MySQL creds
# Tailscale auth key → vault kv put kv/tailscale/authkey value=<key>
```

---

## Ongoing workflow

| Task | How |
|------|-----|
| Change Kubernetes workloads | Edit `apps/` Helm charts, push to `main` → ArgoCD auto-syncs |
| Change OCI infra | Edit `terraform/`, push to `main` → ORM job applies |
| Local Terraform plan | `source scripts/tf-env.sh && terraform init -reconfigure && terraform plan` |
| Get kubeconfig | `oci ce cluster create-kubeconfig --cluster-id <id> --file ~/.kube/oke-homelab.config --region ap-sydney-1 --token-version 2.0.0` |
| Access ArgoCD | `https://argocd.stevegore.au` (GitHub SSO) |

---

## Secrets model

All secrets live in Vault (`vault.stevegore.au`). The Vault Secrets Operator (VSO) syncs them into Kubernetes `Secret` objects consumed by each app. No secrets are committed to this repo.

- SOPS / age used previously for ampere-ubuntu VM configs — **no longer in use**.
- `config/secrets.sops.yaml` is retained for reference only.
