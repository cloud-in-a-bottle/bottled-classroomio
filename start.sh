#!/bin/bash

set -Eeuo pipefail

PERSIST="${OPENHOST_APP_DATA_DIR:-/data/app_data/classroomio}"
TEMP="${OPENHOST_APP_TEMP_DIR:-/tmp/classroomio}"
ZONE_DOMAIN="${OPENHOST_ZONE_DOMAIN:-localhost}"
APP_NAME="${OPENHOST_APP_NAME:-classroomio}"
APP_HOST="${APP_NAME}.${ZONE_DOMAIN}"
PUBLIC_ORIGIN="${CLASSROOMIO_PUBLIC_ORIGIN:-https://${APP_HOST}}"

PG_DATA="$PERSIST/postgres"
REDIS_DATA="$PERSIST/redis"
MINIO_DATA="$PERSIST/minio"
SECRETS_DIR="$PERSIST/secrets"
LOG_DIR="$TEMP/log"
JOBS_TEMP="$TEMP/jobs"
MC_CONFIG="$TEMP/mc"
BOOTSTRAP_MARKER="$PERSIST/bootstrap-complete"

API_ROOT=/opt/classroomio/api
DASHBOARD_ROOT=/opt/classroomio/dashboard
JOBS_ROOT=/app
PG_BIN=/usr/lib/postgresql/16/bin

PIDS=()
CLEANED_UP=0

log() {
    printf '[classroomio] %s\n' "$*" >&2
}

cleanup() {
    if [[ "$CLEANED_UP" == 1 ]]; then
        return
    fi
    CLEANED_UP=1
    trap - EXIT TERM INT

    if ((${#PIDS[@]} > 0)); then
        log "stopping services"
        # SIGINT asks PostgreSQL for a fast, checkpointed shutdown rather than
        # TERM's potentially unbounded smart shutdown.
        if [[ -n "${PG_PID:-}" ]]; then
            kill -INT "$PG_PID" 2>/dev/null || true
        fi
        for pid in "${PIDS[@]}"; do
            [[ "$pid" == "${PG_PID:-}" ]] && continue
            kill -TERM "$pid" 2>/dev/null || true
        done

        for _ in $(seq 1 120); do
            local any_running=0
            for pid in "${PIDS[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    any_running=1
                    break
                fi
            done
            [[ "$any_running" == 0 ]] && break
            sleep 0.25
        done

        for pid in "${PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                log "service $pid did not stop gracefully; sending SIGKILL"
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done
        wait "${PIDS[@]}" 2>/dev/null || true
    fi
}

terminate() {
    cleanup
    exit 0
}

trap cleanup EXIT
trap terminate TERM INT

ensure_secret() {
    local path="$1"
    local bytes="$2"

    if [[ -s "$path" ]]; then
        return
    fi

    local temporary_path="${path}.tmp.$$"
    if ! (umask 077; openssl rand -hex "$bytes" > "$temporary_path"); then
        rm -f "$temporary_path"
        return 1
    fi
    mv "$temporary_path" "$path"
    chmod 0600 "$path"
}

wait_for_process() {
    local pid="$1"
    local description="$2"
    shift 2

    for _ in $(seq 1 120); do
        if timeout 5s "$@" >/dev/null 2>&1; then
            return
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            log "$description exited before becoming ready"
            return 1
        fi
        sleep 1
    done

    log "timed out waiting for $description"
    return 1
}

mkdir -p "$PG_DATA" "$REDIS_DATA" "$MINIO_DATA" "$SECRETS_DIR" \
    "$LOG_DIR" "$JOBS_TEMP" "$MC_CONFIG" "$TEMP/home"
chmod 0700 "$SECRETS_DIR"
chown -R postgres:postgres "$PG_DATA"
chown -R redis:redis "$REDIS_DATA"
chown -R classroomio:classroomio "$MINIO_DATA" "$JOBS_TEMP" "$MC_CONFIG" "$TEMP/home"
chmod 0700 "$PG_DATA"

ensure_secret "$SECRETS_DIR/postgres-password" 32
ensure_secret "$SECRETS_DIR/better-auth-secret" 32
ensure_secret "$SECRETS_DIR/private-server-key" 32
ensure_secret "$SECRETS_DIR/minio-access-key" 10
ensure_secret "$SECRETS_DIR/minio-secret-key" 24

DB_PASSWORD="$(<"$SECRETS_DIR/postgres-password")"
BETTER_AUTH_SECRET="$(<"$SECRETS_DIR/better-auth-secret")"
PRIVATE_SERVER_KEY="$(<"$SECRETS_DIR/private-server-key")"
MINIO_ACCESS_KEY="$(<"$SECRETS_DIR/minio-access-key")"
MINIO_SECRET_KEY="$(<"$SECRETS_DIR/minio-secret-key")"

if [[ ! -s "$PG_DATA/PG_VERSION" ]]; then
    log "initializing PostgreSQL"
    # PG_VERSION is written only after a successful initdb. Clearing a partial
    # directory makes an interrupted first boot recoverable on the next start.
    rm -rf "$PG_DATA"
    install -d -o postgres -g postgres -m 0700 "$PG_DATA"
    gosu postgres "$PG_BIN/initdb" \
        -D "$PG_DATA" \
        --auth-local=trust \
        --auth-host=scram-sha-256 \
        --encoding=UTF8 \
        --locale=C \
        --username=postgres
fi

log "starting PostgreSQL"
gosu postgres "$PG_BIN/postgres" \
    -D "$PG_DATA" \
    -c listen_addresses=127.0.0.1 \
    -c port=5432 \
    -c unix_socket_directories=/run/postgresql &
PG_PID=$!
PIDS+=("$PG_PID")
wait_for_process "$PG_PID" PostgreSQL \
    gosu postgres "$PG_BIN/psql" -d postgres -tAc "SELECT 1"

printf "ALTER ROLE postgres WITH PASSWORD '%s';\n" "$DB_PASSWORD" \
    | gosu postgres "$PG_BIN/psql" -d postgres -v ON_ERROR_STOP=1 >/dev/null
if [[ "$(gosu postgres "$PG_BIN/psql" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'classroomio'")" != 1 ]]; then
    log "creating ClassroomIO database"
    gosu postgres "$PG_BIN/createdb" -O postgres classroomio
fi

log "starting Redis"
gosu redis redis-server \
    --bind 127.0.0.1 \
    --port 6379 \
    --protected-mode yes \
    --dir "$REDIS_DATA" \
    --appendonly yes \
    --appendfsync everysec \
    --save 300 1 \
    --maxmemory-policy noeviction \
    --daemonize no &
REDIS_PID=$!
PIDS+=("$REDIS_PID")
wait_for_process "$REDIS_PID" Redis redis-cli -h 127.0.0.1 ping

log "starting MinIO"
gosu classroomio env \
    HOME="$TEMP/home" \
    MINIO_ROOT_USER="$MINIO_ACCESS_KEY" \
    MINIO_ROOT_PASSWORD="$MINIO_SECRET_KEY" \
    MINIO_API_CORS_ALLOW_ORIGIN="$PUBLIC_ORIGIN" \
    MINIO_BROWSER=off \
    minio server "$MINIO_DATA" \
        --address 127.0.0.1:9000 \
        --console-address 127.0.0.1:9001 &
MINIO_PID=$!
PIDS+=("$MINIO_PID")
wait_for_process "$MINIO_PID" MinIO \
    curl -fsS http://127.0.0.1:9000/minio/health/ready

log "creating object-storage buckets"
for bucket in videos documents media; do
    gosu classroomio env \
        MC_CONFIG_DIR="$MC_CONFIG" \
        MC_HOST_local="http://${MINIO_ACCESS_KEY}:${MINIO_SECRET_KEY}@127.0.0.1:9000" \
        mc mb --ignore-existing "local/$bucket" >/dev/null
done
gosu classroomio env \
    MC_CONFIG_DIR="$MC_CONFIG" \
    MC_HOST_local="http://${MINIO_ACCESS_KEY}:${MINIO_SECRET_KEY}@127.0.0.1:9000" \
    mc anonymous set download local/media >/dev/null

export NODE_ENV=production
export PUBLIC_IS_SELFHOSTED=true
export DATABASE_URL="postgresql://postgres:${DB_PASSWORD}@127.0.0.1:5432/classroomio"
export REDIS_URL=redis://127.0.0.1:6379
export BETTER_AUTH_SECRET
export PRIVATE_SERVER_KEY
export DASHBOARD_ORIGIN="$PUBLIC_ORIGIN"
export PUBLIC_SERVER_URL="$PUBLIC_ORIGIN/proxy"
export TRUSTED_ORIGINS="$PUBLIC_ORIGIN"
export PRIVATE_SERVER_URL=http://127.0.0.1:3081
export PRIVATE_APP_HOST="$APP_HOST"
export PRIVATE_APP_SUBDOMAINS="$APP_NAME"
export OBJECT_STORAGE_ENDPOINT=http://127.0.0.1:9000
export OBJECT_STORAGE_PUBLIC_ENDPOINT="$PUBLIC_ORIGIN"
export OBJECT_STORAGE_REGION=us-east-1
export OBJECT_STORAGE_ACCESS_KEY_ID="$MINIO_ACCESS_KEY"
export OBJECT_STORAGE_SECRET_ACCESS_KEY="$MINIO_SECRET_KEY"
export OBJECT_STORAGE_FORCE_PATH_STYLE=true
export OBJECT_STORAGE_BUCKET_VIDEOS=videos
export OBJECT_STORAGE_BUCKET_DOCUMENTS=documents
export OBJECT_STORAGE_BUCKET_MEDIA=media
export OBJECT_STORAGE_MEDIA_PUBLIC_BASE_URL="$PUBLIC_ORIGIN/media"
export GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
export GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"
export MEDIA_WORKER_CONCURRENCY="${MEDIA_WORKER_CONCURRENCY:-1}"
export TMPDIR="$JOBS_TEMP"

log "running database migrations"
(
    cd "$API_ROOT"
    exec gosu classroomio env HOME="$TEMP/home" pnpm --filter @cio/db db:setup
) &
MIGRATION_PID=$!
PIDS+=("$MIGRATION_PID")
if ! wait "$MIGRATION_PID"; then
    log "database migrations failed"
    exit 1
fi
unset 'PIDS[-1]'

monitor_bootstrap_completion() {
    while [[ ! -f "$BOOTSTRAP_MARKER" ]]; do
        local organization_count
        local normalized_count
        organization_count="$(
            gosu postgres "$PG_BIN/psql" -d classroomio -tAc 'SELECT count(*) FROM organization' \
                2>/dev/null || true
        )"
        normalized_count="${organization_count//[[:space:]]/}"
        if [[ "$normalized_count" =~ ^[1-9][0-9]*$ ]]; then
            touch "$BOOTSTRAP_MARKER"
            chmod 0644 "$BOOTSTRAP_MARKER"
            log "first organization created; learner authentication is now public"
            # Remain alive so cleanup can safely retain and signal this PID
            # without risking later PID reuse.
            while sleep 3600; do :; done
        fi
        sleep 2
    done
}

if [[ ! -f "$BOOTSTRAP_MARKER" ]]; then
    monitor_bootstrap_completion &
    BOOTSTRAP_MONITOR_PID=$!
    PIDS+=("$BOOTSTRAP_MONITOR_PID")
fi

log "starting API"
(
    cd "$API_ROOT"
    exec gosu classroomio env HOME="$TEMP/home" PORT=3081 node apps/api/dist/index.js
) &
API_PID=$!
PIDS+=("$API_PID")
wait_for_process "$API_PID" "ClassroomIO API" \
    curl -fsS http://127.0.0.1:3081/

log "starting jobs worker"
(
    cd "$JOBS_ROOT"
    exec gosu classroomio env HOME="$TEMP/home" node apps/jobs/dist/index.js
) &
JOBS_PID=$!
PIDS+=("$JOBS_PID")

log "starting dashboard"
(
    cd "$DASHBOARD_ROOT/apps/dashboard"
    exec gosu classroomio env HOME="$TEMP/home" PORT=3082 ORIGIN="$PUBLIC_ORIGIN" node build/index.js
) &
DASHBOARD_PID=$!
PIDS+=("$DASHBOARD_PID")
wait_for_process "$DASHBOARD_PID" "ClassroomIO dashboard" \
    curl -fsS http://127.0.0.1:3082/login

log "starting bootstrap and health sidecar"
gosu classroomio env \
    BOOTSTRAP_MARKER="$BOOTSTRAP_MARKER" \
    JOBS_PID="$JOBS_PID" \
    SIDECAR_PORT=8090 \
    node /opt/bottled-classroomio/sidecar.js &
SIDECAR_PID=$!
PIDS+=("$SIDECAR_PID")
wait_for_process "$SIDECAR_PID" "ClassroomIO sidecar" \
    curl -fsS http://127.0.0.1:8090/health

log "starting nginx at $PUBLIC_ORIGIN"
nginx -g 'daemon off;' &
NGINX_PID=$!
PIDS+=("$NGINX_PID")

set +e
wait -n "$PG_PID" "$REDIS_PID" "$MINIO_PID" "$API_PID" "$JOBS_PID" "$DASHBOARD_PID" "$SIDECAR_PID" "$NGINX_PID"
EXIT_CODE=$?
set -e

if [[ "$EXIT_CODE" == 0 ]]; then
    EXIT_CODE=1
fi
log "a required service exited with status $EXIT_CODE"
exit "$EXIT_CODE"
