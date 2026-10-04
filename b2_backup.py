#!/usr/bin/env python3
"""QuizDock <-> Backblaze B2 backup helper for a Render Free deployment.

Storage layout in the private B2 bucket:
    <prefix>/latest.zip
    <prefix>/previous.zip

The archive contains the same durable data that QuizDock's documented standalone
backup captures: PostgreSQL plus /data/media and /data/store. Render environment
variables are intentionally NOT copied into the archive because B2 credentials and
other Render secrets must never be written into a backup. Render persists those
settings independently of the container filesystem.

Exit codes:
    0 = success
    2 = no backup exists yet when restoring
    3 = configuration error
    4 = backup/restore operation error
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

try:
    import boto3
    from botocore.exceptions import ClientError, EndpointConnectionError
except Exception as exc:  # pragma: no cover
    print(f"[b2] boto3 is unavailable: {exc}", file=sys.stderr)
    sys.exit(3)

DATA_DIR = Path(os.environ.get("QUIZDOCK_DATA_DIR", "/data"))
PGDATA = Path(os.environ.get("PGDATA", str(DATA_DIR / "postgres")))
MEDIA_DIR = Path(os.environ.get("MEDIA_DIR", str(DATA_DIR / "media")))
STORE_DIR = Path(os.environ.get("STORE_DIR", str(DATA_DIR / "store")))
WORK_DIR = DATA_DIR / ".b2-backup-work"
LAST_HASH_FILE = DATA_DIR / ".b2-last-upload-sha256"
PREFIX = os.environ.get("B2_PREFIX", "quizdock").strip("/")
LATEST_KEY = f"{PREFIX}/latest.zip" if PREFIX else "latest.zip"
PREVIOUS_KEY = f"{PREFIX}/previous.zip" if PREFIX else "previous.zip"


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"missing required environment variable: {name}")
    return value


def b2_client():
    endpoint = required_env("B2_ENDPOINT")
    region = os.environ.get("B2_REGION", "us-west-004").strip()
    key_id = required_env("B2_KEY_ID")
    app_key = required_env("B2_APPLICATION_KEY")
    bucket = required_env("B2_BUCKET_NAME")

    client = boto3.client(
        "s3",
        endpoint_url=endpoint,
        region_name=region,
        aws_access_key_id=key_id,
        aws_secret_access_key=app_key,
    )
    return client, bucket


def run(cmd: list[str], *, stdout=None) -> None:
    print("[b2] $", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, stdout=stdout)


def now_stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def zip_dir(source: Path, zf: zipfile.ZipFile, arcname: str) -> None:
    if not source.exists():
        return
    for path in source.rglob("*"):
        if path.is_file():
            zf.write(path, Path(arcname) / path.relative_to(source))


def make_backup_archive() -> tuple[Path, str]:
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    temp_root = Path(tempfile.mkdtemp(prefix="backup-", dir=WORK_DIR))
    archive = temp_root / f"quizdock-{now_stamp()}.zip"

    database_sql = temp_root / "database.sql"
    print("[b2] dumping PostgreSQL…", flush=True)
    with database_sql.open("wb") as fh:
        run(
            [
                "pg_dump",
                "-h",
                "127.0.0.1",
                "-U",
                "quizdock",
                "--clean",
                "--if-exists",
                "quizdock",
            ],
            stdout=fh,
        )

    # The official QuizDock backup captures media and shared templates separately
    # because they are not stored in PostgreSQL.
    metadata = {
        "format": 1,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "quizdock_flavor": os.environ.get("QUIZDOCK_FLAVOR", "standalone"),
        "app_version": os.environ.get("APP_VERSION", "unknown"),
        "database": "PostgreSQL database dump",
        "media": "/data/media",
        "store": "/data/store",
        "note": "Render environment variables are deliberately not included; configure them in Render.",
    }
    metadata_path = temp_root / "metadata.json"
    metadata_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    print("[b2] creating backup ZIP…", flush=True)
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        zf.write(database_sql, "database.sql")
        zf.write(metadata_path, "metadata.json")
        zip_dir(MEDIA_DIR, zf, "media")
        zip_dir(STORE_DIR, zf, "store")

    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    return archive, digest


def object_exists(s3, bucket: str, key: str) -> bool:
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return True
    except ClientError as exc:
        code = str(exc.response.get("Error", {}).get("Code", ""))
        if code in {"404", "NoSuchKey", "NotFound"}:
            return False
        raise


def upload_backup(force: bool = False) -> bool:
    s3, bucket = b2_client()
    archive, digest = make_backup_archive()
    try:
        previous_digest = LAST_HASH_FILE.read_text(encoding="utf-8").strip() if LAST_HASH_FILE.exists() else ""
        if not force and previous_digest == digest:
            print("[b2] backup content is unchanged; skipping upload.", flush=True)
            return False

        # Keep a second recovery point before replacing latest.
        if object_exists(s3, bucket, LATEST_KEY):
            print("[b2] moving current latest backup to previous…", flush=True)
            s3.copy_object(
                Bucket=bucket,
                Key=PREVIOUS_KEY,
                CopySource={"Bucket": bucket, "Key": LATEST_KEY},
                MetadataDirective="COPY",
            )

        print(f"[b2] uploading {archive.stat().st_size / (1024 * 1024):.2f} MiB to B2…", flush=True)
        s3.upload_file(
            str(archive),
            bucket,
            LATEST_KEY,
            ExtraArgs={"ContentType": "application/zip"},
        )
        LAST_HASH_FILE.write_text(digest, encoding="utf-8")
        print(f"[b2] uploaded {LATEST_KEY}; sha256={digest}", flush=True)
        return True
    finally:
        shutil.rmtree(archive.parent, ignore_errors=True)


def safe_extract(zf: zipfile.ZipFile, destination: Path) -> None:
    destination = destination.resolve()
    for member in zf.infolist():
        name = Path(member.filename)
        if name.is_absolute() or ".." in name.parts:
            raise RuntimeError(f"unsafe path in backup: {member.filename}")
        target = (destination / name).resolve()
        if destination not in [target, *target.parents]:
            raise RuntimeError(f"unsafe extraction target: {member.filename}")
    zf.extractall(destination)


def restore_backup() -> int:
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    s3, bucket = b2_client()
    try:
        s3.head_object(Bucket=bucket, Key=LATEST_KEY)
    except ClientError as exc:
        code = str(exc.response.get("Error", {}).get("Code", ""))
        if code in {"404", "NoSuchKey", "NotFound"}:
            print("[b2] no latest backup exists yet.", flush=True)
            return 2
        raise

    restore_root = Path(tempfile.mkdtemp(prefix="restore-", dir=WORK_DIR))
    archive = restore_root / "latest.zip"
    try:
        print("[b2] downloading latest backup…", flush=True)
        s3.download_file(bucket, LATEST_KEY, str(archive))

        with zipfile.ZipFile(archive, "r") as zf:
            names = set(zf.namelist())
            if "database.sql" not in names:
                raise RuntimeError("latest backup is missing database.sql")
            print("[b2] extracting backup…", flush=True)
            safe_extract(zf, restore_root)

        # Restore the PostgreSQL dump into the already-started empty/temporary DB.
        print("[b2] restoring PostgreSQL…", flush=True)
        with (restore_root / "database.sql").open("rb") as fh:
            subprocess.run(
                ["psql", "-q", "-h", "127.0.0.1", "-U", "quizdock", "-d", "quizdock"],
                stdin=fh,
                check=True,
            )

        # On a fresh Render filesystem these directories are normally empty, but clear
        # them so a partial filesystem cannot leave stale files mixed with the backup.
        for target in (MEDIA_DIR, STORE_DIR):
            if target.exists():
                for child in target.iterdir():
                    if child.is_dir():
                        shutil.rmtree(child)
                    else:
                        child.unlink()
            target.mkdir(parents=True, exist_ok=True)

        extracted_media = restore_root / "media"
        if extracted_media.exists():
            print("[b2] restoring media…", flush=True)
            for src in extracted_media.rglob("*"):
                rel = src.relative_to(extracted_media)
                dst = MEDIA_DIR / rel
                if src.is_dir():
                    dst.mkdir(parents=True, exist_ok=True)
                else:
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src, dst)

        extracted_store = restore_root / "store"
        if extracted_store.exists():
            print("[b2] restoring shared templates…", flush=True)
            for src in extracted_store.rglob("*"):
                rel = src.relative_to(extracted_store)
                dst = STORE_DIR / rel
                if src.is_dir():
                    dst.mkdir(parents=True, exist_ok=True)
                else:
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src, dst)

        # Remember what was restored so the first scheduled backup does not upload an
        # identical archive unnecessarily.
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        LAST_HASH_FILE.write_text(digest, encoding="utf-8")
        print("[b2] restore completed successfully.", flush=True)
        return 0
    finally:
        shutil.rmtree(restore_root, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    backup = sub.add_parser("backup")
    backup.add_argument("--force", action="store_true")
    sub.add_parser("restore")
    args = parser.parse_args()

    try:
        if args.command == "backup":
            upload_backup(force=args.force)
            return 0
        return restore_backup()
    except EndpointConnectionError as exc:
        print(f"[b2] unable to reach B2: {exc}", file=sys.stderr)
        return 4
    except ClientError as exc:
        print(f"[b2] B2 API error: {exc}", file=sys.stderr)
        return 4
    except subprocess.CalledProcessError as exc:
        print(f"[b2] command failed with exit code {exc.returncode}", file=sys.stderr)
        return 4
    except Exception as exc:
        print(f"[b2] ERROR: {exc}", file=sys.stderr)
        return 4


if __name__ == "__main__":
    sys.exit(main())
