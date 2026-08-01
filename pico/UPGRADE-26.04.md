# pico: Ubuntu 24.04 → 26.04 LTS upgrade prep

**Status as of 2026-08-01: wait for the supported LTS upgrade path.** Ubuntu
24.04 users are scheduled to be offered 26.04 when 26.04.1 is released on
2026-08-04. Do not force the development path with `do-release-upgrade -d`.
See the [Ubuntu 26.04 release announcement](https://discourse.ubuntu.com/t/ubuntu-26-04-resolute-raccoon-lts-released/80833).

Current state: Ubuntu 24.04.4 LTS (noble), kernel 6.8.0-136, 31 containers,
Ubuntu Pro attached (esm-infra, esm-apps, livepatch).

The raw baseline is deliberately private because it contains a complete
package, service, container, volume, and network inventory plus Ubuntu Pro
account information. Capture it outside this public repository:

```bash
cd ~/code/infra
scripts/capture-pico-upgrade-state.sh \
  ~/.local/state/infra/upgrade-26.04-state
```

The original pre-Home-Assistant-teardown snapshot is archived as
`~/.local/state/infra/upgrade-26.04-state-pre-ha-teardown-20260801`.

---

## Blockers to clear first

### 1. Old HA Supervised stack resurrecting at boot — cleared

`hassio-supervisor.service` was disabled, but `hassio-apparmor.service` remained
enabled and declared `Wants=hassio-supervisor.service`. At boot it pulled the
Supervisor back up, which recreated the old plugin containers and resumed
host-level `autofix` across the whole Docker daemon.

Cleared on 2026-08-01:

- `hassio-apparmor.service` and `hassio-supervisor.service` are both disabled
  and inactive.
- The seven legacy containers and `hassio` bridge network were removed.
- A subsequent reboot confirmed they do not return.
- `homeassistant-app`, `homeassistant-db`, and `homeassistant-matter` remain
  healthy; `homeassistant-app` is the sole listener on port 8123.

The old `/usr/share/hassio/homeassistant` tree remains as a rollback reference.
The `os-agent` package and `haos-agent.service` remain enabled/running but are
unused by Container mode; they can be removed after the rollback window closes.

### 2. Root filesystem is at 88%

`/` is 456G with **54G free**. That is probably enough, but the release upgrade
downloads and unpacks a full release with no easy abort. Get it under roughly
80% first. Recheck immediately before cleanup because these numbers change.

Likely reclaimable sources:

| Source | Last measured | Command |
| --- | ---: | --- |
| Docker images | ~18 GB | `docker image prune -a` — aggressive; Compose must re-pull |
| Docker build cache | ~2 GB | `docker builder prune -af` |
| Docker volumes | ~1.7 GB | `docker volume prune` — review the list first |
| APT cache | ~500 MB | `sudo apt clean` |
| Disabled snap revisions | ~2 GB | remove only revisions marked `disabled` |
| Superseded kernel packages | ~400 MB | `sudo apt autoremove --purge` |

The weekly `docker-prune.timer` is enabled and handles unused images/build
cache, but do not assume it has run recently. It deliberately never removes
volumes.

Safe minimum before the release upgrade:

```bash
docker builder prune -af
sudo apt clean
sudo apt autoremove --purge
df -h / /boot
```

### 3. Restore the Docker APT repository

There is no active `/etc/apt/sources.list.d/docker.list`; only
`docker.list.save` and `docker.list.distUpgrade` remain from the 22.04→24.04
upgrade. Docker is therefore pinned at `5:29.0.1-1~ubuntu.24.04~noble` with no
repository candidate.

Because the source is absent, `do-release-upgrade` has nothing to rewrite and
may propose removing `docker-ce`. Restore it before upgrading:

```bash
sudo cp /etc/apt/sources.list.d/docker.list.save \
  /etc/apt/sources.list.d/docker.list
sudo apt update
apt-cache policy docker-ce
```

Expect a real Docker repository candidate before proceeding. Review the other
`.save` and `.distUpgrade` files in `sources.list.d` so the next upgrade's
leftovers are unambiguous.

### 4. Resolve or explicitly baseline failed services

Two units are already failed and must not be mistaken for upgrade fallout:

- `vault-token-sync.service`
- `vw-mysql-to-sqlite.service`

Fix them before upgrading or record their logs and accept them as known
pre-existing failures.

---

## Third-party repositories

Vendor repository compatibility checked during the 2026-08-01 assessment:

| Repository | 26.04 status | Note |
| --- | --- | --- |
| Docker | Resolute repository exists | Source file is currently missing; blocker 3 |
| Tailscale | Resolute repository exists | Current source is pinned to `noble` |
| HashiCorp | Resolute repository exists | Current source is pinned to `noble` |
| deadsnakes PPA | Resolute repository exists | Filename still says `jammy`; suite is `noble` |
| Brave, VS Code, Mozilla, Warp | Suite-independent | Use `stable`/`mozilla`, not Ubuntu codenames |

`do-release-upgrade` disables third-party repositories and leaves
`.distUpgrade` copies. Re-enable them one at a time afterward, running
`apt update` between each. Brave itself is not installed; only its repository
packages remain. VS Code is installed and intentionally follows the separate
third-party unattended-upgrades policy in `AUTO_UPDATES.md`.

Python 3.12 is the system default, with Python 3.11 installed from deadsnakes.
Before upgrading, confirm nothing under `~/code` hard-codes the 3.12 executable
path.

---

## Rollback plan

`/` is LVM (`ubuntu-vg/ubuntu-lv`), so an LVM snapshot is the cheapest rollback.
This needs sudo and has not yet been verified:

```bash
sudo vgs
sudo lvcreate -L 20G -s -n ubuntu-lv-pre2604 \
  /dev/ubuntu-vg/ubuntu-lv
```

Do not create the snapshot unless the volume group has at least 20G free. If it
does not, rollback means reinstall and restore. In that case, verify Duplicati
has a current *restorable* backup; merely seeing a backup job is insufficient.

Either way, capture off-box copies of `/opt/ha-container` (including `.env`),
custom systemd units, and Portainer stack definitions first. Run
`/home/steve/.local/bin/backup-ha-container` and verify its archive/checksums.

---

## Upgrade run

Use a directly attached console or Tailscale SSH, not a session that depends on
a service being upgraded.

```bash
sudo apt update
sudo apt full-upgrade
sudo reboot
sudo do-release-upgrade       # only once the supported 24.04 LTS path opens
```

Keep the local version of hand-edited files such as SSH, netplan, Docker daemon,
and unattended-upgrades configuration, then diff them afterward. Expect desktop
packages to change too: pico has GNOME/gdm3 installed.

---

## Post-upgrade verification

Set `S` to the private baseline captured above:

```bash
S=~/.local/state/infra/upgrade-26.04-state
systemctl --failed
diff <(systemctl list-unit-files --state=enabled --no-legend) \
  "$S/systemd-enabled.txt"
diff <(docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | sort) \
  "$S/docker-containers.txt"
diff <(docker volume ls -q | sort) "$S/docker-volumes.txt"
ip -br addr
ip route
```

Specifically confirm:

- **Docker:** daemon starts, all 31 baseline containers return, and storage is
  still `overlay2`.
- **Home Assistant:** three Container-mode services are running; MariaDB is
  healthy; recorder did not hit the boot race documented in
  `home-assistant.md`.
- **Old Supervisor:** both systemd units remain disabled/inactive and no
  `hassio*` containers or network reappear.
- **Tailscale:** node is connected and the intended subnet routes are still
  advertised. Establish the authoritative pre-upgrade value with
  `sudo tailscale debug prefs`; the non-root output previously conflicted with
  `hosts.md`.
- **cloudflared:** `hass2.stevegore.au` depends on `cloudflared.service`.
- **Ubuntu Pro:** ESM and Livepatch remain attached and compatible with the new
  kernel.
- **Custom units:** verify `grafana-agent`, `stats-server`,
  `arr-malware-watchdog`, `docker-prune`, `vault-token-sync`,
  `vw-mysql-to-sqlite`, Samba, OpenVPN, and LXD.

## Remaining sudo/judgement checks

1. `sudo vgs` — confirm snapshot capacity or accept reinstall/restore rollback.
2. `sudo tailscale debug prefs` — establish the true route baseline.
3. Choose aggressive Docker image pruning versus the safe minimum.
4. Fix or explicitly baseline both failed services.
5. Restore and verify the Docker APT repository.
