# uptime-kuma

Uptime/status monitoring, deployed on OKE. **Migrated off pico** — see "History" below;
the Portainer stack and its SQLite database are gone.

- **Image:** `docker.io/louislam/uptime-kuma:2.4.0`, `replicaCount: 1`. Kuma 2.x, not 1.x —
  it supports an external MariaDB/MySQL backend, which is what this deployment uses.
- **Database:** **MySQL on OCI HeatWave**, not SQLite. Host
  `heatwave.sub02040931041.nebula.oraclevcn.com:3306`, database `uptime_kuma`, user
  `uptime_kuma`. The host is a private VCN address, so it is reachable **only from inside
  the cluster** (or another VCN host) — you cannot connect from a laptop.
- **Credentials:** Vault `kv/uptime-kuma/config`, synced by VSO (`refreshAfter: 1h`) into the
  `uptime-kuma-db` Secret in the `uptime-kuma` namespace. Keys: `db_hostname`, `db_port`,
  `db_name`, `db_username`, `db_password`, `admin_username`, `admin_password`.
- **Storage:** PVC `uptime-kuma-data`, 50Gi on `oci-bv` (RWO), mounted at `/app/data`. With
  MySQL holding the monitor config, this now only carries local state — it is **not** where
  monitors live, so restoring it does not restore your monitors.
- **Exposure:** Caddy serves `uptime.stevegore.au` (Authentik-protected) and
  `status.stevegore.au` (public status page, slug `homelab`), both proxying
  `uptime-kuma.uptime-kuma.svc.cluster.local:3001`.
- **Reaching pico:** `templates/pico-egress.yaml` creates a Tailscale egress Service so
  in-cluster Kuma can probe pico's internal ports (`http://pico:9092`, `http://pico:8191`, …).

## Provisioning monitors and the status page

Monitor config is written **straight into MySQL** by two idempotent scripts
(`scripts/setup_uptime_kuma.py`, `scripts/setup_status_page.py`). ArgoCD runs them from the
`uptime-kuma-reconcile` PostSync hook inside the VCN, using the VSO-managed `uptime-kuma-db`
Secret. After both transactions commit, the hook deletes only the Kuma Deployment pod so its
in-memory monitor cache reloads; the ReplicaSet recreates it. The hook's ServiceAccount has
namespace-scoped `get`, `list`, and `delete` permission on pods and nothing else.

Changes to either setup script trigger an immediate `uptime-kuma` sync through
`.github/workflows/argocd-sync.yml`. No laptop database route, copied secret, temporary
ConfigMap, or imperative Deployment mutation is required.

**Adding a monitor for a new service** means editing `scripts/setup_uptime_kuma.py` and
re-running the above. Adding it to the **public** status page is a separate, deliberate step —
append the monitor name to a group in `scripts/setup_status_page.py` and run that script the
same way. Remember `status.stevegore.au` is world-readable: anything listed there advertises
that hostname's existence.

## History

- **2026-05-24/25** — moved to Kubernetes as `apps-oke/uptime-kuma`, then consolidated into
  `apps/` on 2026-05-26.
- **2026-06-06** — switched from SQLite to the MySQL HeatWave backend (`fcaab8a`). This is the
  change that invalidated the old "stop the container, mount the named volume, run python
  against `kuma.db`" runbook.
- The pico Portainer stack (was ID 61) no longer exists. Its Docker volume
  `uptime-kuma_uptime-kuma_data` is still on pico, **orphaned** — it holds the pre-2026-06-06
  SQLite database and nothing reads it.
