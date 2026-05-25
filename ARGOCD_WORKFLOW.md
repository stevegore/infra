# ArgoCD Deployment Workflow

**Single Rule:** Modify manifests in the repo, not in the cluster. Let ArgoCD manage all OKE deployments.

## Why

ArgoCD is the **source of truth** for cluster state. Direct `kubectl` edits are lost when ArgoCD syncs next, creating drift between repo and running cluster.

This breaks:
- Reproducibility (can't recreate the setup from git)
- Troubleshooting (which state is actually deployed?)
- Persistence (changes disappear on next ArgoCD sync)

## Workflow

### 1. Identify What to Change

Need to update a ConfigMap, Helm value, or Kubernetes resource?

- **ConfigMap/Secret** → Find the Helm template: `apps/<app>/templates/`
- **Deployment spec** → Find the Helm values: `apps/<app>/values.yaml` or `apps/<app>/Chart.yaml`
- **New service** → Add to ArgoCD Application manifest or Helm chart

### 2. Edit the Repo

Modify the **repo files**, not the cluster:

```bash
# Example: Update Caddy ConfigMap
vim apps/caddy/templates/configmap.yaml

# Example: Update Homepage values
vim apps/homepage/values.yaml
```

### 3. Commit & Push

```bash
git add apps/caddy/templates/configmap.yaml
git commit -m "Update Caddy ConfigMap: add stats.stevegore.au route"
git push origin main
```

### 4. Trigger ArgoCD Sync

On OKE cluster:

```bash
export KUBECONFIG=~/.kube/oke-homelab.config

# Hard refresh to pull latest from git
kubectl -n argocd patch app <app-name> --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

**Available apps:**
```bash
kubectl get app -n argocd
```

### 5. Verify Rollout

```bash
kubectl rollout status deployment/<name> -n <namespace>
```

## Examples

### Example 1: Update Caddy route

```bash
# 1. Edit the ConfigMap template
vim apps/caddy/templates/configmap.yaml
# → Add new reverse_proxy block for stats.stevegore.au

# 2. Commit
git add apps/caddy/templates/configmap.yaml
git commit -m "Add stats route to Caddy"
git push origin main

# 3. Sync ArgoCD
kubectl -n argocd patch app caddy --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# 4. Verify
kubectl rollout status deployment/caddy -n caddy
curl https://stats.stevegore.au/
```

### Example 2: Update Homepage widget

```bash
# 1. Edit the ConfigMap template
vim apps/homepage/templates/configmap.yaml
# → Update services.yaml or widgets.yaml sections

# 2. Commit
git add apps/homepage/templates/configmap.yaml
git commit -m "Add stats iframe widget to homepage"
git push origin main

# 3. Sync ArgoCD
kubectl -n argocd patch app homepage --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# 4. Verify
kubectl rollout status deployment/homepage -n homepage
curl https://homepage.stevegore.au/ | grep stats
```

## Exception: Emergency Fixes

If an emergency fix is needed directly in the cluster:

```bash
# Temporary fix (will be overwritten on next ArgoCD sync)
kubectl set env deployment/caddy -n caddy EMERGENCY_FIX="true"
```

**Then immediately:**

1. Fix the root cause in the repo
2. Commit and push
3. Re-sync ArgoCD
4. Document what happened

## Checking ArgoCD Status

```bash
# Get app status
kubectl get app -n argocd <app-name>

# See detailed sync status
kubectl describe app -n argocd <app-name>

# View ArgoCD logs
kubectl logs -n argocd deployment/argocd-application-controller -f

# Access ArgoCD UI
https://argocd.stevegore.au
```

## Related Files

- ArgoCD apps: `argocd/*.yaml`
- Caddy Helm: `apps/caddy/`
- Homepage Helm: `apps/homepage/`
- Other apps: `apps/*/`
