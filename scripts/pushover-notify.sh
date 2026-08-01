#!/usr/bin/env bash
# pushover-notify.sh — send a Pushover alert, credentials from Vault.
#
# Exists because systemd units on pico fail silently. The Vaultwarden
# warm-standby sync (vw-mysql-to-sqlite.service) failed hourly from the
# 2026-06-06 cluster rebuild until 2026-08-01 — eight weeks — and nothing
# said so; bw2 was trusted the whole time. See architecture-proposal.md §7.1.1.
#
# Two forms:
#   pushover-notify.sh --unit <unit>      compose a failure alert for a systemd
#                                         unit, including its journal tail
#   pushover-notify.sh <title> <message>  send an arbitrary message
#
# Wire a unit up for alerting by adding to its [Unit] section:
#   OnFailure=pushover-failure@%n.service
#
# Credentials come from kv/homelab/pushover via the pico-token-sync AppRole,
# the same path scripts/arr-malware-watchdog.sh uses. Never on disk.
#
# Exit status is always 0: a failure to alert must not itself become a
# cascading unit failure (and OnFailure= units that fail are not re-notified).

set -uo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.stevegore.au}"
CRED_DIR="${CRED_DIR:-$HOME/.config/vault-token-sync}"
JOURNAL_LINES="${JOURNAL_LINES:-12}"

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

# Pushover truncates around 1024 chars; leave room for the title.
MAX_MSG=900

send() { # $1 = title, $2 = message, $3 = priority
  local title=$1 msg=$2 priority=$3 token app user creds
  [[ -r $CRED_DIR/role_id && -r $CRED_DIR/secret_id ]] || {
    log "WARN  pushover: no AppRole credentials, alert not sent"; return; }

  token=$(VAULT_ADDR="$VAULT_ADDR" vault write -field=token auth/approle/login \
      role_id="$(tr -d '\n' < "$CRED_DIR/role_id")" \
      secret_id="$(tr -d '\n' < "$CRED_DIR/secret_id")" 2>/dev/null) || {
    log "WARN  pushover: vault login failed, alert not sent"; return; }

  creds=$(VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$token" \
      vault kv get -format=json kv/homelab/pushover 2>/dev/null) || {
    log "WARN  pushover: could not read kv/homelab/pushover, alert not sent"
    VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$token" vault token revoke -self >/dev/null 2>&1
    return; }
  VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$token" vault token revoke -self >/dev/null 2>&1

  app=$(printf '%s' "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["data"]["app_token"])' 2>/dev/null)
  user=$(printf '%s' "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["data"]["user_key"])' 2>/dev/null)
  [[ -n ${app:-} && -n ${user:-} ]] || { log "WARN  pushover: creds incomplete"; return; }

  if curl -sf --max-time 20 -o /dev/null \
       --form-string "token=$app" --form-string "user=$user" \
       --form-string "title=$title" --form-string "message=$msg" \
       --form-string "priority=$priority" \
       https://api.pushover.net/1/messages.json; then
    log "      pushover alert sent: $title"
  else
    log "WARN  pushover: send failed"
  fi
}

if [[ ${1:-} == --unit ]]; then
  unit=${2:?--unit needs a unit name}

  # ExecMainStatus is the exit code of the process that actually failed;
  # Result distinguishes exit-code from timeout/signal/oom.
  result=$(systemctl show -p Result --value "$unit" 2>/dev/null)
  status=$(systemctl show -p ExecMainStatus --value "$unit" 2>/dev/null)

  # Drop systemd's own "Starting/Failed with result" chatter — the useful
  # part is whatever the unit itself printed before dying.
  context=$(journalctl -u "$unit" -n "$JOURNAL_LINES" --no-pager -o cat 2>/dev/null \
            | grep -vE '^(Starting|Started|Stopped|Failed with result|Main process exited)' \
            | tail -n "$JOURNAL_LINES")

  msg="Host: $(hostname)
Result: ${result:-unknown} (exit ${status:-?})
Time: $(date -Is)

${context:-<no journal output>}"

  # Trim from the front: the tail of a traceback names the actual error.
  if (( ${#msg} > MAX_MSG )); then
    msg="…${msg: -MAX_MSG}"
  fi

  send "pico: $unit failed" "$msg" 1
else
  send "${1:?usage: pushover-notify.sh [--unit <unit>] | <title> <message>}" \
       "${2:-}" "${PUSHOVER_PRIORITY:-0}"
fi

exit 0
