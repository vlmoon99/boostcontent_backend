# Runbook: what runs where, and what to do (updated 2026-10-11 13:50 UTC)

**The Sparks are off and the Mac is the server.** `boostcontent.io` and `api.vramhouse.com` point at the Mac's
tunnel `bc-mac`. The Mac runs the database, the pictures' storage and the API in Docker Desktop; the models do
not run on the Mac: captions are written on NEAR AI Cloud (in a TEE) and pictures are drawn on Comfy Cloud.
Both keys are in `inference_system/hosts/mac/.env` (`NEARAI_API_KEY`, `COMFY_API_KEY`), with
`LLM_PROVIDER`, `IMAGE_PROVIDER` and `IMAGE_QUALITY=low` (cheapest pictures; `medium`, `high`).

**The two databases have diverged.** The Mac's database is its copy from 2026-10-10 21:25 UTC plus everything
made since 2026-10-11 13:40 UTC. The Sparks' database has what was made on them between those two moments.
When the Sparks return, one of the two has to be chosen as the truth (see "Moving the data"); nothing merges
them automatically. Until that is decided, **do not give the names back to the Sparks**, and do not start a
second tunnel for them.

A phone that last used the Sparks is signed out by the Mac (its sign-in is not in the Mac's copy) and starts
as a new account. `deploy/mac/adopt.sh` gives such a new account an older account's data.

To start the Mac after a restart: open Docker Desktop, then
`( cd ../inference_system/hosts/mac && ./run.sh start )`, `deploy/mac/inference.sh cloud`,
`deploy/mac/tunnel.sh named https://boostcontent.io`. The Mac must stay awake and online.

## Plans (2026-10-11)

New accounts are `free`: 12 options and 12 pictures a month, one picture per option, and every option that is
made counts. The owner's own accounts on the Mac are on `team` (1000 / 3000 / 3), set by hand:
`docker exec bc-db psql -U postgres -d boostcontent -c "update private.accounts set plan='team' where id='<id>'"`
(`deploy/mac/adopt.sh list` shows the ids). A phone that signs up again is `free` until that is run for it.

## Promo codes (2026-10-11)

Owner console → tab **Promo** → "Create code" (default: `pro` for 30 days, no limit of accounts). Give the code
to the tester; in the app it is entered in Settings → Plan → "Promo code". The console is at
`http://127.0.0.1:3200` on the machine that serves (on the Sparks: the master's tailnet address, port 3200);
its password is set on the first visit. Without the console:
`docker exec bc-db psql -U postgres -d boostcontent -c "select code from admin_api.create_promo(days => 30, max_uses => 5, note => 'testers')"`

## Every day

| I want to… | Where | Do this |
|---|---|---|
| Use the app | iPhone | Just open it. It talks to `https://boostcontent.io` |
| Check the Sparks | any machine on the tailnet | `ssh 100.64.0.12 'cd ~/boostcontent_backend && deploy/node.sh status'` → node1 MASTER, node0 follower, "streaming" |
| Run the full self-test | on dgx-spark-2 | `cd ~/boostcontent_backend && ./smoke.sh` → `16 passed` (about a minute) |

## The Sparks lost power → the Mac takes over (slower, and with OLD data)

The Mac's database is a copy from 2026-10-10 21:25 UTC. Anything made on the Sparks after that is not in it.
Use this only to keep the app working; when the Sparks return, what was made on the Mac in between has to be
moved back the same way (see "Moving the data" below), or it is lost.

1. Open **Docker Desktop**, wait until it runs.
2. In `inference_system/hosts/mac`: `./run.sh start` (the models its `.env` names: the Mac's own, or the clouds)
3. In `boostcontent_backend`: `deploy/mac/inference.sh mac` (`cloud` when the models are in the clouds)
4. Point the names at the Mac and start its tunnel:
   ```
   cloudflared tunnel route dns --overwrite-dns bc-mac boostcontent.io
   cloudflared --origincert ~/.cloudflared/cert-vramhouse.pem tunnel route dns --overwrite-dns bc-mac api.vramhouse.com
   deploy/mac/tunnel.sh named https://boostcontent.io
   ```

## The Sparks are back → give them the names again

```
cloudflared tunnel route dns --overwrite-dns test_ads_client boostcontent.io
cloudflared --origincert ~/.cloudflared/cert-vramhouse.pem tunnel route dns --overwrite-dns test_ads_client api.vramhouse.com
deploy/mac/tunnel.sh stop && deploy/mac/up.sh down
( cd ../inference_system/hosts/mac && ./run.sh stop )
```

Never let both tunnels serve at once: two machines with two databases must not answer for one name.

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
