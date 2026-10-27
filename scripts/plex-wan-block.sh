#!/usr/bin/env bash
# plex-wan-block.sh — keep Plex's TCP ports off the internet, whatever the router does.
#
# Exists because the eero forwarded 32400 straight to pico, and that is how
# Plex was compromised (pico/plex/INCIDENT-2026-10-27.md). Remote access goes
# through plex.stevegore.au: Caddy on OKE -> Tailscale -> tailscale0 -> pico,
# so nothing legitimate needs the forward. The eero has no API, so the forward
# can only be removed by hand in the app. This makes it irrelevant instead.
#
# IPv4: Docker DNATs published ports and routes them through FORWARD, so the
#       rule goes in DOCKER-USER, the one chain Docker never flushes.
# IPv6: Docker IPv6 is off, so [::]:32400 is docker-proxy listening on the host
#       and the traffic hits INPUT instead.
#
# Only packets arriving on the default-route (LAN) interface are filtered, so
# tailscale0 (Caddy, Uptime Kuma) and the Docker bridges are untouched.
#
#   plex-wan-block.sh apply    idempotently insert the rules (default)
#   plex-wan-block.sh remove   delete them
#   plex-wan-block.sh status   show what is installed
#
# Run as root by plex-wan-block.service, which is PartOf docker.service.

set -euo pipefail

PORTS="${PLEX_TCP_PORTS:-32400,3005,8324,32469}"
LAN_V4="${LAN_V4:-192.168.0.0/16}"
TAG="plex-wan-block"

IFACE=$(ip -4 route show default | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')
[[ -n $IFACE ]] || { echo "no default route; refusing to guess the LAN interface" >&2; exit 1; }

# The delegated /64 is dynamic, so read it at apply time; the unit reruns on
# every boot and Docker restart.
V6_PREFIX=$(ip -6 route show dev "$IFACE" | awk '$1 ~ /^2[0-9a-f]*:.*\/64$/ {print $1; exit}')

v4_rule=(DOCKER-USER -i "$IFACE" -p tcp -m multiport --dports "$PORTS"
         ! -s "$LAN_V4" -m comment --comment "$TAG" -j DROP)

v6_rules=()
for src in fe80::/10 fc00::/7 ${V6_PREFIX:+"$V6_PREFIX"}; do
  v6_rules+=("INPUT -i $IFACE -p tcp -m multiport --dports $PORTS -s $src -m comment --comment $TAG -j ACCEPT")
done
v6_rules+=("INPUT -i $IFACE -p tcp -m multiport --dports $PORTS -m comment --comment $TAG -j DROP")

remove() {
  # Delete by comment so a changed prefix or interface leaves nothing stale.
  local tool chain
  for tool in iptables ip6tables; do
    for chain in DOCKER-USER INPUT; do
      $tool -S "$chain" 2>/dev/null | grep -- "--comment $TAG" | sed 's/^-A/-D/' |
        while read -r spec; do eval "$tool $spec"; done
    done
  done
}

apply() {
  iptables -n -L DOCKER-USER >/dev/null 2>&1 || {
    echo "DOCKER-USER chain missing — is Docker running with iptables enabled?" >&2; exit 1; }
  remove
  iptables -I "${v4_rule[@]}"
  # Insert in reverse so the ACCEPTs end up above the DROP.
  local i
  for (( i=${#v6_rules[@]}-1; i>=0; i-- )); do
    # shellcheck disable=SC2086
    ip6tables -I ${v6_rules[i]}
  done
  echo "applied on $IFACE: tcp/$PORTS allowed from $LAN_V4${V6_PREFIX:+, $V6_PREFIX}, link-local and ULA only"
}

status() {
  iptables -S DOCKER-USER | grep -- "$TAG" || echo "ipv4: none"
  ip6tables -S INPUT | grep -- "$TAG" || echo "ipv6: none"
}

case "${1:-apply}" in
  apply) apply ;;
  remove) remove; echo removed ;;
  status) status ;;
  *) echo "usage: $0 [apply|remove|status]" >&2; exit 2 ;;
esac
