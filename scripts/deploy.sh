#!/bin/bash
# deploy.sh - Safely rebuild and redeploy Hindsight Docker container
#
# Usage:
#   ./scripts/deploy.sh              # Build and deploy
#   ./scripts/deploy.sh --no-backup  # Skip pre-deploy backup
#   ./scripts/deploy.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/docker/standalone/docker-compose.yml"
SKIP_BACKUP=false

# Parse args
for arg in "$@"; do
    case $arg in
        --no-backup) SKIP_BACKUP=true ;;
        --help|-h)
            echo "Usage: $0 [--no-backup]"
            echo ""
            echo "Safely rebuilds and redeploys the Hindsight Docker container."
            echo "Runs a pre-deploy backup by default to protect your data."
            exit 0
            ;;
    esac
done

echo "Hindsight Deploy"
echo "================="

# Step 1: Pre-deploy backup
if [ "$SKIP_BACKUP" = false ]; then
    echo ""
    echo "Step 1/4: Pre-deploy backup..."
    if bash "$SCRIPT_DIR/backup-hindsight.sh"; then
        echo "   Backup complete."
    else
        echo "WARNING: Backup failed or skipped (source may be smaller than backup)."
        echo "   Continuing with deploy... (use --no-backup to suppress this warning)"
    fi
else
    echo "Step 1/4: Backup skipped (--no-backup)"
fi

# Step 2: Build new image
echo ""
echo "Step 2/4: Building Docker image..."
cd "$REPO_ROOT"
docker build -f docker/standalone/Dockerfile -t hindsight-standalone .
echo "   Build complete."

# Step 3: Stop existing container
echo ""
echo "Step 3/4: Stopping existing container..."
docker compose -f "$COMPOSE_FILE" down || true
echo "   Stopped."

# Step 4: Start with new image
echo ""
echo "Step 4/4: Starting container..."
docker compose -f "$COMPOSE_FILE" up -d
echo ""
echo "Deploy complete!"
echo ""
echo "Services:"
echo "   API:           http://localhost:8888"
echo "   Control Plane: http://localhost:9999"
echo ""
echo "Logs: docker compose -f $COMPOSE_FILE logs -f"
