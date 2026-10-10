#!/bin/bash
# pgTAP suite against the running bc-db (the MASTER: a follower is read-only). Every file is one transaction
# that rolls back. DB_CONTAINER=<name> runs it against another container.
# A file passes only if it ran its whole plan and no assertion failed.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0; total=0
for f in db/tests/*.sql; do
  out=$(docker exec -i "${DB_CONTAINER:-bc-db}" psql -X -q -tA -U postgres -d boostcontent -v ON_ERROR_STOP=1 < "$f" 2>&1)
  plan=$(echo "$out" | grep -oE '^1\.\.[0-9]+' | cut -d. -f3)
  oks=$(echo "$out" | grep -cE '^ok ')
  echo "$out" | grep -E '^(ok|not ok)' | sed "s|^|$(basename "$f"): |"
  total=$((total + oks))
  if [ -z "$plan" ] || [ "$oks" != "$plan" ] || echo "$out" | grep -qE '^not ok|ERROR'; then
    fail=1; echo "!! $(basename "$f"): $oks/${plan:-?} ok"; echo "$out" | grep -E 'ERROR|^#' | head -20
  fi
done
[ $fail = 0 ] && echo "ALL $total TESTS PASSED" || { echo "TESTS FAILED"; exit 1; }
