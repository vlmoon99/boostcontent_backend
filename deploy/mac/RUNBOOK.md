# Runbook: what runs where, and what to do (updated 2026-10-11 15:50 UTC)

**The Sparks are the server.** `boostcontent.io` and `api.vramhouse.com` point at the Sparks' tunnel
(`test_ads_client`). dgx-spark-2 is the master (database, storage, API), dgx-spark the follower.
**The models are not the Sparks' own:** the backend calls the cloud gateway on each Spark (`:8011`,
`inference_system/hosts/cloud`), which sends text to NEAR AI and pictures to Comfy Cloud. The Sparks' own models
still run next to it and can be used again with one command (below). The Mac runs nothing: it is a spare.

## Where the model calls go

On **each** Spark, in `boostcontent_backend`:

```
deploy/inference.sh status   # cloud or own
deploy/inference.sh own      # the Sparks' own models (free, no TEE note in the app)
deploy/inference.sh cloud    # NEAR AI and Comfy Cloud (paid, the app shows the TEE note)
```

Picture quality on the clouds is `IMAGE_QUALITY` in `~/inference_cloud/hosts/cloud/.env` on each Spark
(`low`, `medium`, `high`), applied with `docker compose up -d` in that folder. The two cloud keys are in the
same file.

## What was merged on 2026-10-11 15:40 UTC

The Mac's database (everything since the afternoon: plans, promo codes, the accounts made on it) became the
Sparks' database, and the two accounts that only the Sparks had up to date were put back into it from the
Sparks' own copy: `eb743a59…` ("Urban Winter Wardrobe" and "Sport", 29 posts) and one smoke account. Nothing
else differed. This month's usage of those two was set to zero like everyone's. The pictures made on the Mac
(20 objects) were copied into the Sparks' storage.

Kept on dgx-spark-2 in `~/bc-backups/`: `sparks-before-merge-20261011-1537.dump` (the Sparks as they were),
`mac-final-20261011-1537.dump` (the Mac as it was) and `merge.sh` (what was run). The old Sparks data is also
still a scratch database, `bc_spark_old`, on the master: drop it when nothing is missed
(`docker exec bc-db psql -U postgres -c 'drop database bc_spark_old'`).

## The Sparks lose power → the Mac takes over

The Mac's database is its copy from 2026-10-11 15:37 UTC. Anything made on the Sparks after that is not in it;
what is made on the Mac in between has to be merged back afterwards (as above), or it is lost.

1. Open **Docker Desktop**, wait until it runs.
2. In `inference_system/hosts/mac`: `./run.sh start` (its `.env` says clouds: no model runs on the Mac).
3. In `boostcontent_backend`: `deploy/mac/inference.sh cloud`
4. Point the names at the Mac and start its tunnel:
   ```
   cloudflared tunnel route dns --overwrite-dns bc-mac boostcontent.io
   cloudflared --origincert ~/.cloudflared/cert-vramhouse.pem tunnel route dns --overwrite-dns bc-mac api.vramhouse.com
   deploy/mac/tunnel.sh named https://boostcontent.io
   ```
   For a few minutes after a switch some requests still fail (Cloudflare error 1033) while the change spreads.

## After a power cut, check the follower

Three times now dgx-spark came back with `bc-db`, `bc-garage` and `inf-litellm-db` without a Docker network,
and the watchdog does not heal that (`inference_system/docs/PROGRESS.md`). `deploy/node.sh status` then says
"database not answering" on both nodes. Fix on dgx-spark:
`docker compose --profile follower up -d --no-build --no-deps --force-recreate db garage` in boostcontent_backend
and `docker compose up -d --no-build --no-deps --force-recreate litellm-db` in `inference_system/hosts/dgx-spark`.

## Plans (2026-10-11)

Every account is `free`: 12 options and 12 pictures a month, one picture per option, and every option that is
made counts. `pro` (150 / 300 / 3, $20) is shown in the app but cannot be bought yet; `team` (1000 / 3000 / 3)
is for the owner's own accounts. Change an account's plan in the console (Users → the user → "Set pro"), or
give the tester a promo code.

## Promo codes (2026-10-11)

Owner console → tab **Promo** → "Create code" (default: `pro` for 30 days, no limit of accounts). Give the code
to the tester; in the app it is entered in Settings → Plan → "Promo code". The console is at
`http://100.64.0.12:3200` from any machine on the tailnet (on the Mac, when it serves: `http://127.0.0.1:3200`);
its password is set on the first visit. Without the console, on dgx-spark-2:
`docker exec bc-db psql -U postgres -d boostcontent -c "select code from admin_api.create_promo(days => 30, max_uses => 5, note => 'testers')"`

## Every day

| I want to… | Where | Do this |
|---|---|---|
| Use the app | iPhone | Just open it. It talks to `https://boostcontent.io` |
| Check the Sparks | any machine on the tailnet | `ssh 100.64.0.12 'cd ~/boostcontent_backend && deploy/node.sh status'` → node1 MASTER, node0 follower, "streaming" |
| Run the full self-test | on dgx-spark-2 | `cd ~/boostcontent_backend && ./smoke.sh` → `16 passed` (about a minute) |

## Moving the data (what was done on 2026-10-10, for the next time)

1. Stop the entry on the source so nothing new is written (`docker stop bc-caddy bc-rest bc-auth`).
2. `pg_dump -Fc boostcontent` on the source; copy the file to the target master.
3. On the target: stop the watchdog on every node (`systemctl --user stop bc-node`), dump the current database
   as a backup, stop `bc-rest bc-rest-admin bc-auth`, `drop database boostcontent with (force)`, create it,
   `pg_restore`, then `docker compose --profile master run --rm --no-deps configure` (writes the target's own
   addresses and keys into the settings), start the three services and the watchdogs.
4. Copy the pictures with rclone between the two storages (bucket `bc-media`, each side's own S3 keys).
5. Switch the names, run `./smoke.sh` on the target.

Backups left on dgx-spark-2 in `~/boostcontent_backend/.data/backups/`: `sparks-before-mac-data.dump` (the
Sparks' database as it was before the Mac's data replaced it) and `before-0012-0014.dump`.

## New build for the iPhone

On the Mac, in `boostcontent_client`, phone connected by cable and unlocked:
`fvm flutter build ios --profile && fvm flutter install --profile -d 00008110-0019744C0AD9401E`

## In Cloudflare (dashboard), once

* `vramhouse.com` → DNS: delete the record `boostcontent.io.vramhouse.com` (a leftover, harmless).

## Not decided yet (yours to decide)

* **The watchdog bug** found on 2026-10-10 (`inference_system/docs/PROGRESS.md`): after a power cut a Spark can
  come up with network-less database containers and not heal itself.
* **A real sign-in.** Still guest only: deleting the app or changing the phone loses the account.
* **The landing page text** still says "Posts appear by themselves" and "every week".
* **The Mac's model files** (7 GB in `~/.cache/inf-mac/models`) are kept for the spare role; delete them if the
  Mac should never serve again.

## Where the secrets are

Sparks: `~/boostcontent_backend/.env` and `inference_system/hosts/<host>/.env` on each node.
Mac: `boostcontent_backend/.env` (its own database passwords and keys) and `~/.cloudflared/` (the tunnel
`bc-mac` and the two Cloudflare logins that can repoint the names). Back them up somewhere else.
