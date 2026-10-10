#!/bin/bash
# Is the copy alive and how far behind? Run on the replica machine. Exit 0 = healthy.
cd "$(dirname "$0")"
q() { docker exec bc-replica-db psql -U postgres -d boostcontent -tAc "$1" 2>&1; }
rec=$(q "select pg_is_in_recovery()")
st=$(q "select status from pg_stat_wal_receiver")
lag=$(q "select coalesce(round(extract(epoch from now() - pg_last_xact_replay_timestamp()))::text, 'n/a')")
echo "db:    standby=$rec  stream=${st:-DOWN}  last change replayed ${lag}s ago (idle primary = grows; pg_cron ticks keep it low)"
echo "dumps: $(ls -1 .data/dumps/*.dump 2>/dev/null | wc -l) files, newest $(ls -1t .data/dumps/*.dump 2>/dev/null | head -1 | xargs -r basename)"
echo "media: $(find .data/media -type f 2>/dev/null | wc -l) objects, $(du -sh .data/media 2>/dev/null | cut -f1); $(docker logs --tail 1 bc-replica-media 2>&1)"
[ "$rec" = t ] && [ "$st" = streaming ]
