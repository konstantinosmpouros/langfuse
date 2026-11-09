#!/usr/bin/env bash
# CD on Dennis: deploy one commit of this repo. Installed by hand as
# /opt/deploy/langfuse.sh (root-owned, 0755) and run ONLY through the forced
# command of the gha-langfuse key in ~deployer/.ssh/authorized_keys:
#
#   command="/opt/deploy/langfuse.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty,no-user-rc ssh-ed25519 AAAA… gha-langfuse
#
# The client's requested command arrives in $SSH_ORIGINAL_COMMAND and must be a
# full 40-hex commit sha that is reachable from origin/main; anything else is
# refused. Steps: check out that sha in the repo clone → pull → up -d → wait
# for every long-running container's healthcheck → re-run the two idempotent
# one-shots (MinIO bucket/lifecycle/user, ClickHouse 30-day TTL). Exits
# non-zero on any failure (the CD job fails).
#
# Same body as mcp_gateway's and sandbox's deploy script except the "Project"
# block, the multi-container wait and the one-shots. Runbook: CLAUDE.md § CD.
set -euo pipefail
umask 022
export LC_ALL=C

# ---- Project ---------------------------------------------------------------
readonly PROJECT=langfuse
readonly REPO_DIR=/opt/langfuse/repo
readonly COMPOSE_FILE=docker-compose-denis.yaml
readonly -a CONTAINERS=(langfuse-postgres langfuse-clickhouse langfuse-valkey langfuse-minio langfuse-web langfuse-worker)
readonly -a ONE_SHOTS=(minio-init retention-init)
readonly HEALTH_TIMEOUT=420 # s; first boot runs ~450 Postgres + ClickHouse migrations
# Repo files bind-mounted into containers: compose can't see a change to a
# bind-mounted file's contents, so a change to one forces a re-create.
# (Secrets live in /opt/langfuse/secrets, outside the repo.)
readonly -a RECREATE_ON_CHANGE=(config scripts)
# ---------------------------------------------------------------------------

log() { printf '%s deploy[%s]: %s\n' "$(date -u +%FT%TZ)" "$PROJECT" "$*"; }
die() { log "FAILED: $*"; exit 1; }

# 1. The only accepted input: a full commit sha (never echoed back if invalid).
sha=${SSH_ORIGINAL_COMMAND:-}
[[ $sha =~ ^[0-9a-f]{40}$ ]] || die "refused: expected a 40-hex commit sha"

# 2. One deploy at a time per project (a second one waits).
exec 9>"/run/lock/deploy-$PROJECT.lock"
flock -w 900 9 || die "another deploy is still running"

cd "$REPO_DIR" || die "no repo clone at $REPO_DIR"

# 3. Fetch, then only commits on origin/main may be deployed.
log "fetch origin"
git fetch --quiet --prune origin || die "git fetch failed"
git cat-file -e "$sha^{commit}" 2>/dev/null || die "commit $sha not found on origin"
git merge-base --is-ancestor "$sha" origin/main || die "commit $sha is not on origin/main"

prev=$(git rev-parse --verify --quiet HEAD || true)
log "checkout $sha (was ${prev:-none})"
git checkout --quiet --detach "$sha" || die "checkout failed (local changes in $REPO_DIR?)"

recreate=()
if ((${#RECREATE_ON_CHANGE[@]})) && [ -n "$prev" ] && [ "$prev" != "$sha" ] &&
  ! git diff --quiet "$prev" "$sha" -- "${RECREATE_ON_CHANGE[@]}"; then
  log "bind-mounted config changed: re-creating"
  recreate=(--force-recreate)
fi

compose=(docker compose -p "$PROJECT" -f "$COMPOSE_FILE")

# 4. Pull, then up. `up -d` waits for depends_on health conditions itself.
log "pull"
"${compose[@]}" pull --quiet || die "pull failed"
log "up"
"${compose[@]}" up -d --remove-orphans "${recreate[@]}" || die "up failed"

# 5. Wait for Docker's healthcheck on every long-running container.
log "wait for ${CONTAINERS[*]} healthy (up to ${HEALTH_TIMEOUT}s)"
deadline=$((SECONDS + HEALTH_TIMEOUT))
for c in "${CONTAINERS[@]}"; do
  while :; do
    state=$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
      "$c" 2>/dev/null || echo missing)
    case $state in
    running/healthy) break ;;
    running/starting | restarting/*) ;;
    *) die "$c is $state (see: docker logs $c)" ;;
    esac
    ((SECONDS < deadline)) || die "$c not healthy after ${HEALTH_TIMEOUT}s ($state)"
    sleep 5
  done
done

# 6. Re-assert the one-shots: an upgrade's migrations may re-create a table
#    without its TTL; the MinIO policy/lifecycle files may have changed.
for job in "${ONE_SHOTS[@]}"; do
  log "run $job"
  "${compose[@]}" run --rm --no-deps "$job" || die "$job failed"
done

log "OK: $PROJECT healthy at $sha"
