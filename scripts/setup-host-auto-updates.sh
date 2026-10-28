#!/usr/bin/env bash
#
# Host-level auto-updates for pico (Ubuntu 26.04).
#
# Run this ON pico, with sudo — passwordless sudo is not configured there, so it
# cannot be driven remotely:
#     scp scripts/setup-host-auto-updates.sh pico.local:/tmp/
#     ssh -t pico.local 'sudo bash /tmp/setup-host-auto-updates.sh'
#
# What it changes, and why each piece is needed:
#
#  1. apt: widen unattended-upgrades to the `-updates` pocket.
#     unattended-upgrades is already installed and running daily, but its
#     Allowed-Origins only lists the release and -security pockets. Most
#     non-security package updates land in `noble-updates`, so today they are
#     silently never applied. This is the change that makes "auto-update
#     everything" actually true for apt.
#
#  2. apt: permit the signed Tailscale stable repository. Tailscale is pico's
#     recovery/control path, so leaving it outside unattended-upgrades created
#     a permanent patch-level gap even while Ubuntu packages stayed current.
#     Other desktop/vendor repositories remain manual by design.
#
#  3. apt: reclaim disk. Remove-Unused-Kernel-Packages and
#     Remove-Unused-Dependencies. pico had 4 kernel images installed and its
#     root filesystem is at 88%; unattended kernel upgrades without cleanup
#     fill /boot and then fail.
#
#  4. apt: automatic reboot at 05:00. A reboot has been pending since well
#     before this script existed, which means kernel and libc updates were
#     being installed but never taking effect. 05:00 is after the Home
#     Assistant update automation's 04:00 run. Verified safe: pico has no LUKS
#     or crypttab entries, so an unattended boot will not hang on a passphrase
#     prompt with no remote recovery path.
#
#  5. docker: weekly image + build-cache prune. This one exists BECAUSE of the
#     rest of the auto-update pipeline. Renovate bumps image tags and Portainer
#     force-pulls on redeploy, so every update leaves the old image behind. At
#     install time pico was already holding 20.6 GB of reclaimable images and
#     2.8 GB of build cache on a filesystem with 55 GB free. Without this the
#     auto-updates fill the disk within months.
#
#     Prunes IMAGES and BUILD CACHE only. It deliberately never touches
#     volumes: `docker system prune --volumes` on pico would destroy live
#     application data.
#
#  6. apt: own the third-party sources that (2) and (7) depend on. The
#     2026-09 do-release-upgrade to 26.04 disabled tailscale.list ("could not
#     be automatically migrated"), so the Tailscale origin in (2) matched
#     nothing and tailscaled sat on 1.102.3 with nobody noticing. Both repos
#     are now written here as deb822 .sources. A release upgrade will disable
#     them again: RE-RUN THIS SCRIPT AFTER EVERY do-release-upgrade. The same
#     upgrade disabled docker.list, leaving Docker CE on noble's 29.0.1.
#
#     Docker CE is allowed unattended too (chosen 2026-10-27). Every engine
#     upgrade restarts dockerd, which restarts every container on pico —
#     including any `restart: always` container that was stopped by hand.
#     Stacks that must stay down are deleted, not stopped (AUTO_UPDATES.md).
#
#  7. cloudflared (hass2.stevegore.au tunnel): install from Cloudflare's apt
#     repo and allow it unattended. It was a one-off 2023.8.2 .deb with no
#     repo behind it, run with --no-autoupdate, and the old
#     cloudflared-update.timer (`cloudflared update`, which refuses to touch a
#     package-managed binary anyway) was disabled — so it was 3 years stale.
#     The package does not manage the service (the unit, which holds the tunnel
#     token, came from `cloudflared service install`), so a DPkg::Post-Invoke
#     hook restarts it whenever its binary has been replaced underneath it.
#
#  8. HashiCorp (the `vault` CLI used by vault-token-sync, pushover-notify and
#     the provisioning scripts): the same release upgrade disabled
#     hashicorp.list, so the CLI sat on 2.1.0 while the OKE server moved to
#     2.2.1. Written as a .sources and allowed unattended. Its Release file
#     says Origin/Label "Artifactory" (generic), so the origin is matched on
#     site= instead.
#
# Everything here is idempotent — safe to re-run.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (use sudo)" >&2
    exit 1
fi

APT_DROPIN=/etc/apt/apt.conf.d/52homelab-auto-upgrades
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

echo "==> writing third-party apt sources (Tailscale: $CODENAME, cloudflared: any)"
curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$CODENAME.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
cat > /etc/apt/sources.list.d/tailscale.sources <<EOF
Types: deb
URIs: https://pkgs.tailscale.com/stable/ubuntu
Suites: $CODENAME
Components: main
Signed-By: /usr/share/keyrings/tailscale-archive-keyring.gpg
EOF
# The release upgrader's disabled leftovers; the .sources above replaces them.
rm -f /etc/apt/sources.list.d/tailscale.list /etc/apt/sources.list.d/tailscale.list.disabled

curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $CODENAME
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.list.disabled \
    /etc/apt/sources.list.d/docker.list.save

curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    -o /usr/share/keyrings/cloudflare-main.gpg
# Suite `any`, not the codename: Cloudflare publishes one suite for every
# release, so this line never goes stale on an Ubuntu upgrade.
cat > /etc/apt/sources.list.d/cloudflared.sources <<'EOF'
Types: deb
URIs: https://pkg.cloudflare.com/cloudflared
Suites: any
Components: main
Signed-By: /usr/share/keyrings/cloudflare-main.gpg
EOF

curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor --yes \
    -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
cat > /etc/apt/sources.list.d/hashicorp.sources <<EOF
Types: deb
URIs: https://apt.releases.hashicorp.com
Suites: $CODENAME
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/hashicorp-archive-keyring.gpg
EOF
rm -f /etc/apt/sources.list.d/hashicorp.list /etc/apt/sources.list.d/hashicorp.list.disabled

echo "==> installing restart-if-replaced hook"
cat > /usr/local/sbin/homelab-restart-replaced <<'EOF'
#!/bin/sh
# Restart each named service whose running binary has been replaced on disk
# (/proc/PID/exe then reads "... (deleted)"). Called from DPkg::Post-Invoke for
# packages whose postinst does not restart their own service. Managed by
# scripts/setup-host-auto-updates.sh in stevegore/infra.
for svc in "$@"; do
    pid=$(systemctl show -p MainPID --value "$svc" 2>/dev/null)
    [ -n "$pid" ] && [ "$pid" != 0 ] || continue
    case "$(readlink "/proc/$pid/exe")" in
        *" (deleted)") logger -t homelab-restart-replaced "restarting $svc"; systemctl restart "$svc" ;;
    esac
done
EOF
chmod 755 /usr/local/sbin/homelab-restart-replaced

echo "==> removing the dead cloudflared-update timer"
systemctl disable --now cloudflared-update.timer 2>/dev/null || true
rm -f /etc/systemd/system/cloudflared-update.timer /etc/systemd/system/cloudflared-update.service

echo "==> writing $APT_DROPIN"
# A drop-in rather than editing 50unattended-upgrades: that file is package-owned
# and an apt upgrade will prompt about or revert local edits. 52 sorts after 50,
# so these win.
cat > "$APT_DROPIN" <<'EOF'
// Homelab auto-update policy. Managed by scripts/setup-host-auto-updates.sh
// in stevegore/infra — re-run that script rather than hand-editing.

// The stock config ships only the release and -security pockets. -updates is
// where the bulk of ordinary package updates land, so without it "unattended
// upgrades" only ever means security fixes.
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}:${distro_codename}-updates";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// Third-party origins allowed unattended: Tailscale (pico's remote recovery
// path), cloudflared (internet-facing tunnel daemon) and Docker CE (engine
// upgrades restart every container). Code, Brave and other workstation
// packages stay manual.
Unattended-Upgrade::Origins-Pattern {
    "origin=Tailscale,codename=${distro_codename},label=Tailscale";
    "origin=cloudflared,codename=any,label=cloudflared";
    "origin=Docker,archive=${distro_codename},label=Docker CE";  // no Codename in its Release file
    "site=apt.releases.hashicorp.com,codename=${distro_codename}";  // Origin is just "Artifactory"
};

// cloudflared's package does not restart the service; this does, but only
// when the binary was actually replaced. `|| true`: never fail an apt run.
DPkg::Post-Invoke { "/usr/local/sbin/homelab-restart-replaced cloudflared.service || true"; };

// Keep the root filesystem from filling: drop superseded kernels and
// orphaned dependencies instead of accumulating them.
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Kernel and libc updates do nothing until a reboot. Safe here: no LUKS, so
// the host comes back unattended. Containers are restart:unless-stopped.
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "05:00";

// Keep going if one package fails rather than abandoning the whole run.
Unattended-Upgrade::MinimalSteps "true";
EOF

echo "==> ensuring the periodic timers are on"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

echo "==> scheduling the upgrade window to 05:30-06:00"
# Stock: lists refresh at 06:00/18:00 + up to 12h random, upgrade at 06:00 + up
# to 60m. Pin the upgrade (and with it any Docker engine restart, which bounces
# every container) to 05:30-06:00, and refresh lists just before it so the run
# doesn't install from day-old metadata. Sits after the 05:00 auto-reboot and
# before the 06:30 Portainer reconciler.
mkdir -p /etc/systemd/system/apt-daily.timer.d /etc/systemd/system/apt-daily-upgrade.timer.d
cat > /etc/systemd/system/apt-daily.timer.d/homelab-window.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 05:00,17:00
RandomizedDelaySec=20m
EOF
cat > /etc/systemd/system/apt-daily-upgrade.timer.d/homelab-window.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 05:30
RandomizedDelaySec=30m
EOF
systemctl daemon-reload
systemctl restart apt-daily.timer apt-daily-upgrade.timer

echo "==> validating apt config parses"
apt-config dump > /dev/null
echo "    ok"

echo "==> bringing cloudflared, tailscale and docker current now"
apt-get update -q
# Post-Invoke restarts cloudflared once its binary is replaced. tailscaled's own
# postinst restarts it; run this from the LAN (pico.local), not over Tailscale.
apt-get install -y -q cloudflared tailscale vault
# --only-upgrade: bring the installed Docker CE packages forward without
# pulling in ones pico never had. This restarts dockerd and every container.
apt-get install -y -q --only-upgrade docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
cloudflared --version
tailscale version | head -1
vault version
docker version --format 'docker {{.Server.Version}}'
systemctl is-active cloudflared docker

echo "==> dry-run of unattended-upgrades"
unattended-upgrade --dry-run --debug 2>&1 | tail -15 || true

echo "==> installing weekly docker prune timer"
cat > /etc/systemd/system/docker-prune.service <<'EOF'
[Unit]
Description=Prune unused Docker images and build cache
Documentation=https://github.com/stevegore/infra
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
# IMAGES AND BUILD CACHE ONLY.
# Never add --volumes and never use `docker system prune`: pico keeps live
# application data in named volumes, and pruning those destroys it.
# `until=168h` keeps the last week of images so a rollback to the previous
# tag does not need a re-pull.
ExecStart=/usr/bin/docker image prune -af --filter until=168h
ExecStart=/usr/bin/docker builder prune -af --filter until=168h
EOF

cat > /etc/systemd/system/docker-prune.timer <<'EOF'
[Unit]
Description=Weekly Docker image and build-cache prune

[Timer]
OnCalendar=Sun 04:30
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now docker-prune.timer

echo
echo "==> done. current state:"
systemctl is-enabled apt-daily-upgrade.timer && echo "    apt-daily-upgrade.timer: enabled"
systemctl list-timers apt-daily.timer apt-daily-upgrade.timer docker-prune.timer --no-pager | head -4
df -h / | tail -1
if [[ -f /var/run/reboot-required ]]; then
    echo
    echo "NOTE: a reboot is already pending (was pending before this script ran)."
    echo "      With Automatic-Reboot now on, it will happen at the next 05:00."
    echo "      To take it now instead: sudo reboot"
fi
