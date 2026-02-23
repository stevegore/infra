# SSH Hosts

## Local Network

| Host                   | Description                                                 |
| ---------------------- | ----------------------------------------------------------- |
| pico.local             | Raspberry Pi Pico (192.168.4.120)                           |
| pico-wg                | Pico via WireGuard (10.20.30.1 via ProxyJump ampere-ubuntu) |
| `pi@raspberrypi.local` | Raspberry Pi (192.168.4.61)                                 |

## WireGuard Network (10.20.30.x)

| Host              | Notes                                                    |
| ----------------- | -------------------------------------------------------- |
| steve@10.20.30.1  | pico, reachable via ProxyJump through .2 (ampere-ubuntu) |
| ubuntu@10.20.30.2 | ampere-ubuntu (WireGuard hub)                            |

## Cloud / Remote Servers

| Host                   | Notes                        |
| ---------------------- | ---------------------------- |
| ubuntu@158.178.136.162 | Oracle Cloud (ampere-ubuntu) |

---

## Server Details

### pico (192.168.4.120 / 10.20.30.1)

**Purpose:** Home server running Home Assistant (supervised) and Docker services

**Key Services:**

- **Home Assistant** — supervised install via Hassio
  - Config: `/usr/share/hassio/homeassistant/`
  - DB: MariaDB addon (`core-mariadb`)
  - External access: `hass2.stevegore.au` (Cloudflare Tunnel, direct) and `hass.stevegore.au` (via WireGuard → Caddy)
  - Custom components: `tuya_local`, `eero` (new), `eero_tracker` (legacy — kept for now, `interval_seconds: 30` set to avoid scan overrun)
- **WireGuard** — 10.20.30.1/32, managed by `wg-quick@wg0.service`
  - Config: `/etc/wireguard/wg0.conf`
  - PersistentKeepalive = 25 (to ampere-ubuntu peer)
  - No ListenPort set — uses ephemeral port (seen by ampere as 159.196.97.38:PORT)
- **Cloudflare Tunnel** — `cloudflared.service`, exposes HA at `hass2.stevegore.au`
- **Docker services** — managed via Portainer (`port.stevegore.au`)

**Network:**

| Interface | Address         | DNS                          |
| --------- | --------------- | ---------------------------- |
| enp3s0    | 192.168.4.120   | 192.168.4.1 (router)         |
| wg0       | 10.20.30.1/32   | 10.20.30.2 (~10.20.30.0/24)  |

**Resolved issues (for reference):**
- `openvpn@yourvpn.service` — disabled (config file never existed; was restart-looping)
- Firefox snap AppArmor denials for `/proc/pressure/memory` — fixed
- `/etc/netplan/00-installer-config.yaml` and `/etc/NetworkManager/system-connections/default` — permissions set to 600

---

### ampere-ubuntu (158.178.136.162)

**Purpose:** ARM-based server running WireGuard VPN hub, Caddy reverse proxy, and MicroK8s (ArgoCD)

**Key Services:**

- **WireGuard VPN** - Network hub (10.20.30.2)
  - Config: `/etc/wireguard/wg0.conf`
  - Peers: 10.20.30.1 (pico), 10.20.30.3 (laptop)
  - Public key: `h8oS9EjhkNFq5hgX5MFYS9a9ZyhwlKgrWpidFsqZzRs=`
- **Caddy** - Reverse proxy with HTTPS & GitHub OAuth authentication
  - Config: `/etc/caddy/Caddyfile`
  - Env file: `/etc/caddy/caddy.env`
  - Log: `/var/lib/caddy/caddy.log`
  - Built with `xcaddy` + `caddy-security` plugin
- **MicroK8s** - Single-node Kubernetes cluster
  - Addons: (core addons only, ingress/metallb/cert-manager removed)
  - kubelite process handles all k8s components
- **ArgoCD** - GitOps continuous delivery
  - Namespace: `argocd`
  - UI: <https://argocd.stevegore.au> (proxied by Caddy → NodePort 32392)
  - gRPC: grpc.argocd.stevegore.au (proxied by Caddy → NodePort 30481)
  - CLI: `/usr/local/bin/argo`
- **Calico** - Container networking

**Domains proxied (via Caddy → 10.20.30.1 pico):**

| Domain                 | Backend     | Description                   |
| ---------------------- | ----------- | ----------------------------- |
| auth.stevegore.au      | -           | GitHub OAuth portal           |
| hass.stevegore.au      | :8123       | Home Assistant                |
| desk.stevegore.au      | :8111       | (protected)                   |
| gym.stevegore.au       | :8112       | (protected)                   |
| plex.stevegore.au      | :32400      | Plex Media Server             |
| photos.stevegore.au    | :2342       | PhotoPrism                    |
| port.stevegore.au      | :9000       | Portainer                     |
| huggin.stevegore.au    | :3000       | Huginn                        |
| ~~vault.stevegore.au~~ | ~~:8202~~   | ~~Vault~~ (moved to MicroK8s) |
| pdf.stevegore.au       | :8083       | Stirling PDF                  |
| strava.stevegore.au    | :8180       | Stravakeeper                  |
| bw.stevegore.au        | :8081/:3012 | Bitwarden/Vaultwarden         |
| stevegore.au           | :8788       | Main site                     |

**Domains proxied (local to ampere-ubuntu):**

| Domain                   | Backend         | Description                           |
| ------------------------ | --------------- | ------------------------------------- |
| argocd.stevegore.au      | localhost:32392 | ArgoCD UI                             |
| grpc.argocd.stevegore.au | localhost:30481 | ArgoCD gRPC                           |
| vault.stevegore.au       | localhost:30820 | HashiCorp Vault (OCI KMS auto-unseal) |
| healthz.stevegore.au     | -               | Health check                          |

**MicroK8s Namespaces:**

- kube-system, kube-public, kube-node-lease, default
- argocd
- vault

**Useful Commands:**

```bash
alias k='microk8s kubectl'
microk8s status          # Check cluster status
k get pods -n argocd     # ArgoCD pods
k get svc -n argocd      # ArgoCD services (NodePort)
```
