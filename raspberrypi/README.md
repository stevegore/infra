# raspberrypi — deCONZ host rebuild

The Pi's only job is the Zigbee gateway for the light switches: a **ConBee II**
USB stick running **deCONZ**, used by Home Assistant's `deconz` integration on
pico. It stays on the Pi because of where it sits: pico is out of range of the
mesh.

This replaces the Raspbian 10 (Buster, EOL) install described in
[`hosts.md`](../hosts.md) with:

| Piece | What | Kept current by |
| --- | --- | --- |
| OS | Raspberry Pi OS Lite **64-bit**, no desktop | unattended-upgrades, auto-reboot 04:30 (`bootstrap.sh`) |
| Docker CE | Docker's Debian repo | unattended-upgrades |
| deCONZ | `deconzcommunity/deconz`, digest-pinned in [`deconz/compose.yaml`](deconz/compose.yaml) | Renovate (automerge after a 7-day soak), applied by `deconz-gitops.timer` every 5 min |
| Monitoring | `deconz-heartbeat.timer` → Uptime Kuma push monitor **deCONZ (raspberrypi)** → Pushover | goes down if the Pi, container or ConBee drops, or gitops/apt fails |

Dropped: Pi-hole (no LAN client used it), RealVNC, the desktop, lighttpd.

Nothing about the Zigbee network changes. The network key, PAN ID and channel
live on the ConBee II itself, and devices, groups and API keys live in
`zll.db`, which is carried over. Same stick means the same bridge ID
(`00212E05015F`), and the same IP means Home Assistant's config entry needs no
change. **No re-pairing.**

## SD card

The current card is a 128 GB SanDisk consumer microSDXC (`SH128`, 10/2020).
It has worked for six years, but it is not endurance-rated, and keeping it
untouched is the rollback plan anyway.

Buy a **high-endurance** card, 32–64 GB: **SanDisk High Endurance** or
**Samsung PRO Endurance**. The Pi 3B+'s SD interface tops out around 25 MB/s,
so a faster "Extreme/PRO Plus" card buys nothing. Endurance is what matters for
a box that writes logs and a database around the clock for years. 64 GB costs
little more than 32 GB and has twice the rated write endurance. The system uses
about 4 GB.

## Runbook

Switches are dead from step 3 to step 5: plan for 30–45 minutes.

### 1. Uptime Kuma token (any time before cutover)

The push token stays out of this public repo; it lives in Vault next to Kuma's
DB credentials, which VSO already syncs into the `uptime-kuma-db` Secret.

```bash
TOKEN=$(openssl rand -hex 10)   # 20 chars: Kuma's push_token column is VARCHAR(20)
vault kv patch kv/uptime-kuma/config push_token_deconz="$TOKEN"
```

Write it **before** this branch merges. The reconcile hook requires the key, so
a missing one fails the `uptime-kuma` sync instead of creating a broken monitor.
After the merge the monitor shows down until the Pi starts pushing (step 6), so
expect one Pushover alert if you merge well ahead of the cutover.

### 2. Flash the new card (on the Mac)

Raspberry Pi Imager → device **Raspberry Pi 3** → **Raspberry Pi OS Lite (64-bit)**.
In OS customisation:

- hostname `raspberrypi`, username `pi`, with a new password (store it in
  Vaultwarden; `pi.creds` can then be deleted)
- SSH: **public-key only**, paste `~/.ssh/raspberrypi_ed25519.pub`
- locale: `Australia/Sydney`; no Wi-Fi (wired only). Imager pre-fills the
  Mac's Wi-Fi network, so clear that field. On 2026-11-06 it didn't get
  cleared, and the Pi joined Wi-Fi as well (`sudo nmcli radio wifi off` fixes it).

After the first boot, give `pi` passwordless sudo. Current Pi OS images ask
for a password, which stops `bootstrap.sh` from running over SSH. Run this in a
real terminal, because it prompts for the password:

```bash
ssh -t raspberrypi 'echo "pi ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/010_pi-nopasswd >/dev/null && sudo chmod 440 /etc/sudoers.d/010_pi-nopasswd && sudo -n true && echo OK'
```

Check the eero has a DHCP reservation for the Pi at `192.168.4.61`. The MAC
doesn't change, so a reservation is what guarantees the same address.

### 3. Back up and stop the old install (downtime starts)

```bash
ssh raspberrypi 'sudo systemctl stop deconz deconz-update && \
  sudo tar -C /home/pi/.local/share/dresden-elektronik -czf /tmp/deconz-data.tgz deCONZ'
scp raspberrypi:/tmp/deconz-data.tgz ~/Backups/deconz-data-$(date +%F).tgz
ssh raspberrypi 'sudo poweroff'
```

(Optionally also take a Phoscon backup first: Gateway → Backup.)

Swap the cards and boot. Leave the ConBee II where it is: on a short USB
extension cable if it's plugged straight into the Pi, as USB 3 hubs and the
Pi's own noise interfere at 2.4 GHz.

### 4. Bootstrap, then restore the deCONZ data

```bash
ssh-keygen -R raspberrypi.local; ssh-keygen -R 192.168.4.61   # new host key
scp raspberrypi/bootstrap.sh ~/Backups/deconz-data-*.tgz raspberrypi:/tmp/
ssh raspberrypi 'sudo bash /tmp/bootstrap.sh'
# deCONZ is NOT started yet: /opt/deconz/data is empty.
ssh raspberrypi 'sudo tar -C /opt/deconz/data --strip-components=1 -xzf /tmp/deconz-data-*.tgz && \
  sudo chown -R 1000:1000 /opt/deconz/data && sudo bash /tmp/bootstrap.sh'
```

The second run enables `deconz-gitops.timer` and starts the container.

On 2026-11-06 the Pi rebooted itself once during this step, under load on
1 GB of RAM (most likely the hardware watchdog). Nothing was lost: the restore
had finished and deCONZ came up on boot. If the SSH session drops here, wait
a minute, check `docker ps`, and re-run the bootstrap.

### 5. Verify (downtime ends)

- Phoscon at `http://192.168.4.61:8080`: log in with the old Phoscon
  password. All 12 devices and 11 sensors should be present.
- Gateway → firmware: the ConBee II firmware is shown there. If an update is
  offered, apply it now. If Phoscon can't flash from inside the container,
  follow the firmware section of the
  [deconz-docker README](https://github.com/deconz-community/deconz-docker).
- Home Assistant → Settings → Devices → deCONZ: the integration reconnects by
  itself (same bridge ID, same API key from `zll.db`).
- Press every switch once and check it shows up in HA's logbook. Battery
  switches sleep, and a press makes them check in.

### 6. Heartbeat

Create a deCONZ API key for the heartbeat. Unlock the gateway first: Phoscon →
Gateway → Advanced → **Authenticate app**. Then, within 60 seconds:

```bash
ssh raspberrypi
KEY=$(curl -s -X POST -d '{"devicetype":"heartbeat#raspberrypi"}' http://127.0.0.1:8080/api | jq -r '.[0].success.username')
TOKEN=...   # from step 1: vault kv get -field=push_token_deconz kv/uptime-kuma/config
printf 'KUMA_PUSH_TOKEN=%s\nDECONZ_API_KEY=%s\n' "$TOKEN" "$KEY" | sudo tee /etc/deconz-heartbeat.env >/dev/null
sudo bash /tmp/bootstrap.sh   # third run enables deconz-heartbeat.timer
```

**deCONZ (raspberrypi)** in Uptime Kuma should turn green within a minute,
with the message `OK fw <version>`.

### Rollback

Power off, put the old card back in, boot. It is exactly as it was: the
Buster install with deCONZ 2.12.06 and the same `zll.db`. Keep the old card
for a few weeks before reusing it.

## Day 2

- **deCONZ upgrades** arrive as Renovate PRs labelled `critical`. They
  automerge once the release is 7 days old, and the Pi applies them within 5
  minutes. To hold one, close the PR.
- **Unit changes** (`systemd/*`) are copied in by `bootstrap.sh`, not by
  gitops. Re-run it after changing them.
- **Logs:** `journalctl -u deconz-gitops -u deconz-heartbeat`, `docker logs deconz`.
- **Unattended reboots** happen at 04:30 when a kernel update needs one. The
  switches drop for ~2 minutes; the 5-minute push window keeps that from paging.
