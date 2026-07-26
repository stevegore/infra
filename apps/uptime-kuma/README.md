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
(`scripts/setup_uptime_kuma.py`, `scripts/setup_status_page.py`). They skip anything whose
name already exists, so re-running is safe. `setup_uptime_kuma.py` also deactivates any
monitor listed in `retired_monitor_names`.

Both scripts need a MySQL driver (`pymysql`) and VCN network access, and the Kuma image ships
neither `pip` nor a driver — so run them from a short-lived pod in the namespace, pulling
credentials from the existing Secret rather than passing a password by hand:

```bash
export KUBECONFIG=~/.kube/oke-homelab.config
kubectl -n uptime-kuma create configmap kuma-setup-script \
  --from-file=setup_uptime_kuma.py=scripts/setup_uptime_kuma.py

kubectl -n uptime-kuma run kuma-setup --restart=Never --image=python:3.12-alpine \
  --overrides='{
    "spec": {"containers": [{
      "name": "setup", "image": "python:3.12-alpine",
      "command": ["sh","-c"],
      "args": ["pip install --quiet --no-cache-dir pymysql && python /script/setup_uptime_kuma.py --host \"$DB_HOSTNAME\" --port \"$DB_PORT\" --database \"$DB_NAME\" --user \"$DB_USERNAME\" --password \"$DB_PASSWORD\""],
      "env": [
        {"name":"DB_HOSTNAME","valueFrom":{"secretKeyRef":{"name":"uptime-kuma-db","key":"db_hostname"}}},
        {"name":"DB_PORT","valueFrom":{"secretKeyRef":{"name":"uptime-kuma-db","key":"db_port"}}},
        {"name":"DB_NAME","valueFrom":{"secretKeyRef":{"name":"uptime-kuma-db","key":"db_name"}}},
        {"name":"DB_USERNAME","valueFrom":{"secretKeyRef":{"name":"uptime-kuma-db","key":"db_username"}}},
        {"name":"DB_PASSWORD","valueFrom":{"secretKeyRef":{"name":"uptime-kuma-db","key":"db_password"}}}
      ],
      "volumeMounts": [{"name":"script","mountPath":"/script"}]
    }],
    "volumes": [{"name":"script","configMap":{"name":"kuma-setup-script"}}]}
  }'

kubectl -n uptime-kuma logs -f kuma-setup
kubectl -n uptime-kuma delete pod kuma-setup configmap/kuma-setup-script
```

**Kuma caches monitors in memory at startup**, so a direct DB write is not picked up until the
pod restarts. Restart by deleting the pod (the ReplicaSet recreates it) rather than
`kubectl rollout restart`, which mutates the Deployment spec and shows up as ArgoCD drift:

```bash
kubectl -n uptime-kuma delete pod -l app.kubernetes.io/name=uptime-kuma
kubectl -n uptime-kuma wait --for=condition=ready pod -l app.kubernetes.io/name=uptime-kuma --timeout=180s
```

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
