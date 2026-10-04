# QuizDock on Render Free with Backblaze B2 persistence

This repository wraps the official `fchaussin/quizdock:standalone` image with a small backup/restore layer for Render Free.

## What it does

- Runs official QuizDock standalone.
- On a fresh Render filesystem, downloads `quizdock/latest.zip` from a private Backblaze B2 bucket before QuizDock migrations start.
- The backup contains PostgreSQL, `/data/media`, and `/data/store`, matching the durable parts of QuizDock's documented backup.
- Every `B2_BACKUP_INTERVAL_SECONDS` (default 600 seconds), creates a new backup and uploads it only when the SHA-256 changes.
- Keeps two cloud copies: `latest.zip` and `previous.zip`.
- On SIGTERM, attempts one final backup before PostgreSQL is stopped.
- Does not place Render or B2 secrets into the backup.

## Files

- `Dockerfile` - builds on QuizDock's official standalone image and adds Python/boto3.
- `render-start.sh` - starts PostgreSQL, restores B2 on a fresh filesystem, starts Redis/migrations/QuizDock, and runs the backup loop.
- `b2_backup.py` - creates/restores the backup and talks directly to Backblaze B2 using its S3-compatible API.

## Backblaze setup

1. Create a Backblaze B2 account. The first 10 GB are free and no billing method is required to get started.
2. Create a private bucket, e.g. `my-quizdock-backups`.
3. Create an application key restricted to that bucket with list/read/write/delete access. If B2 asks for `listAllBucketNames` for S3 SDK compatibility, enable it; the key remains bucket-restricted for object access.
4. Copy the bucket's S3 endpoint, e.g. `https://s3.us-west-004.backblazeb2.com`.

## Render setup

Create a Docker web service from this repository on the Free plan.

Set these environment variables:

```text
PORT=10000
APP_PUBLIC_URL=https://YOUR-SERVICE.onrender.com
AUTH_MODE=none
ALLOW_ANONYMOUS_PARTICIPANTS=true
ADMIN_WEB_SCOPE=read

B2_ENDPOINT=https://s3.us-west-004.backblazeb2.com
B2_REGION=us-west-004
B2_BUCKET_NAME=YOUR_BUCKET_NAME
B2_KEY_ID=YOUR_B2_KEY_ID
B2_APPLICATION_KEY=YOUR_B2_APPLICATION_KEY
B2_PREFIX=quizdock

RESTORE_ON_START=true
B2_BACKUP_INITIAL_DELAY_SECONDS=30
B2_BACKUP_INTERVAL_SECONDS=600
FORCE_BACKUP_ON_START=false
```

Set Render's health check path to:

```text
/health/ready
```

Do not add a persistent disk: Render Free does not provide one, and this design intentionally uses B2 for persistence.

## First startup

If B2 has no `latest.zip`, QuizDock starts as a new empty instance. After you create your first quiz and/or run a game, the periodic backup creates `latest.zip` in B2.

If B2 already has a backup and Render starts with an empty `/data`, the startup script downloads and restores the latest backup before applying QuizDock migrations.

## Manual backup

Locally (or in a shell inside an equivalent container) you can run:

```bash
python3 /usr/local/bin/b2_backup.py backup --force
```

On Render Free there is no normal shell/one-off job workflow. For a forced Render-side startup backup, temporarily set:

```text
FORCE_BACKUP_ON_START=true
```

and redeploy. The script restores first if the filesystem is fresh, then immediately uploads a forced backup.

## Important Render behavior

Render Free services can spin down after 15 minutes without inbound HTTP/WebSocket traffic, and local filesystem changes are lost on restart/redeploy/spindown. That is why B2 is the persistence layer.

The shutdown backup is only a best-effort final copy. The periodic upload is the real safeguard against unexpected termination.

## Security note

`AUTH_MODE=none` is QuizDock local mode. It is intended for trusted networks. If your Render URL is public, anyone who can reach the host interface may be able to use the host seat. Do not expose QuizDock publicly until you are comfortable with its host/authentication configuration.
