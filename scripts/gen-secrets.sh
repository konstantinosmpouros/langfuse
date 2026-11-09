#!/usr/bin/env bash
# Generate every secret file the Langfuse stack reads, once, into DIR.
#
#   Local:   scripts/gen-secrets.sh ./secrets admin@example.com
#   Dennis:  sudo scripts/gen-secrets.sh --dennis /opt/langfuse/secrets admin@example.com
#
# One value per file, no trailing newline, hex only (URL-safe: Prisma and the
# ClickHouse migration URL embed the passwords unescaped). An existing file is
# never overwritten — rotating a secret means deleting that file on purpose
# first (CLAUDE.md § Rotating a secret). Values are never printed.
#
# --dennis also sets each file's owner/mode to the uid of the ONE container
# user that reads it (CLAUDE.md § Secrets): root-run entrypoints (postgres,
# clickhouse) read anything; Langfuse runs as uid 1001, MinIO as 65532, Valkey
# drops to 999 before it reads its ACL file. The directory is 0711: the
# deployer can stat the files (compose needs that), not read or list them.
set -euo pipefail
umask 077
export LC_ALL=C

usage() { echo "usage: $0 [--dennis] DIR ADMIN_EMAIL" >&2; exit 2; }

dennis=0
if [ "${1:-}" = --dennis ]; then dennis=1; shift; fi
[ $# -eq 2 ] || usage
dir=$1
email=$2
[[ $email =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { echo "not an e-mail address: $email" >&2; exit 2; }
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }
if ((dennis)) && [ "$(id -u)" != 0 ]; then echo "--dennis must run as root (sudo)" >&2; exit 1; fi

hex() { openssl rand -hex "$1"; }

mkdir -p "$dir"

# write NAME VALUE — create DIR/NAME with VALUE unless it already exists.
write() {
  local f="$dir/$1"
  if [ -e "$f" ]; then
    echo "keep  $1"
  else
    printf '%s' "$2" >"$f"
    echo "new   $1"
  fi
}

write postgres_password "$(hex 24)"
write clickhouse_password "$(hex 24)"
write redis_password "$(hex 24)"
# The Valkey ACL file carries the same password as redis_password (Langfuse
# authenticates as the default user); derived from the file, so it stays in
# sync when only one of the two is regenerated.
write valkey_users.acl "user default on >$(cat "$dir/redis_password") ~* &* +@all"
write minio_root_user "lfroot$(hex 4)"
write minio_root_password "$(hex 24)"
# Secret of the least-privileged MinIO user `langfuse` (bucket `langfuse` only),
# created by the minio-init one-shot. Langfuse never sees the root credentials.
write s3_secret_key "$(hex 24)"
write salt "$(hex 32)"
write encryption_key "$(hex 32)" # 64 hex chars = 256 bit, as Langfuse requires
write nextauth_secret "$(hex 32)"
# Headless init (LANGFUSE_INIT_*): org `denis`, project `magenticx`, its API
# keys and the first (owner) user.
write init_user_email "$email"
write init_user_password "$(hex 16)"
write init_project_public_key "pk-lf-$(hex 16)"
write init_project_secret_key "sk-lf-$(hex 24)"

if ((dennis)); then
  chown root:root "$dir"
  chmod 0711 "$dir"
  # owner:group mode file...
  set_perms() {
    local og=$1 mode=$2
    shift 2
    for name in "$@"; do
      chown "$og" "$dir/$name"
      chmod "$mode" "$dir/$name"
    done
  }
  # Langfuse web + worker (uid 1001). postgres/clickhouse read these as root.
  set_perms 1001:0 0400 postgres_password clickhouse_password redis_password \
    salt encryption_key nextauth_secret \
    init_user_email init_user_password init_project_public_key init_project_secret_key
  # Langfuse (1001) and minio-init (65532, sets the user's secret in MinIO).
  set_perms 1001:65532 0440 s3_secret_key
  # MinIO server and minio-init (65532).
  set_perms 65532:65532 0400 minio_root_user minio_root_password
  # Valkey (999 after setpriv).
  set_perms 999:0 0400 valkey_users.acl
fi

echo "done: $dir"
