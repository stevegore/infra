#!/bin/bash
# Setup pico stats server with OCI CLI and kubeconfig

set -e

echo "=== Pico Stats Server Setup ==="

# 1. Ensure systemd service is installed
echo "Installing systemd service..."
sudo cp ~/code/infra/scripts/stats-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable stats-server

# 2. Restart the service to pick up latest code and PATH
echo "Starting stats service..."
sudo systemctl restart stats-server

# 3. Verify it's running
echo "Verifying stats service..."
sleep 2
if sudo systemctl is-active --quiet stats-server; then
    echo "✅ Stats service is running"
else
    echo "❌ Stats service failed to start"
    sudo journalctl -u stats-server -n 20
    exit 1
fi

# 4. Test the endpoints
echo "Testing stats endpoints..."
if curl -s http://localhost:8001/api/stats > /dev/null 2>&1; then
    echo "✅ /api/stats endpoint working"
else
    echo "❌ /api/stats endpoint failed"
    exit 1
fi

if curl -s http://localhost:8001/ > /dev/null 2>&1; then
    echo "✅ HTML dashboard working"
else
    echo "❌ HTML dashboard failed"
    exit 1
fi

# 5. Verify OKE cluster access
echo "Verifying OKE cluster access..."
export KUBECONFIG=~/.kube/oke-homelab.config
if /home/steve/kubectl get nodes &>/dev/null; then
    echo "✅ Kubernetes cluster access working"
else
    echo "❌ Kubernetes cluster access failed"
    exit 1
fi

echo ""
echo "=== Setup Complete ==="
echo "Stats server is running on http://localhost:8001"
echo "Public access: https://stats.stevegore.au"
echo "API endpoint: https://stats.stevegore.au/api/stats"
echo "Homepage widget: https://homepage.stevegore.au"
