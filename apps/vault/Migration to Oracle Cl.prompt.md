# HashiCorp Vault Migration to Oracle Cloud

## Goal
Deploy a new HashiCorp Vault instance at **vault.stevegore.au** on Oracle Cloud (Ampere), replacing the current pico instance.

## Current State (from context)

| Component | Status | Notes |
|-----------|--------|-------|
| **MicroK8s** | ✅ Running | Already on ampere-ubuntu |
| **ArgoCD** | ✅ Running | argocd.stevegore.au (NodePort 32392) |
| **Caddy** | ✅ Running | Systemd service at `/etc/caddy/Caddyfile` (not K8s) |
| **DNS** | ✅ Configured | Wildcard `*.stevegore.au → 158.178.136.162` |
| **Old Vault** | ⚠️ Running | pico:8202 (Docker, file storage, manual unseal) |
| **OCI CLI** | ✅ Configured | `~/.oci/config` with compartment `main` |

## Key Architecture Decisions

| Component | Decision |
|-----------|----------|
| **Unseal** | OCI KMS with HSM-backed keys + Instance Principal auth |
| **Storage** | OCI Object Storage backend |
| **Platform** | MicroK8s on Ampere (already running) |
| **GitOps** | ArgoCD with ApplicationSet (directory generator) |
| **TLS** | Caddy handles all TLS termination (existing systemd service) |
| **Deployment** | Helm chart wrapper pattern |

## Repository Structure
```
infra/
├── argocd/
│   └── applicationset.yaml      # Git directory generator
├── apps/
│   └── vault/
│       ├── Chart.yaml           # Wrapper chart with hashicorp/vault dependency
│       ├── values.yaml          # Overrides only (OCI KMS + Object Storage)
│       └── templates/           # Optional: extra resources if needed
└── bootstrap/
    └── install.sh               # One-time setup reference
```

### Wrapper Chart Pattern

Each app uses a minimal wrapper chart that declares the upstream chart as a dependency. This minimizes local changes—only `values.yaml` overrides are needed.

**apps/vault/Chart.yaml:**
```yaml
apiVersion: v2
name: vault
version: 1.0.0
dependencies:
  - name: vault
    version: 0.28.1
    repository: https://helm.releases.hashicorp.com
```

**apps/vault/values.yaml:**
```yaml
vault:
  server:
    ha:
      enabled: false
    standalone:
      enabled: true
      config: |
        ui = true
        listener "tcp" {
          address = "[::]:8200"
          cluster_address = "[::]:8201"
          tls_disable = 1  # Caddy handles TLS
        }
        storage "oci" {
          bucket_name = "vault-storage"
          ha_enabled = "false"
          auth_type_api_key = "false"  # Use instance principal
        }
        seal "ocikms" {
          key_id = "<KEY_OCID>"
          crypto_endpoint = "https://<vault-id>-crypto.kms.ap-sydney-1.oraclecloud.com"
          management_endpoint = "https://<vault-id>-management.kms.ap-sydney-1.oraclecloud.com"
          auth_type_api_key = "false"  # Use instance principal
        }
    service:
      type: NodePort
      nodePort: 30820
```

> **Benefit:** Upstream chart updates only require bumping the version in `Chart.yaml`. No template changes needed.

> **Note:** Caddy is a systemd service on ampere-ubuntu, not deployed via K8s. Update `/etc/caddy/Caddyfile` directly.

## Implementation Steps

### Phase 1: OCI Infrastructure

1. **Create OCI KMS Vault**
   - Provision vault in compartment `main` (ocid1.compartment.oc1..aaaaaaaays62ka24mqjmg7ej5khoswujbqjhwwlvalkjbfm7lz5pkmqugwba)
   - Create HSM-protected AES-256 master encryption key for auto-unseal
   ```bash
   oci kms management vault create \
     --compartment-id ocid1.compartment.oc1..aaaaaaaays62ka24mqjmg7ej5khoswujbqjhwwlvalkjbfm7lz5pkmqugwba \
     --display-name "hashicorp-vault-unseal" \
     --vault-type DEFAULT
   ```

2. **Create OCI Object Storage Bucket**
   - Bucket name: `vault-storage`
   - Enable versioning for recovery
   - No public access
   ```bash
   oci os bucket create \
     --compartment-id ocid1.compartment.oc1..aaaaaaaays62ka24mqjmg7ej5khoswujbqjhwwlvalkjbfm7lz5pkmqugwba \
     --name vault-storage \
     --versioning Enabled
   ```

3. **Configure IAM for Instance Principal**
   - Create dynamic group matching ampere-ubuntu instance
   - Create policy granting KMS use and Object Storage access
   ```
   # Dynamic Group: vault-instances
   instance.id = 'ocid1.instance.oc1.ap-sydney-1.anzxsljrxbp2yoqcuh4ka3eoi4novuompif6tkoiqij57zi7fxmh24b5q53a'
   
   # Policy: vault-kms-policy
   Allow dynamic-group vault-instances to use keys in compartment main
   Allow dynamic-group vault-instances to manage objects in compartment main where target.bucket.name='vault-storage'
   Allow dynamic-group vault-instances to read buckets in compartment main
   ```

### Phase 2: GitOps Configuration

4. **Create Vault Helm Chart Wrapper**
   - `apps/vault/Chart.yaml` – dependency on `hashicorp/vault` chart (pin version)
   - `apps/vault/values.yaml` – overrides only: OCI KMS seal, Object Storage backend, NodePort
   - Run `helm dependency update apps/vault/` to generate `Chart.lock`
   - Commit `Chart.lock` so ArgoCD can resolve dependencies

5. **Create ArgoCD ApplicationSet**
   - Configure directory generator for `apps/*/`
   - Point to `stevegore/infra` repo (main branch)
   - Target namespace per app directory name

6. **Create Vault Namespace**
   ```bash
   microk8s kubectl create namespace vault
   ```

### Phase 3: Deployment

7. **Push to GitHub**
   - Commit repo structure to `stevegore/infra`
   - ArgoCD syncs automatically

8. **Verify ArgoCD Sync**
   - Check https://argocd.stevegore.au for vault application status
   - Wait for pods to be running

9. **Update Caddy Configuration**
   - SSH to ampere-ubuntu
   - Edit `/etc/caddy/Caddyfile` to proxy vault.stevegore.au to K8s service
   - Change from `10.20.30.1:8202` to `localhost:<vault-nodeport>` or ClusterIP
   ```bash
   sudo systemctl reload caddy
   ```

10. **Initialize Vault**
    - Run `vault operator init` to generate root token and recovery keys
    - With auto-unseal, only recovery keys are generated (not unseal keys)
    ```bash
    microk8s kubectl exec -n vault vault-0 -- vault operator init
    ```

### Phase 4: Cutover & Cleanup

11. **Verify New Vault**
    - Test https://vault.stevegore.au
    - Login and verify auto-unseal is working
    - Confirm OCI Object Storage backend is functioning

12. **Stop Old Vault on pico**
    - Use Portainer API (token at `portainer.token`)
    ```bash
    curl -X POST "https://port.stevegore.au/api/stacks/23/stop" \
      -H "X-API-Key: $(cat portainer.token)"
    ```
    - Or via Portainer UI: Stacks → vault → Stop

13. **Update Documentation**
    - Update [portainer.md](portainer.md) to mark vault stack as stopped
    - Update [dns.md](dns.md) service mapping table

## Pre-flight Checklist

- [ ] OCI CLI working (`oci iam region list`)
- [ ] MicroK8s healthy (`microk8s status`)
- [ ] ArgoCD accessible (https://argocd.stevegore.au)
- [ ] GitHub repo accessible
- [ ] Portainer API token valid

## DNS Note

**No DNS changes required** – Wildcard `*.stevegore.au` already points to ampere-ubuntu (158.178.136.162). Caddy configuration change handles the routing.

## Rollback Plan

If issues occur:
1. Revert Caddyfile to proxy to `10.20.30.1:8202`
2. Restart old vault stack via Portainer
3. Delete vault namespace in MicroK8s

## Estimated Monthly Cost

- **OCI KMS**: ~$0.53/month (1 key + ~1,000 operations)
- **OCI Object Storage**: ~$0.03–0.10/month (minimal usage)
- **Compute**: Free tier (Ampere A1 already running)
