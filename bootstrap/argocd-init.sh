#!/usr/bin/env bash
# Bootstrap ArgoCD onto a freshly-provisioned OKE cluster.
#
# Run this once after Terraform/ORM has finished creating the cluster.
# ArgoCD manages itself and all other apps after this point — do not
# kubectl-apply individual workloads.
#
# Prerequisites:
#   - oci CLI configured (~/.oci/config + ~/oci.pem)
#     Fresh machine: source scripts/vault-env.sh && vlogin && bash scripts/restore-oci-creds.sh
#   - kubectl in PATH
#   - Vault accessible (export KUBECONFIG + vault login) for post-init cred provisioning
#
# What this script does:
#   1. Fetches kubeconfig from OCI
#   2. Installs ArgoCD from upstream manifests
#   3. Applies the infra-apps ApplicationSet (covers all apps/)
#   4. Provisions the OCIR pull secret
#   5. Prints Vault init instructions (first-install only)
#
# Idempotent — safe to re-run; each step skips itself if already done.

set -euo pipefail

OKE_CLUSTER_ID="ocid1.cluster.oc1.ap-sydney-1.aaaaaaaayyadaznxbxlzv7qz6drid3w3erh3yunv2zp7wdqzjclxsok2k6nq"
REGION="ap-sydney-1"
KUBECONFIG_PATH="$HOME/.kube/oke-homelab.config"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
skip() { printf '    \033[2m· %s\033[0m\n' "$*"; }

export KUBECONFIG="$KUBECONFIG_PATH"

for bin in oci kubectl; do
  command -v "$bin" >/dev/null || { echo "missing required tool: $bin"; exit 1; }
done

# ---------- 1. kubeconfig ----------
log "kubeconfig (${KUBECONFIG_PATH})"
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
oci ce cluster create-kubeconfig \
  --cluster-id "$OKE_CLUSTER_ID" \
  --file "$KUBECONFIG_PATH" \
  --region "$REGION" \
  --token-version 2.0.0
echo "✓ kubeconfig written"

# ---------- 2. ArgoCD ----------
log "ArgoCD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl get deploy -n argocd argocd-server >/dev/null 2>&1; then
  ARGOCD_VER=$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest | \
    grep '"tag_name"' | head -1 | cut -d'"' -f4)
  kubectl apply -n argocd \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VER}/manifests/install.yaml"
  echo "    waiting for argocd-server..."
  kubectl rollout status -n argocd deploy/argocd-server --timeout=5m
else
  skip "argocd-server already deployed"
fi

# Cilium generic-veth sees OKE/Flannel kubelet probes as traffic from cni0's
# 10.244.x bridge gateway, not as the host. The upstream policies correctly
# reject that source on restricted health ports. Keep the policies and move the
# affected probes to the same localhost endpoints from inside each container.
kubectl patch deployment argocd-repo-server -n argocd --type=strategic --patch '
spec:
  template:
    spec:
      containers:
        - name: argocd-repo-server
          readinessProbe:
            httpGet: null
            exec:
              command:
                - /usr/bin/bash
                - -ec
                - exec 3<>/dev/tcp/127.0.0.1/8084; printf "GET /healthz HTTP/1.0\r\n\r\n" >&3; read -r status <&3; [[ "$status" == *" 200 "* ]]
          livenessProbe:
            httpGet: null
            exec:
              command:
                - /usr/bin/bash
                - -ec
                - exec 3<>/dev/tcp/127.0.0.1/8084; printf "GET /healthz?full=true HTTP/1.0\r\n\r\n" >&3; read -r status <&3; [[ "$status" == *" 200 "* ]]
' >/dev/null

kubectl patch statefulset argocd-application-controller -n argocd --type=strategic --patch '
spec:
  template:
    spec:
      containers:
        - name: argocd-application-controller
          readinessProbe:
            httpGet: null
            exec:
              command:
                - /usr/bin/bash
                - -ec
                - exec 3<>/dev/tcp/127.0.0.1/8082; printf "GET /healthz HTTP/1.0\r\n\r\n" >&3; read -r status <&3; [[ "$status" == *" 200 "* ]]
' >/dev/null

kubectl patch deployment argocd-notifications-controller -n argocd --type=strategic --patch '
spec:
  template:
    spec:
      containers:
        - name: argocd-notifications-controller
          livenessProbe:
            tcpSocket: null
            exec:
              command:
                - /usr/bin/bash
                - -ec
                - exec 3<>/dev/tcp/127.0.0.1/9001
' >/dev/null
echo "✓ ArgoCD probes made Flannel/Cilium chaining-safe"

# ---------- 3. ApplicationSet ----------
log "ApplicationSet"
kubectl apply -f "${REPO_ROOT}/argocd/applicationset.yaml"
echo "✓ infra-apps ApplicationSet applied — ArgoCD will sync all apps"

# ---------- 4. OCIR pull secret ----------
# caddy/values.yaml references imagePullSecrets: [ocir-creds].
# VSO does NOT manage this secret — it must be created manually.
# The OCIR auth-token lives in Vault at kv/oci/ocir (minted by
# scripts/provision-ocir-creds.sh and stored there once).
log "OCIR pull secret (ocir-creds in caddy namespace)"
if kubectl get secret ocir-creds -n caddy >/dev/null 2>&1; then
  skip "ocir-creds already exists in caddy namespace"
else
  # The caddy namespace may not exist yet if ArgoCD hasn't synced.
  kubectl create namespace caddy --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true

  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    echo "    reading OCIR credentials from Vault..."
    OCIR_USER=$(vault kv get -field=username kv/oci/ocir 2>/dev/null)
    OCIR_TOKEN=$(vault kv get -field=auth_token kv/oci/ocir 2>/dev/null)
    if [[ -z "$OCIR_USER" || -z "$OCIR_TOKEN" ]]; then
      echo "    ERROR: kv/oci/ocir missing or empty — run scripts/provision-ocir-creds.sh first"
    else
      kubectl create secret docker-registry ocir-creds \
        -n caddy \
        --docker-server=syd.ocir.io \
        --docker-username="$OCIR_USER" \
        --docker-password="$OCIR_TOKEN" \
        --docker-email=steve.j.gore@gmail.com
      echo "✓ ocir-creds created in caddy namespace"
    fi
  else
    echo "    VAULT_TOKEN not set — after Vault is up, run:"
    echo "      export KUBECONFIG=$KUBECONFIG_PATH"
    echo "      source scripts/vault-env.sh && vlogin"
    echo "      bash bootstrap/argocd-init.sh   # idempotent, re-runs only missing steps"
  fi
fi

# ---------- 5. ArgoCD GitHub OAuth client secret ----------
# Dex needs dex.github.clientSecret in argocd-secret to authenticate via GitHub.
# VSO syncs kv/argocd → argocd-github-oauth, but VSO must be running first.
# Patching argocd-secret directly breaks the circular bootstrap dependency.
log "ArgoCD GitHub OAuth client secret"
EXISTING=$(kubectl get secret argocd-secret -n argocd \
  -o jsonpath='{.data.dex\.github\.clientSecret}' 2>/dev/null || true)
if [[ -n "$EXISTING" ]]; then
  skip "dex.github.clientSecret already set in argocd-secret"
elif [[ -n "${VAULT_TOKEN:-}" ]]; then
  GH_SECRET=$(vault kv get -field=github_client_secret kv/argocd 2>/dev/null || true)
  if [[ -z "$GH_SECRET" ]]; then
    echo "    ERROR: kv/argocd missing — store the GitHub OAuth client secret first:"
    echo "      vault kv put kv/argocd github_client_secret=<secret>"
  else
    kubectl patch secret argocd-secret -n argocd \
      --type=json \
      -p='[{"op":"add","path":"/data/dex.github.clientSecret","value":"'"$(echo -n "$GH_SECRET" | base64)"'"}]'
    echo "✓ dex.github.clientSecret patched into argocd-secret"
  fi
else
  echo "    VAULT_TOKEN not set — after Vault is up, run:"
  echo "      export KUBECONFIG=$KUBECONFIG_PATH"
  echo "      source scripts/vault-env.sh && vlogin"
  echo "      bash bootstrap/argocd-init.sh   # idempotent, re-runs only missing steps"
fi

# ---------- Done ----------
cat <<EOF

==================== ArgoCD bootstrap complete ====================

ArgoCD is now syncing all apps from GitHub. Monitor progress at:
  https://argocd.stevegore.au  (once Caddy is up and DNS resolves)

  Local: kubectl port-forward -n argocd svc/argocd-server 8080:80
         argocd login localhost:8080 --username admin --insecure
         argocd account update-password

Manual steps for a fresh cluster (skip if Vault already has prior data):

  1. Vault initialisation (first install only — OCI KMS auto-unseal):
       kubectl exec -n vault vault-0 -- vault operator init \\
         -recovery-shares=1 -recovery-threshold=1
     Save the recovery key somewhere safe (e.g. 1Password).

  2. Provision Caddy ACME Cloudflare creds after Vault is unsealed:
       source scripts/vault-env.sh && vlogin
       bash scripts/provision-caddy-acme-creds.sh
       bash scripts/publish-mysql-creds.sh

  3. Tailscale operator auth key must be set in Vault at kv/tailscale/authkey
     before the tailscale-operator app syncs cleanly.

EOF
