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

## Compartments

| Name | OCID |
|------|------|
| main | `ocid1.compartment.oc1..aaaaaaaays62ka24mqjmg7ej5khoswujbqjhwwlvalkjbfm7lz5pkmqugwba` |

## Compute Instances

### ampere-ubuntu

| Property | Value |
|----------|-------|
| Compartment | main |
| Shape | VM.Standard.A1.Flex |
| OCPUs | 4 |
| Memory | 24 GB |
| Processor | 3.0 GHz Ampere® Altra™ |
| State | RUNNING |
| Availability Domain | AP-SYDNEY-1-AD-1 |
| Fault Domain | FAULT-DOMAIN-2 |
| Created | 2023-09-14 |
| Private IP | 10.0.0.127 |
| Public IP | 158.178.136.162 |
| Instance OCID | `ocid1.instance.oc1.ap-sydney-1.anzxsljrxbp2yoqcuh4ka3eoi4novuompif6tkoiqij57zi7fxmh24b5q53a` |
| Services | WireGuard VPN hub, Caddy reverse proxy, MicroK8s (ArgoCD, Vault) |

## Networking

### VCN: nebula

| Property | Value |
|----------|-------|
| CIDR Block | 10.0.0.0/16 |
| DNS Label | nebula |
| Domain Name | nebula.oraclevcn.com |
| VCN OCID | `ocid1.vcn.oc1.ap-sydney-1.amaaaaaaxbp2yoqa2larzivt567wt2wffa4g6b3iwtrbmjqbiamdsxrawtoa` |

### Subnets

| Name | CIDR | Public Access |
|------|------|---------------|
| Public Subnet-nebula | 10.0.0.0/24 | ✅ Yes |
| Private Subnet-nebula | 10.0.1.0/24 | ❌ No |

### Security List: nebula-public

| Protocol | Port(s) | Source | Description |
|----------|---------|--------|-------------|
| TCP | 22 | 159.196.97.38/32 | SSH (home IP only) |
| TCP | 80 | 0.0.0.0/0 | HTTP |
| TCP | 443 | 0.0.0.0/0 | HTTPS |
| TCP | 32400 | 0.0.0.0/0 | Plex |
| UDP | 51820 | 0.0.0.0/0 | WireGuard |
| ICMP | type 3 code 4 | 0.0.0.0/0 | Path MTU Discovery |
| ICMP | all | 10.0.0.0/16 | Ping (VCN only) |

### Security List: nebula-private

| Protocol | Port(s) | Source | Description |
|----------|---------|--------|-------------|
| TCP | 22 | 10.0.0.0/16 | SSH (VCN only) |
| ICMP | all | 10.0.0.0/16 | Ping (VCN only) |

### Network Security Groups

| Name | Purpose | VNICs |
|------|---------|-------|
| allow-wireguard | WireGuard VPN access | 1 (ampere-ubuntu) |
| allow-all-egress | Outbound traffic | 1 (ampere-ubuntu) |
| allow-ssh | SSH access | 1 (ampere-ubuntu) |
| allow-http-https | Web traffic | 1 (ampere-ubuntu) |

### Gateways

| Name | Type |
|------|------|
| Internet Gateway-nebula | Internet Gateway |
| NAT Gateway-nebula | NAT Gateway |
| Service Gateway-nebula | Service Gateway |

## Other Resources

### Reserved Public IPs

| Name | State |
|------|-------|
| publicip20230914115348 | ASSIGNED |

### Boot Volumes

| Name | State |
|------|-------|
| ampere-ubuntu (Boot Volume) | AVAILABLE |

### Logging

| Log Group | Logs |
|-----------|------|
| Default_Group | — |
| hasslogs | — |
| — | Public_Subnet_nebula_all |

---

## Key Management (KMS)

### Vault: hashicorp-vault-unseal

| Property | Value |
|----------|-------|
| Vault OCID | `ocid1.vault.oc1.ap-sydney-1.fnuxtwyhaahla.abzxsljrvudzw4lbnbgggxygz5icznztgl557ezsbgw4qkp7qbm6fdwvq5da` |
| Vault Type | DEFAULT |
| Crypto Endpoint | `https://fnuxtwyhaahla-crypto.kms.ap-sydney-1.oraclecloud.com` |
| Management Endpoint | `https://fnuxtwyhaahla-management.kms.ap-sydney-1.oraclecloud.com` |
| State | ACTIVE |

### Key: vault-auto-unseal

| Property | Value |
|----------|-------|
| Key OCID | `ocid1.key.oc1.ap-sydney-1.fnuxtwyhaahla.abzxsljrgzjola7olf2nj27fljzgkqx5vdwq5f44g7n6wse3awmsoee2imfa` |
| Algorithm | AES |
| Length | 256-bit (32 bytes) |
| Protection Mode | HSM |
| State | ENABLED |
| Purpose | HashiCorp Vault auto-unseal |

---

## Object Storage

### Bucket: vault-storage

| Property | Value |
|----------|-------|
| Namespace | `sdajdczqv0qo` |
| Compartment | main |
| Versioning | Enabled |
| Public Access | No |
| Purpose | HashiCorp Vault storage backend |

---

## Identity & Access Management (IAM)

### Dynamic Group: vault-instances

| Property | Value |
|----------|-------|
| OCID | `ocid1.dynamicgroup.oc1..aaaaaaaareb5w5qct2kihtaah6nq6tj5uo4fbeg36df6tmfxk3na44oxrvbq` |
| Matching Rule | `instance.id = 'ocid1.instance.oc1.ap-sydney-1.anzxsljrxbp2yoqcuh4ka3eoi4novuompif6tkoiqij57zi7fxmh24b5q53a'` |
| Purpose | Instance principal auth for Vault on ampere-ubuntu |

### Policy: vault-kms-objectstorage-policy

| Property | Value |
|----------|-------|
| OCID | `ocid1.policy.oc1..aaaaaaaa7wstjq64sc4yh3w5ted4yltlgscezbcakm6x7yxqmmfkjteqjkca` |
| Compartment | main |
| Statements | |

```
Allow dynamic-group vault-instances to use keys in compartment main
Allow dynamic-group vault-instances to manage objects in compartment main where target.bucket.name='vault-storage'
Allow dynamic-group vault-instances to read buckets in compartment main
```
