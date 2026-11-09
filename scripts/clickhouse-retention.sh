#!/bin/sh
# One-shot (service retention-init, ClickHouse image): put a row TTL of
# RETENTION_DAYS (default 30) on the ClickHouse tables that hold trace content.
# Idempotent; the CD deploy re-runs it after every deploy, because a Langfuse
# upgrade's ClickHouse migrations may re-create a table without our TTL.
#
# Why not Langfuse's own project retention: on self-hosted it is an Enterprise
# Edition feature (CLAUDE.md § Retention). This is the open-source equivalent,
# done in the storage we own. Postgres holds no trace content in Langfuse v4;
# the raw events in MinIO expire through the bucket lifecycle (minio-init).
set -eu

DAYS=${RETENTION_DAYS:-30}
case $DAYS in '' | *[!0-9]*) echo "retention-init: RETENTION_DAYS must be a number" >&2; exit 1 ;; esac

CLICKHOUSE_PASSWORD=$(cat /run/secrets/clickhouse_password)
export CLICKHOUSE_PASSWORD

q() { clickhouse-client --host clickhouse --user langfuse --query "$1"; }

# table:time-column — the columns Langfuse's own retention uses. events_full /
# events_core are v4's trace-content tables; the topic tables hold summaries
# derived from traces. (observations_batch_staging has its own 48 h TTL.)
for spec in traces:timestamp observations:start_time scores:timestamp \
  events_full:start_time events_core:start_time \
  topics:created_at topic_assignments:unit_start_time topic_facet_summaries:unit_start_time; do
  table=${spec%%:*}
  col=${spec#*:}
  exists=$(q "SELECT count() FROM system.tables WHERE database = currentDatabase() AND name = '$table'")
  if [ "$exists" != 1 ]; then
    echo "retention-init: table $table not found (Langfuse migrations not run yet?)" >&2
    exit 1
  fi
  q "ALTER TABLE $table MODIFY TTL toDateTime($col) + INTERVAL $DAYS DAY"
  ttl=$(q "SELECT extract(create_table_query, 'TTL [^S]*') FROM system.tables WHERE database = currentDatabase() AND name = '$table'")
  echo "retention-init: $table -> $ttl"
done
