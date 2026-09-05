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
`compose.yaml`. The reviewed source is `pico/homeassistant/compose.yaml`; the
deployed copy remains `/opt/ha-container/compose.yaml`. The stack is deliberately
not registered with Portainer, so Renovate opens held PRs for Core/Matter and the
database policy holds MariaDB, but merging cannot restart HA unexpectedly.

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
docker compose pull && docker compose up -d      # after backup + reviewed tag bump
```

`compose.yaml` pins an exact Core version (not `stable`) so upgrades are deliberate.
Before an image change, run `/home/steve/.local/bin/backup-ha-container`; the
nightly copy runs at 00:30 automatically.

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
| `tuya_local` | active | Local control (`local_push`), bundles `tinytuya==1.20.0`. Version `2026.7.2`. Source: [`make-all/tuya-local`](https://github.com/make-all/tuya-local). |
| `eero` | active | Read-only sensors + device tracker, **115 registry entities**. **No services exposed** — cannot create DHCP reservations from HA. |
| `eero_tracker` | legacy, **archived upstream** | v1.0.10. [`jrlucier/eero_tracker`](https://github.com/jrlucier/eero_tracker) has been **archived since May 2021** — no fixes will ever land. Legacy YAML `device_tracker` platform (`configuration.yaml`), creates **0 registry entities** — it writes to `known_devices.yaml` (107 devices tracked). Kept with `interval_seconds: 30` to avoid scan overrun. Redundant with the modern `eero` component; removal is a presence-detection behaviour change, so it has not been done. |

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

**The same DHCP drift hits LIFX, and there it is far worse** — a stale LIFX host
that collides with a live bulb's IP leaks UDP sockets without bound and
eventually breaks unrelated integrations. See
[LIFX socket leak](#lifx-socket-leak--fd-exhaustion--tuya_local-discovery-failure-2026-08-08).
Reserve the LIFX bulbs too.

## `eero_tracker` traceback noise is transient DNS, not auth

`eero_tracker` periodically dumps a full traceback ending in:

```
requests.exceptions.ConnectionError: HTTPSConnectionPool(host='api-user.e2ro.com', port=443):
  ... NameResolutionError(... [Errno -3] Try again)
socket.gaierror: [Errno -3] Try again
```

**This is not expired auth and not an eero API change** — the usual suspects for
a 5-year-archived component. `EAI_AGAIN` is a *transient* resolver failure. The
container resolves via `8.8.8.8`/`8.8.4.4` (Docker overrides the host's
`127.0.0.53` systemd-resolved stub), so occasional failures against public DNS
are expected.

Rate is ~4 failures/day against `interval_seconds: 30` — **~0.14% of ~2880
scans**. Each failure produces a long traceback because the component has no
exception handling around `requests.get`, and it is archived upstream so it will
never get any. One failure prints the message several times (chained
exceptions), so **grep counts overstate the incident count** — count
`socket.gaierror` occurrences, not message matches.

Verdict: cosmetic log noise, no functional impact (`consider_home: 60` rides out
a missed scan). **Nothing was changed for this on 2026-08-08** — 0 occurrences in
the 88 min after the HA restart, but at ~4/day that window proves nothing, so
treat this as *unfixed and understood*, not fixed. Options, in order of
preference:

1. **Leave it** — 4 tracebacks/day, harmless.
2. **Silence it** — `logger:` override for the `homeassistant` "Error doing job"
   path (blunt; would hide unrelated errors too).
3. **Remove `eero_tracker`** — the modern `eero` component already supplies 115
   entities. But `eero_tracker` is the thing populating `known_devices.yaml`
   (107 devices), so this is a **real presence-detection behaviour change**,
   not a cleanup. Needs a deliberate decision + migration of anything relying on
   those legacy `device_tracker.*` entities.

## LIFX socket leak → FD exhaustion → `tuya_local` discovery failure (2026-08-08)

**The single most important gotcha on this box.** A LIFX IP clash leaks UDP
sockets until the HA process holds >1024 file descriptors, at which point
*any* library using `select()` breaks — even though nothing is wrong with
that library.

### Symptom

`tuya_local` discovery failing ~100×/day, every scan pass (`SCAN_INTERVAL` is
10 min):

```
File "/config/custom_components/tuya_local/helpers/discovery.py", line 82, in _scan_all
    return tinytuya.deviceScan(verbose=False, poll=False)
ValueError: filedescriptor out of range in select()
```

`tuya_local` is the **victim, not the culprit**. `select.select()` cannot
accept a descriptor numbered ≥ `FD_SETSIZE` (1024) — a hard glibc/CPython
limit, unrelated to `ulimit`. The HA process was holding **1121 FDs**, so
every newly-created socket got a number above 1024 and the scan died
instantly.

### Root cause

`ss -uan` showed **1037 ESTAB UDP sockets to a single peer, `192.168.4.38:56700`**
(56700 = the LIFX LAN protocol port), out of 1285 UDP sockets total.

Two LIFX config entries both claimed `192.168.4.38`:

| Entry | unique_id (MAC) | State |
|---|---|---|
| `Lounge Room 1` | `d0:73:d5:51:6d:ea` | `loaded` — genuinely at `.38` per ARP |
| `Dining Room 1` | `d0:73:d5:51:59:9e` | `setup_retry` — **stale host, bulb not on the LAN at all** |

A ping sweep of the whole `192.168.4.0/22` (both `.4.x` and `.5.x`) found 21
LIFX devices; `d0:73:d5:51:59:9e` was **not among them**. That bulb is gone.

So `aiolifx` kept connecting "Dining Room 1" to `.38`, got a serial mismatch
back from Lounge Room 1, retried — and **leaked one UDP socket per retry,
forever**. This is a known aiolifx failure mode: sockets are only closed when a
bulb is deemed offline, so an IP clash (where something *does* answer) never
triggers the close path.

**Beware the self-reinforcing loop:** once FD numbers pass 1024, `tinytuya`'s
scan raises mid-loop and leaks its own sockets too, so the condition sustains
itself.

### Fix applied

Disabled the dead `Dining Room 1` config entry (entry_id
`00ed63d36ce6523decf13fabe57d878f`) — matching what was already done by hand for
the dead `Dining Room 2` and `Light strip` entries (`disabled_by: user`). A
user-disabled entry is not re-enabled by discovery.

```python
ha_set_integration(entry_id="00ed63d36ce6523decf13fabe57d878f", enabled=False)
```

**Disabling alone does not reclaim the leaked sockets** — they are orphaned in
the process and survive the entry unload (FD count went 1121 → 1119). An **HA
restart is required** to actually drop them.

`ha_restart` restarts the HA **process inside** the container, so
`docker ps` still reports the old container uptime ("Up 7 days"). Confirm the
restart by the HA pid changing (71 → 364), not by container uptime.

### Verified result (2026-08-08)

| Metric | Before | After |
|---|---|---|
| HA process FDs | 1121 | **77** |
| Highest FD number | 1131 (> 1024 → `select()` fails) | **103** |
| UDP sockets to `192.168.4.38:56700` | 1038 | **1** |
| Total UDP sockets | 1285 | 249 |
| `filedescriptor out of range` in log | 102 | **0** (over 88 min ≈ 8 scan intervals) |

Positive confirmation that discovery works end-to-end, not merely that it is
quiet — `discovery.py:221` logs a product-id warning only on the **success**
path, well past the line-82 `deviceScan` that used to throw:

- last successful scan before the fix: **2026-08-01 11:45:47** (the previous HA
  start, before the leak accumulated)
- first successful scan after the fix: **2026-08-08 15:35:47**, exactly one
  10-minute `SCAN_INTERVAL` after the 15:25:26 restart

**Tuya discovery had therefore been dead for a full 7 days.** Device control was
never affected — all four `tuya_local` entries use static hosts and stayed
`loaded` throughout.

### Why it surfaced as an unhandled task exception

`_scan_all()` wraps `tinytuya.deviceScan()` in `except OSError`. `ValueError` is
**not** an `OSError`, so it escaped the handler and bubbled up as
`Error doing job: Task exception was never retrieved`. Worth remembering when
reading these tracebacks: the traceback names `tuya_local`, but the handler gap
is why it is *loud*, and the FD leak elsewhere is why it *happens*.

### Diagnosing this again

```bash
# The HA process is NOT pid 1 in the container — find it first
HAPID=$(docker exec homeassistant-app pgrep -f "m homeassistant" | head -1)
docker exec homeassistant-app sh -c "ls /proc/$HAPID/fd | wc -l"      # want << 1024
docker exec homeassistant-app grep -i "open files" /proc/$HAPID/limits # soft limit 2048

# Who is hogging sockets? (host networking, so run ss on pico)
ss -uan | tail -n +2 | awk '{print $5}' | sort | uniq -c | sort -rn | head
```

`ulimit` is a **red herring** here — the soft limit is 2048 and was never hit.
The breakage is purely the 1024 `FD_SETSIZE` ceiling on `select()`.

### Still outstanding

`Master Bedroom Right Side` (`192.168.4.22`) and `Master Bedroom Left Side`
(`192.168.4.41`) are also stuck in `setup_retry`, and neither MAC appears in the
LAN sweep. They are **not currently leaking** — nothing answers at those IPs, so
aiolifx's offline path closes the socket correctly. But if DHCP ever hands `.22`
or `.41` to another device, they will start leaking exactly like `Dining Room 1`
did. DHCP reservations for the LIFX bulbs (same fix as the Tuya bulbs above)
would prevent the whole class of problem.

## Light service parameter churn

`light.turn_on` has had its colour-temperature parameter renamed twice. As of the
running Core version, the **only** accepted key is `color_temp_kelvin`:

- `kelvin` — **removed**. Fails with `extra keys not allowed @ data['kelvin']`.
- `color_temp` (mireds) — **removed in 2026.3**.
- `color_temp_kelvin` — current. Same units as the old `kelvin`, so a `kelvin`
  value carries over unchanged (no mired conversion).

This bit `automation.bathroom_lights_morning_colour`, which failed silently at
04:30 every day (fixed 2026-08-08 — `kelvin: 6500` → `color_temp_kelvin: 6500`).
Verify the live schema rather than trusting docs:

```python
ha_list_services(domain="light", query="turn_on", detail_level="full")
```

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

### Old Supervised install — fully torn down

Disabling `hassio-supervisor.service` alone was not sufficient:
`hassio-apparmor.service` was still enabled and declared
`Wants=hassio-supervisor.service`, so `multi-user.target` pulled the Supervisor
back up on every boot. The Supervisor then recreated all five plugin containers
and resumed host-level `autofix` across the whole Docker daemon.

Resolved on 2026-08-01 by disabling both units, removing the seven legacy
containers, and removing the `hassio` bridge network. Verified on the booted
system: both units report `disabled`/`inactive`, no `hassio*` containers remain,
and `homeassistant-app` is still the only listener on port 8123.

- `hassio-supervisor.service`: **disabled and stopped** (2026-08-01).
- `hassio-apparmor.service`: **disabled and stopped** (2026-08-01) — this was
  the unit that kept pulling the Supervisor back up.
- Core was set to `boot=false`/`watchdog=false`; the legacy `homeassistant`
  container has since been removed.
- All add-ons (`core_mariadb`, `core_matter_server`, `a0d7b954_vscode`,
  `a0d7b954_phpmyadmin`) set to `boot: manual` and stopped. **This matters** — on
  `auto` the Supervisor would start a second Matter server on the same fabric.
- Old config remains at `/usr/share/hassio/homeassistant` as a read-only rollback
  reference. The Supervisor images remain unreferenced. The `os-agent` package
  and `haos-agent.service` remain enabled/running but are unused by Container
  mode; remove them only after the rollback window closes.

The removed containers were `hassio_supervisor`, `hassio_dns`, `hassio_audio`,
`hassio_multicast`, `hassio_cli`, `hassio_observer`, and the exited Supervised
Core container `homeassistant`. Order matters if this ever has to be repeated:
disable both systemd units before removing containers, otherwise the
Supervisor's `Restart=always` path recreates them. The Container stack does not
use `hassio_dns` or the removed `hassio` network.

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

# FD health — if this approaches 1024, select()-based libs (tinytuya) break.
# NOTE: the HA process is not pid 1 in the container.
HAPID=$(docker exec homeassistant-app pgrep -f "m homeassistant" | head -1)
docker exec homeassistant-app sh -c "ls /proc/$HAPID/fd | wc -l"

# Top socket peers — finds leaks (e.g. LIFX :56700). Host networking, so run on pico.
ss -uan | tail -n +2 | awk '{print $5}' | sort | uniq -c | sort -rn | head

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
  Container mode once the stale `hassio` entry is removed. Duplicati does not
  mount `/opt`, so `scripts/backup-ha-container.sh` creates a logical MariaDB
  dump plus config/Matter archive and stages it under Duplicati's existing
  `/usr/share/hassio/` source before the 01:00 job.
- **eero integration is read-only.** No service to create reservations, change SSIDs, etc. Reservations must be done in the eero mobile app.
- **`tuya_local` requires a static `host`** — there's no built-in auto-discovery mode for the IP. The `auto` option in the schema is for **protocol version**, not IP. Workaround documented above.
- **`homeassistant.reload_config_entry` reads in-memory state, not disk.** Always pair direct `.storage` edits with a restart.
- **Restarting HA breaks the SSE connection** to the official MCP server. Claude Code reconnects automatically; just wait ~30–60s after `ha_restart`.
- **A fresh copy of a Supervised config boots dirty once.** Expect
  `hassio → backup → cloud → default_config` to all fail on the first start; HA
  removes the stale `hassio` config entry itself and the next start is clean.
