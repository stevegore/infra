#!/usr/bin/env bash
# Vaultwarden warm-standby sync: MySQL HeatWave → pico sqlite
# See architecture-proposal.md §7.1.1
#
# Requires:
#   - mysql-client (for mysqldump)
#   - mysql2sqlite (https://github.com/dumblob/mysql2sqlite — place in PATH)
#   - sqlite3
#
# MySQL endpoint reachable via Tailscale (10.0.1.0/24 advertised by oke-connector).
# Use IP directly to avoid OCI VCN DNS resolution.

set -euo pipefail

MYSQL_HOST="10.0.1.51"
MYSQL_PORT="3306"
MYSQL_USER="vaultwarden"
MYSQL_PASS_FILE="/etc/vw-mysql-sync.pass"   # contains just the password, mode 0600
MYSQL_DB="vaultwarden"

DATA_DIR="/usr/share/bitwarden"
SQLITE_DB="${DATA_DIR}/db.sqlite3"
CONTAINER_NAME="bitwarden"

TMP_DUMP=$(mktemp /tmp/vw-mysql-dump.XXXXXX.sql)
TMP_SQLITE=$(mktemp /tmp/vw-sqlite.XXXXXX.db)
trap 'rm -f "$TMP_DUMP" "$TMP_SQLITE"' EXIT

# Read password from file (avoids shell history / env leak)
MYSQL_PASS=$(cat "$MYSQL_PASS_FILE")

# 1. Dump MySQL
mysqldump \
  --single-transaction \
  --skip-add-drop-table \
  --skip-add-locks \
  --skip-comments \
  --skip-set-charset \
  -h "$MYSQL_HOST" -P "$MYSQL_PORT" \
  -u "$MYSQL_USER" -p"${MYSQL_PASS}" \
  "$MYSQL_DB" > "$TMP_DUMP"

# 2. Convert to sqlite
mysql2sqlite "$TMP_DUMP" | sqlite3 "$TMP_SQLITE"

# 3. Verify the converted DB has users (sanity check before overwriting live DB)
USER_COUNT=$(sqlite3 "$TMP_SQLITE" "SELECT COUNT(*) FROM users;" 2>/dev/null || echo 0)
if [ "$USER_COUNT" -lt 1 ]; then
  echo "ERROR: converted sqlite has 0 users — aborting swap" >&2
  exit 1
fi

# 4. Atomic swap: brief container stop, replace sqlite, restart
docker stop "$CONTAINER_NAME"
cp "$TMP_SQLITE" "${SQLITE_DB}.new"
chown root:root "${SQLITE_DB}.new"
chmod 644 "${SQLITE_DB}.new"
mv "${SQLITE_DB}.new" "$SQLITE_DB"
docker start "$CONTAINER_NAME"

echo "vaultwarden sync complete: ${USER_COUNT} users, sqlite at ${SQLITE_DB}"
