#!/usr/bin/env bash
#
# Produce a restorable Home Assistant Container snapshot on pico.
#
# The existing Duplicati "Home Assistant" job backs up /usr/share/hassio/ to
# OneDrive. HA moved to /opt/ha-container on 2026-08-01, so this script stages a
# consistent snapshot back under /usr/share/hassio/backup/ha-container/ before
# that Duplicati job runs. It does not require sudo: Docker performs the final
# copy into the root-owned legacy backup directory.

set -euo pipefail

HA_ROOT=/opt/ha-container
LOCAL_BACKUP_DIR="$HA_ROOT/backups"
DUPLICATI_SOURCE_DIR=/usr/share/hassio/backup/ha-container
HELPER_IMAGE=ghcr.io/home-assistant/home-assistant:2026.7.4
KEEP_LOCAL_DAYS=3
KEEP_DUPLICATI_DAYS=14

if [[ $(hostname -s) != pico ]]; then
    echo "error: this backup must run on pico" >&2
    exit 1
fi

for required in docker tar gzip sha256sum; do
    command -v "$required" >/dev/null || {
        echo "error: required command not found: $required" >&2
        exit 1
    }
done

[[ -f "$HA_ROOT/compose.yaml" ]] || {
    echo "error: $HA_ROOT/compose.yaml not found" >&2
    exit 1
}

for container in homeassistant-app homeassistant-db homeassistant-matter; do
    [[ $(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null) == true ]] || {
        echo "error: required container is not running: $container" >&2
        exit 1
    }
done

umask 077
mkdir -p "$LOCAL_BACKUP_DIR"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
archive_name="ha-container-$stamp.tar.gz"
staging_dir=$(mktemp -d "$LOCAL_BACKUP_DIR/.staging.XXXXXX")
archive_tmp="$LOCAL_BACKUP_DIR/$archive_name.partial"
archive_path="$LOCAL_BACKUP_DIR/$archive_name"

cleanup() {
    rm -rf "$staging_dir" "$archive_tmp"
}
trap cleanup EXIT

echo "==> dumping MariaDB"
docker exec homeassistant-db sh -c '
    exec mariadb-dump \
      --single-transaction --quick --routines --events --triggers \
      -uroot -p"$MARIADB_ROOT_PASSWORD" --databases homeassistant
' | gzip -9 > "$staging_dir/homeassistant.sql.gz"

gzip -t "$staging_dir/homeassistant.sql.gz"
gzip -cd "$staging_dir/homeassistant.sql.gz" | grep 'CREATE TABLE' >/dev/null

echo "==> archiving config, Matter state, Compose definition and secrets"
docker run --rm \
    --entrypoint tar \
    -v "$HA_ROOT:/source:ro" \
    -v "$staging_dir:/backup" \
    "$HELPER_IMAGE" \
    --exclude='./backups' \
    --exclude='./dbdata' \
    -C /source \
    -czf /backup/files.tar.gz \
    config matter-data compose.yaml README.md .env

tar -tzf "$staging_dir/files.tar.gz" >/dev/null
sha256sum "$staging_dir/homeassistant.sql.gz" "$staging_dir/files.tar.gz" \
    > "$staging_dir/SHA256SUMS"

cat > "$staging_dir/RESTORE.txt" <<'EOF'
Home Assistant Container backup

1. Verify: sha256sum -c SHA256SUMS
2. Extract files.tar.gz into /opt/ha-container on pico.
3. Start only homeassistant-db and wait until healthy.
4. Restore the logical dump:
     gzip -cd homeassistant.sql.gz | docker exec -i homeassistant-db \
       sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'
5. Start homeassistant-matter and homeassistant.
6. Verify recorder/history, integrations, Matter state and both HA endpoints.
EOF

tar -C "$staging_dir" -czf "$archive_tmp" .
tar -tzf "$archive_tmp" >/dev/null
mv "$archive_tmp" "$archive_path"

echo "==> copying snapshot into Duplicati's existing Home Assistant source"
docker run --rm \
    --entrypoint sh \
    -e ARCHIVE_NAME="$archive_name" \
    -e KEEP_DAYS="$KEEP_DUPLICATI_DAYS" \
    -v "$LOCAL_BACKUP_DIR:/source:ro" \
    -v "$DUPLICATI_SOURCE_DIR:/dest" \
    "$HELPER_IMAGE" -eu -c '
        cp "/source/$ARCHIVE_NAME" "/dest/$ARCHIVE_NAME.partial"
        chmod 600 "/dest/$ARCHIVE_NAME.partial"
        mv "/dest/$ARCHIVE_NAME.partial" "/dest/$ARCHIVE_NAME"
        find /dest -maxdepth 1 -type f -name "ha-container-*.tar.gz" \
          -mtime "+$KEEP_DAYS" -delete
    '

find "$LOCAL_BACKUP_DIR" -maxdepth 1 -type f -name 'ha-container-*.tar.gz' \
    -mtime "+$KEEP_LOCAL_DAYS" -delete

trap - EXIT
cleanup

echo "==> backup complete"
echo "    local:      $archive_path"
echo "    Duplicati:  $DUPLICATI_SOURCE_DIR/$archive_name"
