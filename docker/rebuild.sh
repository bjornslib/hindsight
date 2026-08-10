#!/bin/bash
# Rebuild Hindsight Docker image from this fork (preserves hindsight-data volume)
#
# Usage:
#   ./docker/rebuild.sh          # Rebuild and restart
#   ./docker/rebuild.sh --no-cache  # Full clean rebuild

cd "$(dirname "$0")/.."

EXTRA_ARGS=""
if [[ "$1" == "--no-cache" ]]; then
  EXTRA_ARGS="--no-cache"
  echo "Forcing full rebuild (no cache)..."
fi

echo "Building hindsight-standalone from fork..."
echo ""

docker compose build $EXTRA_ARGS

echo ""
echo "Restarting container (hindsight-data volume preserved)..."
docker compose down
docker compose up -d

echo ""
echo "Waiting for health..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:8888/health > /dev/null 2>&1; then
    echo "Hindsight is healthy!"
    curl -s http://localhost:8888/health | python3 -m json.tool 2>/dev/null
    exit 0
  fi
  sleep 2
done

echo "Warning: Health check timed out after 120s"
docker logs hindsight-mcp --tail 20
exit 1
