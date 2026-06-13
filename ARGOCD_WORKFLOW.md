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

### 4. Sync happens automatically

Pushing to `main` is enough. Two mechanisms converge:

- **ArgoCD auto-sync** — every app has `syncPolicy.automated` (`selfHeal` +
  `prune`, see `argocd/applicationset.yaml`), so ArgoCD reconciles on its own
  within ~3 min of the git poll.
- **GitHub Actions** (`.github/workflows/argocd-sync.yml`) — on every push to
  `main` touching `apps/**`, it triggers an **immediate** `argocd app sync` for
  the changed apps and waits for them to go Healthy, so you don't wait for the
  poll. It authenticates as the `ci-github-actions` API account.

You normally don't need to do anything after `git push`. Watch the run under the
repo's **Actions** tab, or:

```bash
gh run watch        # from a clone of the repo
```

**Manual fallback** (CI down, or you want to force it from a shell):

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

#### One-time CI setup

The Action needs an ArgoCD token stored as the `ARGOCD_AUTH_TOKEN` repo secret.
The `ci-github-actions` account (`apps/argocd/templates/argocd-cm.yaml`) and its
sync-only RBAC (`apps/argocd/templates/argocd-rbac-cm.yaml`) are already in the
repo; once they're synced, mint and store the token:

```bash
argocd login argocd.stevegore.au --sso --grpc-web
argocd account generate-token --account ci-github-actions \
  | gh secret set ARGOCD_AUTH_TOKEN --repo stevegore/infra
```

`--grpc-web` is required because Caddy terminates TLS and proxies HTTP/1.1.
Trigger any app manually with `gh workflow run argocd-sync.yml -f app=<name>`
(or `-f app=all`).

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
