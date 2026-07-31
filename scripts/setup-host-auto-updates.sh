#!/usr/bin/env bash
#
# Host-level auto-updates for pico (Ubuntu 24.04).
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
#  2. apt: reclaim disk. Remove-Unused-Kernel-Packages and
#     Remove-Unused-Dependencies. pico had 4 kernel images installed and its
#     root filesystem is at 88%; unattended kernel upgrades without cleanup
#     fill /boot and then fail.
#
#  3. apt: automatic reboot at 05:00. A reboot has been pending since well
#     before this script existed, which means kernel and libc updates were
#     being installed but never taking effect. 05:00 is after the Home
#     Assistant update automation's 04:00 run. Verified safe: pico has no LUKS
#     or crypttab entries, so an unattended boot will not hang on a passphrase
#     prompt with no remote recovery path.
#
#  4. docker: weekly image + build-cache prune. This one exists BECAUSE of the
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
# Everything here is idempotent — safe to re-run.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (use sudo)" >&2
    exit 1
fi

APT_DROPIN=/etc/apt/apt.conf.d/52homelab-auto-upgrades

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

echo "==> validating apt config parses"
apt-config dump > /dev/null
echo "    ok"

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
systemctl list-timers docker-prune.timer --no-pager | tail -2
df -h / | tail -1
if [[ -f /var/run/reboot-required ]]; then
    echo
    echo "NOTE: a reboot is already pending (was pending before this script ran)."
    echo "      With Automatic-Reboot now on, it will happen at the next 05:00."
    echo "      To take it now instead: sudo reboot"
fi
