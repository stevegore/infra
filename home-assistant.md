# Home Assistant

**HA Container** install on `pico` (192.168.4.120), managed by `docker compose` from
`/opt/ha-container`. Migrated from HA Supervised on **2026-08-01** — see
[Migration from Supervised](#migration-from-supervised-2026-08-01).

| | |
|---|---|
| Stack dir | `/opt/ha-container` (`compose.yaml`, `README.md`, `.env`) |
| Core container | `homeassistant-app` (`ghcr.io/home-assistant/home-assistant`), host networking, `:8123` |
| Config root | `/opt/ha-container/config` (host) = `/config` (in container) |
| Database | `homeassistant-db` — MariaDB 11, bound to `127.0.0.1:3307`, data in `./dbdata` |
| Matter | `homeassistant-matter` — `python-matter-server`, fabric in `./matter-data` |
| Secrets | `/opt/ha-container/.env` (mode 600) — DB password + `HA_DB_URL` |

There is **no Supervisor and no add-ons.** Core upgrades are an image tag bump in
`compose.yaml`, the same workflow as every other service on pico. The stack is
deliberately **not** registered with Portainer or the GitOps repo, so nothing
auto-deploys over it.

External access (unchanged by the migration):

- `hass.stevegore.au` — OKE NLB → Caddy → Tailscale Egress Service (`pico` svc) → pico:8123
- `hass2.stevegore.au` — via Cloudflare Tunnel directly from pico (`cloudflared.service`, systemd, not a container)

**`trusted_proxies` requirement:** HASS rejects proxied requests unless the forwarding host is trusted. `config/configuration.yaml` currently has:
```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
    - 10.0.0.0/8      # covers OKE pod CIDR 10.244.0.0/16 and the old 10.20.30.x
    - 100.64.0.0/10   # Tailscale CGNAT range
```

Long-lived access token: `~/code/infra/home-assistant.token` (gitignored via `*.token`).

## Operating the stack

```bash
cd /opt/ha-container
docker compose ps
docker compose logs -f homeassistant
docker compose restart homeassistant
docker compose pull && docker compose up -d      # after bumping the image tag
```

`compose.yaml` pins an exact Core version (not `stable`) so upgrades are deliberate.

## Non-obvious settings that must not be lost

These were all discovered the hard way during the migration; the Supervised
install got them implicitly by running the Core container **privileged**.

| Setting | Why |
|---|---|
| `--fabricid 2 --vendorid 4939` on `homeassistant-matter` | Defaults are fabricid 1 / vendorid 65521. With the defaults the server silently allocates a **brand-new empty fabric** — no error, every commissioned device just disappears. Real data is in `./matter-data/server-2-134b`. |
| `/run/dbus` mounted **read-write** | Connecting to the D-Bus socket needs write access. |
| `apparmor=unconfined` on `homeassistant-app` | BlueZ D-Bus access fails under Docker's default AppArmor profile with `AttributeError: 'NoneType' object has no attribute 'send'`. |
| `NET_ADMIN` + `NET_RAW` | HA logs this requirement explicitly for Bluetooth adapter management. |
| `network_mode: host` | mDNS/SSDP discovery (LIFX, Sonos, Cast, WebOS, Brother, upnp) and the HomeKit bridge on `:21063`. |
| `recorder.db_url: !env_var HA_DB_URL` | Keeps the DB password out of `configuration.yaml`. If this config is ever restored elsewhere, that env var **must** be set or the recorder won't start. |
| `recorder.db_max_retries: 30` | Boot-race protection — see below. |

### The boot race (found by testing, 2026-08-01)

Docker **ignores compose `depends_on` when the daemon starts at boot** — it just
restarts containers per their restart policy, in no particular order. So
`homeassistant-app` can come up before `homeassistant-db` is accepting
connections.

Recorder's default is 10 retries × 3s ≈ **30 seconds**, after which it gives up
**permanently**: `recorder`, `history`, `logbook`, `energy` and
`usage_prediction` all fail to set up. HA keeps running and still serves HTTP
200, so the failure is **silent** — you'd only notice when history was missing.
Starting the database afterwards does **not** recover it; only an HA restart does.

Verified by holding the DB down for 60s while HA started: with the defaults, all
five integrations were permanently dead. With `db_max_retries: 30`
(≈90s of retries) the same test logged 21 retries and then connected cleanly,
with 0 setup failures.

30s would usually be enough at a real boot, but MariaDB doing InnoDB recovery
after an unclean shutdown can easily exceed it — which is exactly the case where
a reboot would silently cost you history.

## MCP servers

Two MCP servers are wired into Claude Code via `/home/steve/code/infra/.mcp.json`. Both authenticate with the same long-lived token, exported as `HA_TOKEN` from `~/.zshrc` (which `cat`s the token file).

| Server          | Type  | Transport                                | Source                                                                |
| --------------- | ----- | ---------------------------------------- | --------------------------------------------------------------------- |
| `home-assistant` | SSE   | `http://pico.local:8123/mcp_server/sse`  | Built-in HA `mcp_server` integration (HA 2025.2+, must be enabled in UI) |
| `ha-mcp`        | stdio | `uvx ha-mcp@latest`                      | [`homeassistant-ai/ha-mcp`](https://github.com/homeassistant-ai/ha-mcp), 80+ tools |

Notes:

- The official endpoint is `/mcp_server/sse` — **not** `/api/mcp_server/sse` (that 404s).
- `uvx` comes from [`uv`](https://github.com/astral-sh/uv); installed at `~/.local/bin/uv` and `~/.local/bin/uvx`.
- `ha-mcp` env vars: `HOMEASSISTANT_URL=http://pico.local:8123`, `HOMEASSISTANT_TOKEN=${HA_TOKEN}`.
- Restart Claude Code after changing `HA_TOKEN` so child MCP processes inherit it.
- **Supervisor-dependent `ha-mcp` tools no longer work** — add-on management, Supervisor logs, and Supervisor backups have no backend now. Entity/automation/HACS tools are unaffected.

### Capability differences

| Capability | `home-assistant` (official) | `ha-mcp` (community) |
|---|---|---|
| Read live entity state | ✅ `GetLiveContext` | ✅ `ha_get_state`, `ha_get_overview` |
| Turn entities on/off | ✅ `HassTurnOn` / `HassTurnOff` (by area, name, domain) | ✅ `ha_call_service`, `ha_bulk_control` |
| Media control | ✅ rich tool set | ✅ via `ha_call_service` |
| Logs (system, error) | ❌ | ✅ `ha_get_logs` |
| Config-entry inspection | ❌ | ✅ `ha_get_integration` |
| Automations / scripts / dashboards CRUD | ❌ | ✅ `ha_config_*` |
| HACS, system health | ❌ | ✅ |
| Restart HA core | ❌ | ✅ `ha_restart` |
| Add-on management, Supervisor backups | ❌ | ⚠️ no longer applicable (no Supervisor) |

Default to the official server for everyday on/off + state, switch to `ha-mcp` for diagnostics and config changes.

## Custom components

| Component | Status | Notes |
|---|---|---|
| `tuya_local` | active | Local control (`local_push`), bundles `tinytuya==1.20.0`. Source: [`make-all/tuya-local`](https://github.com/make-all/tuya-local). |
| `eero` | active | Read-only sensors + device tracker. **No services exposed** — cannot create DHCP reservations from HA. |
| `eero_tracker` | legacy | Kept with `interval_seconds: 30` to avoid scan overrun. |

Custom component path: `/opt/ha-container/config/custom_components/<name>/` (host) or `/config/custom_components/<name>/` (in container).

**Version pinning gotcha:** custom components are the main thing that breaks on a
Core upgrade. `tuya_local` 2026.4.2 broke on Core 2026.7.4 with
`ImportError: cannot import name 'ATTR_MODE' from 'homeassistant.components.text.const'`
(Core moved it to `homeassistant.const`). Check HACS for pending updates
**before** bumping the Core image tag.

## State storage

HA's authoritative config-entry data lives in `/opt/ha-container/config/.storage/core.config_entries`.
The directory is owned by `steve`, but HA (running as root) rewrites the files as
root-owned — so reads need no sudo, writes still go through the container.

**Read pattern** (host, no sudo needed — this got simpler after the migration):

```bash
cat /opt/ha-container/config/.storage/core.config_entries
```

**Write pattern** (use the container — the files themselves are root-owned):

```bash
docker exec homeassistant-app python3 -c "
import json
path = '/config/.storage/core.config_entries'
with open(path) as f: d = json.load(f)
# ...mutate d['data']['entries']...
with open(path, 'w') as f: json.dump(d, f, indent=4)
"
```

If HA is stopped you can also write via a throwaway container, which avoids
quoting pain:
`docker run --rm -v /opt/ha-container/config:/config --entrypoint python3 ghcr.io/home-assistant/home-assistant:<tag> -c '...'`

**Critical:** `homeassistant.reload_config_entry` reloads from **in-memory** state, not disk. After editing `core.config_entries` directly you must **restart HA core** to pick up the change. Reload alone will not work.

## Tuya local-control state

Tuya bulbs are controlled both by the official cloud Tuya integration (`tuya`) and by `tuya_local`. The cloud one shows the bulbs as `Genio Smart WIFI bulb G45 RGB+CCT N`; the local one shows them as `Bathroom Light N`. Local has lower latency.

### Per-device matching

Each `tuya_local` config entry stores `host`, `device_id`, `local_key`, `protocol_version`. The local key and device ID are pulled from the Tuya cloud (originally extracted via `tuya-cloudcutter`/`tinytuya` wizard) and live in `core.config_entries`. Local keys rotate when the bulb is re-paired or firmware-updated via the Smart Life app — if local control breaks after a firmware update, suspect a key rotation first, then DHCP drift.

### Bathroom bulbs (current as of 2026-04-26)

| Bulb | MAC | IP (DHCP, drift-prone) | Tuya `device_id` (full) |
|---|---|---|---|
| Bathroom Light 1 | `10:5a:17:92:ac:38` | 192.168.4.111 | `bf80b9df7540a580878o7e` |
| Bathroom Light 2 | `10:5a:17:b3:fe:3f` | 192.168.4.70  | `bf68c1d85f35b4fc58k361` |
| Bathroom Light 3 | `10:5a:17:b4:08:4f` | 192.168.4.69  | `bfc06401135e58504ckbar` |
| Bathroom Light 4 | `10:5a:17:b4:08:91` | 192.168.4.72  | `bf6ba2a36341d1b003hrxj` |

OUI `10:5a:17` = Espressif (Tuya's SoC vendor) — useful for spotting Tuya devices in ARP/nmap output. Local keys are intentionally **not** in this doc; read them from `.storage/core.config_entries` when needed.

### Network topology gotcha

Pico's wired NIC `enp3s0` and Wi-Fi `wlp4s0` are both in `192.168.4.0/22` (covers `.4.0`–`.7.255`). The eero hands out a mix of `192.168.4.x` and `192.168.5.x` from this single subnet — they all sit on the same L2, no VLAN in play. Don't be fooled into thinking different `/24` octets imply isolation.

## Recurring problem: `tuya_local` setup_retry after DHCP drift

Symptoms: one or more `tuya_local` entries in `setup_retry` state, reason `tuya-local device offline`. Cloud Tuya integration for the same physical bulbs still works (they have power and Wi-Fi). Diagnostic confirms: pings to the configured IPs fail, but `nmap -p 6668 --open` finds Tuya devices at different IPs.

### Repair recipe

1. **Discover current IPs** by device_id (UDP broadcast):

   ```bash
   docker exec homeassistant-app python3 -c "
   import tinytuya, json
   d = json.load(open('/config/.storage/core.config_entries'))
   for e in d['data']['entries']:
       if e['domain'] != 'tuya_local': continue
       did = e['data']['device_id']
       r = tinytuya.find_device(dev_id=did)
       print(e['title'], did, '->', r.get('ip'))
   "
   ```

   `ip: None` means the bulb is genuinely offline (powered off or Wi-Fi disconnected).

2. **Back up** (always):

   ```bash
   cp /opt/ha-container/config/.storage/core.config_entries /tmp/core.config_entries.bak.$(date +%s)
   ```

3. **Patch the host field** for each found device using the write pattern above (mutate `e['data']['host']`).

4. **Restart HA** (reload alone is insufficient):

   ```bash
   cd /opt/ha-container && docker compose restart homeassistant
   ```

   Or via `ha_restart(confirm=True)` / the UI: Developer Tools → YAML → Restart.

5. **Verify** all entries are `loaded`:

   ```python
   ha_get_integration(domain="tuya_local")
   ```

### Permanent fix

Add DHCP reservations on the eero (Settings → Network settings → Reservations & Port Forwarding → Add a reservation, pick by MAC). The IPs in `core.config_entries` and the reservations must match — if you change one, change the other. Once reserved, this entire repair recipe should never need to run again.

## Migration from Supervised (2026-08-01)

### Why

It was a **hand-rolled** Supervised install: only `os-agent` came from dpkg, while
`/usr/sbin/hassio-supervisor` and its systemd unit were placed by hand in **2021**
and updated by nothing. The Supervisor self-updates from ghcr.io, so when
2026.07.5 began bind-mounting `/run/supervisor` into the Core container, container
creation failed with:

```
invalid mount config for type "bind": bind source path does not exist: /run/supervisor
```

Core vanished entirely (a pending 2026.4.4 → 2026.7.4 update removed the old
container; both the update and its rollback hit the missing mount). Container mode
removes this whole failure class — there is no host-side launcher to drift.

### Old Supervised install — now fully disabled

- `hassio-supervisor.service`: **disabled and stopped** (2026-08-01).
- Core: `boot=false`, `watchdog=false`, container `homeassistant` exited.
- All add-ons (`core_mariadb`, `core_matter_server`, `a0d7b954_vscode`,
  `a0d7b954_phpmyadmin`) set to `boot: manual` and stopped. **This matters** — on
  `auto` the Supervisor would start a second Matter server on the same fabric.
- Old config still at `/usr/share/hassio/homeassistant` — read-only reference,
  never modified during migration.

**Leftover cruft:** the plugin containers `hassio_dns`, `hassio_audio`,
`hassio_multicast`, `hassio_cli`, `hassio_observer` are still present.
All are `restart: no` **except `hassio_observer`, which is `restart: always` and
will come back after every reboot holding port 4357.** Safe to
`docker rm -f` all five once you're confident in the new stack.

### Verification at cutover

- 0 errors in the Core log; 0 setup failures.
- Entities 620 → 614. The 6 lost are exactly the Supervisor/add-on `update.*`
  entities (Core Update, Supervisor Update, MariaDB, Matter Server, phpMyAdmin,
  VS Code), which cannot exist without a Supervisor.
- All 37 automations, both scripts, and the HomeKit bridge (same bridge ID and
  pairing state) restored.
- `repair_count` 5 → 0 — the "unsupported system" / "unhealthy docker" warnings
  are gone; a Container install has no such constraints.
- Recorder: 283,377 states / 561 entities carried over.
- Matter: 0 nodes loaded, which is **correct** — 0 Matter devices are commissioned.

### Rollback

Documented in `/opt/ha-container/README.md`. Requires re-enabling the Supervisor
service, flipping Core `boot`/`watchdog` back to true and restarting the
`core_mariadb` + `core_matter_server` add-ons. History recorded since
2026-08-01 10:30 would be lost, as the two databases have diverged.

## Useful commands cheatsheet

```bash
# Inside-container Python (has tinytuya, voluptuous, all HA deps)
docker exec homeassistant-app python3 -c '...'

# Tail HA logs
docker compose -f /opt/ha-container/compose.yaml logs -f --tail 200 homeassistant
docker logs -f --tail 200 homeassistant-app

# Recorder DB (password from /opt/ha-container/.env)
set -a; . /opt/ha-container/.env; set +a
docker exec -e RP="$HA_DB_ROOT_PASSWORD" homeassistant-db \
  sh -c 'mariadb -uroot -p"$RP" -e "SELECT COUNT(*) FROM homeassistant.states;"'

# Check what the integration thinks is going on (via ha-mcp)
ha_get_integration(domain="tuya_local")
ha_get_logs(source="system", search="tuya_local")

# Find Tuya devices on the LAN (port 6668 = local Tuya protocol)
nmap -p 6668 --open -T4 -n 192.168.4.0/22

# ARP cache (no scan, just what's been seen recently)
ip neigh show | grep -E '192\.168\.[4-7]\.'

# HA REST API health check
curl -sS -H "Authorization: Bearer $(cat ~/code/infra/home-assistant.token)" http://localhost:8123/api/
```

Note: these now run **directly on pico** (no `ssh pico.local` prefix needed when
already on the host — check with `hostname` first).

## Known limitations

- **No add-ons.** Studio Code Server → use SSH / VS Code Remote. phpMyAdmin → the
  existing adminer container. MariaDB → `homeassistant-db`.
- **Supervisor backups are gone.** HA's built-in `backup` integration works in
  Container mode (it sets up cleanly once the stale `hassio` config entry is
  removed), and Duplicati already covers `/opt/ha-container`.
- **eero integration is read-only.** No service to create reservations, change SSIDs, etc. Reservations must be done in the eero mobile app.
- **`tuya_local` requires a static `host`** — there's no built-in auto-discovery mode for the IP. The `auto` option in the schema is for **protocol version**, not IP. Workaround documented above.
- **`homeassistant.reload_config_entry` reads in-memory state, not disk.** Always pair direct `.storage` edits with a restart.
- **Restarting HA breaks the SSE connection** to the official MCP server. Claude Code reconnects automatically; just wait ~30–60s after `ha_restart`.
- **A fresh copy of a Supervised config boots dirty once.** Expect
  `hassio → backup → cloud → default_config` to all fail on the first start; HA
  removes the stale `hassio` config entry itself and the next start is clean.
