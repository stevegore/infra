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

| Node | Internal IP | Status | Capacity | Mem used | CPU used |
|------|-------------|--------|----------|----------|----------|
| FD-1 (10.0.1.146) | 10.0.1.146 | Ready | 2 OCPU / 12 GB RAM | 3.9 GB (41%) | 12% |
| FD-2 (10.0.1.138) | 10.0.1.138 | Ready | 2 OCPU / 12 GB RAM | 2.8 GB (30%) | 11% |

**Total Cluster:** 4 OCPU / 24 GB RAM (within Always Free tier). ~36% memory / ~11% CPU in use — roughly **12 GB RAM free** (measured 2026-06-01 via metrics-server). The cluster is *not* memory- or CPU-constrained; an earlier note here claiming "~1.5 GB available / 87% CPU-bound / pods evicting" was inaccurate and has been corrected against live `kubectl top` data.

**Workload Distribution:**
- `argocd` (2 replicas) + `vault` (1) + `vault-secrets-operator` + `caddy` (2 replicas) + `authentik` (server+worker) + `cloudnative-pg` operator (1) + `databases`/`pg-shared` Postgres (1) + `vaultwarden` (1) + `uptime-kuma` (1) + `homepage` (1) + `metrics-server` (1) + `tailscale-operator` (1)
- Top memory consumers (actual RSS): argocd-application-controller ~317 MB, uptime-kuma ~219 MB, oke-dataplane-observability-agent ~170 MB ×2, vaultwarden ~138 MB, homepage ~106 MB. caddy ~50 MB. (hermes removed 2026-06-06)

**Metrics:** metrics-server is deployed (`apps/metrics-server`, wrapper over the upstream chart, `--kubelet-insecure-tls` for OKE managed kubelets). `kubectl top nodes` / `kubectl top pods -A` work cluster-wide.

### Deployed Applications (Helm Charts)

| Application | Version | Repository | Status |
|-------------|---------|-----------|--------|
| ArgoCD | v3.4.2 | ArgoCD | Manages this cluster |
| Vault | 1.18.1 | HashiCorp | Unsealed with auto-unseal |
| Caddy | 2.11.3 | Custom build | 2 replicas, TLS termination for `*.stevegore.au`; Authentik forward_auth (stateless, see dns.md) |
| Authentik | 2026.5.2 | goauthentik.io | GitHub-federated SSO + forward-auth outpost; Postgres on pg-shared, no Redis; secrets via VSO (`kv/authentik/config`) |
| CloudNativePG | 1.29.1 (chart 0.28.2) | cloudnative-pg | Cluster-wide Postgres operator (CRDs + controller) |
| pg-shared (Postgres) | 16 | CNPG `Cluster` | Shared instance in ns `databases`, 50 GB `oci-bv`; WAL+base backups to OCI Object Storage (`pg-backups` bucket) |
| Tailscale Operator | 1.98.3 | Tailscale | Manages k8s cluster membership on tailnet |
| Vaultwarden | 1.36.0 | — | MySQL backend on OCI via HeatWave; security fixes (SSO CSRF, enumeration) |
| Uptime Kuma | 2.3.2 | — | SQLite backend on 50GB OCI block volume; monitors pico+external services |
| Homepage | 0.10.9 | — | Service dashboard (gated by Authentik) |
| metrics-server | 0.8.0 (chart 3.13.0) | kubernetes-sigs | `kubectl top` / HPA metrics; `--kubelet-insecure-tls` |

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

| Name              | Purpose                              | VNICs                                          |
| ----------------- | ------------------------------------ | ---------------------------------------------- |
| mysql-heatwave    | MySQL HeatWave NSG                   | OKE private subnet nodes                       |
| oke-workers       | OKE worker nodes                     | OKE node pool                                  |
| oke-api-endpoint  | OKE API endpoint                     | OKE API endpoint VNIC                          |
| fss-mount-target  | NFS ingress for the homelab-fss MT   | `homelab-fss` Mount Target VNIC (Private subnet) |

Ingress on `fss-mount-target`: TCP/UDP 111 + 2048–2050 from the `oke-workers` NSG only. No egress rules (Mount Targets are pure responders). Worker NSG egress is `0.0.0.0/0`, so no worker-side rule change is needed.

Note: `allow-wireguard`, `allow-all-egress`, `allow-ssh`, and `allow-http-https` were deleted 2026-05-26 (all were attached to ampere-ubuntu which was terminated). TF code blocks for those were removed in commit `baf439e` on 2026-06-01.

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
| caddy-nlb-reserved     | 159.13.44.68    | RESERVED  | OKE Caddy NLB (CCM-managed)         | ASSIGNED |
| publicip20230914115348 | 158.178.136.162 | EPHEMERAL | (none — detached when ampere terminated 2026-05-26) | UNASSIGNED |
| (NAT gateway IP)       | 168.138.106.64  | EPHEMERAL | NAT-Gateway-nebula                   | ASSIGNED |

`caddy-nlb-reserved` (`159.13.44.68`) is a Terraform-managed reserved IP (`oci_core_public_ip.caddy_nlb` in `nlb.tf`). The Kubernetes CCM creates an NLB and attaches this IP to it when the Caddy `LoadBalancer` service is created. **Important:** when the OKE cluster is rebuilt, the CCM-created NLB is **not** automatically deleted. It must be manually removed so the reserved IP is freed for the new cluster's CCM:

```bash
# Check if IP is still assigned to an old NLB
oci network public-ip get --public-ip-address 159.13.44.68 --region ap-sydney-1 | grep lifecycle-state
# If ASSIGNED, find and delete the old NLB:
oci nlb network-load-balancer list --compartment-id <compartment-ocid> --region ap-sydney-1 --all \
  | python3 -c "import sys,json; [print(n['id'],n['display-name']) for n in json.load(sys.stdin)['data']['items'] if any(i.get('ip-address')=='159.13.44.68' for i in n.get('ip-addresses',[]))]"
oci nlb network-load-balancer delete --network-load-balancer-id <ID> --region ap-sydney-1 --force
```

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

## File Storage

### Mount Target: homelab-fss

| Property            | Value                                                                                                       |
| ------------------- | ----------------------------------------------------------------------------------------------------------- |
| OCID                | `ocid1.mounttarget.oc1.ap_sydney_1.aaaaaa4np2xizqumon4willqojxwiotboawxg6lenzsxsljrfvqwiljr`                |
| Compartment         | main                                                                                                        |
| Availability Domain | `tbGS:AP-SYDNEY-1-AD-1` (must match the OKE node pool AD)                                                   |
| Subnet              | `Private-Subnet-nebula` (10.0.1.0/24)                                                                       |
| Private IP          | `10.0.1.254`                                                                                                |
| NSG                 | `fss-mount-target` (ingress: TCP/UDP 111, 2048-2050 from `oke-workers` NSG)                                 |
| Purpose             | NFS endpoint for the `oci-fss` Kubernetes StorageClass — RWX, AD-durable, multi-FD via `fss.csi.oraclecloud.com` |

File Systems themselves are dynamically provisioned by the CSI driver on PVC
creation; no per-FS Terraform resource. Cost is $0 under the 100 GB FSS
Always-Free allotment.

Used by: `apps/oci-fss/` Helm chart (StorageClass manifest only — the Mount
Target OCID lives in that chart's `values.yaml`).

#### Gotcha: FSS CSI auth needs a cluster-principal grant, not `service OKE`

The OKE-bundled `fss.csi.oraclecloud.com` provisioner runs on the OKE managed
control plane and authenticates as the **cluster instance principal**, not as
`service OKE`. Granting `Allow service OKE to manage file-family` is necessary
but *not* sufficient — PVCs stall with `HTTP 404 NotAuthorizedOrNotFound` on
`GetMountTarget` until the cluster principal is granted directly. Both
statements are in `oke-service-policy` (see IAM section below); the
load-bearing one is the `any-user where request.principal.type='cluster'` line.

This differs from the BV CSI driver (`blockvolume.csi.oraclecloud.com`), which
*does* work with just `Allow service OKE to manage volume-family`. Verified
empirically 2026-06-01 — commit `d3af061`. Reproduces if you ever recreate the
cluster or test in another tenancy.

---

## Identity & Access Management (IAM)

### Dynamic Group: vault-instances

| Property      | Value                                                                                                         |
| ------------- | ------------------------------------------------------------------------------------------------------------- |
| OCID          | `ocid1.dynamicgroup.oc1..aaaaaaaareb5w5qct2kihtaah6nq6tj5uo4fbeg36df6tmfxk3na44oxrvbq`                        |
| Matching Rule | `instance.compartment.id = 'ocid1.compartment.oc1..aaaaaaaays62ka24mqjmg7ej5khoswujbqjhwwlvalkjbfm7lz5pkmqugwba'` |
| Purpose       | Instance principal auth for Vault auto-unseal (KMS + Object Storage), Caddy ACME storage (Object Storage), and OKE FSS CSI provisioning (File Storage). Broadened from ampere instance OCID to compartment-match so OKE worker nodes inherit the same auth. |

### Policy: vault-kms-objectstorage-policy

| Property    | Value                                                                            |
| ----------- | -------------------------------------------------------------------------------- |
| OCID        | `ocid1.policy.oc1..aaaaaaaa7wstjq64sc4yh3w5ted4yltlgscezbcakm6x7yxqmmfkjteqjkca` |
| Compartment | main                                                                             |
| Statements  |                                                                                  |

```text
Allow dynamic-group vault-instances to use keys in compartment main
Allow dynamic-group vault-instances to manage objects in compartment main where target.bucket.name='vault-storage'
Allow dynamic-group vault-instances to manage objects in compartment main where target.bucket.name='caddy-acme'
Allow dynamic-group vault-instances to read buckets in compartment main
Allow dynamic-group vault-instances to manage file-family in compartment main
```

### Policy: oke-service-policy

| Property    | Value                                                                            |
| ----------- | -------------------------------------------------------------------------------- |
| OCID        | `ocid1.policy.oc1..aaaaaaaahmnm5qw5ntj6pnbuhbrvy7e2hovfc2suzjoxarp4fzym26mjh73a` |
| Compartment | main                                                                             |
| Statements  |                                                                                  |

```text
Allow service OKE to manage virtual-network-family in compartment main
Allow service OKE to manage instance-family in compartment main
Allow service OKE to manage load-balancers in compartment main
Allow service OKE to manage volume-family in compartment main
Allow service OKE to manage cluster-node-pools in compartment main
Allow service OKE to manage file-family in compartment main
Allow any-user to manage file-family in compartment main where ALL {request.principal.type='cluster', request.principal.compartment.id='<main-compartment-ocid>'}
```

The last statement is the one that actually unblocks the FSS CSI provisioner
(see the "FSS CSI auth" gotcha in the File Storage section above). The
`service OKE` `file-family` line is kept for belt-and-suspenders; remove it
once you've confirmed FSS CSI never falls back to the service-principal path.

### MySQL service policy

| Property    | Value                                                                            |
| ----------- | -------------------------------------------------------------------------------- |
| OCID        | (see `terraform/oke-iam.tf` → `oci_identity_policy.mysql_service`)               |
| Purpose     | Grants the MySQL DB Service the access it needs to provision a HeatWave DB system in `main` (VNICs, KMS for at-rest encryption, automatic backups to Oracle-managed Object Storage, work-request tracking). |

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
| OCID                    | `ocid1.cluster.oc1.ap-sydney-1.aaaaaaaayyadaznxbxlzv7qz6drid3w3erh3yunv2zp7wdqzjclxsok2k6nq`         |
| Kubernetes version      | `v1.35.2`                                                                                            |
| Type                    | BASIC_CLUSTER (free — Enhanced incurs ~$0.15/hr; downgrade requires full cluster rebuild)            |
| API endpoint            | Public, NSG-restricted to home IP `159.196.97.38/32`                                                 |
| CNI                     | FLANNEL_OVERLAY (pods 10.244.0.0/16, services 10.96.0.0/16)                                          |
| Node pool               | `homelab-arm`, VM.Standard.A1.Flex 2 OCPU / 12 GB, 2 nodes (FD-1 + FD-2 in Private Subnet-nebula)    |
| Worker NSG              | `oke-workers`                                                                                        |
| API endpoint NSG        | `oke-api-endpoint`                                                                                   |
| API endpoint subnet     | `oke-api-endpoint` (10.0.2.0/28)                                                                     |
| StorageClasses          | `oci-bv` (RWO Block, FD-pinned, default), `oci-fss` (RWX File, AD-durable, Retain reclaim)           |
| Managed by              | Terraform (`terraform/oke-*.tf`, `terraform/fss.tf`)                                                  |

### Kubeconfig

#### Local (Mac)

| Path                                | Notes                                                                              |
| ----------------------------------- | ---------------------------------------------------------------------------------- |
| `~/.kube/oke-homelab.config`        | Generated locally on the Mac; uses OCI CLI auth (your `~/.oci/config` API key).    |

Regenerate (e.g. on a fresh machine, or to refresh the OCI token cache):

```bash
oci ce cluster create-kubeconfig \
  --cluster-id ocid1.cluster.oc1.ap-sydney-1.aaaaaaaayyadaznxbxlzv7qz6drid3w3erh3yunv2zp7wdqzjclxsok2k6nq \
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
     --cluster-id ocid1.cluster.oc1.ap-sydney-1.aaaaaaaayyadaznxbxlzv7qz6drid3w3erh3yunv2zp7wdqzjclxsok2k6nq \
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
