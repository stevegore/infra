# Home Assistant

Supervised install on `pico` (192.168.4.120). Container: `homeassistant` (Docker). Config root on host: `/usr/share/hassio/homeassistant/` (root-owned). Same path inside the container: `/config/`.

External access:

- `hass.stevegore.au` — via WireGuard tunnel → Caddy on ampere-ubuntu → pico:8123
- `hass2.stevegore.au` — via Cloudflare Tunnel directly from pico

Long-lived access token: `~/code/infra/home-assistant.token` (gitignored via `*.token`).

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

### Capability differences

| Capability | `home-assistant` (official) | `ha-mcp` (community) |
|---|---|---|
| Read live entity state | ✅ `GetLiveContext` | ✅ `ha_get_state`, `ha_get_overview` |
| Turn entities on/off | ✅ `HassTurnOn` / `HassTurnOff` (by area, name, domain) | ✅ `ha_call_service`, `ha_bulk_control` |
| Media control | ✅ rich tool set | ✅ via `ha_call_service` |
| Logs (system, error, supervisor add-on) | ❌ | ✅ `ha_get_logs` |
| Config-entry inspection | ❌ | ✅ `ha_get_integration` |
| Automations / scripts / dashboards CRUD | ❌ | ✅ `ha_config_*` |
| HACS, backups, system health | ❌ | ✅ |
| Restart HA core | ❌ | ✅ `ha_restart` |

Default to the official server for everyday on/off + state, switch to `ha-mcp` for diagnostics and config changes.

## Custom components

| Component | Status | Notes |
|---|---|---|
| `tuya_local` | active | Local control (`local_push`), bundles `tinytuya==1.18.0`. Source: [`make-all/tuya-local`](https://github.com/make-all/tuya-local). |
| `eero` | active | Read-only sensors + device tracker. **No services exposed** — cannot create DHCP reservations from HA. |
| `eero_tracker` | legacy | Kept with `interval_seconds: 30` to avoid scan overrun. |

Custom component path: `/usr/share/hassio/homeassistant/custom_components/<name>/` (host) or `/config/custom_components/<name>/` (in container).

## State storage

HA's authoritative config-entry data lives in `/config/.storage/core.config_entries` (root-owned on the host; readable+writable from inside the `homeassistant` container as `/config/.storage/core.config_entries`).

**Read pattern** (host, no sudo needed):

```bash
ssh pico.local "cat /usr/share/hassio/homeassistant/.storage/core.config_entries"
```

**Write pattern** (use the container — host file is root-owned):

```bash
ssh pico.local "docker exec homeassistant python3 -c \"
import json
path = '/config/.storage/core.config_entries'
with open(path) as f: d = json.load(f)
# ...mutate d['data']['entries']...
with open(path, 'w') as f: json.dump(d, f, indent=4)
\""
```

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

OUI `10:5a:17` = Espressif (Tuya's SoC vendor) — useful for spotting Tuya devices in ARP/nmap output. Local keys are intentionally **not** in this doc; read them from `/config/.storage/core.config_entries` when needed.

### Network topology gotcha

Pico's wired NIC `enp3s0` and Wi-Fi `wlp4s0` are both in `192.168.4.0/22` (covers `.4.0`–`.7.255`). The eero hands out a mix of `192.168.4.x` and `192.168.5.x` from this single subnet — they all sit on the same L2, no VLAN in play. Don't be fooled into thinking different `/24` octets imply isolation.

## Recurring problem: `tuya_local` setup_retry after DHCP drift

Symptoms: one or more `tuya_local` entries in `setup_retry` state, reason `tuya-local device offline`. Cloud Tuya integration for the same physical bulbs still works (they have power and Wi-Fi). Diagnostic confirms: pings to the configured IPs fail, but `nmap -p 6668 --open` finds Tuya devices at different IPs.

### Repair recipe

Run from the laptop (or anywhere with `ssh pico.local` working):

1. **Discover current IPs** by device_id (UDP broadcast):

   ```bash
   ssh pico.local "docker exec homeassistant python3 -c \"
   import tinytuya, json
   d = json.load(open('/config/.storage/core.config_entries'))
   for e in d['data']['entries']:
       if e['domain'] != 'tuya_local': continue
       did = e['data']['device_id']
       r = tinytuya.find_device(dev_id=did)
       print(e['title'], did, '->', r.get('ip'))
   \""
   ```

   `ip: None` means the bulb is genuinely offline (powered off or Wi-Fi disconnected).

2. **Back up** (always):

   ```bash
   ssh pico.local "cp /usr/share/hassio/homeassistant/.storage/core.config_entries /tmp/core.config_entries.bak.\$(date +%s)"
   ```

3. **Patch the host field** for each found device using the write pattern above (mutate `e['data']['host']`).

4. **Restart HA** (reload alone is insufficient):

   ```python
   ha_restart(confirm=True)
   ```

   Or via the UI: Developer Tools → YAML → Restart.

5. **Verify** all entries are `loaded`:

   ```python
   ha_get_integration(domain="tuya_local")
   ```

### Permanent fix

Add DHCP reservations on the eero (Settings → Network settings → Reservations & Port Forwarding → Add a reservation, pick by MAC). The IPs in `core.config_entries` and the reservations must match — if you change one, change the other. Once reserved, this entire repair recipe should never need to run again.

## Useful commands cheatsheet

```bash
# Inside-container Python (has tinytuya, voluptuous, all HA deps)
ssh pico.local "docker exec homeassistant python3 -c '...'"

# Tail HA logs
ssh pico.local "docker logs -f --tail 200 homeassistant"

# Check what the integration thinks is going on (via ha-mcp)
ha_get_integration(domain="tuya_local")
ha_get_logs(source="system", search="tuya_local")

# Find Tuya devices on the LAN (port 6668 = local Tuya protocol)
ssh pico.local "nmap -p 6668 --open -T4 -n 192.168.4.0/22"

# ARP cache (no scan, just what's been seen recently)
ssh pico.local "ip neigh show | grep -E '192\\.168\\.[4-7]\\.'"

# HA REST API health check
ssh pico.local "curl -sS -H 'Authorization: Bearer \$(cat ~/code/infra/home-assistant.token)' http://localhost:8123/api/"
```

## Known limitations

- **eero integration is read-only.** No service to create reservations, change SSIDs, etc. Reservations must be done in the eero mobile app.
- **`tuya_local` requires a static `host`** — there's no built-in auto-discovery mode for the IP. The `auto` option in the schema is for **protocol version**, not IP. Workaround documented above.
- **`homeassistant.reload_config_entry` reads in-memory state, not disk.** Always pair direct `.storage` edits with `ha_restart(confirm=true)`.
- **Restarting HA breaks the SSE connection** to the official MCP server. Claude Code reconnects automatically; just wait ~30–60s after `ha_restart`.
