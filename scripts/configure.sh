#!/bin/bash
# Upsert every key=value from $S into private.settings (runs on every `docker compose up`).
set -euo pipefail
sql="begin;"
for kv in $S; do
  k=${kv%%=*}; v=${kv#*=}
  [ -z "$v" ] && continue
  v=${v//\'/\'\'}
  sql+=" insert into private.settings(key, value) values ('$k', '$v') on conflict (key) do update set value = excluded.value, updated_at = now();"
done
sql+=" commit;"
psql -h db -U postgres -d boostcontent -v ON_ERROR_STOP=1 -qc "$sql"
if [ -n "${REPL_PASSWORD:-}" ]; then      # the streaming-replication login for replica/ (idempotent)
  psql -h db -U postgres -d boostcontent -v ON_ERROR_STOP=1 -q -v pw="$REPL_PASSWORD" <<'SQL'
select format('%s role replicator login replication password %L',
              case when exists (select 1 from pg_roles where rolname = 'replicator') then 'alter' else 'create' end, :'pw') \gexec
SQL
fi
echo "settings: $(psql -h db -U postgres -d boostcontent -tAc 'select string_agg(key, $$, $$ order by key) from private.settings')"
