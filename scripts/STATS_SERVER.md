# Stats Server Deployment

Real-time resource monitoring for pico and OKE cluster, exposed at https://stats.stevegore.au.

## Installation

### Prerequisites

- Python 3.8+
- systemd (already available on Ubuntu)
- `pipx` for OCI CLI installation (already available)
- `kubectl` binary (downloaded during initial setup)
- OCI credentials for API access (from Vault)
- Access to `sudo` for service installation

### Quick Setup (on pico)

```bash
bash ~/code/infra/scripts/setup-pico-stats.sh
```

This automated script:
- Installs systemd service
- Starts the service
- Verifies all endpoints
- Tests OKE cluster access

### Manual Setup

#### 1. Install OCI CLI (one-time)

```bash
pipx install oci-cli
# Adds ~/.local/bin to PATH in ~/.bashrc and ~/.zshrc
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.bashrc
```

#### 2. Setup OCI Credentials (one-time)

Copy from local machine:
```bash
# From your local machine
scp ~/.oci/config steve@pico.local:~/.oci/
scp ~/oci.pem steve@pico.local:~/
```

On pico:
```bash
chmod 600 ~/.oci/config ~/.oci/config.lock
chmod 600 ~/oci.pem
```

#### 3. Generate Kubeconfig (one-time)

```bash
mkdir -p ~/.kube
oci ce cluster create-kubeconfig \
  --cluster-id ocid1.cluster.oc1.ap-sydney-1.aaaaaaaaok3ygaxxoaf3vlwoytcnift4yxrmr4dmd75be53iocfghlpevogq \
  --file ~/.kube/oke-homelab.config \
  --region ap-sydney-1 \
  --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT
```

Verify:
```bash
export KUBECONFIG=~/.kube/oke-homelab.config
/home/steve/kubectl get nodes
```

#### 4. Install Systemd Service (on pico)

```bash
sudo cp ~/code/infra/scripts/stats-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable stats-server
sudo systemctl start stats-server
```

#### 5. Verify Installation

```bash
# Check service status
sudo systemctl status stats-server

# Test endpoints
curl http://localhost:8001/
curl http://localhost:8001/api/stats | jq
```

## Accessing the Stats

- **HTML Dashboard**: https://stats.stevegore.au
- **JSON API**: `https://stats.stevegore.au/api/stats`
- **Local (pico)**: `http://localhost:8001/` or `http://pico.local:8001/`

## Metrics Provided

### Pico Stats
- Root disk (/) usage and capacity
- Media disk (/media/m2) usage and capacity
- RAM usage and capacity
- CPU core count

### OKE Cluster Stats
- Cluster status and version
- Node count and status
- Total CPU and memory capacity
- Per-node details (name, status, capacity)

## Monitoring in Homepage

The stats server is exposed as an iframe widget in https://homepage.stevegore.au. The widget displays the full HTML dashboard.

## Troubleshooting

### Service not starting
```bash
sudo journalctl -u stats-server -f
```

### Connection refused
Check firewall and ensure port 8000 is accessible:
```bash
sudo ss -tlnp | grep 8000
```

### OKE Cluster Monitoring

The stats server includes OKE cluster metrics (node status, capacity, version) when properly configured with:
- OCI CLI (`oci-cli` package installed via pipx)
- OCI credentials (`~/.oci/config` and `~/oci.pem`)
- Kubeconfig (`~/.kube/oke-homelab.config` generated via `oci ce cluster create-kubeconfig`)
- Kubectl wrapper script (`~/code/infra/scripts/kubectl-wrapper.sh`) that provides PATH for oci credential plugin

All of these are set up automatically by the `setup-pico-stats.sh` script.

**If OKE stats show "unavailable":**

1. Verify kubeconfig exists:
   ```bash
   ls -la ~/.kube/oke-homelab.config
   ```

2. Test kubectl access:
   ```bash
   export KUBECONFIG=~/.kube/oke-homelab.config
   /home/steve/kubectl get nodes
   ```

3. Verify oci CLI is in PATH:
   ```bash
   which oci
   ~/.local/bin/oci --version
   ```

4. Check service logs:
   ```bash
   sudo journalctl -u stats-server -n 30
   ```

## Updates

To update the stats server:
1. Edit `~/code/infra/scripts/stats-server.py`
2. Restart the service:
   ```bash
   sudo systemctl restart stats-server
   ```
