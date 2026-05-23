#!/bin/bash
# Bootstrap ampere-ubuntu from a fresh Ubuntu 22.04 aarch64 install.
#
# Idempotent — safe to re-run. Each step skips itself if already done.
#
# Run from the repo root:
#   bash bootstrap/install.sh
#
# Requires: a user with passwordless or interactive sudo. Run as that user,
# NOT as root, so snap/microk8s group membership lands on the right account.
#
# Secret config files (Caddyfile, caddy.env, JWT keys, wg0.conf) are restored
# automatically by bootstrap/restore-config.sh from the SOPS-encrypted bundle
# at config/secrets.sops.yaml. See that script's header for the trust model.
#
# Manual steps still required afterwards:
#   - dex.github.clientSecret       (ArgoCD GitHub OAuth — set in argocd-secret)
#   - Vault init (first install only)

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Don't run as root — run as a sudoer (e.g. 'ubuntu')."
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MICROK8S_CHANNEL="1.27/stable"
ARGOCD_NS="argocd"
VAULT_NS="vault"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
skip() { printf '    \033[2m· %s\033[0m\n' "$*"; }

sudo -v  # prime sudo

# ---------- 1. Base system ----------
log "Base packages + unattended upgrades"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  ca-certificates curl git jq gettext-base \
  iptables-persistent netfilter-persistent \
  fail2ban \
  wireguard wireguard-tools \
  unattended-upgrades apt-listchanges \
  logrotate \
  build-essential

# sops / age / yq — needed by restore-config.sh
SOPS_VER="3.9.4"
AGE_VER="1.2.1"
YQ_VER="4.45.1"
[[ -x /usr/local/bin/sops ]] || { curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VER}/sops-v${SOPS_VER}.linux.arm64" -o /tmp/sops && sudo install -m 755 /tmp/sops /usr/local/bin/sops && rm /tmp/sops; }
[[ -x /usr/local/bin/age ]]  || { curl -fsSL "https://github.com/FiloSottile/age/releases/download/v${AGE_VER}/age-v${AGE_VER}-linux-arm64.tar.gz" | tar -xz -C /tmp && sudo install -m 755 /tmp/age/age /usr/local/bin/age && sudo install -m 755 /tmp/age/age-keygen /usr/local/bin/age-keygen && rm -rf /tmp/age; }
[[ -x /usr/local/bin/yq ]]   || { curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VER}/yq_linux_arm64" -o /tmp/yq && sudo install -m 755 /tmp/yq /usr/local/bin/yq && rm /tmp/yq; }
sudo dpkg-reconfigure -f noninteractive unattended-upgrades

# ---------- 1b. Log rotation + journald cap ----------
# Oracle's Ubuntu cloud image ships WITHOUT logrotate and WITHOUT /etc/logrotate.conf,
# so nothing rotates wtmp/btmp by default. On an internet-facing host SSH brute-force
# fills /var/log/btmp unbounded (saw ~1 GiB / 2.5M failed-login records grow over
# ~20 months) which can push the node into k8s ephemeral-storage eviction.
log "logrotate configs for btmp/wtmp + journald size cap"
if [[ ! -f /etc/logrotate.d/btmp ]]; then
  sudo tee /etc/logrotate.d/btmp >/dev/null <<'EOF'
/var/log/btmp {
    missingok
    weekly
    create 0660 root utmp
    rotate 1
}
EOF
fi
if [[ ! -f /etc/logrotate.d/wtmp ]]; then
  sudo tee /etc/logrotate.d/wtmp >/dev/null <<'EOF'
/var/log/wtmp {
    missingok
    monthly
    create 0664 root utmp
    rotate 1
}
EOF
fi
sudo systemctl enable --now logrotate.timer >/dev/null

# Cap journald at 500M (default floats to ~10% of disk, ~4.5 GiB on this VM —
# wasteful on a 45 GiB root fs that also hosts containerd snapshots).
sudo install -d /etc/systemd/journald.conf.d
if [[ ! -f /etc/systemd/journald.conf.d/00-size.conf ]]; then
  sudo tee /etc/systemd/journald.conf.d/00-size.conf >/dev/null <<'EOF'
[Journal]
SystemMaxUse=500M
SystemKeepFree=2G
EOF
  sudo systemctl restart systemd-journald
fi

# ---------- 2. fail2ban ----------
log "fail2ban (SSH jail with escalating bans)"
if [[ ! -f /etc/fail2ban/jail.local ]]; then
  sudo tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[DEFAULT]
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ssh
backend = systemd
EOF
  sudo systemctl restart fail2ban
else
  skip "jail.local already present"
fi
sudo systemctl enable --now fail2ban >/dev/null

# ---------- 3. WireGuard ----------
log "WireGuard (hub at 10.20.30.2)"
sudo install -d -m 700 /etc/wireguard
# wg0.conf is rendered later by restore-config.sh; enabling is deferred to then.

# Forwarding + masquerade required for WireGuard to function as a hub.
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf; then
  echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf >/dev/null
  sudo sysctl -p >/dev/null
fi

# ---------- 4. Caddy (custom build with caddy-security plugin) ----------
log "Caddy (xcaddy build with caddy-security)"
if caddy version 2>/dev/null | grep -q '^v2\.' && caddy list-modules 2>/dev/null | grep -q '^security$'; then
  skip "caddy already installed with security module ($(caddy version | awk '{print $1}'))"
else
  # Install Go if missing
  if ! command -v go >/dev/null; then
    sudo snap install go --classic
  fi
  # Install xcaddy
  if ! command -v xcaddy >/dev/null; then
    XCADDY_VER="0.4.5"
    TMPD=$(mktemp -d)
    curl -fsSL "https://github.com/caddyserver/xcaddy/releases/download/v${XCADDY_VER}/xcaddy_${XCADDY_VER}_linux_arm64.tar.gz" \
      | tar -xz -C "$TMPD" xcaddy
    sudo install -m 755 "$TMPD/xcaddy" /usr/local/bin/xcaddy
    rm -rf "$TMPD"
  fi
  TMPD=$(mktemp -d)
  (cd "$TMPD" && xcaddy build --with github.com/greenpau/caddy-security)
  sudo install -m 755 "$TMPD/caddy" /usr/bin/caddy
  rm -rf "$TMPD"

  # System user + group (matches apt package layout)
  if ! id caddy >/dev/null 2>&1; then
    sudo groupadd --system caddy
    sudo useradd --system --gid caddy --create-home --home-dir /var/lib/caddy \
      --shell /usr/sbin/nologin --comment "Caddy web server" caddy
  fi
fi

sudo install -d -o caddy -g caddy -m 755 /etc/caddy /var/lib/caddy
sudo install -d -o caddy -g caddy -m 700 /etc/caddy/keys

# systemd unit
if [[ ! -f /etc/systemd/system/caddy.service ]]; then
  sudo tee /etc/systemd/system/caddy.service >/dev/null <<'EOF'
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
EnvironmentFile=-/etc/caddy/caddy.env
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
fi

# Caddyfile is rendered later by restore-config.sh; enabling is deferred to then.
sudo systemctl enable caddy >/dev/null 2>&1 || true

# ---------- 5. iptables (persisted via netfilter-persistent) ----------
# OCI security lists are the primary firewall; these host rules are belt-and-braces
# for ports OCI does NOT cover (e.g. WireGuard-internal DNS on 53, k8s API on 16443).
log "iptables rules (persisted)"
if [[ ! -f /etc/iptables/rules.v4 ]] || ! sudo grep -q 'dpt:51820' /etc/iptables/rules.v4 2>/dev/null; then
  sudo iptables -C INPUT -p udp --dport 51820 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null \
    || sudo iptables -A INPUT -p udp --dport 51820 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
  sudo iptables -C INPUT -s 10.20.30.0/24 -p tcp --dport 53 -j ACCEPT 2>/dev/null \
    || sudo iptables -A INPUT -s 10.20.30.0/24 -p tcp --dport 53 -j ACCEPT
  sudo iptables -C INPUT -s 10.20.30.0/24 -p udp --dport 53 -j ACCEPT 2>/dev/null \
    || sudo iptables -A INPUT -s 10.20.30.0/24 -p udp --dport 53 -j ACCEPT
  sudo iptables -C INPUT -p tcp --dport 16443 -j ACCEPT 2>/dev/null \
    || sudo iptables -A INPUT -p tcp --dport 16443 -j ACCEPT
  sudo netfilter-persistent save >/dev/null
else
  skip "iptables rules already saved"
fi

# ---------- 6. MicroK8s ----------
log "MicroK8s (channel ${MICROK8S_CHANNEL})"
if ! command -v microk8s >/dev/null; then
  sudo snap install microk8s --classic --channel="${MICROK8S_CHANNEL}"
else
  skip "microk8s already installed ($(snap list microk8s | awk 'NR==2 {print $2}'))"
fi

if ! id -nG "$USER" | grep -qw microk8s; then
  sudo usermod -a -G microk8s "$USER"
  sudo chown -f -R "$USER" ~/.kube 2>/dev/null || true
  echo "    NOTE: re-login (or 'newgrp microk8s') so group membership applies before continuing."
  exec sg microk8s "$0 $*"
fi

sudo microk8s status --wait-ready >/dev/null
sudo microk8s enable dns hostpath-storage helm3 >/dev/null

# ---------- 7. ArgoCD CLI ----------
log "ArgoCD CLI"
if ! command -v argocd >/dev/null && [[ ! -x /usr/local/bin/argo ]]; then
  ARGOCD_VER=$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r .tag_name)
  curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VER}/argocd-linux-arm64" -o /tmp/argocd
  sudo install -m 755 /tmp/argocd /usr/local/bin/argo
  rm -f /tmp/argocd
else
  skip "argocd CLI already at $(command -v argocd || echo /usr/local/bin/argo)"
fi

# ---------- 8. ArgoCD (initial install — then helm chart in apps/argocd reconciles itself) ----------
log "ArgoCD core (raw manifests — managed by apps/argocd helm chart after first sync)"
microk8s kubectl create namespace "${ARGOCD_NS}" --dry-run=client -o yaml | microk8s kubectl apply -f -
if ! microk8s kubectl get deploy -n "${ARGOCD_NS}" argocd-server >/dev/null 2>&1; then
  microk8s kubectl apply -n "${ARGOCD_NS}" \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  echo "    waiting for argocd-server to become available..."
  microk8s kubectl rollout status -n "${ARGOCD_NS}" deploy/argocd-server --timeout=5m
else
  skip "argocd-server already deployed"
fi

# ---------- 9. Vault namespace + ApplicationSet ----------
log "Vault namespace + ApplicationSet"
microk8s kubectl create namespace "${VAULT_NS}" --dry-run=client -o yaml | microk8s kubectl apply -f -
microk8s kubectl apply -f "${REPO_ROOT}/argocd/applicationset.yaml"

# ---------- 10. Render encrypted config files ----------
log "Render Caddy / WireGuard / JWT configs from SOPS bundle"
if [[ -f "${REPO_ROOT}/config/secrets.sops.yaml" ]]; then
  bash "${REPO_ROOT}/bootstrap/restore-config.sh"
else
  skip "config/secrets.sops.yaml missing — see config/secrets.sops.yaml.example,"
  skip "then run: bash bootstrap/restore-config.sh"
fi

# ---------- Done ----------
cat <<EOF

==================== Bootstrap Complete ====================

Manual steps still required:

  1. Set the ArgoCD GitHub OAuth client secret:
       microk8s kubectl -n ${ARGOCD_NS} patch secret argocd-secret \\
         --type merge -p '{"stringData":{"dex.github.clientSecret":"<SECRET>"}}'
       microk8s kubectl -n ${ARGOCD_NS} rollout restart deploy/argocd-dex-server

  2. Vault auto-unseals from OCI KMS using instance principal — no manual
     init required if vault-storage bucket has prior data. For a fresh
     install only:
       microk8s kubectl exec -n ${VAULT_NS} vault-0 -- vault operator init \\
         -recovery-shares=1 -recovery-threshold=1

  3. ArgoCD UI: https://argocd.stevegore.au (after Caddy is up + DNS resolves)

EOF
