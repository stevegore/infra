#!/usr/bin/env bash
# deconz-heartbeat.sh — push deCONZ health to Uptime Kuma.
#
# Kuma runs on OKE and cannot reach the Pi (LAN only, not on the tailnet), so
# the Pi pushes instead: the "deCONZ (raspberrypi)" push monitor goes down if
# no "up" arrives for a few minutes. That one monitor covers the Pi being off,
# the container being down, and the ConBee II dropping off (rfconnected=false).
# Kuma's managed Pushover notification does the alerting.
#
#   deconz-heartbeat.sh                 check deCONZ and push up/down
#   deconz-heartbeat.sh --down <msg>    push down with a message (OnFailure=
#                                       hook for the gitops and apt units)
#
# /etc/deconz-heartbeat.env (root, 0600) provides:
#   KUMA_PUSH_TOKEN   kv/uptime-kuma/config push_token_deconz
#   DECONZ_API_KEY    a deCONZ API key created for this script
#
# Exit status is always 0: the push is the signal, and a failed push already
# reads as "down" in Kuma.

set -uo pipefail

# shellcheck source=/dev/null
. /etc/deconz-heartbeat.env

push() { # $1 = up|down, $2 = message
    curl -sf --max-time 15 -o /dev/null -G \
        --data-urlencode "status=$1" --data-urlencode "msg=$2" \
        "https://uptime.stevegore.au/api/push/$KUMA_PUSH_TOKEN" \
        || echo "push failed ($1: $2)"
}

if [[ ${1:-} == --down ]]; then
    push down "${2:-unit failed}"
    exit 0
fi

if ! config=$(curl -sf --max-time 10 "http://127.0.0.1:8080/api/$DECONZ_API_KEY/config"); then
    push down "deCONZ API not answering on :8080"
    exit 0
fi

rf=$(jq -r '.rfconnected' <<<"$config")
fw=$(jq -r '.fwversion' <<<"$config")
if [[ $rf == true ]]; then
    push up "OK fw $fw"
else
    push down "ConBee II not connected (rfconnected=$rf)"
fi
exit 0
