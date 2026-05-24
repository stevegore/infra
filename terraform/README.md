# Terraform — OCI homelab

Manages every resource in the `main` compartment (plus the IAM dynamic-group +
policy at the tenancy level). State lives in OCI Object Storage; runs happen
locally for fast iteration and via OCI Resource Manager for the real apply.

## Workflow

```
plan locally → review → push to GitHub → ORM job applies
```

- `terraform plan` runs **anywhere** that can reach the state bucket.
- `terraform apply` runs **only via ORM**. This isn't a hard lock — both
  endpoints share the same state — it's a discipline so the audit trail and
  approval flow always go through ORM. Bucket versioning is the safety net
  if the discipline ever slips.

## First-time local setup

```bash
# 1. Load Vault, then load TF s3-backend creds into env
source ../scripts/vault-env.sh && vlogin
source ../scripts/tf-env.sh

# 2. Init (downloads provider, pulls state from the bucket)
terraform init

# 3. Plan — should report "No changes" once Phase E of the plan is done
terraform plan
```

## Layout

| Path | Purpose |
| --- | --- |
| `versions.tf` | Terraform + provider version pins |
| `backend.tf` | s3 backend → `infra-tfstate` bucket via OCI S3-compat |
| `providers.tf` | OCI provider config (auth via `~/.oci/config` locally, ORM-injected in jobs) |
| `variables.tf` | Tenancy/compartment/region inputs |
| `terraform.tfvars` | Concrete values for the homelab tenancy |
| `imported/` | Auto-generated `.tf` from OCI Resource Discovery — don't hand-edit until they've been refactored |

## Resources under management

See `imported/` for the authoritative list. At a glance:

- **Networking:** VCN `nebula`, public + private subnets, security lists, NSGs, internet/NAT/service gateways
- **Compute:** `ampere-ubuntu` instance, boot volume (will be `terraform destroy`'d in Phase 7 of the OKE migration)
- **Reserved IP:** `publicip20230914115348` (kept across migrations)
- **KMS:** `hashicorp-vault-unseal` vault + `vault-auto-unseal` key
- **Object Storage:** `vault-storage` bucket
- **IAM:** `vault-instances` dynamic group + `vault-kms-objectstorage-policy`
- **State infra (self-managed):** `infra-tfstate` bucket itself

## ORM Stack

Created by `scripts/provision-orm-stack.sh` (see Phase D of the plan). Points
at `github.com/stevegore/infra` branch `main`, working directory `terraform/`,
same backend config so it shares state with local runs.
