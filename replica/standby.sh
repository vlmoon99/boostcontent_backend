#!/bin/bash
# Entrypoint of the standby. First start (empty volume): clone the primary with pg_basebackup, which also
# creates the replication slot and writes standby.signal + primary_conninfo. Every start: run read-only and
# follow the primary. pg_cron and pg_net are NOT loaded here: the standby must not run jobs or call the
# model. After a promotion, start this data directory with the normal image command instead (README).
set -euo pipefail
D=${PGDATA:-/var/lib/postgresql/data}
if [ ! -s "$D/PG_VERSION" ]; then
  echo "standby: cloning $PRIMARY_HOST:$PRIMARY_PORT (slot $SLOT)"
  mkdir -p "$D" && chown postgres:postgres "$D" && chmod 700 "$D"
  until gosu postgres pg_isready -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -q; do echo "standby: waiting for the primary"; sleep 5; done
  bb() { gosu postgres pg_basebackup -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U replicator -D "$D" -R -X stream -S "$SLOT" "$@"; }
  # -C creates the slot; if an earlier clone already made it, clear the half-written copy and reuse the slot
  bb -C || { find "$D" -mindepth 1 -delete; bb; }
fi
exec docker-entrypoint.sh postgres -c hba_file=/etc/postgresql/pg_hba.conf -c shared_preload_libraries= \
  -c max_worker_processes=20 -c hot_standby=on -c hot_standby_feedback=on -c max_standby_streaming_delay=300s
