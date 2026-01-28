#!/bin/bash
# Bootstrap script for infra GitOps setup
# Run this once on ampere-ubuntu to configure ArgoCD ApplicationSet

set -euo pipefail

echo "=== Infra GitOps Bootstrap ==="

# Check if microk8s is available
if ! command -v microk8s &> /dev/null; then
    echo "Error: microk8s not found"
    exit 1
fi

# Alias for convenience
alias k='microk8s kubectl'

# Create vault namespace
echo "Creating vault namespace..."
microk8s kubectl create namespace vault --dry-run=client -o yaml | microk8s kubectl apply -f -

# Apply ApplicationSet
echo "Applying ApplicationSet..."
microk8s kubectl apply -f argocd/applicationset.yaml

echo ""
echo "=== Bootstrap Complete ==="
echo ""
echo "Next steps:"
echo "1. Push this repo to GitHub"
echo "2. ArgoCD will automatically sync applications from apps/*"
echo "3. Check status: https://argocd.stevegore.au"
echo ""
echo "To initialize Vault after deployment:"
echo "  microk8s kubectl exec -n vault vault-0 -- vault operator init"
