# DNS Configuration

## Domain: stevegore.au

**Registrar:** GoDaddy (original nameservers: ns13/14.domaincontrol.com)  
**DNS Provider:** Cloudflare (Free plan)  
**Nameservers:** adi.ns.cloudflare.com, terry.ns.cloudflare.com  
**Zone ID:** `34fb9dbe54bc48a889c22bfcd442bc50`  
**Account:** Steve Gore (`2282093ab76f6c3932ec3fc3bcb67276`)

---

## DNS Records

### A Records

| Name                     | Value         | Proxied | Notes                                       |
| ------------------------ | ------------- | ------- | ------------------------------------------- |
| stevegore.au             | 159.13.44.68  | No      | Root domain → OKE NLB (Caddy)               |
| *.stevegore.au           | 159.13.44.68  | No      | Wildcard → OKE NLB (Caddy)                  |
| argocd.stevegore.au      | 159.13.44.68  | No      | → OKE NLB (Caddy → ArgoCD in-cluster)       |
| grpc.argocd.stevegore.au | 159.13.44.68  | No      | → OKE NLB (Caddy → ArgoCD gRPC in-cluster)  |

`uptime.stevegore.au` is covered by the wildcard `*.stevegore.au` A record, so no separate Cloudflare DNS record is required unless we later want host-specific proxy or TTL settings.

**Reserved IP:** `159.13.44.68` — OCI NLB reserved public IP (OCID in `terraform/nlb.tf`). Survives NLB recreation.

### CNAME Records

| Name                        | Target                                                | Proxied | Notes                                        |
| --------------------------- | ----------------------------------------------------- | ------- | -------------------------------------------- |
| `www.stevegore.au`          | stevegore.au                                          | No      | WWW redirect                                 |
| hass2.stevegore.au          | c7f990bb-9fba-4fc9-af4a-0eb509e99798.cfargotunnel.com | **Yes** | Cloudflare Tunnel → pico                     |
| bw2.stevegore.au            | c7f990bb-9fba-4fc9-af4a-0eb509e99798.cfargotunnel.com | **Yes** | Cloudflare Tunnel → pico Vaultwarden standby |
| autodiscover.stevegore.au   | autodiscover.outlook.com                              | No      | Outlook autodiscover                         |
| _domainconnect.stevegore.au | _domainconnect.gd.domaincontrol.com                   | No      | GoDaddy domain connect                       |

### Mail Records

| Type | Name                  | Value                           | Priority |
| ---- | --------------------- | ------------------------------- | -------- |
| MX   | stevegore.au          | 171177469.pamx1.hotmail.com     | 0        |
| TXT  | stevegore.au          | v=spf1 include:outlook.com -all | -        |
| TXT  | _outlook.stevegore.au | 171177469                       | -        |

---

## Traffic Flow

```text
Internet
    │
    ├─── *.stevegore.au ──────────► 159.13.44.68 (OCI NLB, reserved IP)
    │                                    │
    │                                    └─► Caddy (OKE Deployment, 2 replicas)
    │                                            │
    │                                            ├─► In-cluster services (ClusterIP)
    │                                            │       ├─► argocd-server.argocd:80
    │                                            │       ├─► vault.vault:8200
    │                                            │       ├─► vaultwarden.vaultwarden:80
    │                                            │       ├─► homepage.homepage:3000
    │                                            │       ├─► uptime-kuma.uptime-kuma:3001
    │                                            │       ├─► headlamp.headlamp:80
    │                                            │       └─► openclaw.openclaw:18789
    │                                            │
    │                                            └─► pico (via Tailscale Egress Service)
    │                                                    │  (Tailscale operator proxy pod
    │                                                    │   `pico` ExternalName svc → tailnet)
    │                                                    └─► Docker services on pico
    │                                                            ├─► :8123 Home Assistant
    │                                                            ├─► :8788 ttyd
    │                                                            ├─► :32400 Plex
    │                                                            └─► ... (all pico ports)
    │
    └─── hass2.stevegore.au / bw2.stevegore.au ─► Cloudflare Tunnel
                                                   │
                                                   └─► pico (direct)
```

**ACME certificates:** DNS-01 challenge via Cloudflare (token in Vault at `kv/caddy/config → cf_api_token`). Cert state shared across Caddy replicas via OCI Object Storage (`caddy-acme` bucket, S3-compat endpoint). Let's Encrypt only; ZeroSSL fallback disabled.

**NLB backend policy:** `THREE_TUPLE` (src IP / dst IP / proto), set via `oci-network-load-balancer.oraclecloud.com/backend-policy` on the caddy Service. Default `FIVE_TUPLE` hashes the source port too, so a single browser's TCP connections fan out across both caddy pods — that breaks caddy-security's in-process OAuth flow state (AUTHP_SESSION_ID → redirect_url), leaving users stuck on `auth.stevegore.au` after a successful GitHub login. THREE_TUPLE pins a client IP to one node, and pod anti-affinity makes that the same pod for every connection.

---

## Cloudflare Tunnel

**Name:** pico  
**ID:** `c7f990bb-9fba-4fc9-af4a-0eb509e99798`  
**Status:** Healthy  
**Origin IP:** 159.196.97.38 (home IP)  
**Client Version:** 2023.8.2  
**Connections:** 4 active (syd06 x2, bne01 x2)

**Usage:** Direct access to Home Assistant via `hass2.stevegore.au` and Vaultwarden standby via `bw2.stevegore.au` without going through WireGuard/Caddy

---

## WireGuard Mesh Network

**Hub:** ampere-ubuntu (158.178.136.162)
**Interface:** wg0
**Listen Port:** 51820
**Network:** 10.20.30.0/24
**Hub Public Key:** `h8oS9EjhkNFq5hgX5MFYS9a9ZyhwlKgrWpidFsqZzRs=`

### Peers

| IP         | Endpoint              | Description         |
| ---------- | --------------------- | ------------------- |
| 10.20.30.1 | 159.196.97.38:44126   | pico (home server)  |
| 10.20.30.2 | 158.178.136.162:51820 | ampere-ubuntu (hub) |
| 10.20.30.3 | 159.196.97.38:56998   | Laptop (macOS)      |

---

## Local DNS Configuration

### ampere-ubuntu (10.20.30.2) — DNS Server

systemd-resolved stub listener bound to the WireGuard IP via drop-in config.

**Config:** `/etc/systemd/resolved.conf.d/wireguard-dns.conf`
```ini
[Resolve]
DNSStubListenerExtra=10.20.30.2
```

**`/etc/hosts` WireGuard entries** (served to peers via `ReadEtcHosts=yes`):
```
10.20.30.1 pico
10.20.30.2 ampere-ubuntu
10.20.30.3 laptop
```

**iptables rules** (persisted in `/etc/iptables/rules.v4`):
```
-A INPUT -i wg0 -s 10.20.30.0/24 -p udp --dport 53 -j ACCEPT
-A INPUT -i wg0 -s 10.20.30.0/24 -p tcp --dport 53 -j ACCEPT
```
These rules must sit before the blanket `REJECT` rule. The OCI Security List does **not** need port 53 open — DNS queries travel inside the WireGuard tunnel (encrypted UDP to port 51820).

**Upstream DNS:** 169.254.169.254 (Oracle Cloud metadata DNS)

---

### Laptop (macOS)

**WireGuard Address:** 10.20.30.3/24

**Nameservers (via WireGuard):**

1. 192.168.4.1 (router)
2. 10.20.30.2 (ampere-ubuntu via WireGuard)
3. 192.168.0.1 (fallback)

### pico (10.20.30.1)

**DNS via:** systemd-resolved (stub resolver 127.0.0.53)

**Interface DNS:**

- enp3s0/wlp4s0: 192.168.4.1 (router)
- wg0: 10.20.30.2 (ampere-ubuntu) with domain `~10.20.30.0/24` (reverse DNS for WireGuard subnet only — not a default route)

**`/etc/wireguard/wg0.conf` DNS line:** `DNS = 10.20.30.2` (only the WireGuard DNS — 192.168.4.1 is already on enp3s0, adding it here is redundant)

**`/etc/hosts` WireGuard entries** (for fast forward lookups without DNS round-trip):
```
10.20.30.2 ampere-ubuntu ampere
10.20.30.3 laptop
```

> **Known boot behaviour:** systemd-resolved logs `Using degraded feature set TCP instead of UDP` for `10.20.30.2` for ~25 seconds after wg0 comes up, while WireGuard completes its first PersistentKeepalive handshake. This is transient and harmless.

---

## Service → Domain Mapping

All services proxied through Caddy on OKE (NLB → 159.13.44.68).

**In-cluster (OKE) services:**

| Domain                   | Backend (ClusterIP)                       | Auth     | Notes                            |
| ------------------------ | ----------------------------------------- | -------- | -------------------------------- |
| auth.stevegore.au        | —                                         | —        | GitHub OAuth portal (caddy-security) |
| healthz.stevegore.au     | —                                         | —        | Caddy `respond "OK"`             |
| argocd.stevegore.au      | argocd-server.argocd:80 (HTTP, insecure)  | ArgoCD   | ArgoCD in `--insecure` mode      |
| grpc.argocd.stevegore.au | argocd-server.argocd:80 (h2c)             | ArgoCD   | ArgoCD gRPC                      |
| vault.stevegore.au       | vault.vault:8200                          | Vault UI | Vault handles own auth           |
| bw.stevegore.au          | vaultwarden.vaultwarden:80 / :3012        | —        | Vaultwarden + WebSocket hub      |
| homepage.stevegore.au    | homepage.homepage:3000                    | adminonly| Homepage dashboard               |
| uptime.stevegore.au      | uptime-kuma.uptime-kuma:3001             | Uptime Kuma | Full UI + status page         |
| status.stevegore.au      | uptime-kuma.uptime-kuma:3001             | —        | Custom-domain alias for the `homelab` status page (cname row managed by `scripts/setup_status_page.py`) |
| headlamp.stevegore.au    | headlamp.headlamp:80                      | adminonly| Kubernetes web dashboard         |
| openclaw.stevegore.au    | openclaw.openclaw:18789                   | —        |                                  |

**Via Tailscale Egress Service to pico (`pico` ExternalName svc in caddy namespace):**

| Domain              | pico Port | Auth     | Service                        |
| ------------------- | --------- | -------- | ------------------------------ |
| stevegore.au        | 8788      | —        | ttyd web terminal              |
| hass.stevegore.au   | 8123      | —        | Home Assistant                 |
| desk.stevegore.au   | 8111      | adminonly| NuraSpace remote desktop       |
| gym.stevegore.au    | 8112      | adminonly| GymMaster                      |
| plex.stevegore.au   | 32400     | —        | Plex Media Server              |
| photos.stevegore.au        | 2283      | —        | Immich photo library (primary) |
| immich.stevegore.au        | 2283      | —        | Immich (alias)                 |
| photoprism.stevegore.au    | 2342      | —        | PhotoPrism                     |
| port.stevegore.au   | 9000      | —        | Portainer                      |
| huginn.stevegore.au | 3000      | —        | Huginn                         |
| pdf.stevegore.au    | 8083      | —        | Stirling PDF                   |
| strava.stevegore.au | 8180      | —        | Stravakeeper                   |
| stats.stevegore.au  | 8001      | —        | Stats server — public JSON + HTML dashboard (`scripts/STATS_SERVER.md`) |

**Direct access (not via Caddy):**

| Domain             | Target            | Service                      |
| ------------------ | ----------------- | ---------------------------- |
| hass2.stevegore.au | Cloudflare Tunnel | Home Assistant (backup)      |
| bw2.stevegore.au   | Cloudflare Tunnel | Vaultwarden (warm standby)   |
