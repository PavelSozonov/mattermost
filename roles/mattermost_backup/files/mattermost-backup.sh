#!/usr/bin/env bash
# Nightly Mattermost backup: a custom-format database dump and an archive of
# the data and config directories, uploaded to S3-compatible storage.
#
# Configuration comes from /etc/mattermost-backup.env (EnvironmentFile of the
# unit). The last successful run writes $MM_BACKUP_DIR/.last-success, which is
# what a freshness check should read.
set -Eeuo pipefail

: "${MM_BASE_DIR:?}" "${MM_BACKUP_DIR:?}" "${PG_CONTAINER:?}" "${PG_USER:?}" "${PG_DB:?}"
: "${S3_ENDPOINT:?}" "${S3_BUCKET:?}" "${S3_PREFIX:?}" "${S3_ACCESS_KEY:?}" "${S3_SECRET_KEY:?}"
KEEP_DAYS="${KEEP_DAYS:-14}"

log() { printf '%s mattermost-backup: %s\n' "$(date -u +%FT%TZ)" "$*"; }

TS="$(date -u +%Y-%m-%d_%H%M%S)"
STAGE="${MM_BACKUP_DIR}/${TS}"
umask 077
mkdir -p "${STAGE}"
trap 'rm -rf "${STAGE}"' ERR

log "dumping database ${PG_DB}"
docker exec "${PG_CONTAINER}" pg_dump -U "${PG_USER}" -d "${PG_DB}" -Fc > "${STAGE}/db.dump"
# A dump that pg_restore cannot list is not a backup.
docker exec -i "${PG_CONTAINER}" pg_restore --list < "${STAGE}/db.dump" > /dev/null

log "archiving data and config"
# Mattermost keeps running while its files are archived, so GNU tar can find a
# file changing under it. It then exits 1 ("file changed as we read it") and
# still writes the archive; under errexit that alone failed a whole night's
# backup. Exit 1 is accepted, anything higher is a real error.
tar_rc=0
tar -C "${MM_BASE_DIR}/volumes/mattermost" --warning=no-file-changed \
  -czf "${STAGE}/files.tar.gz" data config || tar_rc=$?
if (( tar_rc > 1 )); then
  log "tar failed with exit ${tar_rc}"
  rm -rf "${STAGE}"
  exit "${tar_rc}"
fi
# An archive tar cannot list is not a backup either.
tar -tzf "${STAGE}/files.tar.gz" > /dev/null

log "uploading to s3://${S3_BUCKET}/${S3_PREFIX}/${TS}/"
STAGE="${STAGE}" TS="${TS}" python3 - <<'PY'
import datetime
import hashlib
import os
import sys

import boto3
from botocore.config import Config

client = boto3.client(
    "s3",
    endpoint_url=os.environ["S3_ENDPOINT"],
    aws_access_key_id=os.environ["S3_ACCESS_KEY"],
    aws_secret_access_key=os.environ["S3_SECRET_KEY"],
    region_name=os.environ.get("S3_REGION") or None,
    config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 3}),
)
bucket = os.environ["S3_BUCKET"]
prefix = os.environ["S3_PREFIX"].strip("/") + "/"
stage = os.environ["STAGE"]

for name in ("db.dump", "files.tar.gz"):
    path = os.path.join(stage, name)
    key = f"{prefix}{os.environ['TS']}/{name}"
    sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
    client.upload_file(path, bucket, key, ExtraArgs={"Metadata": {"sha256": sha}})
    remote = client.head_object(Bucket=bucket, Key=key)["ContentLength"]
    if remote != os.path.getsize(path):
        sys.exit(f"size mismatch for {key}: local {os.path.getsize(path)}, remote {remote}")
    print(f"uploaded {key} ({remote} bytes)")

# Prune only after this night's upload is verified, and only inside the
# prefix: the bucket may hold other backups.
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(
    days=int(os.environ.get("KEEP_DAYS", "14")))
old = []
for page in client.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
    old += [o["Key"] for o in page.get("Contents", []) if o["LastModified"] < cutoff]
for i in range(0, len(old), 1000):
    client.delete_objects(Bucket=bucket, Delete={"Objects": [{"Key": k} for k in old[i:i + 1000]]})
print(f"pruned {len(old)} objects older than {cutoff:%Y-%m-%d}")
PY

# Keep only the newest local copy.
find "${MM_BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d ! -name "${TS}" -exec rm -rf {} +
date -u +%s > "${MM_BACKUP_DIR}/.last-success"
log "done"
