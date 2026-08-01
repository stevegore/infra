#!/usr/bin/env bash
# Push every *.token file in TOKEN_DIR to Vault under kv/homelab/<basename>.
# Authenticates via AppRole; Vault sees pico's Tailscale IP (100.98.212.71).
set -euo pipefail

# Resolve the Vault proxy without trusting MagicDNS or any single hostname.
# Two separate things have broken this in the past 24h:
#
#   1. The 2026-06-06 rebuild left the original `vault-oke` device registered but
#      dead. The live proxy took `vault-oke-1`; MagicDNS kept pointing the old
#      name at the corpse, so this failed as a 30s i/o timeout — not a name
#      error — every 15 minutes, and kv/homelab/* went stale for 55 days.
#      Deleting the corpses on 2026-08-01 inverted the hazard: the clean names
#      are free again, so the *next* rebuild registers `vault-oke` with no
#      suffix and anything pinned to `-1` breaks instead.
#   2. NetworkManager (`dns=default`, `rc-manager=file`) periodically overwrites
#      systemd-resolved's stub-resolv.conf with the router's address, which cuts
#      out the resolver holding tailscaled's split-DNS route. MagicDNS then dies
#      host-wide until it is put back.
#
# So: ask tailscaled directly (no DNS in the path), and health-check before
# committing to an address — a registered-but-dead device still resolves and
# then blackholes, which is precisely failure 1. First candidate that actually
# answers wins. Falls back to the MagicDNS name so a host without the tailscale
# CLI degrades to the old behaviour rather than dying.
# Space-separated, in preference order. Plain string rather than an array so it
# stays overridable from the environment and safe under `set -u`.
TS_HOSTS="${TS_HOSTS:-vault-oke-1 vault-oke}"
VAULT_PORT="${VAULT_PORT:-8200}"

resolve_vault_addr() {
    local host ip addr
    command -v tailscale >/dev/null 2>&1 || return 1
    for host in $TS_HOSTS; do
        ip=$(tailscale ip -4 "$host" 2>/dev/null | head -n1) || true
        [[ -n "$ip" ]] || continue
        addr="http://$ip:$VAULT_PORT"
        # Any HTTP answer means something is listening; we only need to rule out
        # the blackhole. -m 5 so a dead peer costs 5s, not the 30s TCP timeout.
        if curl -s -m 5 -o /dev/null "$addr/v1/sys/health"; then
            echo "resolved $host -> $ip" >&2
            printf '%s' "$addr"
            return 0
        fi
        echo "candidate $host ($ip) did not answer, trying next" >&2
    done
    return 1
}

export VAULT_ADDR="${VAULT_ADDR:-$(resolve_vault_addr || echo "http://vault-oke-1:$VAULT_PORT")}"
CRED_DIR="${CRED_DIR:-$HOME/.config/vault-token-sync}"
TOKEN_DIR="${TOKEN_DIR:-$HOME/code/infra}"
# Don't sync the bootstrap credential into the thing it bootstraps.
SKIP_NAMES_RE="${SKIP_NAMES_RE:-^(vault-root)$}"

ROLE_ID="$(tr -d '\n' < "$CRED_DIR/role_id")"
SECRET_ID="$(tr -d '\n' < "$CRED_DIR/secret_id")"

VAULT_TOKEN=$(vault write -field=token auth/approle/login \
    role_id="$ROLE_ID" secret_id="$SECRET_ID")
[[ -z "$VAULT_TOKEN" ]] && { echo "approle login failed" >&2; exit 1; }
export VAULT_TOKEN

trap 'vault token revoke -self >/dev/null 2>&1 || true' EXIT

shopt -s nullglob
synced=0
for f in "$TOKEN_DIR"/*.token; do
    name="$(basename "$f" .token)"
    if [[ "$name" =~ $SKIP_NAMES_RE ]]; then
        echo "  skip $name (excluded)"
        continue
    fi

    value="$(tr -d '\n' < "$f")"
    if [[ -z "$value" ]]; then
        echo "  skip $name (empty)"
        continue
    fi

    if vault kv put "kv/homelab/$name" token="$value" >/dev/null; then
        echo "  put kv/homelab/$name"
        synced=$((synced + 1))
    else
        echo "  FAIL kv/homelab/$name" >&2
    fi
done

echo "synced $synced token(s)"
