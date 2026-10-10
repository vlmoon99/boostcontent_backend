#!/bin/bash
# The node watchdog: one master, N followers, and the next node in line takes over when the ones above it die.
#
#   deploy/node.sh run       the loop (user unit bc-node.service runs it; it is the only thing that starts the stack)
#   deploy/node.sh status    every node's role, as this node sees it
#   deploy/node.sh promote   make THIS node the master now (the old master, if alive, yields on its next tick)
#
# NODES in .env lists every node in priority order ("tailnetIP[/lanIP] ..."), the same on all nodes.
# The rules, all of them:
#   1. A node's role is what its Postgres says: read-write = master, standby = follower.
#   2. Master: run the API, the entry and the Cloudflare tunnel. Follower: stream the master's database,
#      copy its pictures every minute, run nothing public.
#   3. A follower that sees no master takes over when every node above it in NODES has been unreachable on
#      every path (database port, tailnet ping, LAN ping) for NODE_FAIL_SECS. A host that still answers pings
#      is alive, so nobody takes over from it: a crashed container is Docker's job to restart.
#   4. Two masters (a node came back, or the nodes lost sight of each other): the one promoted LAST wins
#      (Postgres timeline; a tie goes to the higher priority). The loser dumps its database to
#      .data/backups/before-reclone-*.dump, throws its copy away and re-clones as a follower.
# No voting: all nodes sit in one room on one switch. Across sites this needs a quorum (rule 3 can then
# promote on a network split), which is a different tool (Patroni).
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${NODES:?set NODES in .env}" "${REPL_PASSWORD:?set REPL_PASSWORD in .env}"
TICK=${NODE_TICK:-5}; FAIL_SECS=${NODE_FAIL_SECS:-60}
read -ra N <<<"$NODES"
ME=-1; for i in "${!N[@]}"; do [ "${N[$i]%%/*}" = "$TAILNET_IP" ] && ME=$i; done
[ "$ME" -ge 0 ] || { echo "TAILNET_IP $TAILNET_IP is not in NODES"; exit 1; }
MASTER_SVC=(auth rest rest-admin caddy cloudflared)
Q="select case when pg_is_in_recovery() then 't 0' else 'f ' || ('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::int end"

log() { echo "$(date -u +%FT%TZ) node$ME($TAILNET_IP) $*"; }
dc() { docker compose "$@"; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

# "f <timeline>" = master, "t 0" = follower, "" = no answer
local_role() { running bc-db && docker exec bc-db psql -X -U postgres -d boostcontent -tAc "$Q" 2>/dev/null; }
probe() {
  local conn="host=$1 port=5442 user=replicator dbname=boostcontent connect_timeout=3"
  if running bc-db; then docker exec -e PGPASSWORD="$REPL_PASSWORD" bc-db psql -X "$conn" -tAc "$Q" 2>/dev/null
  else docker run --rm --network host -e PGPASSWORD="$REPL_PASSWORD" --entrypoint psql bc/db:local -X "$conn" -tAc "$Q" 2>/dev/null; fi
}
pings() {      # the host itself answers on any path (NODE_NO_PING=1: a test knob, the database port alone decides)
  [ "${NODE_NO_PING:-0}" = 1 ] && return 1
  local ip; for ip in ${1//\// }; do ping -c1 -W2 "$ip" >/dev/null 2>&1 && return 0; done; return 1
}

# A container Docker itself failed to start at boot (tailnet IP missing) comes up afterwards WITHOUT its
# published ports, and neither restart nor stop/start brings them back (Docker 29.2.1, seen 2026-10-10):
# recreate it. Data lives in named volumes, so this is safe.
heal_ports() {
  local s c want
  for s in $(dc --profile master --profile follower ps --services 2>/dev/null); do
    c=$(dc --profile master --profile follower ps -q "$s"); [ -n "$c" ] || continue
    want=$(docker inspect "$c" --format '{{len .HostConfig.PortBindings}}')
    [ "$want" -gt 0 ] && [ -z "$(docker port "$c")" ] || continue
    log "$s has no published ports, recreating"
    MASTER_IP=${LAST_MASTER:-} dc up -d --no-build --no-deps --force-recreate "$s" 2>&1 | tail -2
  done
}

ensure_master() {
  local c need=0
  for c in bc-db bc-garage bc-backup bc-auth bc-rest bc-rest-admin bc-caddy bc-cloudflared; do running $c || need=1; done
  if running bc-sync; then dc stop sync >/dev/null 2>&1; fi
  [ $need = 0 ] && return
  log "master: bringing the stack up"
  dc --profile master up -d --no-build 2>&1 | grep -vE 'Running|Healthy|Waiting|Exited' | tail -8
  heal_ports
}

clone_from() {   # throw the local copy away and become a follower of node $1
  local mip=${N[$1]%%/*} ts; ts=$(date -u +%Y%m%dT%H%M%S)
  log "re-cloning from node$1 ($mip)"
  if [ -n "$(local_role)" ] && running bc-backup; then
    docker exec bc-backup sh -c "pg_dump -h db -U postgres -Fc boostcontent > /backups/before-reclone-$ts.dump" \
      && log "local database saved first: .data/backups/before-reclone-$ts.dump" || log "could not dump the local database first"
  fi
  dc stop "${MASTER_SVC[@]}" db >/dev/null 2>&1
  dc run --rm --no-deps -T -e PGPASSWORD="$REPL_PASSWORD" --entrypoint bash db -c '
    set -e
    bb() { gosu postgres pg_basebackup -h '"$mip"' -p 5442 -U replicator -D "$PGDATA" -R -X stream -S node'"$ME"' "$@"; }
    find "$PGDATA" -mindepth 1 -delete; chown postgres:postgres "$PGDATA"; chmod 700 "$PGDATA"
    bb -C 2>/dev/null || { find "$PGDATA" -mindepth 1 -delete; bb; }' 2>&1 | tail -3
  dc up -d --no-build db 2>&1 | tail -1
  LAST_MASTER=
}

ensure_follower() {   # of node $1
  local mip=${N[$1]%%/*} c stop=()
  for c in "${MASTER_SVC[@]}"; do running "bc-$c" && stop+=("$c"); done
  [ ${#stop[@]} -gt 0 ] && { log "follower: stopping ${stop[*]}"; dc stop "${stop[@]}" >/dev/null 2>&1; }
  if ! docker exec bc-db psql -X -U postgres -tAc "show primary_conninfo" 2>/dev/null | grep -q "host=$mip "; then
    clone_from "$1"; return
  fi
  if [ "${LAST_MASTER:-}" != "$mip" ] || ! running bc-sync || ! running bc-garage || ! running bc-backup; then
    log "follower of node$1 ($mip)"
    MASTER_IP=$mip dc up -d --no-build garage backup sync 2>&1 | grep -vE 'Running|Healthy' | tail -4
    LAST_MASTER=$mip; heal_ports
  fi
}

promote() {
  log "PROMOTING: this node becomes the master"
  docker exec -u postgres bc-db pg_ctl promote -w -t 60 2>&1 | tail -1
  dc restart db >/dev/null 2>&1      # same data, now with the master's command (pg_cron + pg_net)
  ensure_master
}

tick() {
  local mine i r tl best_i=-1 best_tl=-1 mytl
  mine=$(local_role)
  for i in "${!N[@]}"; do
    [ "$i" = "$ME" ] && continue
    r=$(probe "${N[$i]%%/*}"); ROLE[$i]=$r
    if [[ $r == f\ * ]]; then tl=${r#f }; if (( tl > best_tl )); then best_tl=$tl; best_i=$i; fi; fi
  done
  case "$mine" in
    f\ *)
      mytl=${mine#f }
      if (( best_i >= 0 )) && { (( best_tl > mytl )) || { (( best_tl == mytl )) && (( best_i < ME )); }; }; then
        log "two masters: node$best_i (timeline $best_tl) beats this node (timeline $mytl); yielding"
        clone_from "$best_i"
      else
        ensure_master
      fi ;;
    t\ *)
      if (( best_i >= 0 )); then DOWN_SINCE=0; WAITING=; ensure_follower "$best_i"; return; fi
      for (( i = 0; i < ME; i++ )); do          # is anyone above me still there?
        if [ -n "${ROLE[$i]:-}" ] || pings "${N[$i]}"; then
          [ "${WAITING:-}" = "$i" ] || { log "no master, but node$i is alive: it goes first"; WAITING=$i; }
          DOWN_SINCE=0; return
        fi
      done
      WAITING=
      if (( DOWN_SINCE == 0 )); then
        DOWN_SINCE=$(date +%s); log "no master and nobody above this node answers; taking over in ${FAIL_SECS}s unless one returns"
      fi
      if (( $(date +%s) - DOWN_SINCE >= FAIL_SECS )); then DOWN_SINCE=0; promote; fi ;;
    *)
      running bc-db && return                     # starting up: ask again next tick
      if dc run --rm --no-deps -T --entrypoint sh db -c 'test -s "$PGDATA/PG_VERSION"' 2>/dev/null; then
        log "database container is down, starting it"; dc up -d --no-build db 2>&1 | tail -1
      elif (( best_i >= 0 )); then clone_from "$best_i"
      elif (( ME == 0 )); then log "empty node, no master anywhere: starting as the first master"; dc --profile master up -d --no-build 2>&1 | tail -3
      fi ;;
  esac
}

case "${1:-status}" in
  run)
    for i in $(seq 120); do ip -4 addr | grep -q " ${TAILNET_IP}/" && break; sleep 5; done   # Docker starts before tailscaled
    for i in $(seq 60); do docker info >/dev/null 2>&1 && break; sleep 5; done
    log "watchdog started (priority $ME of ${#N[@]}, takeover after ${FAIL_SECS}s)"
    declare -a ROLE; DOWN_SINCE=0; LAST_MASTER=; WAITING=
    while true; do tick; sleep "$TICK"; done ;;
  promote)
    [[ "$(local_role)" == t\ * ]] || { echo "this node is not a healthy follower: $(local_role)"; exit 1; }
    promote ;;
  status)
    for i in "${!N[@]}"; do
      if [ "$i" = "$ME" ]; then r=$(local_role); else r=$(probe "${N[$i]%%/*}"); fi
      case "$r" in f\ *) d="MASTER (timeline ${r#f })";; t\ *) d=follower;; *) pings "${N[$i]}" && d="database not answering (host alive)" || d=DOWN;; esac
      echo "node$i ${N[$i]%%/*}  $d$([ "$i" = "$ME" ] && echo '   <- this node')"
    done
    if [[ "$(local_role)" == t\ * ]]; then
      docker exec bc-db psql -X -U postgres -tAc "select 'stream: ' || coalesce((select status from pg_stat_wal_receiver), 'DOWN') || ', last change replayed ' || coalesce(round(extract(epoch from now() - pg_last_xact_replay_timestamp()))::text, '?') || 's ago'"
    else
      docker exec bc-db psql -X -U postgres -tAc "select 'follower ' || client_addr || ' ' || state || ', lag ' || coalesce(replay_lag::text, '0') from pg_stat_replication" 2>/dev/null
    fi
    echo "containers: $(docker ps --format '{{.Names}}' | grep '^bc-' | sort | paste -sd' ')" ;;
  *) echo "usage: $0 run|status|promote"; exit 1 ;;
esac
