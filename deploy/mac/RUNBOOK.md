# Runbook: what runs where, and what to do (2026-10-10)

The short version: **the Mac is the server, the Sparks are the muscles.** The website name, the database,
your items, posts and pictures are on the Mac. Writing captions and drawing pictures happens on the two Sparks.

## Every day

| I want to… | Where | Do this |
|---|---|---|
| Use the app | iPhone | Just open it. It talks to `https://boostcontent.io` |
| Check everything is up | Mac, in `boostcontent_backend` | `docker ps` shows 7 `bc-` containers; `deploy/mac/inference.sh status`; `curl https://boostcontent.io` answers `BoostContent` |
| Run the full self-test | Mac, in `boostcontent_backend` | `BASE=https://boostcontent.io ./smoke.sh` → `16 passed` (about 2 minutes) |

## After the Mac restarts (nothing starts by itself)

1. Open **Docker Desktop** and wait until it says it is running.
2. In `boostcontent_backend`: `deploy/mac/tunnel.sh named https://boostcontent.io`
   (starts the containers and the Cloudflare tunnel for both names).
3. Only if the Sparks are off: see the next section.

The Mac must stay awake, on power and online. If it sleeps, the site is down.

## The Sparks are off (power cut) → run the models on the Mac

Slower (about 4 minutes per round, one picture per option) but it works.

1. In `inference_system/hosts/mac`: `./run.sh start` (loads the Mac's models, about a minute)
2. In `boostcontent_backend`: `deploy/mac/inference.sh mac`

## The Sparks are back → use them again

About 70 seconds per round, up to three pictures per option.

1. In `boostcontent_backend`: `deploy/mac/inference.sh sparks`
   (it refuses and changes nothing if the Sparks' gateway does not answer)
2. In `inference_system/hosts/mac`: `./run.sh stop` (frees the Mac's memory)

If dgx-spark-2 (`100.64.0.12`) is down but dgx-spark (`100.64.0.1`) is up: in `.env` put `100.64.0.1` first in
`SPARK_GATEWAYS`, then run `deploy/mac/inference.sh sparks` again.

## New build for the iPhone

On the Mac, in `boostcontent_client`, with the phone connected by cable and unlocked:
`fvm flutter build ios --profile && fvm flutter install --profile -d 00008110-0019744C0AD9401E`

## On the Sparks

Paste the text from `inference_system/docs/SPARK_HANDOFF.md` (section "Do this on the Sparks") to whoever
works there, or follow it yourself. In short: pull both repos, fix the database of dgx-spark that does not
answer, apply the three new migrations, and do not touch the public names.

## In Cloudflare (dashboard), once

* `vramhouse.com` → DNS: delete the record `boostcontent.io.vramhouse.com` (a leftover, harmless).
* Nothing else. `boostcontent.io` and `api.vramhouse.com` point at the tunnel `bc-mac`; that is intended.

## Not decided yet (yours to decide)

* **Moving everything back to the Sparks.** Then the Mac can be switched off, but today's accounts, items and
  posts live only in the Mac's database and would have to be copied over first. Until then: Mac = server.
* **A real sign-in.** Still guest only: deleting the app or changing the phone loses the account.
* **The landing page text** still says "Posts appear by themselves" and "every week".

## Where the secrets are

`boostcontent_backend/.env` on the Mac (not in git): database passwords, the Mac's own inference key
(`MAC_INFERENCE_KEY`) and the Sparks' project key (`SPARK_INFERENCE_KEY`). `~/.cloudflared/` holds the tunnel
credentials and the two Cloudflare logins. Back these up somewhere that is not this Mac.
