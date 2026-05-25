# Oracle Cloud Infrastructure

**Region:** ap-sydney-1  
**Tenancy:** `ocid1.tenancy.oc1..aaaaaaaa3t6wd5cb4rcwtko3xeovprpnvf4iixks5ytomyftvulepxxnyt5q`

## CLI Configuration

Installed via `brew install oci-cli`. Config file at `~/.oci/config`:

```ini
[DEFAULT]
user=ocid1.user.oc1..aaaaaaaaszjir6oukoajkrfd4ftanulepcokjrmypv3n5hqg7isafmakalea
fingerprint=a4:54:b1:8d:2f:0c:a9:b3:79:aa:d0:16:78:08:da:e4
tenancy=ocid1.tenancy.oc1..aaaaaaaa3t6wd5cb4rcwtko3xeovprpnvf4iixks5ytomyftvulepxxnyt5q
region=ap-sydney-1
key_file=~/oci.pem
```

The private key + all the above fields are backed up in Vault at `kv/oci/api-key`.
On a fresh machine: `source scripts/vault-env.sh && vlogin && bash scripts/restore-oci-creds.sh`
materializes both `~/.oci/config` and `~/oci.pem`.

## Compartments

| Name | OCID                                                                                  |
| ---- | ------------------------------------------------------------------------------------- |
| main | `ocid1.compartment.oc1..aaaaaaaays62ka24mqjmg7ej5khoswujbqjhwwlvalkjbfm7lz5pkmqugwba` |

## Compute Instances

### ampere-ubuntu

| Property            | Value                                                                                         |
| ------------------- | --------------------------------------------------------------------------------------------- |
| Compartment         | main                                                                                          |
| Shape               | VM.Standard.A1.Flex                                                                           |
| OCPUs               | 4                                                                                             |
| Memory              | 24 GB                                                                                         |
| Processor           | 3.0 GHz Ampere® Altra™                                                                        |
| State               | **TERMINATED** (2026-05-26)                                                                   |
| Availability Domain | AP-SYDNEY-1-AD-1 (CLI form: `tbGS:AP-SYDNEY-1-AD-1` — tenancy-aliased)                        |
| Fault Domain        | FAULT-DOMAIN-2                                                                                |
| Created             | 2023-09-14                                                                                    |
| Terminated          | 2026-05-26                                                                                    |
| Private IP          | 10.0.0.127 (was)                                                                              |
| Public IP           | 158.178.136.162 (was — now detached; see Reserved IPs below)                                  |
| Instance OCID       | `ocid1.instance.oc1.ap-sydney-1.anzxsljrxbp2yoqcuh4ka3eoi4novuompif6tkoiqij57zi7fxmh24b5q53a` |
| Services            | **TERMINATED** — all services migrated to OKE. WireGuard replaced by Tailscale.              |
| Boot volume         | Preserved (`--preserve-boot-volume true`); backup taken 2026-05-26.                           |

#### Gotcha: Oracle's Ubuntu image has no logrotate

Oracle Cloud's Ubuntu 22.04 aarch64 cloud image ships **without** the `logrotate`
package and without `/etc/logrotate.conf`. Anything not self-rotated (notably
`/var/log/btmp` and `/var/log/wtmp`) grows unbounded. On 2026-05-23 this filled
`/var/sda1` enough that MicroK8s' kubelet hit its `nodefs.available<1Gi`
eviction threshold and started evicting pods — including `argocd-dex-server`,
which broke GitHub SSO login to ArgoCD.

This was fixed on the now-terminated ampere-ubuntu instance by manually installing
`logrotate`, writing `/etc/logrotate.d/{btmp,wtmp}`, and capping journald at 500 MiB.
**Not applicable to OKE** — node log rotation is managed by OKE's managed node pool.

## OKE Cluster Health & Capacity (homelab)

**Cluster Status:** ACTIVE (v1.35.2)

| Node | Internal IP | Status | Capacity | Available | Allocation |
|------|-------------|--------|----------|-----------|------------|
| FD-1 (10.0.1.146) | 10.0.1.146 | Ready | 2 OCPU / 12 GB RAM | ~1.5 GB available | 87% CPU-bound, pods evicting on memory pressure |
| FD-2 (10.0.1.138) | 10.0.1.138 | Ready | 2 OCPU / 12 GB RAM | ~1.5 GB available | 87% CPU-bound, pods evicting on memory pressure |

**Total Cluster:** 4 OCPU / 24 GB RAM (within Always Free tier)

**Workload Distribution:**
- `argocd` (2 replicas) + `vault` (1) + `vault-secrets-operator` + `caddy` (2 replicas) + `vaultwarden` (1) + `uptime-kuma` (1) + `homepage` (1) + `tailscale-operator` (1)
- Heavy consumers: caddy (2 replicas, TLS termination), uptime-kuma (SQLite queries), argocd-repo-server

**Metrics:** Metrics-server not yet installed; CPU/memory tracking via pod logs and `kubectl top` when available.

### Deployed Applications (Helm Charts)

| Application | Version | Repository | Status |
|-------------|---------|-----------|--------|
| ArgoCD | v3.4.2 | ArgoCD | Manages this cluster |
| Vault | 1.18.1 | HashiCorp | Unsealed with auto-unseal |
| Caddy | 2.11.3 | Custom build | 2 replicas, TLS termination for `*.stevegore.au` |
| Tailscale Operator | 1.98.3 | Tailscale | Manages k8s cluster membership on tailnet |
| Vaultwarden | 1.36.0 | — | MySQL backend on OCI via HeatWave; security fixes (SSO CSRF, enumeration) |
| Uptime Kuma | 2.3.2 | — | SQLite backend on 50GB OCI block volume; monitors pico+external services |
| Homepage | 0.10.9 | — | Service dashboard |

All Helm charts are defined in `apps/` and synced via ArgoCD. See `argocd/applicationset.yaml` for the ApplicationSet (`infra-apps`).

---

## Networking

### VCN: nebula

| Property    | Value                                                                                    |
| ----------- | ---------------------------------------------------------------------------------------- |
| CIDR Block  | 10.0.0.0/16                                                                              |
| DNS Label   | nebula                                                                                   |
| Domain Name | nebula.oraclevcn.com                                                                     |
| VCN OCID    | `ocid1.vcn.oc1.ap-sydney-1.amaaaaaaxbp2yoqa2larzivt567wt2wffa4g6b3iwtrbmjqbiamdsxrawtoa` |

### Subnets

| Name                  | CIDR        | Public Access |
| --------------------- | ----------- | ------------- |
| Public Subnet-nebula  | 10.0.0.0/24 | ✅ Yes        |
| Private Subnet-nebula | 10.0.1.0/24 | ❌ No         |

### Security List: nebula-public

| Protocol | Port(s)       | Source           | Description        |
| -------- | ------------- | ---------------- | ------------------ |
| TCP      | 22            | 159.196.97.38/32 | SSH (home IP only) |
| TCP      | 80            | 0.0.0.0/0        | HTTP               |
| TCP      | 443           | 0.0.0.0/0        | HTTPS              |
| TCP      | 32400         | 0.0.0.0/0        | Plex               |
| ICMP     | type 3 code 4 | 0.0.0.0/0        | Path MTU Discovery |
| ICMP     | all           | 10.0.0.0/16      | Ping (VCN only)    |

### Security List: nebula-private

| Protocol | Port(s) | Source      | Description     |
| -------- | ------- | ----------- | --------------- |
| TCP      | 22      | 10.0.0.0/16 | SSH (VCN only)  |
| ICMP     | all     | 10.0.0.0/16 | Ping (VCN only) |

### Network Security Groups

| Name             | Purpose              | VNICs                         |
| ---------------- | -------------------- | ----------------------------- |
| mysql-heatwave   | MySQL HeatWave NSG   | OKE private subnet nodes      |
| oke-workers      | OKE worker nodes     | OKE node pool                 |
| oke-api-endpoint | OKE API endpoint     | OKE API endpoint VNIC         |

Note: `allow-wireguard`, `allow-all-egress`, `allow-ssh`, and `allow-http-https` were deleted 2026-05-26 (all were attached to ampere-ubuntu which was terminated).

### Gateways

| Name                    | Type             |
| ----------------------- | ---------------- |
| Internet Gateway-nebula | Internet Gateway |
| NAT Gateway-nebula      | NAT Gateway      |
| Service Gateway-nebula  | Service Gateway  |

## Other Resources

### Public IPs

| Name                   | IP              | Lifetime  | Attached to                          | State    |
| ---------------------- | --------------- | --------- | ------------------------------------ | -------- |
| publicip20230914115348 | 158.178.136.162 | EPHEMERAL | (none — detached when ampere terminated 2026-05-26) | UNASSIGNED |
| (NAT gateway IP)       | 168.138.106.64  | EPHEMERAL | NAT-Gateway-nebula                   | ASSIGNED |

`publicip20230914115348` is misleadingly named — the digits look like a date but
it's actually an ephemeral IP that's auto-named by OCI when a VNIC's first
public address is assigned. The architecture migration (Phase 0) promotes it to
RESERVED via Terraform so it can be detached from ampere and re-attached to the
NLB in Phase 3 without changing the IP value (which would break Cloudflare DNS
records).

### Boot Volumes

| Name                        | State     |
| --------------------------- | --------- |
| ampere-ubuntu (Boot Volume) | AVAILABLE (preserved; backup taken 2026-05-26) |

### Logging

| Log Group     | Logs                     |
| ------------- | ------------------------ |
| Default_Group | —                        |
| hasslogs      | —                        |
| —             | Public_Subnet_nebula_all |

---

## Key Management (KMS)

### Vault: hashicorp-vault-unseal

| Property            | Value                                                                                                    |
| ------------------- | -------------------------------------------------------------------------------------------------------- |
| Vault OCID          | `ocid1.vault.oc1.ap-sydney-1.fnuxtwyhaahla.abzxsljrvudzw4lbnbgggxygz5icznztgl557ezsbgw4qkp7qbm6fdwvq5da` |
| Vault Type          | DEFAULT                                                                                                  |
| Crypto Endpoint     | `https://fnuxtwyhaahla-crypto.kms.ap-sydney-1.oraclecloud.com`                                           |
| Management Endpoint | `https://fnuxtwyhaahla-management.kms.ap-sydney-1.oraclecloud.com`                                       |
| State               | ACTIVE                                                                                                   |

### Key: vault-auto-unseal

| Property        | Value                                                                                                  |
| --------------- | ------------------------------------------------------------------------------------------------------ |
| Key OCID        | `ocid1.key.oc1.ap-sydney-1.fnuxtwyhaahla.abzxsljrgzjola7olf2nj27fljzgkqx5vdwq5f44g7n6wse3awmsoee2imfa` |
| Algorithm       | AES                                                                                                    |
| Length          | 256-bit (32 bytes)                                                                                     |
| Protection Mode | HSM                                                                                                    |
| State           | ENABLED                                                                                                |
| Purpose         | HashiCorp Vault auto-unseal                                                                            |

---

## Object Storage

### Bucket: vault-storage

| Property      | Value                           |
| ------------- | ------------------------------- |
| Namespace     | `sdajdczqv0qo`                  |
| Compartment   | main                            |
| Versioning    | Enabled                         |
| Public Access | No                              |
| Purpose       | HashiCorp Vault storage backend |

### Bucket: infra-tfstate

| Property      | Value                                                                          |
| ------------- | ------------------------------------------------------------------------------ |
| Namespace     | `sdajdczqv0qo`                                                                 |
| Compartment   | main                                                                           |
| Versioning    | Enabled                                                                        |
| Public Access | No                                                                             |
| Purpose       | Originally provisioned for Terraform s3-backend state, but ORM's job runner    |
|               | doesn't init custom backends — state lives in ORM directly now. Bucket retained |
|               | so the Customer Secret Key (`terraform-state-s3`) and `oci_objectstorage_bucket` |
|               | resource don't need surgery; reuse for future tooling or delete later.         |

---

## Identity & Access Management (IAM)

### Dynamic Group: vault-instances

| Property      | Value                                                                                                         |
| ------------- | ------------------------------------------------------------------------------------------------------------- |
| OCID          | `ocid1.dynamicgroup.oc1..aaaaaaaareb5w5qct2kihtaah6nq6tj5uo4fbeg36df6tmfxk3na44oxrvbq`                        |
| Matching Rule | `instance.compartment.id = 'ocid1.compartment.oc1..aaaaaaaays62ka24mqjmg7ej5khoswujbqjhwwlvalkjbfm7lz5pkmqugwba'` |
| Purpose       | Instance principal auth for Vault auto-unseal (OCI KMS + Object Storage). Broadened from ampere instance OCID to compartment-match so OKE worker nodes inherit the same auth. |

### Policy: vault-kms-objectstorage-policy

| Property    | Value                                                                            |
| ----------- | -------------------------------------------------------------------------------- |
| OCID        | `ocid1.policy.oc1..aaaaaaaa7wstjq64sc4yh3w5ted4yltlgscezbcakm6x7yxqmmfkjteqjkca` |
| Compartment | main                                                                             |
| Statements  |                                                                                  |

```text
Allow dynamic-group vault-instances to use keys in compartment main
Allow dynamic-group vault-instances to manage objects in compartment main where target.bucket.name='vault-storage'
Allow dynamic-group vault-instances to read buckets in compartment main
```

### Customer Secret Keys (HMAC creds for S3-compat endpoint)

| Display Name       | Access Key ID                              | Purpose                                                  | Stored in Vault at      |
| ------------------ | ------------------------------------------ | -------------------------------------------------------- | ----------------------- |
| `terraform-state-s3` | `edde148ef34b728522e7ad399f7b5b818bec5754` | Terraform `s3` backend → `infra-tfstate` bucket          | `kv/oci/tf-state-s3`    |

OCI users are capped at 2 active Customer Secret Keys. List + delete via
`oci iam customer-secret-key list --user-id <user-ocid>`.

---

## Kubernetes (OKE)

### Cluster: homelab

| Property                | Value                                                                                                |
| ----------------------- | ---------------------------------------------------------------------------------------------------- |
| OCID                    | `ocid1.cluster.oc1.ap-sydney-1.aaaaaaaaok3ygaxxoaf3vlwoytcnift4yxrmr4dmd75be53iocfghlpevogq`         |
| Kubernetes version      | `v1.35.2`                                                                                            |
| Type                    | ENHANCED_CLUSTER (Always Free)                                                                       |
| API endpoint            | Public, NSG-restricted to home IP `159.196.97.38/32`                                                 |
| CNI                     | FLANNEL_OVERLAY (pods 10.244.0.0/16, services 10.96.0.0/16)                                          |
| Node pool               | `homelab-arm`, VM.Standard.A1.Flex 2 OCPU / 12 GB, 2 nodes (FD-1 + FD-2 in Private Subnet-nebula)    |
| Worker NSG              | `oke-workers`                                                                                        |
| API endpoint NSG        | `oke-api-endpoint`                                                                                   |
| API endpoint subnet     | `oke-api-endpoint` (10.0.2.0/28)                                                                     |
| Managed by              | Terraform (`terraform/oke-*.tf`)                                                                     |

### Kubeconfig

#### Local (Mac)

| Path                                | Notes                                                                              |
| ----------------------------------- | ---------------------------------------------------------------------------------- |
| `~/.kube/oke-homelab.config`        | Generated locally on the Mac; uses OCI CLI auth (your `~/.oci/config` API key).    |

Regenerate (e.g. on a fresh machine, or to refresh the OCI token cache):

```bash
oci ce cluster create-kubeconfig \
  --cluster-id ocid1.cluster.oc1.ap-sydney-1.aaaaaaaaok3ygaxxoaf3vlwoytcnift4yxrmr4dmd75be53iocfghlpevogq \
  --file ~/.kube/oke-homelab.config \
  --region ap-sydney-1 \
  --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT
```

Use:

```bash
export KUBECONFIG=~/.kube/oke-homelab.config
kubectl get nodes
```

Or per-command: `KUBECONFIG=~/.kube/oke-homelab.config kubectl ...`.

#### On Pico (for Stats Server)

Pico has kubeconfig for the stats server to monitor OKE cluster metrics:

| Component | Location | Setup |
|-----------|----------|-------|
| OCI CLI | `~/.local/bin/oci` | Installed via `pipx install oci-cli` |
| OCI credentials | `~/.oci/config`, `~/oci.pem` | Copied from Mac via `scp` |
| Kubeconfig | `~/.kube/oke-homelab.config` | Generated via `oci ce cluster create-kubeconfig` |
| Kubectl | `/home/steve/kubectl` | Pre-downloaded binary |
| Kubectl wrapper | `~/code/infra/scripts/kubectl-wrapper.sh` | Custom script providing PATH for oci plugin |

**Setup on pico (automated):**
```bash
bash ~/code/infra/scripts/setup-pico-stats.sh
```

**Setup on pico (manual):**
1. Copy OCI credentials from Mac: `scp ~/.oci/config ~/oci.pem steve@pico.local:~/`
2. Install OCI CLI: `pipx install oci-cli`
3. Generate kubeconfig:
   ```bash
   oci ce cluster create-kubeconfig \
     --cluster-id ocid1.cluster.oc1.ap-sydney-1.aaaaaaaaok3ygaxxoaf3vlwoytcnift4yxrmr4dmd75be53iocfghlpevogq \
     --file ~/.kube/oke-homelab.config \
     --region ap-sydney-1 \
     --token-version 2.0.0 \
     --kube-endpoint PUBLIC_ENDPOINT
   ```
4. Verify: `export KUBECONFIG=~/.kube/oke-homelab.config && /home/steve/kubectl get nodes`

**Access restrictions:**
Access is allowed only from the home IP (`159.196.97.38/32`); from anywhere else you'll get a TCP timeout on 6443. If the home IP changes, update the NSG ingress rule in `terraform/oke-networking.tf` (`oke_api_kubectl_home`).

---

## Terraform / Resource Manager

The OCI footprint (everything in `main` plus the IAM dynamic-group + policy)
is managed by Terraform at `terraform/` in this repo. State lives in the
`infra-tfstate` bucket via the S3-compat endpoint. See `terraform/README.md`
for the local-plan / ORM-apply workflow.

| Component               | Detail                                                                       |
| ----------------------- | ---------------------------------------------------------------------------- |
| ORM Stack display name  | `homelab-tf` (created by `scripts/provision-orm-stack.sh`)                   |
| ORM Stack OCID          | `ocid1.ormstack.oc1.ap-sydney-1.amaaaaaaxbp2yoqaytua3d676bavg2kdjw6oud5srw7egs3iea7q7ppiydoq` |
| State                   | ORM-managed (not a custom backend — see `terraform/README.md`)               |
| GitHub source           | `stevegore/infra`, branch `main`, working directory `terraform/`             |
| GitHub PAT in Vault     | `kv/github/orm-pat`                                                          |
| Resources under control | 30 (see `terraform state list` for the authoritative inventory)              |
