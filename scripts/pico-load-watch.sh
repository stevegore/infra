#!/usr/bin/env bash
# pico-load-watch.sh — page when pico's sustained load is abnormal.
#
# Exists because a cryptominer held about 7 of pico's 12 cores for at least
# nine days (2026-10-18 → 27) and nothing noticed: Uptime Kuma only checks
# reachability, and Plex stayed responsive. See pico/plex/INCIDENT-2026-10-27.md.
#
# Uses the 15-minute load average, which is already a sustained signal. pico
# idles around 1; Plex transcodes and Immich ML jobs reach 3–4.
#
# Alerts once on crossing the threshold, again every REPEAT_HOURS while it
# stays high, and once more on recovery. The alert names the top CPU processes
# and the container each one runs in, because "load is 9" alone sends you off
# hunting, while "export in plex at 720%" says what is wrong.
#
# Runs as steve from pico-load-watch.timer (every 5 min). State lives in
# $STATE_DIRECTORY (systemd StateDirectory=). Always exits 0 except on a bug,
# so the unit's OnFailure= alert means the watcher itself is broken.

set -uo pipefail

THRESHOLD="${LOAD_THRESHOLD:-6}"
REPEAT_HOURS="${REPEAT_HOURS:-6}"
STATE="${STATE_DIRECTORY:-$HOME/.local/state/pico-load-watch}/state"
NOTIFY="${NOTIFY:-$HOME/.local/bin/pushover-notify.sh}"

mkdir -p "$(dirname "$STATE")"
read -r l1 l5 l15 _ < /proc/loadavg
now=$(date +%s)
cores=$(nproc)

# state file: "<high|ok> <epoch of last alert>"
prev=ok last_alert=0
[[ -r $STATE ]] && read -r prev last_alert < "$STATE"

container_of() { # pid -> container name, or "host"
  local id
  id=$(grep -oE '[0-9a-f]{64}' "/proc/$1/cgroup" 2>/dev/null | head -1)
  [[ -n $id ]] || { echo host; return; }
  docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##' || echo "${id:0:12}"
}

top_procs() {
  ps -eo pid=,pcpu=,etimes=,comm= --sort=-pcpu | head -5 |
    while read -r pid pcpu etimes comm; do
      printf '%s%% %s [%s] pid %s, up %sm\n' "$pcpu" "$comm" "$(container_of "$pid")" "$pid" "$((etimes / 60))"
    done
}

high=$(awk -v l="$l15" -v t="$THRESHOLD" 'BEGIN { print (l > t) ? 1 : 0 }')

if (( high )); then
  if [[ $prev != high ]] || (( now - last_alert >= REPEAT_HOURS * 3600 )); then
    PUSHOVER_PRIORITY=1 "$NOTIFY" "pico load ${l15} (15m) on ${cores} cores" \
      "Load ${l1} / ${l5} / ${l15}, threshold ${THRESHOLD}. Top CPU:
$(top_procs)"
    last_alert=$now
  fi
  echo "high $last_alert" > "$STATE"
  echo "load ${l1} ${l5} ${l15} > ${THRESHOLD}: high"
else
  if [[ $prev == high ]]; then
    "$NOTIFY" "pico load recovered" "Load ${l1} / ${l5} / ${l15}, back under ${THRESHOLD}."
  fi
  echo "ok $last_alert" > "$STATE"
  echo "load ${l1} ${l5} ${l15} <= ${THRESHOLD}: ok"
fi
