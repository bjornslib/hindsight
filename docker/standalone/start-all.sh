#!/bin/bash
set -e

# Graceful shutdown handler
shutdown() {
    echo "Shutdown signal received, stopping services..."
    for pid in "${PIDS[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    wait "${PIDS[@]}" 2>/dev/null || true
    echo "Services stopped cleanly."
    exit 0
}
trap shutdown SIGTERM SIGINT

# Service flags (default to true if not set)
ENABLE_API="${HINDSIGHT_ENABLE_API:-true}"
ENABLE_CP="${HINDSIGHT_ENABLE_CP:-true}"

# =============================================================================
# Dependency waiting (opt-in via HINDSIGHT_WAIT_FOR_DEPS=true)
#
# Problem: When running with LM Studio, the LLM may take time to load models.
# If Hindsight starts before LM Studio is ready, it fails on LLM verification.
# This wait loop ensures dependencies are ready before starting.
# =============================================================================
if [ "${HINDSIGHT_WAIT_FOR_DEPS:-false}" = "true" ]; then
    LLM_BASE_URL="${HINDSIGHT_API_LLM_BASE_URL:-http://host.docker.internal:1234/v1}"
    MAX_RETRIES="${HINDSIGHT_RETRY_MAX:-0}"  # 0 = infinite
    RETRY_INTERVAL="${HINDSIGHT_RETRY_INTERVAL:-10}"

    # Check if external database is configured (skip check for embedded pg0)
    SKIP_DB_CHECK=false
    if [ -z "${HINDSIGHT_API_DATABASE_URL}" ]; then
        SKIP_DB_CHECK=true
    else
        DB_CHECK_HOST=$(echo "$HINDSIGHT_API_DATABASE_URL" | sed -E 's|.*@([^:/]+):([0-9]+)/.*|\1 \2|')
    fi

    check_db() {
        if $SKIP_DB_CHECK; then
            return 0
        fi
        if command -v pg_isready &> /dev/null; then
            pg_isready -h $(echo $DB_CHECK_HOST | cut -d' ' -f1) -p $(echo $DB_CHECK_HOST | cut -d' ' -f2) &>/dev/null
        else
            python3 -c "import socket; s=socket.socket(); s.settimeout(5); exit(0 if s.connect_ex(('$(echo $DB_CHECK_HOST | cut -d' ' -f1)', $(echo $DB_CHECK_HOST | cut -d' ' -f2))) == 0 else 1)" 2>/dev/null
        fi
    }

    check_llm() {
        curl -sf "${LLM_BASE_URL}/models" --connect-timeout 5 &>/dev/null
    }

    echo "⏳ Waiting for dependencies to be ready..."
    attempt=1

    while true; do
        db_ok=false
        llm_ok=false

        if check_db; then
            db_ok=true
        fi

        if check_llm; then
            llm_ok=true
        fi

        if $db_ok && $llm_ok; then
            echo "✅ Dependencies ready!"
            break
        fi

        if [ "$MAX_RETRIES" -ne 0 ] && [ "$attempt" -ge "$MAX_RETRIES" ]; then
            echo "❌ Max retries ($MAX_RETRIES) reached. Dependencies not available."
            exit 1
        fi

        echo "   Attempt $attempt: DB=$( $db_ok && echo 'ok' || echo 'waiting' ), LLM=$( $llm_ok && echo 'ok' || echo 'waiting' )"
        sleep "$RETRY_INTERVAL"
        ((attempt++))
    done
fi

# Track PIDs for wait
PIDS=()

# Start API if enabled
if [ "$ENABLE_API" = "true" ]; then
    cd /app/api
    # Run API directly - Python's PYTHONUNBUFFERED=1 handles output buffering
    hindsight-api &
    API_PID=$!
    PIDS+=($API_PID)

    # Wait for API to be ready
    for i in {1..60}; do
        if curl -sf http://localhost:8888/health &>/dev/null; then
            break
        fi
        sleep 1
    done
fi

# Auto-restore: if DB is empty but backups exist, restore from the best one
if [ "$ENABLE_API" = "true" ]; then
    BACKUP_DIR="/home/hindsight/.pg0/backups"
    PG_BIN="/home/hindsight/.pg0/installation/18.1.0/bin"
    MU_COUNT=$(PGPASSWORD=hindsight "$PG_BIN/psql" -U hindsight -h 127.0.0.1 -p 5432 -d hindsight -t -A -c "SELECT COUNT(*) FROM memory_units" 2>/dev/null || echo "-1")
    if [ "$MU_COUNT" = "0" ]; then
        # Find the largest backup file (most likely the last good one)
        BEST_BACKUP=$(ls -S "$BACKUP_DIR"/hindsight-*.sql.gz 2>/dev/null | head -1)
        if [ -n "$BEST_BACKUP" ]; then
            BACKUP_SIZE=$(stat -c%s "$BEST_BACKUP" 2>/dev/null || stat -f%z "$BEST_BACKUP" 2>/dev/null || echo "0")
            if [ "$BACKUP_SIZE" -gt 10000 ]; then
                echo "[auto-restore] WARNING: Database is empty but backup exists!"
                echo "[auto-restore] Restoring from: $BEST_BACKUP ($(du -h "$BEST_BACKUP" | cut -f1))"
                gunzip -c "$BEST_BACKUP" | PGPASSWORD=hindsight "$PG_BIN/psql" -U hindsight -h 127.0.0.1 -p 5432 -d hindsight -q 2>&1 | tail -5
                NEW_COUNT=$(PGPASSWORD=hindsight "$PG_BIN/psql" -U hindsight -h 127.0.0.1 -p 5432 -d hindsight -t -A -c "SELECT COUNT(*) FROM memory_units" 2>/dev/null || echo "0")
                echo "[auto-restore] Restored $NEW_COUNT memory units from backup"
            else
                echo "[auto-restore] WARNING: Database is empty and no good backup found (largest is only $BACKUP_SIZE bytes)"
            fi
        else
            echo "[auto-restore] WARNING: Database is empty and no backups found in $BACKUP_DIR"
        fi
    fi
fi

if [ "$ENABLE_API" != "true" ]; then
    echo "API disabled (HINDSIGHT_ENABLE_API=false)"
fi

# Start Control Plane if enabled
if [ "$ENABLE_CP" = "true" ]; then
    echo "🎛️  Starting Control Plane..."
    cd /app/control-plane
    PORT="${HINDSIGHT_CP_PORT:-9999}" node server.js &
    CP_PID=$!
    PIDS+=($CP_PID)
else
    echo "Control Plane disabled (HINDSIGHT_ENABLE_CP=false)"
fi

# Start automated pg_dump backup loop (if API is running with embedded pg0)
BACKUP_INTERVAL="${HINDSIGHT_BACKUP_INTERVAL_HOURS:-12}"
BACKUP_KEEP="${HINDSIGHT_BACKUP_KEEP:-7}"
if [ "$ENABLE_API" = "true" ] && [ -z "${HINDSIGHT_API_DATABASE_URL}" ]; then
    BACKUP_DIR="/home/hindsight/.pg0/backups"
    mkdir -p "$BACKUP_DIR"
    (
        # Wait for PG to be fully ready
        sleep 30
        PG_BIN="/home/hindsight/.pg0/installation/18.1.0/bin"
        while true; do
            TIMESTAMP=$(date +%Y%m%d-%H%M%S)
            DUMP_FILE="${BACKUP_DIR}/hindsight-${TIMESTAMP}.sql.gz"
            # Safety check: skip backup if DB appears empty (prevents overwriting good backups after OOM crash)
            ROW_COUNT=$(PGPASSWORD=hindsight "$PG_BIN/psql" -U hindsight -h 127.0.0.1 -p 5432 -d hindsight -t -A -c "SELECT COUNT(*) FROM memory_units" 2>/dev/null || echo "0")
            if [ "$ROW_COUNT" -eq 0 ] 2>/dev/null; then
                echo "[backup] WARNING: memory_units is empty — skipping backup to protect existing backups"
                sleep $((BACKUP_INTERVAL * 3600))
                continue
            fi
            if PGPASSWORD=hindsight "$PG_BIN/pg_dump" -U hindsight -h 127.0.0.1 -p 5432 -d hindsight 2>/dev/null | gzip > "$DUMP_FILE"; then
                SIZE=$(du -sh "$DUMP_FILE" | cut -f1)
                echo "[backup] pg_dump completed: $DUMP_FILE ($SIZE)"
                # Prune old backups, keep most recent N
                ls -t "$BACKUP_DIR"/hindsight-*.sql.gz 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | while read f; do
                    echo "[backup] Pruning old backup: $f"
                    rm -f "$f"
                done
            else
                echo "[backup] WARNING: pg_dump failed at $TIMESTAMP"
                rm -f "$DUMP_FILE"
            fi
            sleep $((BACKUP_INTERVAL * 3600))
        done
    ) &
    BACKUP_PID=$!
    PIDS+=($BACKUP_PID)
    echo "📦 Automated backups: every ${BACKUP_INTERVAL}h, keeping ${BACKUP_KEEP} (dir: $BACKUP_DIR)"
fi

# Print status
echo ""
echo "✅ Hindsight is running!"
echo ""
echo "📍 Access:"
if [ "$ENABLE_CP" = "true" ]; then
    echo "   Control Plane: http://localhost:${HINDSIGHT_CP_PORT:-9999}"
fi
if [ "$ENABLE_API" = "true" ]; then
    echo "   API:           http://localhost:8888"
fi
echo ""

# Check if any services are running
if [ ${#PIDS[@]} -eq 0 ]; then
    echo "❌ No services enabled! Set HINDSIGHT_ENABLE_API=true or HINDSIGHT_ENABLE_CP=true"
    exit 1
fi

# Wait for any process to exit
wait -n

# Exit with status of first exited process
exit $?
