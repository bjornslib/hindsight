#!/bin/bash
# backup-hindsight.sh - Host-side backup of Hindsight pg_dump files
#
# Copies good backups from inside the Docker container to ~/.hindsight-backups/
# Only copies dumps > 10KB (skips empty-DB dumps from OOM crashes)
#
# Usage:
#   ./scripts/backup-hindsight.sh              # Run backup now
#   ./scripts/backup-hindsight.sh --list       # List available backups
#   ./scripts/backup-hindsight.sh --install-cron  # Install daily 2am cron job
#
# Restore:
#   ./scripts/restore-hindsight.sh             # Auto-restore from best backup
#   ./scripts/restore-hindsight.sh <file.sql.gz>  # Restore specific backup

set -euo pipefail

BACKUP_HOST_DIR="$HOME/.hindsight-backups"
CONTAINER_NAME="hindsight-mcp"
CONTAINER_BACKUP_DIR="/home/hindsight/.pg0/backups"
KEEP_COUNT=14
MIN_SIZE_KB=10

mkdir -p "$BACKUP_HOST_DIR"

# Handle flags
case "${1:-}" in
    --list)
        echo "Host-side backups in $BACKUP_HOST_DIR:"
        ls -lhS "$BACKUP_HOST_DIR"/hindsight-*.sql.gz 2>/dev/null || echo "  (none)"
        echo ""
        echo "In-container backups:"
        docker exec "$CONTAINER_NAME" ls -lhS "$CONTAINER_BACKUP_DIR"/ 2>/dev/null || echo "  (container not running)"
        exit 0
        ;;
    --install-cron)
        SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
        CRON_LINE="0 2 * * * $SCRIPT_PATH >> $BACKUP_HOST_DIR/backup.log 2>&1"
        if crontab -l 2>/dev/null | grep -qF "$SCRIPT_PATH"; then
            echo "Cron job already installed."
        else
            (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
            echo "Installed daily 2am cron job:"
            echo "  $CRON_LINE"
        fi
        exit 0
        ;;
esac

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$TIMESTAMP] Starting host-side backup..."

# Check Docker is running
if ! docker info &>/dev/null; then
    echo "[$TIMESTAMP] ERROR: Docker is not running. Skipping backup."
    exit 1
fi

# Check container exists
if ! docker ps -q -f "name=$CONTAINER_NAME" | grep -q .; then
    echo "[$TIMESTAMP] ERROR: Container '$CONTAINER_NAME' is not running. Skipping backup."
    exit 1
fi

# Copy backups from container to host
COPIED=0
for file in $(docker exec "$CONTAINER_NAME" find "$CONTAINER_BACKUP_DIR" -name "hindsight-*.sql.gz" -size "+${MIN_SIZE_KB}k" 2>/dev/null); do
    BASENAME=$(basename "$file")
    if [ ! -f "$BACKUP_HOST_DIR/$BASENAME" ]; then
        echo "  Copying $BASENAME..."
        docker cp "$CONTAINER_NAME:$file" "$BACKUP_HOST_DIR/$BASENAME"
        COPIED=$((COPIED + 1))
    fi
done

if [ "$COPIED" -eq 0 ]; then
    echo "  No new backups to copy."
else
    echo "  Copied $COPIED new backup(s)."
fi

# Prune old host-side backups (keep most recent N)
PRUNED=0
for old in $(ls -t "$BACKUP_HOST_DIR"/hindsight-*.sql.gz 2>/dev/null | tail -n +$((KEEP_COUNT + 1))); do
    echo "  Pruning old backup: $(basename "$old")"
    rm -f "$old"
    PRUNED=$((PRUNED + 1))
done

TOTAL=$(ls "$BACKUP_HOST_DIR"/hindsight-*.sql.gz 2>/dev/null | wc -l | tr -d ' ')
echo "[$TIMESTAMP] Done. $TOTAL backup(s) on host ($COPIED new, $PRUNED pruned)."
