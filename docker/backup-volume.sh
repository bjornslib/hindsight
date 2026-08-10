#!/bin/bash
# Backup hindsight-data Docker volume
# Usage: ./docker/backup-volume.sh [backup-name]
#
# Creates a named volume backup: hindsight-data-backup-<name>
# Default name: date-based (e.g., hindsight-data-backup-20260325)
#
# Safe to run while container is running (copies volume files).
# For maximum consistency, stop the container first.

set -euo pipefail

VOLUME_NAME="hindsight-data"
BACKUP_NAME="${1:-$(date +%Y%m%d)}"
BACKUP_VOLUME="${VOLUME_NAME}-backup-${BACKUP_NAME}"

# Check source volume exists
if ! docker volume inspect "$VOLUME_NAME" &>/dev/null; then
    echo "ERROR: Volume '$VOLUME_NAME' not found"
    exit 1
fi

# Check if backup already exists
if docker volume inspect "$BACKUP_VOLUME" &>/dev/null; then
    echo "WARNING: Backup volume '$BACKUP_VOLUME' already exists."
    read -p "Overwrite? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
    docker volume rm "$BACKUP_VOLUME"
fi

echo "Creating backup: $VOLUME_NAME -> $BACKUP_VOLUME"

docker volume create "$BACKUP_VOLUME" > /dev/null

docker run --rm \
    -v "$VOLUME_NAME":/src:ro \
    -v "$BACKUP_VOLUME":/dst \
    alpine sh -c "cp -a /src/. /dst/"

# Verify
SRC_SIZE=$(docker run --rm -v "$VOLUME_NAME":/v alpine du -sh /v/ | cut -f1)
DST_SIZE=$(docker run --rm -v "$BACKUP_VOLUME":/v alpine du -sh /v/ | cut -f1)

echo "Done! Source: $SRC_SIZE, Backup: $DST_SIZE"
echo "Restore with: docker run --rm -v $BACKUP_VOLUME:/src:ro -v $VOLUME_NAME:/dst alpine sh -c 'cp -a /src/. /dst/'"
