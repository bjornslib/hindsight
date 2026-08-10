#!/bin/bash
# restore-hindsight.sh - Restore Hindsight from the best available pg_dump backup
#
# Usage:
#   ./scripts/restore-hindsight.sh                    # Auto-find best backup
#   ./scripts/restore-hindsight.sh <file.sql.gz>      # Restore specific file
#   ./scripts/restore-hindsight.sh --dry-run           # Show what would be restored

set -euo pipefail

BACKUP_HOST_DIR="$HOME/.hindsight-backups"
CONTAINER_NAME="hindsight-mcp"
COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN_SIZE_BYTES=10000
DRY_RUN=false
BACKUP_FILE=""

# Parse args
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *.sql.gz) BACKUP_FILE="$arg" ;;
    esac
done

# Find the best backup if not specified
if [ -z "$BACKUP_FILE" ]; then
    echo "Searching for best backup..."

    # Check host-side backups first (sorted by size, largest first)
    BACKUP_FILE=$(find "$BACKUP_HOST_DIR" -name "hindsight-*.sql.gz" -size "+${MIN_SIZE_BYTES}c" 2>/dev/null | xargs ls -S 2>/dev/null | head -1 || true)

    if [ -z "$BACKUP_FILE" ]; then
        echo "ERROR: No good backup found in $BACKUP_HOST_DIR"
        echo "  (looked for .sql.gz files > $MIN_SIZE_BYTES bytes)"
        exit 1
    fi
fi

# Validate backup exists and is large enough
if [ ! -f "$BACKUP_FILE" ]; then
    echo "ERROR: Backup file not found: $BACKUP_FILE"
    exit 1
fi

FILE_SIZE=$(stat -f%z "$BACKUP_FILE" 2>/dev/null || stat -c%s "$BACKUP_FILE" 2>/dev/null || echo "0")
if [ "$FILE_SIZE" -lt "$MIN_SIZE_BYTES" ]; then
    echo "ERROR: Backup file is too small ($FILE_SIZE bytes) — likely an empty-DB dump"
    exit 1
fi

echo "Best backup: $(basename "$BACKUP_FILE") ($(du -h "$BACKUP_FILE" | cut -f1))"

if $DRY_RUN; then
    echo "[DRY RUN] Would restore from: $BACKUP_FILE"
    echo "[DRY RUN] Would stop container, restore via psql, restart container"
    exit 0
fi

# Confirm
echo ""
echo "This will:"
echo "  1. Stop the Hindsight container"
echo "  2. Start pg0 and restore from $(basename "$BACKUP_FILE")"
echo "  3. Restart the container"
echo ""
read -p "Proceed? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Step 1: Copy backup into container
echo ""
echo "Step 1/4: Copying backup to container..."
docker cp "$BACKUP_FILE" "$CONTAINER_NAME:/tmp/restore.sql.gz"

# Step 2: Stop the API (but keep container running for psql access)
echo "Step 2/4: Stopping API process..."
docker exec "$CONTAINER_NAME" bash -c 'kill $(pgrep -f hindsight-api) 2>/dev/null || true'
sleep 3

# Step 3: Restore via psql
echo "Step 3/4: Restoring database..."
docker exec "$CONTAINER_NAME" bash -c '
PG_BIN="/home/hindsight/.pg0/installation/18.1.0/bin"
echo "  Dropping existing data..."
PGPASSWORD=hindsight "$PG_BIN/psql" -U hindsight -h 127.0.0.1 -p 5432 -d hindsight -c "
    DROP SCHEMA public CASCADE;
    CREATE SCHEMA public;
    GRANT ALL ON SCHEMA public TO hindsight;
" 2>&1
echo "  Loading backup..."
gunzip -c /tmp/restore.sql.gz | PGPASSWORD=hindsight "$PG_BIN/psql" -U hindsight -h 127.0.0.1 -p 5432 -d hindsight -q 2>&1 | tail -5
MU_COUNT=$(PGPASSWORD=hindsight "$PG_BIN/psql" -U hindsight -h 127.0.0.1 -p 5432 -d hindsight -t -A -c "SELECT COUNT(*) FROM memory_units" 2>/dev/null || echo "ERROR")
echo "  Restored memory_units: $MU_COUNT"
rm -f /tmp/restore.sql.gz
'

# Step 4: Restart container completely
echo "Step 4/4: Restarting container..."
docker restart "$CONTAINER_NAME"

echo ""
echo "Waiting for health..."
for i in $(seq 1 60); do
    if curl -sf http://localhost:8888/health > /dev/null 2>&1; then
        echo "Hindsight is healthy!"
        echo ""
        echo "Verify: curl -s http://localhost:8888/health | python3 -m json.tool"
        exit 0
    fi
    sleep 2
done

echo "Warning: Health check timed out. Check: docker logs $CONTAINER_NAME --tail 20"
exit 1
