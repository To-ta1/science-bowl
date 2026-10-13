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
role_pid=""
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
  if [ -n "$role_pid" ]; then
    kill "$role_pid" 2>/dev/null || true
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

# Optional operator-managed role grants. Kinde's OIDC roles can be represented
# as objects, while QuizDock expects an array of literal strings. This mechanism
# uses QuizDock's own qd user:set-role command after each account has signed in
# once, avoiding reliance on the provider's role-claim format.
# Set these Render environment variables only for the accounts you control:
# Preferred: use OIDC subject IDs from QuizDock > My account, because some
# providers (including some Kinde configurations) do not expose an email claim.
#   QUIZDOCK_BOOTSTRAP_ADMIN_SUBJECT=kp_...
#   QUIZDOCK_BOOTSTRAP_HOST_SUBJECTS=kp_host1...,kp_host2...
# Email-based variables remain supported as a fallback when QuizDock has email:
#   QUIZDOCK_BOOTSTRAP_ADMIN_EMAIL=you@example.com
#   QUIZDOCK_BOOTSTRAP_HOST_EMAILS=host1@example.com,host2@example.com
# The worker retries until the accounts exist (or its retry limit is reached).
start_role_bootstrap() {
  bootstrap_admin="${QUIZDOCK_BOOTSTRAP_ADMIN_SUBJECT:-${QUIZDOCK_BOOTSTRAP_ADMIN_EMAIL:-}}"
  bootstrap_hosts="${QUIZDOCK_BOOTSTRAP_HOST_SUBJECTS:-${QUIZDOCK_BOOTSTRAP_HOST_EMAILS:-}}"

  if [ -z "$bootstrap_admin" ] && [ -z "$bootstrap_hosts" ]; then
    return
  fi

  if ! command -v qd >/dev/null 2>&1; then
    echo "[render] WARNING: role bootstrap was configured, but the qd command is unavailable." >&2
    return
  fi

  (
    pending_admin="$bootstrap_admin"
    pending_hosts="$bootstrap_hosts"
    retry_seconds="${QUIZDOCK_BOOTSTRAP_ROLE_RETRY_SECONDS:-60}"
    max_attempts="${QUIZDOCK_BOOTSTRAP_ROLE_MAX_ATTEMPTS:-1440}"
    attempt=1

    # Give the app a moment to start. The user rows are created by first login.
    sleep 20
    while [ "$attempt" -le "$max_attempts" ]; do
      if ! kill -0 "$app_pid" 2>/dev/null; then
        echo "[render] QuizDock stopped; ending role-bootstrap worker."
        exit 0
      fi

      if [ -n "$pending_admin" ]; then
        if qd user:set-role "$pending_admin" host,admin; then
          echo "[render] Applied host,admin grant for configured administrator account."
          pending_admin=""
        else
          echo "[render] Administrator role grant is pending; the account may need to sign in to QuizDock once."
        fi
      fi

      if [ -n "$pending_hosts" ]; then
        next_pending_hosts=""
        saved_ifs="$IFS"
        IFS=','
        # Email addresses are expected to be comma-separated in the environment variable.
        set -- $pending_hosts
        IFS="$saved_ifs"
        for host_email in "$@"; do
          host_email="$(printf '%s' "$host_email" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
          [ -n "$host_email" ] || continue
          if qd user:set-role "$host_email" host; then
            echo "[render] Applied host grant for a configured host account."
          else
            next_pending_hosts="${next_pending_hosts}${host_email},"
          fi
        done
        pending_hosts="${next_pending_hosts%,}"
      fi

      if [ -z "$pending_admin" ] && [ -z "$pending_hosts" ]; then
        echo "[render] All configured QuizDock role grants have been applied."
        exit 0
      fi

      attempt=$((attempt + 1))
      sleep "$retry_seconds"
    done

    echo "[render] WARNING: role bootstrap reached its retry limit. Check logs and the configured account email addresses." >&2
  ) &
  role_pid=$!
}

start_role_bootstrap

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
