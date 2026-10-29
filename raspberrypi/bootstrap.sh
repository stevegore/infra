#!/usr/bin/env bash
#
# Turn a freshly flashed Raspberry Pi OS Lite (64-bit) card into the deCONZ
# host. Run ON the Pi as root; the Imager-created user has passwordless sudo:
#     scp raspberrypi/bootstrap.sh raspberrypi:/tmp/
#     ssh raspberrypi 'sudo bash /tmp/bootstrap.sh'
# Full migration runbook: raspberrypi/README.md.
#
# What it sets up:
#
#  1. Docker CE from Docker's Debian repo (compose plugin included).
#
#  2. unattended-upgrades for Debian (release, -updates, -security), the
#     Raspberry Pi archive (kernel/firmware) and Docker CE, with an automatic
#     reboot at 04:30. The Buster install this replaces had no
#     unattended-upgrades at all and sat 2+ years past EOL.
#
#  3. A sparse clone of stevegore/infra at /opt/infra (public repo, HTTPS, no
#     credentials) and deconz-gitops.timer, which applies
#     raspberrypi/deconz/compose.yaml every 5 minutes. Renovate bumps land
#     here the same way Portainer picks them up on pico.
#
#  4. deconz-heartbeat.timer: pushes deCONZ health to the Uptime Kuma push
#     monitor every minute. deconz-gitops and apt-daily-upgrade failures also
#     mark that monitor down, via deconz-alert@.service.
#
#  5. journald capped at 64 MB, to keep writes to the SD card down.
#
# Units are COPIED from /opt/infra/raspberrypi/systemd, so re-run this script
# after changing them. Everything here is idempotent — safe to re-run.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (use sudo)" >&2
    exit 1
fi

CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
ENV_FILE=/etc/deconz-heartbeat.env

echo "==> base packages ($CODENAME)"
apt-get update -q
apt-get full-upgrade -y -q
apt-get install -y -q ca-certificates curl git jq unattended-upgrades apt-listchanges

echo "==> Docker CE apt source"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update -q
apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

echo "==> unattended-upgrades policy"
# A drop-in rather than editing the package-owned 50unattended-upgrades.
cat > /etc/apt/apt.conf.d/52homelab-auto-upgrades <<'EOF'
// Homelab auto-update policy. Managed by raspberrypi/bootstrap.sh in
// stevegore/infra — re-run that script rather than hand-editing.
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian";
    "origin=Debian,codename=${distro_codename}-updates,label=Debian";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Raspberry Pi Foundation,codename=${distro_codename}";
    "origin=Docker,archive=${distro_codename},label=Docker CE";  // no Codename in its Release file
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
// Kernel/firmware updates need a reboot. deCONZ is restart:unless-stopped and
// the switches are dead for ~2 minutes, so do it while everyone is asleep.
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
Unattended-Upgrade::MinimalSteps "true";
EOF
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
mkdir -p /etc/systemd/system/apt-daily.timer.d /etc/systemd/system/apt-daily-upgrade.timer.d \
    /etc/systemd/system/apt-daily-upgrade.service.d
cat > /etc/systemd/system/apt-daily.timer.d/homelab-window.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:30,15:30
RandomizedDelaySec=20m
EOF
cat > /etc/systemd/system/apt-daily-upgrade.timer.d/homelab-window.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 04:00
RandomizedDelaySec=20m
EOF
cat > /etc/systemd/system/apt-daily-upgrade.service.d/alert.conf <<'EOF'
[Unit]
OnFailure=deconz-alert@%n.service
EOF
apt-config dump > /dev/null

echo "==> journald size cap"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/homelab.conf <<'EOF'
[Journal]
SystemMaxUse=64M
EOF
systemctl restart systemd-journald

echo "==> /opt/infra (sparse clone)"
if [[ ! -d /opt/infra/.git ]]; then
    git clone --quiet --filter=blob:none --no-checkout --branch main \
        https://github.com/stevegore/infra.git /opt/infra
    git -C /opt/infra sparse-checkout set raspberrypi
    git -C /opt/infra checkout --quiet main
fi
git -C /opt/infra pull --quiet --ff-only

echo "==> deCONZ data directory"
# Owned by DECONZ_UID/GID 1000 from compose.yaml. Restore the old
# ~/.local/share/dresden-elektronik/deCONZ contents here BEFORE the first
# gitops run, or deCONZ starts a fresh, empty database (README step 4).
install -d -o 1000 -g 1000 /opt/deconz/data

echo "==> systemd units"
install -m 0644 /opt/infra/raspberrypi/systemd/* /etc/systemd/system/
systemctl daemon-reload
systemctl restart apt-daily.timer apt-daily-upgrade.timer

if [[ -f $ENV_FILE ]]; then
    chmod 600 "$ENV_FILE"
    systemctl enable --now deconz-heartbeat.timer
else
    echo "    $ENV_FILE missing: heartbeat NOT enabled (README step 6), re-run after creating it"
fi

if [[ -n $(ls -A /opt/deconz/data) ]]; then
    systemctl enable --now deconz-gitops.timer
    systemctl start deconz-gitops.service
    docker ps --filter name=deconz --format '{{.Names}} {{.Status}}'
else
    echo "    /opt/deconz/data is empty: deconz-gitops NOT enabled (README step 4), re-run after restoring"
fi

echo "==> dry-run of unattended-upgrades"
unattended-upgrade --dry-run --debug 2>&1 | grep -i -e "allowed origins" -e "packages that will be upgraded" || true
echo "done"
