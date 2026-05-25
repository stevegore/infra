# SSH Hosts

## Local Network

| Host                   | Description                                                 |
| ---------------------- | ----------------------------------------------------------- |
| pico.local             | Pico (192.168.4.120)                           |
| pico-wg                | Pico via WireGuard (10.20.30.1 via ProxyJump ampere-ubuntu) |
| `pi@raspberrypi.local` | Raspberry Pi (192.168.4.61)                                 |

## WireGuard Network (10.20.30.x)

| Host              | Notes                                                    |
| ----------------- | -------------------------------------------------------- |
| steve@10.20.30.1  | pico, reachable via ProxyJump through .2 (ampere-ubuntu) |
| ubuntu@10.20.30.2 | ampere-ubuntu (WireGuard hub)                            |

## Cloud / Remote Servers

| Host                   | Notes                                                                                              |
| ---------------------- | -------------------------------------------------------------------------------------------------- |
| ubuntu@158.178.136.162 | Oracle Cloud (ampere-ubuntu) — being decommissioned in Phase 7 of the OKE migration                |
| OKE cluster `homelab`  | `KUBECONFIG=~/.kube/oke-homelab.config kubectl get nodes` (home-IP only; details in oracle-cloud.md) |

---

## Server Details

### pico (192.168.4.120 / 10.20.30.1)

**Hardware:** ASRock B550M-ITX/ac (Mini-ITX desktop), AMD Ryzen 5 5600G (6c/12t, integrated Radeon), 30 GB RAM
**OS:** Ubuntu 24.04.4 LTS (kernel 6.8.0-107-generic), x86-64
**Storage:**
- `/` — 456 GB LVM (`/dev/mapper/ubuntu--vg-ubuntu--lv`), ~82% full
- `/media/m2` — 3.6 TB NVMe, ~47% used

**Purpose:** Home server running Home Assistant (supervised) and Docker services

**Key Services:**

- **Home Assistant** — supervised install via Hassio
  - Config: `/usr/share/hassio/homeassistant/`
  - DB: MariaDB addon (`core-mariadb`)
  - External access: `hass2.stevegore.au` (Cloudflare Tunnel, direct) and `hass.stevegore.au` (via Tailscale egress in OKE → Caddy → pico:8123)
  - `trusted_proxies` includes `10.244.0.0/16` (OKE pod CIDR) so Caddy pods are trusted for X-Forwarded-For
  - Custom components: `tuya_local`, `eero` (new), `eero_tracker` (legacy — kept for now, `interval_seconds: 30` set to avoid scan overrun)
- **WireGuard** — 10.20.30.1/32, managed by `wg-quick@wg0.service`
  - Config: `/etc/wireguard/wg0.conf`
  - PersistentKeepalive = 25 (to ampere-ubuntu peer)
  - No ListenPort set — uses ephemeral port (seen by ampere as 159.196.97.38:PORT)
  - Being replaced by Tailscale (below) per [architecture-proposal.md](architecture-proposal.md) §5.3
- **Tailscale** — `tailscaled.service`, joined 2026-05-24
  - Tailnet IP: `100.98.212.71` (also `fd7a:115c:a1e0::f039:d447`), MagicDNS `pico.chipmunk-fir.ts.net`
  - Hostname in admin: `pico`
  - Subnet routes: `10.20.30.0/24` + `192.168.4.0/24` can be advertised if needed for OKE access to home LAN devices (currently not required)
- **Cloudflare Tunnel** — `cloudflared.service`, exposes HA at `hass2.stevegore.au`
- **Docker services** — managed via Portainer (`port.stevegore.au`)

**Network:**

| Interface  | Address                                       | DNS                          |
| ---------- | --------------------------------------------- | ---------------------------- |
| enp3s0     | 192.168.4.120                                 | 192.168.4.1 (router)         |
| wg0        | 10.20.30.1/32                                 | 10.20.30.2 (~10.20.30.0/24)  |
| tailscale0 | 100.98.212.71 / fd7a:115c:a1e0::f039:d447     | 100.100.100.100 (MagicDNS)   |

---

### ampere-ubuntu (158.178.136.162)

**Purpose:** ARM-based server retained as WireGuard VPN hub. Caddy and ArgoCD have moved to OKE. Being decommissioned per the OKE migration plan.

**Key Services (remaining):**

- **WireGuard VPN** - Network hub (10.20.30.2)
  - Config: `/etc/wireguard/wg0.conf`
  - Peers: 10.20.30.1 (pico), 10.20.30.3 (laptop)
  - Public key: `h8oS9EjhkNFq5hgX5MFYS9a9ZyhwlKgrWpidFsqZzRs=`
- **fail2ban** - SSH brute-force protection
  - Config: `/etc/fail2ban/jail.local`
  - `sudo fail2ban-client status sshd` to check banned IPs

**Migrated to OKE (no longer on ampere-ubuntu):**
- Caddy → OKE `caddy` namespace (NLB IP 159.13.44.68)
- ArgoCD → OKE `argocd` namespace
- Vault → OKE `vault` namespace
- Vaultwarden → OKE `vaultwarden` namespace

---

### OKE Cluster `homelab`

**KUBECONFIG:** `~/.kube/oke-homelab.config`  
**Access:** `export KUBECONFIG=~/.kube/oke-homelab.config` (or set per-command)  
**Nodes:** 2× ARM workers across 2 fault domains (AD-1 FD-1, AD-1 FD-2)  
**NLB public IP:** `159.13.44.68` (reserved, survives NLB recreation, defined in `terraform/nlb.tf`)

**Namespaces and key workloads:**

| Namespace          | Workload                        | Notes                                      |
| ------------------ | ------------------------------- | ------------------------------------------ |
| caddy              | Caddy (2 replicas)              | NLB → Caddy; DNS-01 ACME via Cloudflare; certmagic-s3 on OCI Object Storage |
| argocd             | ArgoCD                          | `--insecure` mode (Caddy terminates TLS); Git source: `stevegore/infra` |
| vault              | HashiCorp Vault                 | OCI KMS auto-unseal; VSO syncs secrets to k8s |
| vault-secrets-operator | VSO                        | Syncs Vault secrets → k8s Secrets          |
| vaultwarden        | Vaultwarden                     | Password manager                           |
| homepage           | Homepage dashboard              | Protected by caddy-security `adminonly`    |
| openclaw           | OpenClaw                        |                                            |
| tailscale          | Tailscale operator              | Manages Egress Service for pico reachability |

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
