#!/usr/bin/env bash
# Vaultwarden warm-standby sync: MySQL HeatWave → pico sqlite
# See architecture-proposal.md §7.1.1
#
# Uses Python (pymysql + sqlite3) to handle BLOB columns correctly.
# MySQL endpoint reachable via Tailscale (10.0.1.0/24 via oke-connector).

set -euo pipefail

PASS_FILE="/home/steve/.vw-mysql-sync.pass"
DATA_DIR="/usr/share/bitwarden"
SQLITE_DB="${DATA_DIR}/db.sqlite3"
CONTAINER_NAME="bitwarden"
TMP_SQLITE=$(mktemp /tmp/vw-sqlite.XXXXXX.db)
trap 'rm -f "$TMP_SQLITE"' EXIT

python3 -W ignore::DeprecationWarning - "$TMP_SQLITE" "$PASS_FILE" << 'PYEOF'
import sys, pymysql, sqlite3, re, pathlib

dest_path, pass_file = sys.argv[1], sys.argv[2]
password = pathlib.Path(pass_file).read_text().strip()

src = pymysql.connect(
    host="10.0.1.51", port=3306,
    user="vaultwarden", password=password,
    database="vaultwarden",
    cursorclass=pymysql.cursors.DictCursor,
)
dst = sqlite3.connect(dest_path)

def mysql_to_sqlite_type(mysql_type):
    """Convert MySQL type to SQLite type."""
    mysql_type = mysql_type.upper().split('(')[0].split()[0]
    type_map = {
        'INT': 'INTEGER',
        'INTEGER': 'INTEGER',
        'BIGINT': 'INTEGER',
        'TINYINT': 'INTEGER',
        'SMALLINT': 'INTEGER',
        'DECIMAL': 'REAL',
        'FLOAT': 'REAL',
        'DOUBLE': 'REAL',
        'BLOB': 'BLOB',
        'LONGBLOB': 'BLOB',
    }
    return type_map.get(mysql_type, 'TEXT')

with src, dst:
    src_cur = src.cursor()

    src_cur.execute("SHOW TABLES")
    tables = [row["Tables_in_vaultwarden"] for row in src_cur.fetchall()]

    dst.execute("PRAGMA foreign_keys = OFF")
    dst.execute("BEGIN")

    for table in tables:
        # Get column info from MySQL INFORMATION_SCHEMA
        src_cur.execute(f"SELECT COLUMN_NAME, COLUMN_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='{table}' AND TABLE_SCHEMA='vaultwarden' ORDER BY ORDINAL_POSITION")
        columns = src_cur.fetchall()

        if not columns:
            continue

        col_defs_sqlite = []
        for col_info in columns:
            col_name = col_info['COLUMN_NAME']
            col_type = col_info['COLUMN_TYPE']
            sqlite_type = mysql_to_sqlite_type(col_type)
            col_defs_sqlite.append(f'"{col_name}" {sqlite_type}')

        ddl = f'CREATE TABLE IF NOT EXISTS "{table}" ({", ".join(col_defs_sqlite)})'
        dst.execute(ddl)

        # Now sync data
        src_cur.execute(f"SELECT * FROM `{table}`")
        rows = src_cur.fetchall()
        cols = [d[0] for d in src_cur.description]

        if rows and cols:
            dst.execute(f'DELETE FROM "{table}"')
            placeholders = ",".join("?" * len(cols))
            col_list = ",".join(f'"{c}"' for c in cols)

            for row in rows:
                dst.execute(
                    f'INSERT INTO "{table}" ({col_list}) VALUES ({placeholders})',
                    [row[c] for c in cols],
                )

    dst.execute("COMMIT")
    dst.execute("PRAGMA foreign_keys = ON")

print(f"Synced {len(tables)} tables to {dest_path}")
PYEOF

# Sanity check
USER_COUNT=$(python3 -c "import sqlite3; c=sqlite3.connect('$TMP_SQLITE'); print(c.execute('SELECT COUNT(*) FROM users').fetchone()[0])" 2>/dev/null || echo 0)
if [ "$USER_COUNT" -lt 1 ]; then
  echo "ERROR: converted sqlite has 0 users — aborting swap" >&2
  exit 1
fi

# Atomic swap with brief container stop
docker stop "$CONTAINER_NAME"
cp "$TMP_SQLITE" "${SQLITE_DB}.new"
chmod 644 "${SQLITE_DB}.new"
mv "${SQLITE_DB}.new" "$SQLITE_DB"
docker start "$CONTAINER_NAME"

echo "vaultwarden sync complete: ${USER_COUNT} users"
