# boostcontent_backend — working rules

Codeless backend: Postgres 17 (+pg_net, pg_cron, pgvector) + PostgREST + GoTrue + Garage, all in ONE compose file
so it can be redeployed to the cloud. Design record and migration log live in the sibling repo:
`../inference_system/docs/PLATFORM_PLAN.md` and **`../inference_system/docs/PROGRESS.md`. Read PROGRESS.md first.**

* Logic lives in SQL (`api` schema = views + functions), RLS on everything. No application server.
* Postgres never handles image bytes: it signs S3 URLs, and clients and inference move the bytes.
* Admin = a second PostgREST on `admin_api`, bound to the tailnet IP only.
* Migrations: dbmate. Tests: pgTAP. Prove against the running stack before any UI.
