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

| Name                     | Value           | Proxied | Notes                                 |
| ------------------------ | --------------- | ------- | ------------------------------------- |
| stevegore.au             | 158.178.136.162 | No      | Root domain → ampere-ubuntu           |
| *.stevegore.au           | 158.178.136.162 | No      | Wildcard → ampere-ubuntu (Caddy)      |
| argocd.stevegore.au      | 158.178.136.162 | No      | → ampere-ubuntu (Caddy → MicroK8s)    |
| grpc.argocd.stevegore.au | 158.178.136.162 | No      | → ampere-ubuntu (Caddy → ArgoCD gRPC) |

### CNAME Records

| Name                        | Target                                                | Proxied | Notes                    |
| --------------------------- | ----------------------------------------------------- | ------- | ------------------------ |
| `www.stevegore.au`          | stevegore.au                                          | No      | WWW redirect             |
| hass2.stevegore.au          | c7f990bb-9fba-4fc9-af4a-0eb509e99798.cfargotunnel.com | **Yes** | Cloudflare Tunnel → pico |
| autodiscover.stevegore.au   | autodiscover.outlook.com                              | No      | Outlook autodiscover     |
| _domainconnect.stevegore.au | _domainconnect.gd.domaincontrol.com                   | No      | GoDaddy domain connect   |

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
    ├─── *.stevegore.au ──────────► 158.178.136.162 (ampere-ubuntu)
    │                                    │
    │                                    ├─► Caddy reverse proxy
    │                                    │       │
    │                                    │       ├─► WireGuard 10.20.30.2
    │                                    │       │       │
    │                                    │       │       └─► 10.20.30.1 (pico)
    │                                    │       │               └─► Docker services
    │                                    │       │
    │                                    │       └─► ArgoCD (localhost NodePort)
    │                                    │
    │                                    └─► MicroK8s (ArgoCD pods)
    │
    └─── hass2.stevegore.au ──────► Cloudflare Tunnel
                                         │
                                         └─► pico (direct, bypasses WireGuard)
```

---

## Cloudflare Tunnel

**Name:** pico  
**ID:** `c7f990bb-9fba-4fc9-af4a-0eb509e99798`  
**Status:** Healthy  
**Origin IP:** 159.196.97.38 (home IP)  
**Client Version:** 2023.8.2  
**Connections:** 4 active (syd06 x2, bne01 x2)

**Usage:** Direct access to Home Assistant via `hass2.stevegore.au` without going through WireGuard/Caddy

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
- wg0: 10.20.30.2 (ampere-ubuntu) with domain `~10.20.30.0/24`

---

## Service → Domain Mapping

All services below are proxied through Caddy on ampere-ubuntu:

**Via WireGuard to pico (10.20.30.1):**

| Domain              | Port  | Service               |
| ------------------- | ----- | --------------------- |
| stevegore.au        | 8788  | Main site (ttyd)      |
| auth.stevegore.au   | -     | GitHub OAuth portal   |
| hass.stevegore.au   | 8123  | Home Assistant        |
| desk.stevegore.au   | 8111  | NuraSpace (protected) |
| gym.stevegore.au    | 8112  | GymMaster (protected) |
| plex.stevegore.au   | 32400 | Plex Media Server     |
| photos.stevegore.au | 2342  | PhotoPrism            |
| port.stevegore.au   | 9000  | Portainer             |
| huggin.stevegore.au | 3000  | Huginn                |

| pdf.stevegore.au | 8083 | Stirling PDF |
| strava.stevegore.au | 8180 | Stravakeeper |
| bw.stevegore.au | 8081/3012 | Vaultwarden |

**Local to ampere-ubuntu (via Caddy → MicroK8s NodePort):**

| Domain                   | Port  | Service                   |
| ------------------------ | ----- | ------------------------- |
| argocd.stevegore.au      | 32392 | ArgoCD UI                 |
| grpc.argocd.stevegore.au | 30481 | ArgoCD gRPC               |
| vault.stevegore.au       | 30820 | HashiCorp Vault (OCI KMS) |
| healthz.stevegore.au     | -     | Health check              |

**Direct access (not via Caddy):**

| Domain             | Target            | Service                 |
| ------------------ | ----------------- | ----------------------- |
| hass2.stevegore.au | Cloudflare Tunnel | Home Assistant (backup) |
