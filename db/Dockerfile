# Postgres 17 + the extensions the codeless backend needs:
#   pg_net (HTTP from SQL, compiled: not packaged in PGDG), pg_cron, pgvector, pgTAP (tests), pgcrypto (built in).
FROM postgres:17-bookworm AS build
ARG PG_NET_VERSION=v0.20.5
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git ca-certificates libcurl4-openssl-dev postgresql-server-dev-17 \
 && git clone --depth 1 --branch ${PG_NET_VERSION} https://github.com/supabase/pg_net.git /src/pg_net \
 && make -C /src/pg_net && make -C /src/pg_net install DESTDIR=/out

FROM postgres:17-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
      libcurl4 postgresql-17-cron postgresql-17-pgvector postgresql-17-pgtap \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ /
COPY init/ /docker-entrypoint-initdb.d/
COPY pg_hba.conf /etc/postgresql/pg_hba.conf
COPY entry.sh /usr/local/bin/bc-entry.sh
ENTRYPOINT ["bc-entry.sh"]
CMD ["postgres", "-c", "shared_preload_libraries=pg_cron,pg_net", "-c", "cron.database_name=boostcontent", \
     "-c", "cron.use_background_workers=on", "-c", "max_worker_processes=20", "-c", "pg_net.ttl=1 day", "-c", "pg_net.database_name=boostcontent", \
     "-c", "hba_file=/etc/postgresql/pg_hba.conf", "-c", "max_slot_wal_keep_size=8GB"]
