#!/bin/bash
# backup-hindsight.sh - Daily backup of Hindsight PostgreSQL data volume
#
# Setup daily cron (runs at 2am):
#   0 2 * * * /path/to/scripts/backup-hindsight.sh >> /var/log/hindsight-backup.log 2>&1
#
# Or run manually:
#   ./scripts/backup-hindsight.sh

set -euo pipefail

SOURCE_VOL="hindsight-data"
BACKUP_VOL="hindsight-data-backup-daily"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "[$TIMESTAMP] Starting Hindsight volume backup..."
echo "  Source: $SOURCE_VOL"
echo "  Backup: $BACKUP_VOL"

# Get source volume size in bytes
get_volume_size() {
    local vol="$1"
    docker run --rm \
        -v "${vol}:/data:ro" \
        alpine sh -c 'du -sb /data 2>/dev/null | cut -f1' 2>/dev/null || echo "0"
}

# Check source volume exists
if ! docker volume inspect "$SOURCE_VOL" &>/dev/null; then
    echo "ERROR: Source volume '$SOURCE_VOL' not found!"
    exit 1
fi

SOURCE_SIZE=$(get_volume_size "$SOURCE_VOL")
echo "  Source size: ${SOURCE_SIZE} bytes"

# Check if backup volume exists and compare sizes
if docker volume inspect "$BACKUP_VOL" &>/dev/null; then
    BACKUP_SIZE=$(get_volume_size "$BACKUP_VOL")
    echo "  Existing backup size: ${BACKUP_SIZE} bytes"

    if [ "$SOURCE_SIZE" -lt "$BACKUP_SIZE" ]; then
        echo "WARNING: Source ($SOURCE_SIZE bytes) is SMALLER than backup ($BACKUP_SIZE bytes)."
        echo "   This may indicate data loss in the source volume."
        echo "   Skipping backup to protect existing backup data."
        echo "   To force backup anyway, delete '$BACKUP_VOL' first."
        exit 1
    fi

    echo "  Source is >= backup size. Proceeding with backup..."
    # Remove old backup volume to recreate fresh
    docker volume rm "$BACKUP_VOL" >/dev/null
fi

# Create fresh backup volume
docker volume create "$BACKUP_VOL" >/dev/null

# Copy data
echo "  Copying data..."
docker run --rm \
    -v "${SOURCE_VOL}:/source:ro" \
    -v "${BACKUP_VOL}:/dest" \
    alpine sh -c 'cp -av /source/. /dest/ && echo "Copy complete."'

FINAL_SIZE=$(get_volume_size "$BACKUP_VOL")
echo "[$TIMESTAMP] Backup complete. Backup size: ${FINAL_SIZE} bytes"
