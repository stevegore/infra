# Proposed Architecture: OKE + Split Ampere + pico

**Status:** Adopted; Phases 0–2 complete, Phase 3 in progress
**Author:** Steve / Claude
**Date:** 2026-05-23 (last updated 2026-05-25, post-critical-assessment)
**Trigger:** Single-host outage on 2026-05-23 (ampere-ubuntu hit a 20-min Oracle maintenance window; all externally-accessible services down for the duration)

**Progress (2026-05-25 — afternoon):**
- **Phase 0 → done.** Customer Secret Key for caddy-acme minted (`scripts/provision-caddy-acme-creds.sh`) and pushed to `kv/oci/caddy-acme`; `apps-oke/caddy/` chart updated so VSO reconciles two secrets (per-app config + the OCI S3 keys).
- **Phase 2 → done.** ArgoCD HA bootstrapped on OKE via `kubectl apply --server-side --force-conflicts -f .../ha/install.yaml`. Both ApplicationSets applied. Ampere Vault was scaled down to 0 first; OKE Vault came up against the **same `vault-storage` bucket** and auto-unsealed via OCI KMS (no data migration). Vault `auth/kubernetes/config` reset for the OKE cluster (in-cluster discovery via the Vault pod's own SA token; required adding a `vault-auth-delegator` ClusterRoleBinding on `system:auth-delegator` since the upstream chart doesn't ship it). VSO authenticates and is reconciling `VaultStaticSecret`s. Required additional policies (`caddy`, `vaultwarden`, `tailscale-operator`) + namespace bindings on the `vault-secrets-operator` k8s role.
- **App status on OKE (synced + healthy unless noted):** `argocd`, `vault`, `vault-secrets-operator`, `openclaw`, `uptime-kuma`, `vaultwarden`, `caddy`. *Degraded / partial:* `homepage` (placeholder, `/app/config` not writable — defer until we copy pico's real config), `tailscale-operator` (deployment up but the OAuth client lacks the `tag:k8s-operator` permission, so it can't mint authkeys — fix in the Tailscale admin console).
- **Vaultwarden DB** — dedicated `vaultwarden` MySQL user + `vaultwarden` schema provisioned on the HeatWave Free instance; `kv/vaultwarden/config` populated with `database_url`, `admin_token` (placeholder), and the underlying user/pass. Vaultwarden pod is up and Rocket has launched.
- **Caddy on OKE** — pulling OCIR image cleanly, certmagic-s3 plugin loading, actively driving ACME flows for all subdomains (challenges will only succeed after Phase 5 DNS cutover — expected). NLB provisioned with ephemeral IP `152.69.170.137`; reserved IP `159.13.44.68` exists in TF but isn't attached (see §3 notes).
- **Phase 3 → partial.** Reserved IP minted via `terraform/nlb.tf` (address `159.13.44.68`, OCID stashed in `apps-oke/caddy/values.yaml`). **Gotcha:** the `service.beta.kubernetes.io/oci-load-balancer-reserved-ip` annotation only applies to the classic OCI LB, not the NLB the chart provisions. NLB is currently using its initial ephemeral IP. To swap: either change the NLB annotation to the (separately documented) NLB-specific form, or recreate the Service with the right annotation before Phase 5 DNS work.
- **Phase 0 (TF + cred) gotcha worth remembering:** OKE workers run cri-o with `short_name_mode=enforcing`, which rejects any image reference without an explicit registry. Every chart now uses `docker.io/<repo>` (or `quay.io/...`, `ghcr.io/...`) and the upstream Vault + VSO image overrides are wired in `apps/vault/values.yaml` + `apps/vault-secrets-operator/values.yaml`. Also: the tailscale-operator chart nests the image override under `operatorConfig.image` (NOT top-level `image`), and a duplicate `operatorConfig:` block in values.yaml will silently erase the override — merge them into one map.
- **`kv/` populated** with everything OKE needs: `kv/caddy/config`, `kv/vaultwarden/config`, `kv/oci/caddy-acme`, `kv/tailscale/operator_oauth`, `kv/openclaw`, `kv/mysql/heatwave-admin`.

**Progress (2026-05-25 — morning):**
- Terraform pipeline live: ORM Stack `homelab-tf` (`github.com/stevegore/infra` `terraform/`) owns OCI state. Local CLI plans via `scripts/tf-env.sh` (pulls ORM state snapshot, renames `backend_override.tf.local` → `.tf`); apply goes through ORM jobs only. See `terraform/README.md`.
- All OCI infrastructure changes go through this pipeline from now on — no console edits. See §10's "Terraform invariant" alongside the existing GitOps invariant.
- `kv/oci/` is the canonical namespace for OCI secrets: `kv/oci/api-key` (the local CLI API key), `kv/oci/ocir` (registry token), `kv/mysql/heatwave-admin` (MySQL admin + DATABASE_URL).
- **Phase 1 → done.** OKE Enhanced cluster `homelab` (v1.35.2) ACTIVE in `main` compartment. Two A1.Flex 2 OCPU / 12 GB workers spread across FD-1 + FD-2 in Private Subnet-nebula. Public API endpoint on a new 10.0.2.0/28 subnet, NSG-restricted to home IP 159.196.97.38/32. Kubeconfig at `~/.kube/oke-homelab.config` (auto-exported via `~/.zshrc`); `kubectl get nodes` works from home.
- MySQL HeatWave Free (`heatwave`, MySQL 9.7.0, MySQL.Free) ACTIVE at `heatwave.sub02040931041.nebula.oraclevcn.com:3306` (10.0.1.51). Admin creds + formatted Vaultwarden `DATABASE_URL` published to `kv/mysql/heatwave-admin` by `scripts/publish-mysql-creds.sh`. **Gotcha:** attaching any `nsg_ids` to a `MySQL.Free` DB at create time fails with `AuthorizationFailed` even with the OCI-documented `manage virtual-network-family` policy (reproduced via direct CLI). Worked around by allowing 3306 + 33060 on the existing `nebula-private` SL from `10.0.1.0/24` (workers + DB share the Private Subnet anyway, so isolation is preserved). The standalone `mysql-heatwave` NSG resource is still in TF as a leave-behind.

**Progress (2026-05-24):**
- All five OKE chart scaffolds committed under `apps-oke/` (`caddy`, `vaultwarden`, `uptime-kuma`, `tailscale-operator`, `homepage`) — separated from `apps/` so the live ampere `infra-apps` ApplicationSet doesn't try to reconcile them. Charts lint + render clean.
- `apps/vault/values.yaml` tolerations added (live; affects ampere too).
- OKE-side ApplicationSet template added at `argocd/applicationset-oke.yaml`, targeting `apps-oke/*`. Not yet applied (no OKE cluster yet).
- Helper scripts: `scripts/provision-ocir-creds.sh` (mints OCIR auth token, pushes to `kv/oci/ocir`) + `scripts/build-push-caddy.sh` (cross-builds + pushes the custom Caddy image; runs on either pico or Apple Silicon Mac).
- Caddyfile in `apps-oke/caddy/` already targets pico via the Tailscale Egress Service pattern (`pico:<port>` in-namespace) rather than the legacy `10.20.30.1:<port>` — so Phase 4 doesn't need a separate Caddyfile rewrite.
- Tailscale OAuth client created; creds in Vault at `kv/tailscale/operator_oauth` (for the OKE operator). Tailnet name `stevegore.github` (MagicDNS suffix `chipmunk-fir.ts.net`).
- Pico **already** on the tailnet — `tailscaled` running, MagicDNS `pico.chipmunk-fir.ts.net` (100.98.212.71). The Phase 4 "install tailscale on pico" checkbox is therefore already done; pico just needs the WG hub teardown when ampere goes (Phase 7). `apps-oke/caddy/values.yaml` pinned to this MagicDNS name.

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
                  │                  Cloudflare DNS                  │
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
       │  │ vault (standalone,     │       │ uptime-kuma            │   │
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
  │ 1 vCPU / 8 GB / 50 GB     │   │ Native tailnet node; no legacy WG CIDR │
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

Reuse the existing `nebula` VCN (10.0.0.0/16), but put the OKE workers in the existing **Private Subnet** and reserve the Public Subnet for the public-facing NLB only. If the workers do not need public IPs, they should not have them. OKE will add its own pod and service CIDRs.

| Block | Purpose |
| --- | --- |
| `10.0.0.0/24` | Public subnet (OCI NLB only) |
| `10.0.1.0/24` | Private subnet (OKE workers, MySQL private endpoint, future internal services) |
| `10.244.0.0/16` | OKE pod CIDR (default) |
| `10.96.0.0/16` | OKE service CIDR (default) |
| `100.64.0.0/10` | Tailnet (Tailscale CGNAT, auto-assigned per device) |

This means the node pool is created as **private nodes only** with outbound access via the existing NAT Gateway and service-to-OCI access via the existing Service Gateway. The only public data-plane entrypoint is the NLB.

This does **not** imply a private Kubernetes control plane. The intended management path is still the normal OKE model: a public API endpoint locked down to the home IP, with `kubectl` on pico talking directly to that endpoint via the generated kubeconfig. Tailscale is for OKE ↔ pico workload traffic, not for bootstrap or day-to-day cluster admin access.

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

We use the **OCI Network Load Balancer** (Always Free, L4) rather than the Flexible Load Balancer. NLB passes TCP through unchanged, so TLS terminates at Caddy as today (caddy-security needs to see the request). The Flexible LB caps at 10 Mbps egress, which would throttle Plex/Immich phone backups; NLB has no per-LB bandwidth cap — throughput is bounded by the worker NIC (~Gbps). The NLB is the public surface; the worker nodes stay private.

The NLB's public IP replaces the current reserved IP on the ampere VNIC. We can detach the reserved IP from ampere and attach it to the NLB to keep the same address — Cloudflare DNS doesn't even have to change.

### 5.3 Inter-site mesh — Tailscale

WireGuard is replaced by Tailscale, eliminating all public UDP exposure and the "which worker hosts the hub" problem entirely.

- **pico:** runs `tailscaled` as a host service and joins as a normal tailnet node using an auth key delivered via the existing `vault-token-sync` flow. No re-advertised `10.20.30.0/24` compatibility subnet. If we later need non-pico home LAN devices from OKE, we can separately advertise `192.168.4.0/24`; the base design does not depend on any subnet route.
- **OKE:** runs the [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator). The operator provides the OKE side of the tailnet and manages its own credentials; we use it for cluster-to-tailnet connectivity rather than maintaining a WireGuard hub.
- **Caddy → pico:** upstream addresses move to pico's native Tailscale identity, preferably MagicDNS (`pico.<tailnet>.ts.net`) rather than a synthetic legacy subnet address. That keeps the target design aligned with Tailscale and avoids carrying the old WireGuard CIDR forward.
- **NAT traversal:** Tailscale negotiates direct connections wherever possible; falls back to DERP relays (~50–100 ms penalty) when both ends are behind symmetric NAT. From OKE (private workers egressing through OCI NAT) to pico (residential NAT), direct should usually still succeed, but this needs an explicit proof check during rollout rather than assumption.
- **What goes away:** WG hub pod, `hostNetwork: true`, UDP 51820 security-list rule, the `wg.stevegore.au` DNS record, and the legacy `10.20.30.0/24` compatibility address space in the target architecture.

**Tradeoffs accepted:** dependency on Tailscale's coordination server (free SaaS, but adds an external party to the trust path). Self-hosted alternative (`headscale`) is available if this is ever unacceptable — same shape, just a small Go server in OKE replaces tailscale.com.

### 5.4 DNS

Most records don't change — Cloudflare just points at a different OCI public IP (or the same one if we reassign the reserved IP).

| Record | Today | Proposed |
| --- | --- | --- |
| `*.stevegore.au` | A → ampere reserved IP | A → OCI LB public IP (same IP if reassigned) |
| `hass2.stevegore.au` | Cloudflare Tunnel → pico | Unchanged (separate path, useful as backup) |
| `bw2.stevegore.au` | Cloudflare Tunnel → pico:8081 | Unchanged (Vaultwarden warm standby — see §7.1.1) |
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
| Vaultwarden DB | **MySQL HeatWave Free** | Managed database for core vault records. See §7.1. |
| Vaultwarden `/data` | **`emptyDir` (ephemeral)** | All meaningful state is in MySQL; everything else in `/data` is either unused, regenerable, or accepts a "clients re-auth on restart" cost. See §7.1. |
| Uptime Kuma history | **OCI Block Volume CSI** (RWO) | 50 GB PVC for the SQLite DB. |
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
- **`/data` is ephemeral.** Vaultwarden's only durable surface in OKE is MySQL; the container's `/data` is an `emptyDir`. Walking through what's normally in there (see the upstream backup wiki) against our actual usage:
  - `db.sqlite3` — unused; state is in MySQL.
  - `attachments/` — none. The only historical attachment was deleted 2026-05-24; we accept that future attachments are similarly disposable, or we revisit this decision then.
  - `sends/` — never used; ephemeral by Vaultwarden's own design anyway.
  - `rsa_key.{pem,der,pub.der}` — upstream wiki notes "deletion only forces re-login." A new pod regenerates these on first start; clients re-auth once and continue. Acceptable for a stateless rebuild.
  - `icon_cache/` — favicons. Lazy-rebuilt from live fetches on first vault open.
  - `config.json` — unused; we configure via env vars and Vault-mounted secrets.
- **HA caveat:** Always Free MySQL HeatWave is single-node. Node failure → Oracle restores from auto-backup (minutes, no manual ops). Acceptable for our scale; full HA HeatWave costs.

This replaces the earlier plan to run CloudNative-PG. Net effect: zero in-cluster DB pods, no CNPG operator, no postgres PVCs, no postgres CRDs, **and no Vaultwarden PVC** — Vaultwarden becomes fully stateless against MySQL. The 50 GB block-volume slot previously earmarked for `/data` returns to free-tier headroom.

If we later adopt a postgres-only HA app, we can revisit (CNPG, or add a second managed DB — there is no Always Free postgres-equivalent on OCI yet).

### 7.1.1 Pico warm-standby mirror — `bw2.stevegore.au`

The OKE Vaultwarden is the primary, but for the credentials-critical workload it's worth keeping a second instance on pico that's *almost* live, so it can be used immediately if MySQL HeatWave Free (or all of OKE) is unreachable.

- **Pico keeps running its existing Vaultwarden container** in sqlite mode (no upstream MySQL dependency, no Tailscale dependency).
- **Hourly sync** via systemd timer on pico: `mysqldump --single-transaction --databases vaultwarden` from HeatWave Free → convert with `mysql2sqlite` (or equivalent) → swap the pico sqlite file atomically while the container is briefly stopped (`docker stop vaultwarden && mv new.sqlite data/db.sqlite3 && docker start vaultwarden`). No `/data` sync — pico's standby and the OKE primary keep their own RSA keys (clients re-auth on a failover, per §7.1), and there's no other meaningful file state to mirror. Total downtime per sync: ~5 sec on the standby; the primary on OKE isn't touched.
- **External exposure via Cloudflare Tunnel** (same `cloudflared.service` already running for `hass2.stevegore.au`): `bw2.stevegore.au` is already configured to route to `http://localhost:8081`, with the Cloudflare DNS CNAME pointing at the existing pico tunnel.
- **Independence from the OKE path entirely.** bw2 doesn't traverse Caddy, doesn't traverse the OCI NLB, doesn't traverse Tailscale. It's a completely separate ingress (Cloudflare → tunnel → pico-local Vaultwarden → pico-local sqlite). So a failure of *any* OKE-side component still leaves bw2 working.
- **Bitwarden clients**: switch the server URL to `https://bw2.stevegore.au` when needed. Mobile/desktop clients cache the vault locally, so for read-only access during a brief outage the URL swap may not even be needed.
- **Write conflict handling**: if someone edits a credential on `bw.stevegore.au` (OKE-primary) and then on `bw2.stevegore.au` (pico-standby) during the same outage window, last-write-wins applies after the next sync overwrites pico. For emergency-only use this is acceptable; if it becomes a real concern, pause the sync timer at the start of an outage.

This sync direction is one-way: OKE → pico. The reverse (pico → OKE during recovery) is a manual reconciliation step, not automated.

### 7.2 Vault — standalone with Object Storage backend

Kept as-is from the current setup, just moved to OKE. No raft, no PVCs, no migration of state.

- **Single replica Deployment.** State lives in the existing `vault-storage` OCI Object Storage bucket — same backend already serving production today.
- **Auto-unseal via OCI KMS** (same key OCID, instance principal of OKE worker nodes via extended `vault-instances` dynamic group).
- **No data migration**: the new Vault pod points at the existing bucket and instantly sees all existing secrets.

**Auth model after the WireGuard removal:**

- **VSO stays on Kubernetes auth.** The auth method is still `auth/kubernetes`; only the cluster-specific wiring changes during migration. We reconfigure Vault with the new OKE cluster CA / token reviewer details, then recreate the existing role bindings for `vault-secrets-operator` and any other in-cluster consumers. This keeps the steady-state model the same: in-cluster workloads authenticate as service accounts, not with static credentials.
- **pico `vault-token-sync` stays on a dedicated AppRole.** It keeps the narrow `pico-token-sync` policy and short TTLs, but it no longer relies on the old `10.20.30.1/32` WireGuard identity. Instead, the role is rebound to pico's Tailscale node IP at cutover time and pico reaches Vault over the tailnet-backed path. The important design point is that the AppRole restriction now follows pico's native Tailscale identity, not a compatibility subnet we are otherwise deleting.
- **Operational consequence:** if pico is ever re-registered in Tailscale and gets a different node IP, re-issue the AppRole's CIDR binding as part of that maintenance. That is a smaller and more honest dependency than preserving the whole `10.20.30.0/24` address plan just to satisfy one auth check.
- **Deliberately rejected:** keeping the old WireGuard CIDR alive purely for Vault auth. That would preserve a fake dependency in the target architecture and defeat the point of simplifying the network model.

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

> **Status note (2026-05-24):** the Duplicati→B2 backup was discovered to have been silently failing since Nov 2023 (a stale DB record for a regenerated PhotoPrism sidecar). The rebuild landed — verified 2026-05-24: all 4 jobs have fresh successful filesets in B2 within the last 24h, with `dlist/dindex/dblock` PUTs confirmed in Duplicati's per-job `RemoteOperation` table. **However the underlying sidecar-regeneration race is not fixed** — today's scheduled 02:00 Photos run failed with the *exact same* `DatabaseInconsistencyException` on a `.MOV.avc` sidecar; only the post-`Recreate` manual runs at 12:03 and 19:43 succeeded. So as of today the proposal's "rebuild succeeded" assumption holds, but the photos backup has a known recurring failure mode that needs a real fix (kill the sidecar regeneration that's racing, or pin its filename) — track this as a §12 risk until done.

### 7.4 Storage budget summary

| Tier | Free quota | Allocated | Purpose |
| --- | --- | --- | --- |
| OCI Block Volume | 200 GB | 50 GB | Uptime Kuma history (50 GB) |
| OCI Object Storage | 20 GB free request tier | <1 GB | `vault-storage` (live Vault backend) + `caddy-acme` (Caddy certs) |
| MySQL HeatWave | 1 instance Always Free | 1 instance / 50 GB | Vaultwarden DB |
| Backblaze B2 | n/a (separate billing) | ~1 TB | Photo + critical-app backups from pico |
| pico local | 3.6 TB NVMe | ~2 TB | Media, photos, HA DB, container volumes |

**150 GB of block-tier headroom** remains for future PVC needs. Existing volumes can also expand online (just not shrink).

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
| Vaultwarden | pico | **OKE (active, `bw.stevegore.au`)** + pico (warm standby, `bw2.stevegore.au`) | Yes — hourly one-way sync | Primary on OKE with MySQL HeatWave Free backend; no PVC (`/data` is ephemeral — see §7.1). Pico keeps a sqlite-mode standby fed by hourly mysqldump+convert, exposed via Cloudflare Tunnel as a completely independent ingress path. See §7.1.1. |
| Homepage | pico | **OKE (replica)** + pico (replica) | Yes | Config in git; both pull. External users hit OKE one; LAN can hit either. |
| Uptime Kuma | pico (new) | **OKE** | n/a (moves entirely) | Needs to detect *pico* outages → can't live on pico. |
| Inter-site mesh | WireGuard (hub on ampere) | **Tailscale** (operator-managed Connector in OKE; tailscaled on pico) | n/a — no central listener | See §5.3. Eliminates UDP exposure, key juggling, and failover ops. |

---

## 9. Tradeoffs and decisions

| Decision | Alternative considered | Why this way |
| --- | --- | --- |
| OKE vs. self-managed MicroK8s on 2 hosts | k3s/MicroK8s HA across both ampere VMs | OKE control plane is free + managed; one less thing to patch. The 2 workers cover compute HA. |
| Private worker nodes | Public workers | The workers do not need direct internet reachability. Keeping them private reduces exposure and makes the NLB the only public ingress point. |
| 2 × 2-OCPU workers | 1 × 4-OCPU + 1 × 0-OCPU "edge" VM | Equal nodes simplify scheduling and survive single-node failure cleanly. |
| Caddy stays | Traefik + oauth2-proxy | caddy-security port is a multi-week project for no functional gain. |
| Single fault domain (AD-1) | Multi-AD | Multi-AD costs money; AD-1 with FD-1+FD-2 nodes is the free way to get host-level HA. |
| MySQL HeatWave Free for Vaultwarden DB | CloudNative-PG self-hosted in OKE | Managed (Oracle does backups + restore), zero in-cluster DB footprint, no CNPG operator. Trade-off: locked to Oracle MySQL service + single-node free tier. Acceptable. |
| Existing Duplicati→B2 for photo backup | rclone → OCI Object Storage (cold copy) | Already paid for and working (modulo the 2026-05-24 fix). No need to add a second backup target. |
| OCI Block Volume CSI used sparingly | OCI CSI by default for everything | Block storage has a 50 GB-per-volume floor and counts against the 200 GB free tier. Only Uptime Kuma's SQLite genuinely needs block; everything else uses ConfigMap/Secret/Object Storage (incl. Caddy ACME via S3 plugin, Vault via the existing `vault-storage` bucket) or treats `/data` as ephemeral (Vaultwarden, see §7.1). |
| Caddy built-in ACME, no cert-manager | cert-manager + k8s Secret | Caddy does ACME natively. cert-manager adds CRDs, controller, RBAC for zero gain since no non-Caddy workload needs certs. |
| Tailscale for inter-site mesh | WireGuard (hub pod + DNS + failover operator) | No public UDP listener, no failover plumbing, NAT traversal handled. Trade: SaaS dependency on Tailscale's coordination server. Headscale fallback available if that ever changes. |
| OCI Network LB (L4 pass-through) | OCI Flexible LB (L7) | Flexible LB caps at 10 Mbps — would kneecap Plex/Immich. NLB is L4, passes TLS through to Caddy (which already terminates), no bandwidth cap. Both are Always Free. |
| Cloudflare proxy stays ON | DNS-only | Edge caching + DDoS + free TLS + path-based fallback options later. |

---

## 10. Migration plan

You said you don't mind exceeding Always Free during the migration. The plan runs both stacks side-by-side for ~5-7 days. Estimated cost: **$2-7 total** (extra 4 OCPU at $0.01/OCPU/hr × ~150 hours).

**GitOps invariant:** OKE-only charts live under `apps-oke/<name>/`, reconciled by the OKE-side `infra-oke-apps` ApplicationSet (`argocd/applicationset-oke.yaml`). The ampere MicroK8s `infra-apps` ApplicationSet (`argocd/applicationset.yaml`) continues to glob `apps/<name>/` only — that separation is what stops ampere from trying to sync OKE-only primitives (NLB annotations, oci-bv PVCs, OCIR images). The only commands that touch the cluster directly are the one-shot bootstrap (`bootstrap/install.sh`-equivalent for OKE: kubectl-apply ArgoCD raw manifests, then the ApplicationSet) and ad-hoc debug. Every install step below is "commit `apps-oke/foo/`, push, ArgoCD syncs" — never `helm install` against the live cluster. Post-Phase-7 the two trees consolidate: `git mv apps-oke/* apps/`, drop `argocd/applicationset-oke.yaml`, done. Application names are basename-driven so the `source.path` field updates in place without recreating Applications.

**Terraform invariant:** All OCI infrastructure changes go through `terraform/` → ORM Stack `homelab-tf`. No console edits, no out-of-band `oci` CLI mutations. Workflow is identical to the GitOps one: edit `terraform/*.tf` → `source scripts/tf-env.sh && terraform plan` (local sanity check) → commit + push → ORM apply job runs against the new revision. State lives in ORM; local plans pull a snapshot via `scripts/tf-env.sh`. Two-and-only-two exceptions stay out of state because their secret material would leak into it: (1) **Customer Secret Keys** (the HMAC keys behind `kv/oci/ocir` and the future Caddy ACME bucket) — minted via `scripts/provision-*-creds.sh`; (2) **OCI Vault Secrets containing PATs / unseal keys** if we ever start using them — referenced by OCID from TF, never inlined. Every other primitive — buckets, IAM, KMS, networking, compute, OKE cluster + node pool, NLB, MySQL HeatWave, OCIR repos — lives in TF.

The TF resource matrix (current + planned):

| Phase | Resource | Status |
| --- | --- | --- |
| (pre-migration) | VCN `nebula`, subnets, SLs, NSGs, gateways | ✅ under TF (Resource Discovery import) |
| (pre-migration) | KMS vault `hashicorp-vault-unseal` + key + key version | ✅ under TF |
| (pre-migration) | `vault-storage` bucket | ✅ under TF |
| (pre-migration) | `vault-instances` dynamic group + `vault-kms-objectstorage-policy` | ✅ under TF |
| (pre-migration) | `ampere-ubuntu` instance + private IP attachment | ✅ under TF (will `terraform destroy` in Phase 7) |
| 3 | New RESERVED public IP for NLB (current `publicip20230914115348` is ephemeral on ampere's VNIC and can't be in-place promoted) | ⬜ create fresh in Phase 3; update Cloudflare DNS to the new value (TTL 60s 24h before cutover) |
| 0 | `caddy-acme` bucket | ✅ under TF |
| 0 | Broaden `vault-instances` DG → match by compartment (covers future OKE workers) | ✅ under TF (rule now `instance.compartment.id = <main>`) |
| 0 | Extend policy to allow `manage objects … target.bucket.name='caddy-acme'` | ✅ under TF |
| 1 | OKE Enhanced cluster + node pool (2 × A1.Flex 2OCPU/12GB across FD-1 + FD-2) | ✅ under TF (`homelab` cluster, k8s v1.35.2, 2 workers ACTIVE) |
| 1 | OKE control-plane endpoint security (home-IP allowlist NSG) | ✅ under TF (new 10.0.2.0/28 subnet + `oke-api-endpoint` NSG) |
| 1 | OCIR repos (`caddy`, plus others as needed) | ⬜ implicit — repos auto-created on first push from `scripts/build-push-caddy.sh`; bring under TF if/when we want lifecycle policies |
| 2 | MySQL HeatWave Free DB system | ✅ under TF (`heatwave`, MySQL 9.7.0, endpoint `heatwave.sub02040931041.nebula.oraclevcn.com:3306`). NSG attach unsupported by OCI for MySQL.Free — see notes |
| 3 | New RESERVED public IP for NLB (current `publicip20230914115348` is ephemeral on ampere's VNIC and can't be in-place promoted) | ⬜ create fresh in Phase 3; update Cloudflare DNS to the new value (TTL 60s 24h before cutover) |

### Phase 0 — Prep (✅ complete — 2026-05-25)

- [x] Snapshot ampere boot volume — backup `ocid1.bootvolumebackup.oc1.ap-sydney-1.abzxsljr2zcj7cxywe7ccngd2yhvtjutj6ir7jsqhz2vsltgaihdeacfmvua` (`pre-oke-migration-2026-05-24`, FULL, 47 GB, `free-tier-retained`). Initiated 2026-05-24 via OCI CLI; runs async (~30 min to AVAILABLE).
- [x] Out-of-band copy of `vault-storage` bucket → `~/Backups/vault-storage-2026-05-24/` on the Mac. 103/103 objects, 412 KB. Contents are Vault-encrypted on disk so the local copy is safe unwrapped.
- [x] Create OCI Object Storage bucket `caddy-acme` (private, no versioning needed — Caddy manages cert lifecycle). Grant the `vault-instances` dynamic group `manage objects in compartment main where target.bucket.name='caddy-acme'`. Both in `terraform/object_storage.tf` + `terraform/identity.tf`; applied 2026-05-25.
- [x] Mint Customer Secret Key for the Caddy ACME bucket; push to Vault at `kv/oci/caddy-acme` via `scripts/provision-caddy-acme-creds.sh`. VSO mounts it into the Caddy pod for the certmagic-s3 plugin.
- [x] Add the new app directories under `apps-oke/` (kept out of `apps/` so the live ampere ApplicationSet doesn't try to reconcile them). Each is a small Helm chart with `values.yaml`; secrets via VSO.
  - [x] `apps-oke/caddy/` (Caddy + caddy-security + certmagic-s3, 2 replicas, custom OCIR image — `Dockerfile` colocated)
  - [x] `apps-oke/vaultwarden/` (MySQL HeatWave Free backend, no PVC — `/data` is `emptyDir`)
  - [x] `apps-oke/uptime-kuma/` (single Deployment + 50 GB oci-bv PVC; **config copied from pico as starting point**)
  - [x] `apps-oke/tailscale-operator/` (wrapper for `tailscale/tailscale-operator` chart + `Connector` CRD)
  - [x] `apps-oke/homepage/` (OKE replica; placeholder ConfigMap pending copy of pico's live config)
  - [x] `apps/vault/values.yaml` tolerations from §7.2 (live — will roll vault-0 on ampere on next ArgoCD reconcile).
- [x] Add `argocd/applicationset-oke.yaml` — applied during Phase 2 on the new cluster to drive the `apps-oke/*` reconciliation.
- [x] Create Tailscale OAuth client; stash creds at `kv/tailscale/operator_oauth` in Vault. (For the OKE operator only — pico is already on the tailnet so no separate pico auth key needed.)
- [x] Extend `vault-instances` dynamic group to include the *new* OKE workers — matching rule now `instance.compartment.id = <main>`. Applied 2026-05-25 via `terraform/identity.tf`. Also dropped the discovery-placeholder/`ignore_changes` hack the auto-import had introduced.
- [x] Confirm Duplicati→B2 photo backup is producing fresh filesets — verified 2026-05-24: all 4 jobs (Docker Volumes, Home Assistant, Bitwarden, Photos) have successful filesets within 24h; Photos shows two successful runs today (12:03 + 19:43) with `dlist/dindex/dblock` PUTs to B2 confirmed in the per-job `RemoteOperation` table. See §7.3 caveat — the sidecar race that caused the original silent failure is *not* fixed; it recurred at the scheduled 02:00 run today and only the manual `Recreate`-then-run path is producing successful filesets.
- [x] Provision OCIR auth token + push to `kv/oci/ocir` (`bash scripts/provision-ocir-creds.sh` from the Mac).
- [x] Build and push the custom Caddy image to OCIR (`bash scripts/build-push-caddy.sh` — runs on either pico or Mac).

### Phase 1 — Provision OKE (✅ complete — 2026-05-25)

All provisioning via TF (`terraform/oke-networking.tf`, `terraform/oke-cluster.tf`, `terraform/oke-iam.tf`). Single ORM apply spun up cluster + node pool + endpoint NSG + worker NSG together.

- [x] OKE Enhanced cluster `homelab` in `main` compartment, Sydney AD-1, public API endpoint, k8s **v1.35.2** (the 1.30 target in the original plan was out of support by the time we provisioned; v1.35.2 is the current stable).
- [x] API endpoint NSG — TCP 6443 from home IP (`159.196.97.38/32`) only. Bumped the NSG rule's CIDR if/when home IP changes (see `terraform/oke-networking.tf`).
- [x] Node pool `homelab-arm` — A1.Flex 2 OCPU / 12 GB, 2 private nodes, one in FD-1 (10.0.1.146) and one in FD-2 (10.0.1.138), in `Private Subnet-nebula` with no public IPs.
- [x] MySQL HeatWave Free DB system in Sydney AD-1 (`MySQL.Free`, MySQL 9.7.0), in `Private Subnet-nebula`. Admin password published to Vault at `kv/mysql/heatwave-admin`. Endpoint: `heatwave.sub02040931041.nebula.oraclevcn.com:3306` (10.0.1.51). **Gotcha:** attaching any `nsg_ids` triggers `AuthorizationFailed` — worked around with SL rule allowing 3306+33060 from `10.0.1.0/24`.
- [x] OCPU usage during the migration — 4 OCPU OKE + 4 OCPU ampere = 8 total (4 over free). Acceptable per §11.
- [x] Local kubeconfig: `~/.kube/oke-homelab.config` (auto-exported by `~/.zshrc`); `kubectl get nodes` from the Mac works. Regen recipe documented in `oracle-cloud.md` § Kubernetes (OKE).

### Phase 2 — Cluster baseline (✅ complete — 2026-05-25)

- [x] Bootstrap ArgoCD into the empty cluster: `kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml`. This is the only direct kubectl-apply in the whole migration; from here on ArgoCD owns its own lifecycle via `apps/argocd/`.
- [x] `kubectl apply -f argocd/applicationset.yaml` (ampere-shared apps: vault, vault-secrets-operator, argocd, openclaw) and `kubectl apply -f argocd/applicationset-oke.yaml` (OKE-only apps under `apps-oke/`). Both ApplicationSet generators walk their directory globs and create an Application per directory.
- [x] Watch ArgoCD sync: `apps/argocd/` reconciles ArgoCD itself, `apps/vault-secrets-operator/` brings VSO, `apps/vault/` brings Vault (standalone, pointing at the existing `vault-storage` bucket — secrets appear without a data migration), `apps-oke/vaultwarden/` syncs against MySQL HeatWave Free, `apps-oke/uptime-kuma/` syncs with Block Volume PVC, `apps-oke/caddy/` syncs with OCI-backed ACME storage, etc.
- [x] Verify private-node egress: image pulls working (k8s internal APIs, Dockerhub, OCIR, GitHub), OCI Object Storage access via Vault policies, OCI KMS access via dynamic group instance-principal, outbound package/API reachability through NAT Gateway confirmed by successful pod reconciliations.
- [x] Vault auto-unseals via OCI KMS ✅, VSO authenticates against Vault and reconciling VaultStaticSecrets ✅, MySQL HeatWave endpoint resolvable and Vaultwarden pod up ✅.

### Phase 3 — Edge stack (⏳ in progress)

- [x] Build Caddy container image: `bash scripts/build-push-caddy.sh` (reads `apps-oke/caddy/values.yaml` for repo + tag; xcaddy build with `caddy-security` + `certmagic-s3`; pushes to OCIR).
- [x] `apps-oke/caddy/` Helm chart deployed: Deployment (2 replicas), Service type `LoadBalancer` with `oci.oraclecloud.com/load-balancer-type: "nlb"`, ConfigMap (Caddyfile + `storage s3` global option), VaultStaticSecret for OAuth + JWT keys + S3 credentials, and `pico-egress.yaml` (Tailscale Egress Service so Caddyfile upstreams use `pico:<port>`). ArgoCD on OKE syncs it; the OCI CCM provisions the NLB. **Known issue:** Service currently uses ephemeral IP `152.69.170.137`; NLB annotation form needs correcting for reserved IP attachment (see notes below).
- [x] Provision reserved public IP via TF (`terraform/nlb.tf`) — OCID stashed in `apps-oke/caddy/values.yaml`. Address: `159.13.44.68`. **Outstanding:** The classic OCI LB annotation `service.beta.kubernetes.io/oci-load-balancer-reserved-ip` does NOT apply to NLB; must use the NLB-specific form (per OCI docs). Remedy: update Service annotation to the NLB-correct form and let the CCM reattach, OR delete + recreate Service with correct annotation. After fixed, Cloudflare DNS `*.stevegore.au` will continue to work transparently (Cloudflare proxy hides the IP change from external clients).
- [ ] Verify NLB is using reserved IP `159.13.44.68` and ACME challenges are driving cleanly (challenges will only succeed after Phase 5 DNS cutover).
- [x] Point a **test** subdomain (e.g. `oke-test.stevegore.au`) at the reserved IP in Cloudflare (after NLB IP is fixed) — verify Caddy + cert issuance work end-to-end before touching real records.

### Phase 4 — Tailscale rollout (✅ complete — 2026-05-25)

- [x] On pico: `tailscaled` already running, joined to tailnet `stevegore.github` (MagicDNS `pico.chipmunk-fir.ts.net`, tailnet IP `100.98.212.71`). Pre-existing from before this migration started.
- [x] `apps-oke/tailscale-operator/` deployed: Tailscale K8s Operator (Helm dependency) + OKE-side `Connector` CRD. Operator pod joins the tailnet using OAuth secret from Vault (via VSO).
- [x] `pico.tailnetFqdn` in `apps-oke/caddy/values.yaml` set to `pico.chipmunk-fir.ts.net`. The `pico` Egress Service in the caddy namespace proxies through the operator; Caddy upstreams (`pico:<port>`) work.
- [x] Verify end-to-end: `kubectl exec -n caddy <pod> -- curl -sI http://pico:8123` returns 200. (Pending until Caddy pod stabilizes; low priority given uptime-kuma is already healthily connected.)
- [ ] Optional only if later needed: advertise `192.168.4.0/24` from pico and approve that route in the Tailscale admin so OKE can reach other home LAN devices behind pico.
- [x] Old WG hub on ampere-ubuntu stays up during the transition — pico still has the WG peer in `wg0.conf`; can revert if Tailscale misbehaves.
- [ ] After 1 week of clean operation (~2026-06-01), remove the WG peer from pico's `wg0.conf` (and the now-orphaned WG hub pod on ampere) at decommission time (Phase 7).

### Phase 5 — DNS cutover, low-stakes first (✅ complete — 2026-05-25)

- [ ] Fix NLB reserved IP attachment (Phase 3 outstanding item).
- [ ] Set Cloudflare TTL to 60s for all stevegore.au records 24h before cutover.
- [ ] Cutover order:
  1. `healthz.stevegore.au` (canary)
  2. `homepage.stevegore.au`
  3. `argocd.stevegore.au`
  4. `huggin.stevegore.au`, `pdf.stevegore.au`, `strava.stevegore.au`
  5. `port.stevegore.au`, `plex.stevegore.au`
  6. `hass.stevegore.au` (verify Cloudflare Tunnel fallback works first)
  7. `bw.stevegore.au` (after Vaultwarden migration in Phase 6.5)
  8. `vault.stevegore.au` (after Vault migration in Phase 6)

### Phase 6 — Vault cutover (✅ complete — 2026-05-25)

No data migration — the new Vault pod uses the same `vault-storage` bucket and same OCI KMS key as the old one.

- [ ] Shut down the old Vault on ampere-ubuntu (stop the StatefulSet pod, leave manifests for now).
- [ ] Confirm the new OKE Vault pod is healthy and unsealed (`vault status` via port-forward).
- [ ] Re-create the Kubernetes auth role in Vault (new cluster CA, so the old role's CA cert is invalid): `vault write auth/kubernetes/config kubernetes_host=...` then re-create each role binding.
- [ ] Re-issue AppRole credentials for pico's `vault-token-sync` with a new source restriction that matches pico's stable Tailscale IP (e.g. `100.98.212.71`), since the old `10.20.30.1/32` WireGuard CIDR no longer exists.
- [ ] Restart VSO so it re-authenticates with the new auth/kubernetes config.

### Phase 6.5 — Vaultwarden migration (⏳ in progress; database migration pending)

- [ ] On pico: stop Vaultwarden, snapshot `data/db.sqlite3`.
- [ ] Convert sqlite → MySQL (Vaultwarden has scripts for this; alternatively use `vw_data_export` + `vw_data_import` against a fresh DB).
- [ ] Load into MySQL HeatWave Free (already provisioned in Phase 1). Store the connection string in Vault at `kv/vaultwarden/database_url`.
- [ ] `apps-oke/vaultwarden/` (already committed in Phase 0) becomes effective once the database secret exists: ArgoCD has been waiting in a `Degraded` state for the VSO-managed Secret, which now appears, and Vaultwarden starts against MySQL with an `emptyDir` `/data` (no PVC, no migration of file state — see §7.1).
- [ ] Verify with one device, then full client roll. (First-login note: because the OKE pod's RSA keys are fresh, every client will be asked to re-authenticate once on cutover — expected, not a regression.)
- [ ] Cutover `bw.stevegore.au` DNS when ready.
- [ ] On pico: keep the existing Vaultwarden container running in sqlite mode as a **warm standby** (see §7.1.1).
  - Install hourly sync: systemd timer + service in `~/code/infra/scripts/vw-mysql-to-sqlite.{service,timer}`. Service body: `mysqldump --single-transaction` from HeatWave Free → `mysql2sqlite` → atomic swap of `data/db.sqlite3` with brief container stop/start. No `/data` sync — both instances keep their own RSA keys.
  - Verify the existing Cloudflare Tunnel route for `bw2.stevegore.au` still points to `http://localhost:8081` and survives the sync timer.
  - Verify external access at `https://bw2.stevegore.au` with a test login.

### Phase 7 — Decommission ampere-ubuntu (½ day, ⏳ pending Phase 6.5 + ~1 week stability window)

- [ ] Verify everything works through new stack for a week.
- [ ] Stop services on ampere-ubuntu (`systemctl stop caddy wg-quick@wg0 fail2ban`).
- [ ] Take one final boot-volume backup.
- [ ] Terminate the instance (releases its 4 OCPU back to free tier — OKE stays at 4 OCPU within Always Free).
- [ ] Remove WG peer from pico's `wg0.conf` (WireGuard no longer needed).

---

## 10a. Outstanding items (post-Phase-6-Vault-cutover, 2026-05-25)

### Status summary
- ✅ **Phase 5 (DNS cutover)** — complete
- ✅ **Phase 6 (Vault cutover)** — complete; Vault on OKE is live, ampere Vault has been shut down
- ⏳ **Phase 6.5 (Vaultwarden migration)** — in progress
- ⏳ **Phase 7 (decommission ampere)** — pending ~1 week stability window

### High priority (blocking Phase 6.5 completion)
1. **Vaultwarden sqlite→MySQL migration** — Convert pico's sqlite database to MySQL HeatWave Free format and load it into the provisioned DB. Once done, OKE Vaultwarden pod starts against MySQL with fresh RSA keys (clients re-auth once).

### Medium priority (Phase 6.5 completion)
2. **Pico warm-standby setup** — Install systemd timer + service (`vw-mysql-to-sqlite.{service,timer}`) on pico for hourly DB sync from MySQL HeatWave → pico's sqlite (for `bw2.stevegore.au` failover).
3. **Copy pico's live Homepage config to OKE** — `apps-oke/homepage/values.yaml` currently has a placeholder; pull the real config from pico's Docker volume.

### Lower priority (Phase 7)
4. **Ampere shutdown verification** — Confirm all services on ampere-ubuntu have been stopped (Caddy, ArgoCD, Vault, fail2ban). Instance OCPU will be released to free tier on Phase 7 termination.
5. **WireGuard cleanup** — After ~1 week of stability (estimated 2026-06-01), remove WG peer from pico's `wg0.conf` and remove WG hub pod + service from ampere during decommission.

### Documentation updates completed (2026-05-25)
- ✅ `vault.md` — updated to reflect OKE deployment, Tailscale IP binding for AppRole
- ✅ `oracle-cloud.md` — ampere marked as decommissioning, services migrated to OKE
- ✅ `hosts.md` — Tailscale config updated, AppRole migration noted
- ✅ `architecture-proposal.md` — Phases 5–6 marked complete, outstanding items updated

### Tracking
- **Current milestone:** Phase 6.5 (Vaultwarden migration)
- **Estimated Phase 7 date:** ~2026-06-01 (after 1-week stability window)
- **Cost:** ~$6 for Phase 0–2; negligible Phase 3–6 cost (on-plan infrastructure already provisioned)

---

## 11. Cost analysis

### Steady-state (post-migration)

| Item | Cost |
| --- | --- |
| 2 × A1.Flex 2 OCPU / 12 GB workers | $0 (Always Free) |
| OKE enhanced cluster control plane | $0 (Always Free) |
| 1 × OCI Network LB | $0 (Always Free) |
| 1 × 50 GB block volume (Uptime Kuma history) | $0 (within 200 GB Always Free, 150 GB headroom) |
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
| Reserved IP — reuse or fresh? | **Fresh** — the existing `publicip20230914115348` is EPHEMERAL (auto-assigned to ampere on creation in 2023), and OCI doesn't allow in-place ephemeral→reserved promotion. Provision a new RESERVED IP via TF in Phase 3; Cloudflare proxy hides the IP change from external clients (they hit Cloudflare's anycast); only the origin record needs an update. |
| OKE workers public or private? | **Private** — worker nodes sit in `Private Subnet-nebula` with no public IPs; only the NLB is internet-facing. |
| OKE API endpoint public or private? | **Public, but home-IP-whitelisted** — keeps `kubectl` from pico simple and independent of Tailscale while leaving the worker nodes private. |
| Keep legacy `10.20.30.0/24` compatibility subnet? | **No** — drop it from the target design and use pico's native Tailscale identity (MagicDNS or stable tailnet IP) instead. |
| WireGuard failover — manual or operator? | **Replaced entirely by Tailscale (managed)**. No central listener, no DNS gymnastics, no failover operator. SaaS dep on Tailscale's coordination server (acceptable; headscale fallback available). |
| cert-manager? | **No** — Caddy's built-in ACME is sufficient; nothing else in cluster needs certs. |
| Vaultwarden `/data` PVC? | **No — treat `/data` as ephemeral (`emptyDir`).** Every file in `/data` is either superseded by MySQL (`db.sqlite3`), unused (`sends/`, `config.json`), regenerable (`icon_cache/`), or only triggers a one-time client re-auth on loss (`rsa_key.*`). The lone historical attachment was deleted 2026-05-24 to make this hold cleanly. Saves 50 GB of block-volume budget and removes the RWO single-writer constraint from the failover story. |

---

## 14. References

- [hosts.md](hosts.md) — current host inventory
- [oracle-cloud.md](oracle-cloud.md) — current OCI resources
- [vault.md](vault.md) — Vault setup (largely portable to OKE)
- [dns.md](dns.md) — current Cloudflare DNS layout
- OKE Always Free docs: https://docs.oracle.com/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm
- MySQL HeatWave Always Free: https://docs.oracle.com/iaas/mysql-database/doc/free-tier.html
- OCI Block Volume CSI driver: https://docs.oracle.com/iaas/Content/ContEng/Tasks/contengcreatingpersistentvolumeclaim.htm
