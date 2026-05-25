# Stats Server Deployment

Real-time resource monitoring for pico and OKE cluster, exposed at https://stats.stevegore.au.

## Installation

### Prerequisites

- Python 3.8+
- systemd (already available on Ubuntu)
- Access to `sudo` for service installation

### Setup

1. Copy the script to a location on pico:
   ```bash
   # Already in ~/code/infra/scripts/stats-server.py
   ```

2. Install the systemd service:
   ```bash
   sudo cp ~/code/infra/scripts/stats-server.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable stats-server
   sudo systemctl start stats-server
   ```

3. Verify it's running:
   ```bash
   sudo systemctl status stats-server
   curl http://localhost:8000/
   curl http://localhost:8000/api/stats
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

### OKE Cluster Stats (Optional Setup)

The `get_oke_stats()` function requires:
- `kubectl` binary installed on pico (already done)
- KUBECONFIG at `~/.kube/oke-homelab.config` (requires manual setup)
- Cluster API accessible from pico (via Tailscale)

To enable OKE monitoring, copy the kubeconfig from this machine:
```bash
scp ~/.kube/oke-homelab.config steve@pico.local:~/.kube/
ssh steve@pico.local "chmod 600 ~/.kube/oke-homelab.config"
```

Then verify:
```bash
ssh steve@pico.local "~/.kube/oke-homelab.config kubectl get nodes"
```

If OKE stats show "unavailable", check:
```bash
export KUBECONFIG=~/.kube/oke-homelab.config
kubectl get nodes
```

## Updates

To update the stats server:
1. Edit `~/code/infra/scripts/stats-server.py`
2. Restart the service:
   ```bash
   sudo systemctl restart stats-server
   ```
