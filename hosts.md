# SSH Hosts

## Local Network

| Host                   | Description          |
| ---------------------- | -------------------- |
| pico.local             | Pico (192.168.4.120) |
| `pi@raspberrypi.local` | Raspberry Pi (192.168.4.61) |

## Cloud / Remote Servers

| Host                  | Notes                                                                                              |
| --------------------- | -------------------------------------------------------------------------------------------------- |
| OKE cluster `homelab` | `KUBECONFIG=~/.kube/oke-homelab.config kubectl get nodes` (home-IP only; details in oracle-cloud.md) |

---

## Server Details

### pico (192.168.4.120 / 10.20.30.1)

**Hardware:** ASRock B550M-ITX/ac (Mini-ITX desktop), AMD Ryzen 5 5600G (6c/12t, integrated Radeon), 30 GB RAM
**OS:** Ubuntu 24.04.4 LTS (kernel 6.8.0-107-generic), x86-64
**Storage:**
- `/` — 456 GB LVM (`/dev/mapper/ubuntu--vg-ubuntu--lv`), ~82% full
- `/media/m2` — 3.6 TB NVMe, ~47% used

**Purpose:** Home server running Home Assistant and Docker services

**Key Services:**

- **Home Assistant** — **HA Container** via `docker compose` (migrated from Supervised 2026-08-01)
  - Stack: `/opt/ha-container` (`homeassistant-app`, `homeassistant-db`, `homeassistant-matter`)
  - Config: `/opt/ha-container/config/`
  - DB: own MariaDB 11 container on `127.0.0.1:3307` (data in `/opt/ha-container/dbdata`)
  - External access: `hass2.stevegore.au` (Cloudflare Tunnel, direct) and `hass.stevegore.au` (via Tailscale egress in OKE → Caddy → pico:8123)
  - `trusted_proxies` includes `10.0.0.0/8` (covers OKE pod CIDR) and `100.64.0.0/10` (Tailscale) so Caddy pods are trusted for X-Forwarded-For
  - Custom components: `tuya_local`, `eero` (new), `eero_tracker` (legacy — kept for now, `interval_seconds: 30` set to avoid scan overrun)
  - No Supervisor, no add-ons. Core upgrades are an image tag bump. See [`home-assistant.md`](home-assistant.md).
- **Tailscale** — `tailscaled.service`
  - Tailnet IP: `100.98.212.71` (also `fd7a:115c:a1e0::f039:d447`), MagicDNS `pico.chipmunk-fir.ts.net`
  - Hostname in admin: `pico`
  - `--accept-routes` enabled (receives `10.0.1.0/24` OCI subnet route from `oke-connector` for MySQL HeatWave access)
  - Subnet routes: `192.168.4.0/24` can be advertised if OKE ever needs to reach home LAN devices (not currently required)
- **Cloudflare Tunnel** — `cloudflared.service`, exposes HA at `hass2.stevegore.au`
- **Docker services** — managed via Portainer (`port.stevegore.au`)
- **Stats Server** — Python HTTP server (systemd `stats-server.service`)
  - Port: 8001 (HTTP)
  - Endpoints:
    - `/` — HTML dashboard with real-time resource metrics (pico disk, memory, CPU)
    - `/api/stats` — JSON API returning pico + OKE cluster stats
  - Public access: `https://stats.stevegore.au` (via Caddy reverse proxy)
  - Dashboard integration: embedded as iframe widget in `https://homepage.stevegore.au`
  - Deployment: `~/code/infra/scripts/stats-server.py` + systemd service
  - See `scripts/STATS_SERVER.md` for setup and troubleshooting

**Network:**

| Interface  | Address                                       | DNS                         |
| ---------- | --------------------------------------------- | --------------------------- |
| enp3s0     | 192.168.4.120                                 | 192.168.4.1 (router)        |
| tailscale0 | 100.98.212.71 / fd7a:115c:a1e0::f039:d447     | 100.100.100.100 (MagicDNS)  |

**Resource Usage (current):**

| Resource | Total | Used | Available | % Used |
|----------|-------|------|-----------|--------|
| RAM | 30 GB | 9.7 GB | 21 GB available | 32% |
| CPU | 12 cores | varies | idle most of time | <20% sustained |
| `/` root | 456 GB | 384 GB | 52 GB | **89%** |
| `/media/m2` NVMe | 3.6 TB | 1.7 TB | 1.8 TB | 50% |

**Storage Alert:** Root filesystem at 89% — consider cleanup:
- Docker images: `docker image prune`
- Unused volumes: `docker volume prune`
- Duplicati backups: check `/var/lib/docker/volumes/` size
- Home Assistant: recorder DB is MariaDB at `/opt/ha-container/dbdata` (~316 MB). Also
  `/usr/share/hassio/homeassistant/home-assistant_v2.db.corrupt.2024-09-21…` — a **714 MB
  orphaned corrupt DB** from 2024, safe to delete
- Old Supervised install `/usr/share/hassio` — kept for rollback since 2026-08-01, can go once confident

**Monitoring & Observability:**

| Component | Purpose | Access | Status |
|-----------|---------|--------|--------|
| Stats Server | Real-time resource metrics (disk, memory, CPU, OKE cluster) | `https://stats.stevegore.au` | ✅ Running on pico:8001 |
| Homepage Dashboard | Live stats widget (embedded iframe) | `https://homepage.stevegore.au` | ✅ Integrated via Caddy |
| Uptime Kuma | Service health monitoring | `https://uptime.stevegore.au` | ✅ OKE cluster |
| Home Assistant | Smart home platform + history | `https://hass.stevegore.au` | ✅ pico:8123 |

**Stats Server Details:**
- Deployed as: systemd service (`stats-server.service`) on pico
- Port: 8001 (HTTP)
- Metrics provided:
  - **Pico**: root disk (`/`), media disk (`/media/m2`), RAM, CPU cores
  - **OKE cluster**: node status, capacity (OCPU/GB), version
- JSON endpoint: `/api/stats` (for API integrations)
- HTML dashboard: `/` (styled with color-coded resource alerts)
- Color coding: ⚠️ orange >70%, 🔴 red >85%
- Refresh: real-time (no caching, queries on each request)
- Public access: via Caddy reverse proxy at `https://stats.stevegore.au`

**OCI CLI & Kubeconfig Setup (on pico):**
- **OCI CLI**: installed via pipx (available at `~/.local/bin/oci`)
- **OCI credentials**: copied from local machine (`~/.oci/config`, `~/oci.pem`)
- **Kubeconfig**: generated via `oci ce cluster create-kubeconfig` command
- **Kubectl wrapper**: custom shell script (`~/code/infra/scripts/kubectl-wrapper.sh`) that provides PATH for oci credential plugin
- **Setup**: automated via `bash ~/code/infra/scripts/setup-pico-stats.sh`

See `scripts/STATS_SERVER.md` for detailed setup and troubleshooting.

---

---

### OKE Cluster `homelab`

**KUBECONFIG:** `~/.kube/oke-homelab.config`  
**Access:** `export KUBECONFIG=~/.kube/oke-homelab.config` (or set per-command)  
**Nodes:** 2× ARM workers across 2 fault domains (AD-1 FD-1, AD-1 FD-2)  
**NLB public IP:** `159.13.44.68` (reserved, survives NLB recreation, defined in `terraform/nlb.tf`)

**Namespaces and key workloads:**

| Namespace          | Workload                        | Notes                                      |
| ------------------ | ------------------------------- | ------------------------------------------ |
| caddy              | Caddy (2 replicas)              | NLB → Caddy; DNS-01 ACME via Cloudflare; certmagic-s3 on OCI Object Storage. Stateless auth (Authentik forward_auth) so HA across both fault domains (see dns.md). |
| authentik          | Authentik IdP                   | GitHub-federated SSO + domain-level forward-auth outpost for `*.stevegore.au`; Postgres on `pg-shared`, no Redis (2026.5 is Postgres-backed). `auth.stevegore.au` |
| cloudnative-pg     | CloudNativePG operator          | Cluster-wide Postgres operator (CRDs + controller); apps declare Cluster/Database CRs |
| databases          | `pg-shared` Postgres (CNPG)     | Shared PG16 instance on 50 GB `oci-bv`; WAL backups to OCI Object Storage; hosts the `authentik` DB |
| argocd             | ArgoCD                          | `--insecure` mode (Caddy terminates TLS); Git source: `stevegore/infra` |
| vault              | HashiCorp Vault                 | OCI KMS auto-unseal; VSO syncs secrets to k8s |
| vault-secrets-operator | VSO                        | Syncs Vault secrets → k8s Secrets          |
| metrics-server     | metrics-server                  | `kubectl top` / HPA metrics (`--kubelet-insecure-tls`) |
| vaultwarden        | Vaultwarden 1.35.7              | Primary at `bw.stevegore.au`; MySQL HeatWave Free backend (`/data` is `emptyDir`) |
| homepage           | Homepage dashboard              | Gated by Authentik forward-auth            |
| tailscale          | Tailscale operator              | Manages Egress Service for pico reachability |
| garmin-mcp         | Garmin MCP server               | Garmin Connect data for Claude (remote MCP connector); secret-path URL via Caddy at `garmin.stevegore.au`; tokens on `oci-bv` PVC (see `apps/garmin-mcp/README.md`) |

**Useful commands:**

```bash
export KUBECONFIG=~/.kube/oke-homelab.config
kubectl get nodes
kubectl get pods -A
kubectl get pods -n caddy
kubectl logs -n caddy -l app.kubernetes.io/name=caddy -f
# Force VSO secret resync:
kubectl annotate -n caddy vaultstaticsecret caddy-config \
  vault.hashicorp.com/requestID=$(date +%s) --overwrite
```
