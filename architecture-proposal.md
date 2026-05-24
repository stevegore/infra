# Proposed Architecture: OKE + Split Ampere + pico

**Status:** Proposal, not yet adopted
**Author:** Steve / Claude
**Date:** 2026-05-23
**Trigger:** Single-host outage on 2026-05-23 (ampere-ubuntu hit a 20-min Oracle maintenance window; all externally-accessible services down for the duration)

---

## 1. Goals

1. **Eliminate the single-host failure mode** that took down all external access during Oracle maintenance on 2026-05-23.
2. **Keep pico as primary** for services that need local LAN access (Home Assistant, media, photos) or that store too much data to mirror.
3. **Add cloud-side replicas** for services that are small/stateless enough to actively replicate, so that *external* access continues if pico is offline.
4. **Replace MicroK8s** with Oracle Kubernetes Engine so the control plane is no longer our problem.
5. **Stay close to Always Free** in steady state; tolerate some paid usage during migration.

Non-goals: zero-downtime active-active everywhere (not realistic with one home server and one region), regional failover (OCI Sydney AD-1 is single-AD on free tier).

---

## 2. Current state (TL;DR)

- **ampere-ubuntu** (1 × A1.Flex, 4 OCPU / 24 GB): MicroK8s, Caddy, WireGuard hub, ArgoCD, Vault.
- **pico** (home, Ryzen 5 / 30 GB / 3.6 TB NVMe): Home Assistant, Plex, Immich, PhotoPrism, Vaultwarden, Huginn, Stirling, Strava, Portainer, plus everything else through `port.stevegore.au`.
- All public ingress flows through Caddy on ampere → WireGuard → pico backends.
- One reserved public IP fronts everything via Cloudflare-proxied DNS.

Failure modes today:
- `ampere-ubuntu` down → **all** external access dies (vault, hass, bw, plex, …).
- pico down → external still up but all backends 502.
- Either way, half the stack is out.

---

## 3. Target architecture — high level

```
                  ┌──────────────────────────────────────────────────┐
                  │                  Cloudflare DNS                   │
                  │   *.stevegore.au   → OCI NLB public IP (proxied) │
                  │   hass2.stevegore.au → Cloudflare Tunnel (pico)  │
                  │                       — kept as failsafe path    │
                  └────────────────────┬─────────────────────────────┘
                                       ▼
              ┌──────────────────────────────────────────────────────┐
              │  OCI Network Load Balancer (Always Free, L4)         │
              │  Public IP: existing reserved IP (detached from VM,  │
              │             reattached to NLB — DNS doesn't change)  │
              │  Listeners: TCP 80, TCP 443 (pass-through)           │
              │  Backends: both OKE workers (health-checked)         │
              │  No bandwidth cap — limited by worker NIC (~Gbps)    │
              └────────────────────────┬─────────────────────────────┘
                                       │
       ┌───────────────────────────────┼────────────────────────────────┐
       │          OKE Cluster (Sydney AD-1, k8s 1.30, free tier)        │
       │                                                                │
       │  ┌────────────────────────┐   │   ┌────────────────────────┐   │
       │  │ ampere-1 (FD-1)        │   │   │ ampere-2 (FD-2)        │   │
       │  │ A1.Flex 2 OCPU/12 GB   │◀──┴──▶│ A1.Flex 2 OCPU/12 GB   │   │
       │  │                        │       │                        │   │
       │  │ caddy (replica)        │       │ caddy (replica)        │   │
       │  │ argocd-server (HA)     │       │ argocd-repo-server (HA)│   │
       │  │ vault (standalone,     │       │ uptime-kuma             │   │
       │  │   bucket-backed)       │       │ homepage (replica)     │   │
       │  │ vaultwarden            │       │                        │   │
       │  │ tailscale operator     │       │                        │   │
       │  │ + Connector pod        │       │                        │   │
       │  └─────────┬──────────────┘       └────────────┬───────────┘   │
       │            │                                    │              │
       │            ▼                                    ▼              │
       │  ┌──────────────────────────────────────────────────────────┐  │
       │  │  OCI Block Volume CSI: uptime-kuma history PVC (50 GB)   │  │
       │  │  OCI Object Storage: vault-storage (live Vault backend)  │  │
       │  │                      caddy-acme   (Caddy cert state)     │  │
       │  └──────────────────────────────────────────────────────────┘  │
       └────┬────────────────────────────────┬──────────────────────────┘
            │ MySQL wire                      │ Tailscale tailnet (mesh)
            │                                 │ No public listener on either side
            ▼                                 ▼
  ┌───────────────────────────┐   ┌────────────────────────────────────────┐
  │ MySQL HeatWave Free       │   │ pico (home, 192.168.4.120, tailscaled) │
  │ (Always Free, Sydney AD-1)│   │ Ryzen 5 5600G / 30 GB / 3.6 TB NVMe    │
  │ 1 vCPU / 8 GB / 50 GB     │   │ Advertises 10.20.30.0/24 + 192.168.4/24│
  │ Managed + auto-backup     │   │ Primary: HA, Plex, Immich,             │
  │ Backend for Vaultwarden   │   │          Huginn, Stirling, Strava,     │
  └───────────────────────────┘   │          Portainer                     │
                                  │ Backup: Duplicati → Backblaze B2       │
                                  │         (photos + critical app data)   │
                                  └────────────────────────────────────────┘
```

---

## 4. Compute layout

| Host | Role | Shape | OCPU | RAM | Notes |
| --- | --- | --- | --- | --- | --- |
| ampere-1 | OKE worker | A1.Flex | 2 | 12 GB | FD-1 |
| ampere-2 | OKE worker | A1.Flex | 2 | 12 GB | FD-2 (different fault domain) |
| pico | home server | bare metal | 6c/12t | 30 GB | unchanged |

**Total OCI OCPU: 4** (within Always Free).
**Total RAM: 24 GB** (within Always Free).
**Spread:** Two fault domains in AD-1 = pods survive single-host loss inside the same AD.
**Why not 3 nodes?** Free tier caps at 4 OCPU; 1+1+2 or 1+1+1+1 means too little headroom per node. 2+2 is the sweet spot.
**Why not keep ampere as 1 big + 1 tiny?** Asymmetric pools confuse scheduler; equal nodes are easier to reason about and survive eviction.

OKE control plane is free (enhanced cluster, always-free). You only pay for workers, and ours stay in free tier.

---

## 5. Networking

### 5.1 VCN

Reuse the existing `nebula` VCN (10.0.0.0/16) and the existing Public Subnet for OKE workers; OKE will add its own pod and service CIDRs.

| Block | Purpose |
| --- | --- |
| `10.0.0.0/24` | Public subnet (workers + LB) |
| `10.0.1.0/24` | Private subnet (kept for future, unused at first) |
| `10.244.0.0/16` | OKE pod CIDR (default) |
| `10.96.0.0/16` | OKE service CIDR (default) |
| `10.20.30.0/24` | Legacy WG subnet, kept and re-advertised by pico via Tailscale (backward compat for existing Caddyfile/app references) |
| `100.64.0.0/10` | Tailnet (Tailscale CGNAT, auto-assigned per device) |

### 5.2 Ingress path

```
Internet ──▶ Cloudflare ──▶ OCI NLB :443 (L4 pass-through, encrypted)
                                    │
                                    ▼
                       Service/LoadBalancer (OKE, NLB-backed)
                                    │
                                    ▼
                       Caddy Deployment (TLS terminates here)
                              (2 replicas)
                                    │
                ┌───────────────────┼───────────────────┐
                ▼                                       ▼
       in-cluster services                   pico backends via Tailscale
       (vault, argocd, bw, ...)              (hass, plex, immich, ...)
```

We use the **OCI Network Load Balancer** (Always Free, L4) rather than the Flexible Load Balancer. NLB passes TCP through unchanged, so TLS terminates at Caddy as today (caddy-security needs to see the request). The Flexible LB caps at 10 Mbps egress, which would throttle Plex/Immich phone backups; NLB has no per-LB bandwidth cap — throughput is bounded by the worker NIC (~Gbps).

The NLB's public IP replaces the current reserved IP on the ampere VNIC. We can detach the reserved IP from ampere and attach it to the NLB to keep the same address — Cloudflare DNS doesn't even have to change.

### 5.3 Inter-site mesh — Tailscale

WireGuard is replaced by Tailscale, eliminating all public UDP exposure and the "which worker hosts the hub" problem entirely.

- **pico:** runs `tailscaled` as a host service. Joins our tailnet using an auth key delivered via the existing `vault-token-sync` flow. Advertises `10.20.30.0/24` (for backward compat with anything still hard-coding old WG addresses) and `192.168.4.0/24` (so we can also reach pico's other LAN devices if needed).
- **OKE:** runs the [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator). A single `Connector` CRD declares the OKE side of the tailnet — the operator runs the connector pod, manages its key rotation, and configures `--accept-routes` to consume pico's advertised subnets.
- **Caddy → pico:** upstream addresses unchanged (`10.20.30.1:8123` etc.), traffic now routed via the tailscale connector pod instead of a host WG interface.
- **Caddy → pico (alternative):** swap to pico's native tailnet IP (`100.x.x.x`) or MagicDNS name (`pico.<tailnet>.ts.net`). Cleaner long-term, but not required at cutover.
- **NAT traversal:** Tailscale negotiates direct connections wherever possible; falls back to DERP relays (~50–100 ms penalty) when both ends are behind symmetric NAT. From OKE (public IP) to pico (residential NAT), direct should succeed almost always.
- **What goes away:** WG hub pod, `hostNetwork: true`, UDP 51820 security-list rule, the `wg.stevegore.au` DNS record, and the failover-operator subsection that previously stood here.

**Tradeoffs accepted:** dependency on Tailscale's coordination server (free SaaS, but adds an external party to the trust path). Self-hosted alternative (`headscale`) is available if this is ever unacceptable — same shape, just a small Go server in OKE replaces tailscale.com.

### 5.4 DNS

Most records don't change — Cloudflare just points at a different OCI public IP (or the same one if we reassign the reserved IP).

| Record | Today | Proposed |
| --- | --- | --- |
| `*.stevegore.au` | A → ampere reserved IP | A → OCI LB public IP (same IP if reassigned) |
| `hass2.stevegore.au` | Cloudflare Tunnel → pico | Unchanged (separate path, useful as backup) |
| `bw2.stevegore.au` | n/a | Cloudflare Tunnel → pico:8081 (Vaultwarden warm standby — see §7.1.1) |
| `argocd.stevegore.au` | A → ampere | A → OCI LB IP |

**Resilience benefit from Cloudflare:** with Cloudflare proxied on, Cloudflare's own edge caches responses for cacheable content (homepage, static), so a brief origin blip is invisible to users. Plus we can add a Cloudflare Load Balancer / health check later for active failover to a backup IP.

---

## 6. Reverse proxy — do we still use Caddy?

**Yes, keep Caddy.** The caddy-security plugin handles GitHub OAuth + JWT auth across all our subdomains; replacing that with Traefik forward-auth or oauth2-proxy is a significant rewrite for no gain. Caddy runs cleanly as a `Deployment` in k8s.

Changes vs. today:

| Aspect | Today (ampere) | OKE |
| --- | --- | --- |
| Process | systemd unit | Deployment, 2 replicas |
| Caddyfile | `/etc/caddy/Caddyfile` | ConfigMap, mounted at same path |
| caddy.env | `/etc/caddy/caddy.env` | Secret (VSO-managed from Vault) |
| JWT keys | `/etc/caddy/keys/*.pem` | Secret (VSO-managed) |
| TLS certs | Caddy's internal storage on disk | Caddy ACME via S3 storage plugin → OCI Object Storage bucket `caddy-acme`. No PVC, no cert-manager. |
| Public address | host's IP | Service/LoadBalancer (via OCI NLB) |

**Certs:** Caddy's built-in ACME is configured to use OCI Object Storage as its storage backend, via the `certmagic-s3` plugin (e.g. `github.com/ss098/certmagic-s3`), pointed at a new `caddy-acme` bucket. Both Caddy replicas read/write the same bucket — one acquires the lock, performs the ACME flow, the other reads the resulting cert. No PVC, no cert-manager, no PVC-leader gymnastics, no rate-limit risk on restarts. xcaddy build gains one `--with` flag.

---

## 7. Storage strategy

Pick the right primitive per workload — don't reach for PVCs by default.

| Workload | Primitive | Notes |
| --- | --- | --- |
| Vault | **OCI Object Storage** | `vault-storage` bucket (existing). Standalone deployment, auto-unseal via OCI KMS. See §7.2. |
| Caddy ACME store | **OCI Object Storage** | New `caddy-acme` bucket via `certmagic-s3` plugin. Both replicas share state, no PVC. |
| Vaultwarden DB | **MySQL HeatWave Free** | Managed; no PVC, no operator, no in-cluster storage. See §7.1. |
| Uptime Kuma history | **OCI Block Volume CSI** (RWO) | 50 GB PVC for the SQLite DB. The only block-CSI consumer in the cluster. |
| Tiny config (dex secrets, etc.) | **k8s Secret / ConfigMap** | Lives in etcd, replicated free with control plane. |
| Photo backup | **Backblaze B2** (already configured) | Duplicati on pico → B2. Existing path; see §7.3. |

**No replicated filesystem.** No Longhorn, no Rook/Ceph — 2 nodes is too few for either to be healthy, and the only thing actually wanting RWX (Plex media) isn't moving to OKE.

**Block Volume realities to remember:**
- **Minimum 50 GB per volume** regardless of what the PVC `requests`. A 5 GB PVC still provisions a 50 GB volume.
- **Online expansion is supported** (OCI CSI does PVC resize; `resize2fs` on next pod restart). Start small, expand later.
- **Shrinking is impossible** — neither OCI nor Kubernetes supports it. So don't over-provision "just in case."

### 7.1 Vaultwarden DB — MySQL HeatWave Free

Vaultwarden's credentials are the single most critical thing in this stack, so we move them to managed storage rather than self-managed in-cluster.

- **Shape:** `MySQL.Free` (1 vCPU + 8 GB RAM) in Sydney AD-1, confirmed available in the `main` compartment with `mysql-free-count` = 1 entitlement.
- **Storage:** 50 GB included with the Free shape; Oracle handles backups automatically.
- **Network:** lives in an OCI subnet inside our VCN; private endpoint reachable from OKE workers via the existing VCN routing.
- **Connection from Vaultwarden:** `DATABASE_URL=mysql://vaultwarden:<pw>@<private-endpoint>:3306/vaultwarden` (credentials via VSO from Vault).
- **HA caveat:** Always Free is single-node. Node failure → Oracle restores from auto-backup (minutes, no manual ops). This is acceptable for our scale; full HA MySQL HeatWave costs.

This replaces the earlier plan to run CloudNative-PG. Net effect: zero in-cluster DB pods, no CNPG operator, no postgres PVCs, no postgres CRDs. The 100 GB we'd have spent on postgres replicas stays in the block-volume budget.

If we later adopt a postgres-only HA app, we can revisit (CNPG, or add a second managed DB — there is no Always Free postgres-equivalent on OCI yet).

### 7.1.1 Pico warm-standby mirror — `bw2.stevegore.au`

The OKE Vaultwarden is the primary, but for the credentials-critical workload it's worth keeping a second instance on pico that's *almost* live, so it can be used immediately if MySQL HeatWave Free (or all of OKE) is unreachable.

- **Pico keeps running its existing Vaultwarden container** in sqlite mode (no upstream MySQL dependency, no Tailscale dependency).
- **Hourly sync** via systemd timer on pico: `mysqldump --single-transaction --databases vaultwarden` from HeatWave Free → convert with `mysql2sqlite` (or equivalent) → swap the pico sqlite file atomically while the container is briefly stopped (`docker stop vaultwarden && mv new.sqlite data/db.sqlite3 && docker start vaultwarden`). Total downtime per sync: ~5 sec on the standby; the primary on OKE isn't touched.
- **External exposure via Cloudflare Tunnel** (same `cloudflared.service` already running for `hass2.stevegore.au`): new ingress rule `bw2.stevegore.au` → `http://localhost:8081`. Cloudflare DNS gets a CNAME `bw2.stevegore.au` → `<tunnel-id>.cfargotunnel.com`.
- **Independence from the OKE path entirely.** bw2 doesn't traverse Caddy, doesn't traverse the OCI NLB, doesn't traverse Tailscale. It's a completely separate ingress (Cloudflare → tunnel → pico-local Vaultwarden → pico-local sqlite). So a failure of *any* OKE-side component still leaves bw2 working.
- **Bitwarden clients**: switch the server URL to `https://bw2.stevegore.au` when needed. Mobile/desktop clients cache the vault locally, so for read-only access during a brief outage the URL swap may not even be needed.
- **Write conflict handling**: if someone edits a credential on `bw.stevegore.au` (OKE-primary) and then on `bw2.stevegore.au` (pico-standby) during the same outage window, last-write-wins applies after the next sync overwrites pico. For emergency-only use this is acceptable; if it becomes a real concern, pause the sync timer at the start of an outage.

This sync direction is one-way: OKE → pico. The reverse (pico → OKE during recovery) is a manual reconciliation step, not automated.

### 7.2 Vault — standalone with Object Storage backend

Kept as-is from the current setup, just moved to OKE. No raft, no PVCs, no migration of state.

- **Single replica Deployment.** State lives in the existing `vault-storage` OCI Object Storage bucket — same backend already serving production today.
- **Auto-unseal via OCI KMS** (same key OCID, instance principal of OKE worker nodes via extended `vault-instances` dynamic group).
- **No data migration**: the new Vault pod points at the existing bucket and instantly sees all existing secrets.
- **VSO unchanged.**

**Node-failure handling.** Standalone means a node loss takes Vault down briefly. Tuned tolerations in the pod spec compress this to ~90 sec:

```yaml
tolerations:
  - key: node.kubernetes.io/unreachable
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 30
  - key: node.kubernetes.io/not-ready
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 30
```

What's affected during a 90 sec gap: human Vault UI access (503). What isn't: VSO (cached k8s Secrets), pico vault-token-sync (15-min poll cycle), Vaultwarden (DB creds mounted at start), Caddy (talks to bucket, not Vault). Net real-world impact: invisible to almost everything.

HA raft was considered and rejected — the 3 × 50 GB block-volume floor cost (150 GB of the 200 GB free tier) bought ~80 seconds of additional availability for a workload that nothing actually polls in the hot path. Trade not worth it.

### 7.3 Photos

PhotoPrism is being sunset; Immich stays on pico as the only photo service.

**Backups: Duplicati → Backblaze B2.** This is the existing arrangement on pico. No OCI-side photo storage. Net effect:

- No cloud-side photo replica, no 502 fallback to remote.
- During a pico outage `photos.stevegore.au` returns 502 from Caddy. Acceptable: photos aren't latency-critical.
- DR path on total pico loss: restore from B2 via Duplicati to a new disk.

> **Status note (2026-05-24):** the Duplicati→B2 backup was discovered to have been silently failing since Nov 2023 (a stale DB record for a regenerated PhotoPrism sidecar). A rebuild is in progress at the time of writing; this proposal assumes the rebuild lands successfully. If it doesn't, we revisit and add an OCI-side cold copy.

### 7.4 Storage budget summary

| Tier | Free quota | Allocated | Purpose |
| --- | --- | --- | --- |
| OCI Block Volume | 200 GB | 50 GB | Uptime Kuma history (single PVC) |
| OCI Object Storage | 20 GB free request tier | <1 GB | `vault-storage` (live Vault backend) + `caddy-acme` (Caddy certs) |
| MySQL HeatWave | 1 instance Always Free | 1 instance / 50 GB | Vaultwarden DB |
| Backblaze B2 | n/a (separate billing) | ~1 TB | Photo + critical-app backups from pico |
| pico local | 3.6 TB NVMe | ~2 TB | Media, photos, HA DB, container volumes |

**150 GB of block-tier headroom** for future PVC needs. Existing volumes can also expand online (just not shrink).

---

## 8. Service placement

| Service | Today | Proposed primary | OKE replica? | Strategy |
| --- | --- | --- | --- | --- |
| Home Assistant | pico | pico | No | Local sensors/Zigbee → can't move. Cloudflare Tunnel as alt-path. |
| Plex | pico | pico | No | Media on local NVMe; not mirrorable. |
| Immich | pico | pico | No | Backup to Backblaze B2 via Duplicati on pico. |
| PhotoPrism | pico | **decommissioning** | No | Sunset — Immich covers it. |
| Huginn | pico | pico | No | Active scheduler state hard to dual-run. |
| Stirling PDF | pico | pico | No | Stateless, but low value to replicate. |
| Strava / Stravakeeper | pico | pico | No | Not critical. |
| Portainer | pico | pico | No | Manages pico-local Docker. |
| Vault | ampere (MicroK8s) | **OKE (standalone, bucket-backed)** | n/a — tuned-toleration restart, ~90s gap on node loss | Existing setup, just moved. No PVC. See §7.2 for failure analysis. |
| ArgoCD | ampere (MicroK8s) | **OKE (HA install)** | implicit | Stateless, git is source of truth. |
| Caddy | ampere | **OKE (2 replicas)** | implicit | Edge stays at edge. |
| Vaultwarden | pico | **OKE (active, `bw.stevegore.au`)** + pico (warm standby, `bw2.stevegore.au`) | Yes — hourly one-way sync | Primary on OKE with MySQL HeatWave Free backend. Pico keeps a sqlite-mode standby fed by hourly mysqldump+convert, exposed via Cloudflare Tunnel as a completely independent ingress path. See §7.1.1. |
| Homepage | pico | **OKE (replica)** + pico (replica) | Yes | Config in git; both pull. External users hit OKE one; LAN can hit either. |
| Uptime Kuma | pico (new) | **OKE** | n/a (moves entirely) | Needs to detect *pico* outages → can't live on pico. |
| Inter-site mesh | WireGuard (hub on ampere) | **Tailscale** (operator-managed Connector in OKE; tailscaled on pico) | n/a — no central listener | See §5.3. Eliminates UDP exposure, key juggling, and failover ops. |

---

## 9. Tradeoffs and decisions

| Decision | Alternative considered | Why this way |
| --- | --- | --- |
| OKE vs. self-managed MicroK8s on 2 hosts | k3s/MicroK8s HA across both ampere VMs | OKE control plane is free + managed; one less thing to patch. The 2 workers cover compute HA. |
| 2 × 2-OCPU workers | 1 × 4-OCPU + 1 × 0-OCPU "edge" VM | Equal nodes simplify scheduling and survive single-node failure cleanly. |
| Caddy stays | Traefik + oauth2-proxy | caddy-security port is a multi-week project for no functional gain. |
| Single fault domain (AD-1) | Multi-AD | Multi-AD costs money; AD-1 with FD-1+FD-2 nodes is the free way to get host-level HA. |
| MySQL HeatWave Free for Vaultwarden DB | CloudNative-PG self-hosted in OKE | Managed (Oracle does backups + restore), zero in-cluster footprint, no CNPG operator. Trade-off: locked to Oracle MySQL service + single-node free tier. Acceptable. |
| Existing Duplicati→B2 for photo backup | rclone → OCI Object Storage (cold copy) | Already paid for and working (modulo the 2026-05-24 fix). No need to add a second backup target. |
| OCI Block Volume CSI used sparingly | OCI CSI by default for everything | Block storage has a 50 GB-per-volume floor and counts against the 200 GB free tier. Only Uptime Kuma's SQLite genuinely needs block; everything else uses ConfigMap/Secret/Object Storage (incl. Caddy ACME via S3 plugin, Vault via the existing `vault-storage` bucket). |
| Caddy built-in ACME, no cert-manager | cert-manager + k8s Secret | Caddy does ACME natively. cert-manager adds CRDs, controller, RBAC for zero gain since no non-Caddy workload needs certs. |
| Tailscale for inter-site mesh | WireGuard (hub pod + DNS + failover operator) | No public UDP listener, no failover plumbing, NAT traversal handled. Trade: SaaS dependency on Tailscale's coordination server. Headscale fallback available if that ever changes. |
| OCI Network LB (L4 pass-through) | OCI Flexible LB (L7) | Flexible LB caps at 10 Mbps — would kneecap Plex/Immich. NLB is L4, passes TLS through to Caddy (which already terminates), no bandwidth cap. Both are Always Free. |
| Cloudflare proxy stays ON | DNS-only | Edge caching + DDoS + free TLS + path-based fallback options later. |

---

## 10. Migration plan

You said you don't mind exceeding Always Free during the migration. The plan runs both stacks side-by-side for ~5-7 days. Estimated cost: **$2-7 total** (extra 4 OCPU at $0.01/OCPU/hr × ~150 hours).

**GitOps invariant:** every Kubernetes resource lives under `apps/<name>/` in this repo and is reconciled by the existing `infra-apps` ApplicationSet (`argocd/applicationset.yaml`). The only commands that touch the cluster directly are the one-shot bootstrap (`bootstrap/install.sh`-equivalent for OKE: kubectl-apply ArgoCD raw manifests, then the ApplicationSet) and ad-hoc debug. Every install step below is "commit `apps/foo/`, push, ArgoCD syncs" — never `helm install` against the live cluster.

### Phase 0 — Prep (½ day, no risk)

- [ ] Snapshot ampere boot volume (one-click in OCI console).
- [ ] Take an out-of-band copy of the `vault-storage` bucket as a safety net (`oci os object bulk-download --bucket-name vault-storage --download-dir /backup/vault-pre-migration/`). Current Vault is standalone, so the bucket IS the snapshot.
- [ ] Create OCI Object Storage bucket `caddy-acme` (private, no versioning needed — Caddy manages cert lifecycle). Grant the `vault-instances` dynamic group `manage objects in compartment main where target.bucket.name='caddy-acme'`.
- [ ] In a branch, add the new app directories so the ApplicationSet picks them up on first sync. Each is a small Helm chart (or wrapper around an upstream chart) with `values.yaml`; secrets via VSO from the existing SOPS bundle:
  - `apps/caddy/` (Caddy + caddy-security + certmagic-s3, 2 replicas)
  - `apps/vaultwarden/` (Deployment + Service + Ingress, MySQL HeatWave Free as backend)
  - `apps/uptime-kuma/` (single Deployment + small PVC)
  - `apps/tailscale-operator/` (wrapper for `tailscale/tailscale-operator` chart + `Connector` CRD)
  - `apps/homepage/` (OKE replica; same chart values as pico modulo `replicas: 1` per side)
  - Update `apps/vault/values.yaml` to add the tuned tolerations from §7.2 (single in-place edit; ArgoCD reconciles after Phase 2 sync). No raft / standalone-mode change needed — existing values already use standalone + Object Storage backend.
- [ ] Create Tailscale account (if not already), generate a reusable + ephemeral auth key for OKE Connector, plus a non-ephemeral auth key for pico. Stash both in `kv/tailscale/` in Vault.
- [ ] Extend `vault-instances` dynamic group to include the *new* OKE workers (matching rule: instance.compartment.id = main).
- [ ] Confirm Duplicati→B2 photo backup is producing fresh filesets (post-2026-05-24 fix).

### Phase 1 — Provision OKE (½ day)

- [ ] Create OKE cluster in `main` compartment, Sydney AD-1, public API endpoint, k8s 1.30, enhanced cluster (free).
- [ ] Add API endpoint to security list with home IP whitelist.
- [ ] Create node pool: A1.Flex 2 OCPU / 12 GB, **2 nodes**, spread FD-1 + FD-2.
- [ ] Briefly you'll have 8 OCPU in use — within paid tier. Confirm in console that Always Free A1 quota isn't blocked first.
- [ ] Local kubeconfig: `oci ce cluster create-kubeconfig --cluster-id <ocid> ...`.

### Phase 2 — Cluster baseline (1 day)

- [ ] Bootstrap ArgoCD into the empty cluster: `kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml`. This is the only direct kubectl-apply in the whole migration; from here on ArgoCD owns its own lifecycle via `apps/argocd/`.
- [ ] `kubectl apply -f argocd/applicationset.yaml` once. The ApplicationSet generator walks `apps/*` and creates an Application per directory.
- [ ] Watch ArgoCD sync: `apps/argocd/` reconciles ArgoCD itself, `apps/vault-secrets-operator/` brings VSO, `apps/vault/` brings Vault (standalone, pointing at the existing `vault-storage` bucket — secrets appear without a data migration), etc.
- [ ] Out-of-band: provision **MySQL HeatWave Free** in Sydney AD-1 (`oci mysql db-system create --shape-name MySQL.Free ...`), in a private subnet of the existing `nebula` VCN, with NSG opened only to OKE worker CIDR. (Not a k8s resource → not in `apps/`; could be Terraform later.)
- [ ] Verify: Vault auto-unseals via OCI KMS, VSO authenticates against the new Vault, MySQL endpoint resolvable from a debug pod.

### Phase 3 — Edge stack (1 day)

- [ ] Build Caddy container image with `xcaddy build --with github.com/greenpau/caddy-security --with github.com/ss098/certmagic-s3` and push to OCI Container Registry (Always Free, 5 GB). Image tag pinned in `apps/caddy/values.yaml`.
- [ ] Commit `apps/caddy/` — Helm chart producing: Deployment (2 replicas), Service type `LoadBalancer` with annotation `oci.oraclecloud.com/load-balancer-type: "nlb"` (this is how ArgoCD-driven k8s tells OCI to provision the NLB; no separate `oci nlb create` needed), ConfigMap (Caddyfile + `storage s3` global option), VaultStaticSecret for caddy.env + JWT keys + S3 credentials. ArgoCD syncs it; the OCI CCM provisions the NLB.
- [ ] Detach the existing reserved public IP (`publicip20230914115348`) from the ampere VNIC and reattach to the NLB the CCM created — DNS records continue pointing at the same IP, zero Cloudflare change needed. (This step is out-of-band; the CCM accepts a pre-existing reserved IP via the `service.beta.kubernetes.io/oci-load-balancer-reserved-ip` annotation on the Service if we want it fully declarative from day 1.)
- [ ] Point a **test** subdomain (e.g. `oke-test.stevegore.au`) at the new LB IP — verify Caddy + cert issuance work end-to-end before touching real records.

### Phase 4 — Tailscale rollout (½ day)

- [ ] On pico: `sudo apt install tailscale && sudo tailscale up --authkey=<from Vault> --advertise-routes=10.20.30.0/24,192.168.4.0/24 --accept-routes`. Confirm pico is visible in the Tailscale admin console.
- [ ] In the Tailscale admin: approve the advertised subnet routes from pico.
- [ ] `apps/tailscale-operator/` already commits the Tailscale K8s Operator (Helm dependency) plus a `Connector` CRD instance — ArgoCD syncs it on its next reconcile. The operator pod joins the tailnet using the OAuth secret from Vault (via VSO), the connector accepts pico's advertised routes.
- [ ] Caddy upstreams stay at `10.20.30.1:<port>` — packets now route via the connector pod. No Caddyfile changes; ArgoCD doesn't re-sync Caddy.
- [ ] Verify end-to-end: `kubectl exec -n caddy <pod> -- curl -sI http://10.20.30.1:8123` returns 200.
- [ ] Old WG hub on ampere-ubuntu stays up during the transition — pico still has the WG peer; can flap back to it if Tailscale misbehaves.
- [ ] After 1 week of clean operation, remove the WG peer from pico's `wg0.conf` (and the now-orphaned hub on ampere) at decommission time (Phase 7).

### Phase 5 — DNS cutover, low-stakes first (1-2 days, lower TTL first)

- [ ] Set Cloudflare TTL to 60s for all stevegore.au records 24h before cutover.
- [ ] Cutover order:
  1. `healthz.stevegore.au` (canary)
  2. `homepage.stevegore.au`
  3. `argocd.stevegore.au`
  4. `huggin.stevegore.au`, `pdf.stevegore.au`, `strava.stevegore.au`
  5. `port.stevegore.au`, `plex.stevegore.au`
  6. `hass.stevegore.au` (verify Cloudflare Tunnel fallback works first)
  7. `bw.stevegore.au` (after Vaultwarden migration in phase 6.5)
  8. `vault.stevegore.au` (after Vault migration in phase 6)

### Phase 6 — Vault cutover (½ hour)

No data migration — the new Vault pod uses the same `vault-storage` bucket and same OCI KMS key as the old one.

- [ ] Shut down the old Vault on ampere-ubuntu (stop the StatefulSet pod, leave manifests for now).
- [ ] Confirm the new OKE Vault pod is healthy and unsealed (`vault status` via port-forward).
- [ ] Re-create the Kubernetes auth role in Vault (new cluster CA, so the old role's CA cert is invalid): `vault write auth/kubernetes/config kubernetes_host=...` then re-create each role binding.
- [ ] Re-issue AppRole credentials for pico's `vault-token-sync` (CIDR bindings still valid, role ID / secret ID need re-issue against the new cluster).
- [ ] Restart VSO so it re-authenticates with the new auth/kubernetes config.

### Phase 6.5 — Vaultwarden migration

- [ ] On pico: stop Vaultwarden, snapshot `data/db.sqlite3`.
- [ ] Convert sqlite → MySQL (Vaultwarden has scripts for this; alternatively use `vw_data_export` + `vw_data_import` against a fresh DB).
- [ ] Load into MySQL HeatWave Free (already provisioned in phase 2). Store the connection string in Vault at `kv/vaultwarden/database_url`.
- [ ] `apps/vaultwarden/` (already committed in Phase 0) becomes effective once the database secret exists: ArgoCD has been waiting in a `Degraded` state for the VSO-managed Secret, which now appears, and Vaultwarden starts.
- [ ] Verify with one device, then full client roll.
- [ ] Cutover bw.stevegore.au.
- [ ] On pico: keep the existing Vaultwarden container running in sqlite mode as a **warm standby** (see §7.1.1).
  - Install hourly sync: systemd timer + service in `~/code/infra/scripts/vw-mysql-to-sqlite.{service,timer}`. Service body: `mysqldump --single-transaction` from HeatWave Free → `mysql2sqlite` → atomic swap of `data/db.sqlite3` with a brief container stop/start.
  - Add Cloudflare Tunnel ingress rule: `bw2.stevegore.au` → `http://localhost:8081` (alongside the existing `hass2.stevegore.au` route).
  - Create Cloudflare DNS CNAME: `bw2.stevegore.au` → `<tunnel-id>.cfargotunnel.com`.
  - Verify external access at `https://bw2.stevegore.au` with a test login.

### Phase 7 — Decommission ampere-ubuntu (½ day)

- [ ] Verify everything works through new stack for a week.
- [ ] Stop services on ampere-ubuntu (systemctl stop caddy wg-quick@wg0 fail2ban).
- [ ] Take one final boot-volume backup.
- [ ] Terminate the instance (releases its OCPU back to free tier).
- [ ] You're now at 4 OCPU OKE workers, within Always Free.

---

## 11. Cost analysis

### Steady-state (post-migration)

| Item | Cost |
| --- | --- |
| 2 × A1.Flex 2 OCPU / 12 GB workers | $0 (Always Free) |
| OKE enhanced cluster control plane | $0 (Always Free) |
| 1 × OCI Network LB | $0 (Always Free) |
| 50 GB block volume (Uptime Kuma history) | $0 (within 200 GB Always Free, 150 GB headroom) |
| OCI KMS HSM key | $0 (one Always Free vault) |
| OCI Object Storage — `vault-storage` + `caddy-acme` | $0 (well under 20 GB tier) |
| 1 × MySQL HeatWave Free (Vaultwarden DB) | $0 (Always Free) |
| Backblaze B2 — photo + critical-app backups (existing) | unchanged from today (separate billing) |
| Cloudflare DNS + proxy | $0 |
| **Total incremental OCI spend** | **$0/mo** |

### Migration window (5-7 days, both stacks running)

| Item | Cost |
| --- | --- |
| Extra 4 OCPU A1 above free tier | ~$0.04/hr × 150 hr = **~$6** |
| Extra block volume during snapshots | <$1 |
| **Total one-off** | **~$7** |

---

## 12. What this proposal does *not* solve

- **Home internet outage**: anything pico-only is still unreachable. Home Assistant is fundamentally tied to your house.
- **Regional outage**: Sydney goes down → everything cloud-side goes down. Free tier is single-region.
- **Storage at scale**: photos still live in one place (pico). If pico's NVMe dies between Duplicati runs, you lose up to 24 hours of new photos.
- **DDoS / public abuse**: Cloudflare proxy helps but isn't bulletproof for the LB IP if attackers find it directly. Origin firewall (Security List) already restricts SSH; consider restricting 443 to Cloudflare IP ranges.
- **Vaultwarden true HA**: dual-master Vaultwarden is unsolved upstream, and MySQL HeatWave Free is single-node. The pico warm-standby at `bw2.stevegore.au` (§7.1.1) covers the case where MySQL/OKE/Caddy go down — it has its own ingress via Cloudflare Tunnel — but writes to bw2 during an outage need manual reconciliation back to the primary, and sessions don't sync across the two instances.
- **Vault availability on node loss.** Standalone Vault means ~90 sec of UI 503 if the node hosting it dies (see §7.2 timeline). Acceptable for our usage (nothing in the hot path polls Vault), but worth knowing — if Vault ever becomes time-critical for something new, revisit HA raft + paid small block volumes (option B in the storage-strategy debate).

---

## 13. Decisions made

These started as open questions and were resolved during proposal review (Steve, 2026-05-24):

| Question | Decision |
| --- | --- |
| Sunset PhotoPrism? | **Yes** — Immich covers the use case; drop PhotoPrism from pico during migration. |
| Vault HA raft vs. standalone+object-storage? | **Standalone + Object Storage** — kept from current setup. HA raft was rejected after evaluating the trade: 150 GB block-tier cost for ~80 sec of extra availability on a workload nothing polls in the hot path. Tuned tolerations bring node-failure recovery to ~90 sec. |
| Keep Cloudflare Tunnel `hass2.stevegore.au` as alt-path? | **Yes** — proved useful during the 2026-05-23 outage. |
| Reserved IP — reuse or fresh? | **Reuse** — detach from ampere VNIC, attach to NLB; DNS records unchanged. |
| WireGuard failover — manual or operator? | **Replaced entirely by Tailscale (managed)**. No central listener, no DNS gymnastics, no failover operator. SaaS dep on Tailscale's coordination server (acceptable; headscale fallback available). |
| cert-manager? | **No** — Caddy's built-in ACME is sufficient; nothing else in cluster needs certs. |

---

## 14. References

- [hosts.md](hosts.md) — current host inventory
- [oracle-cloud.md](oracle-cloud.md) — current OCI resources
- [vault.md](vault.md) — Vault setup (largely portable to OKE)
- [dns.md](dns.md) — current Cloudflare DNS layout
- OKE Always Free docs: https://docs.oracle.com/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm
- MySQL HeatWave Always Free: https://docs.oracle.com/iaas/mysql-database/doc/free-tier.html
- OCI Block Volume CSI driver: https://docs.oracle.com/iaas/Content/ContEng/Tasks/contengcreatingpersistentvolumeclaim.htm
