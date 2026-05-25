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
- **Local (pico)**: `http://localhost:8000/`

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

### kubectl timeouts
The `get_oke_stats()` function requires:
- KUBECONFIG set to `~/.kube/oke-homelab.config`
- Cluster API accessible from pico (via Tailscale)

If stats show "unreachable", check OKE cluster status:
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
