#!/bin/sh
# Entrypoint shim for langfuse-web / langfuse-worker: Langfuse reads secrets
# only from environment variables, so for every FOO_FILE=/run/secrets/<name>
# this exports FOO=<file contents> (trailing newline stripped), unsets FOO_FILE
# and execs the image's own entrypoint ("$@").
#
# Why: secrets then live only in this process tree's environment — never in
# `docker inspect`, the compose file, `docker compose config`, or the repo.
# Only paths under /run/secrets/ are accepted; a missing or unreadable file is
# fatal (fail closed, never start with an empty secret). Values are never
# printed.
set -eu

for var in $(env | sed -n 's/^\([A-Z0-9_]*\)_FILE=.*$/\1/p'); do
  file=$(printenv "${var}_FILE")
  case $file in
    /run/secrets/*) ;;
    *)
      echo "secrets-env: ${var}_FILE must point under /run/secrets/" >&2
      exit 1
      ;;
  esac
  if [ ! -r "$file" ]; then
    echo "secrets-env: ${var}_FILE ($file) is missing or unreadable" >&2
    exit 1
  fi
  value=$(cat "$file")
  if [ -z "$value" ]; then
    echo "secrets-env: ${var}_FILE ($file) is empty" >&2
    exit 1
  fi
  export "$var=$value"
  unset "${var}_FILE"
done
unset var file value

exec "$@"
