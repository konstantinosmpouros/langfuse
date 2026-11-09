#!/bin/sh
# One-shot (service minio-init, MinIO image, uid 65532): idempotently prepare
# MinIO for Langfuse. Safe to re-run; the CD deploy re-runs it every time.
#   1. bucket `langfuse`, no anonymous access;
#   2. lifecycle: every object expires after 30 days (the raw ingestion events
#      under events/ hold full prompts/responses — CLAUDE.md § Retention);
#   3. least-privileged user `langfuse` with policy `langfuse-rw` (objects in
#      bucket `langfuse` only). Langfuse never gets the root credentials.
# Credentials come from /run/secrets and go into MC_HOST_local, an environment
# variable of this process only; nothing is printed.
set -eu

BUCKET=langfuse
USER=langfuse
POLICY=langfuse-rw
CONF=/etc/langfuse/minio

root_user=$(cat /run/secrets/minio_root_user)
root_pass=$(cat /run/secrets/minio_root_password)
lf_secret=$(cat /run/secrets/s3_secret_key)
MC_HOST_local="http://${root_user}:${root_pass}@minio:9000"
export MC_HOST_local
MC_CONFIG_DIR=/tmp/mc
export MC_CONFIG_DIR
unset root_user root_pass

i=0
until mc ready local >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || { echo "minio-init: MinIO not ready after 60s" >&2; exit 1; }
  sleep 2
done

mc mb --ignore-existing "local/$BUCKET"
mc anonymous set none "local/$BUCKET"
mc ilm import "local/$BUCKET" <"$CONF/lifecycle.json"
mc admin policy create local "$POLICY" "$CONF/langfuse-policy.json"
# `user add` on an existing user resets its secret: the file is the source of truth.
mc admin user add local "$USER" "$lf_secret" >/dev/null
unset lf_secret
case $(mc admin user info local "$USER") in
  *"$POLICY"*) ;;
  *) mc admin policy attach local "$POLICY" --user "$USER" ;;
esac

# Verify (the image has no grep): the expiry rule is in place.
case $(mc ilm rule ls "local/$BUCKET" --json) in
  *'"Days":30'* | *'"days":30'*) ;;
  *)
    echo "minio-init: lifecycle rule missing on $BUCKET" >&2
    exit 1
    ;;
esac
echo "minio-init: OK bucket=$BUCKET (private, 30-day expiry) user=$USER policy=$POLICY"
