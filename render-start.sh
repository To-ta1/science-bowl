#!/bin/sh
# QuizDock standalone entrypoint adapted for Render Free + Backblaze B2.
# Upstream data model/startup order is preserved:
#   PostgreSQL -> optional restore -> Redis -> Prisma migrations -> QuizDock.
# The upstream standalone image is the base image, so the application itself
# remains the official QuizDock release.
set -eu

PGDATA="${PGDATA:-/data/postgres}"
MEDIA_DIR="${MEDIA_DIR:-/data/media}"
STORE_DIR="${STORE_DIR:-/data/store}"
BACKUP_SCRIPT="/usr/local/bin/b2_backup.py"

# Debian puts server tools under /usr/lib/postgresql/<ver>/bin.
PGBIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"
export PATH="$PGBIN:$PATH"

mkdir -p "$PGDATA" "$MEDIA_DIR" "$STORE_DIR"

fresh_data=0
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  fresh_data=1
  echo "[render] no existing PostgreSQL cluster found; this is a fresh Render filesystem."
  echo "[render] initializing PostgreSQL…"
  initdb -D "$PGDATA" -U quizdock --auth-local=trust --auth-host=trust --encoding=UTF8 >/dev/null
  echo "listen_addresses='localhost'" >>"$PGDATA/postgresql.conf"
fi

echo "[render] starting PostgreSQL…"
pg_ctl -D "$PGDATA" -w -t 60 \
  -o "-c listen_addresses=localhost -c port=5432 -c unix_socket_directories=/tmp" start

if ! psql -h 127.0.0.1 -U quizdock -d postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname='quizdock'" | grep -q 1; then
  echo "[render] creating database 'quizdock'…"
  createdb -h 127.0.0.1 -U quizdock quizdock
fi

# On a brand-new Render instance, restore the most recent cloud backup before
# Prisma migrations and before starting the application. If B2 has no backup yet,
# continue with an empty QuizDock. If B2 is configured but inaccessible, fail rather
# than silently starting a blank instance.
if [ "$fresh_data" = "1" ] && [ "${RESTORE_ON_START:-true}" != "false" ]; then
  echo "[render] checking Backblaze B2 for a QuizDock backup…"
  if python3 "$BACKUP_SCRIPT" restore; then
    echo "[render] cloud restore completed."
  else
    rc=$?
    if [ "$rc" = "2" ]; then
      echo "[render] no cloud backup exists yet; starting a new QuizDock instance."
    else
      echo "[render] cloud restore failed; refusing to start with an untrusted empty database." >&2
      exit "$rc"
    fi
  fi
fi

echo "[render] starting Redis…"
redis-server --bind 127.0.0.1 --port 6379 --save '' --appendonly no >/tmp/redis.log 2>&1 &
REDIS_PID=$!

# The official standalone image runs Prisma migrations at startup.
echo "[render] applying QuizDock migrations…"
(cd /app && node node_modules/prisma/build/index.js migrate deploy)

shutdown_started=0
backup_pid=""
app_pid=""

shutdown() {
  if [ "$shutdown_started" = "1" ]; then
    return
  fi
  shutdown_started=1
  echo "[render] shutdown requested; attempting final cloud backup…"

  # Stop accepting new game traffic first.
  if [ -n "$app_pid" ]; then
    kill "$app_pid" 2>/dev/null || true
  fi

  # There is no persistent live-game state in standalone Redis, so it can stop now.
  kill "$REDIS_PID" 2>/dev/null || true

  # The database must remain running while pg_dump executes.
  python3 "$BACKUP_SCRIPT" backup --force || \
    echo "[render] WARNING: final backup failed; the periodic backup remains the primary safeguard." >&2

  pg_ctl -D "$PGDATA" -m fast -w stop 2>/dev/null || true

  if [ -n "$backup_pid" ]; then
    kill "$backup_pid" 2>/dev/null || true
  fi
  exit 0
}
trap shutdown TERM INT

# Periodic backup process. A backup is only uploaded when the generated archive
# differs from the last successful upload, which avoids needless B2 traffic when idle.
(
  interval="${B2_BACKUP_INTERVAL_SECONDS:-600}"
  initial_delay="${B2_BACKUP_INITIAL_DELAY_SECONDS:-30}"

  sleep "$initial_delay"
  while :; do
    python3 "$BACKUP_SCRIPT" backup || \
      echo "[render] WARNING: periodic backup failed; will retry after the interval." >&2
    sleep "$interval"
  done
) &
backup_pid=$!

# Optional one-shot startup backup. This is useful after you explicitly set
# FORCE_BACKUP_ON_START=true in Render and redeploy.
if [ "${FORCE_BACKUP_ON_START:-false}" = "true" ]; then
  echo "[render] FORCE_BACKUP_ON_START=true; creating a cloud backup now…"
  python3 "$BACKUP_SCRIPT" backup --force || \
    echo "[render] WARNING: forced startup backup failed." >&2
fi

echo "[render] starting QuizDock on :${PORT:-10000} …"
cd /app
node dist/main.js &
app_pid=$!

wait "$app_pid"
status=$?

# If the app exits on its own rather than via SIGTERM, still try to save state.
if [ "$shutdown_started" = "0" ]; then
  echo "[render] QuizDock exited with status $status; attempting a final backup…" >&2
  kill "$REDIS_PID" 2>/dev/null || true
  python3 "$BACKUP_SCRIPT" backup --force || true
  pg_ctl -D "$PGDATA" -m fast -w stop 2>/dev/null || true
fi

exit "$status"
