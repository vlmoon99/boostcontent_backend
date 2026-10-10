#!/bin/bash
# One image, two roles, and the data directory says which: `standby.signal` present = follower.
# A follower replays the master's changes read-only and must NOT run jobs or call the model, so pg_cron and
# pg_net are not loaded there. A master runs the image's normal command. deploy/node.sh switches roles by
# promoting (the signal file goes away) or re-cloning (the signal file appears), then restarting this container.
set -e
if [ -f "$PGDATA/standby.signal" ]; then
  exec docker-entrypoint.sh postgres -c hba_file=/etc/postgresql/pg_hba.conf -c shared_preload_libraries= \
    -c max_worker_processes=20 -c hot_standby=on -c hot_standby_feedback=on -c max_standby_streaming_delay=300s \
    -c max_slot_wal_keep_size=8GB
fi
exec docker-entrypoint.sh "$@"
