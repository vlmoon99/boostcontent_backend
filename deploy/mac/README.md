# deploy/mac — the whole backend on one Mac

For when the Sparks are off, or for development: the same compose stack on Docker Desktop, with its own
empty database and storage, and inference from `inference_system/hosts/mac` on the same machine.
The Sparks use nothing from this folder; `compose.yaml`, `deploy/node.sh` and the migrations are untouched.

```
# 1. inference first (see inference_system/hosts/mac/README.md), then:
deploy/mac/up.sh                      # http://localhost:3100, this Mac only; writes .env with random secrets
BASE=http://localhost:3100 ./smoke.sh # 16/16

deploy/mac/tunnel.sh start            # a free Cloudflare address (new on every start) + up.sh for it
deploy/mac/tunnel.sh url | stop
deploy/mac/up.sh down                 # stop the containers (data stays in the docker volumes)
```

What is different from a Spark node:

* `compose.mac.yaml` replaces the port lists (there is no tailnet IP) and Caddy listens on every interface.
  cloudflared runs natively (`tunnel.sh`), because `network_mode: host` does nothing on Docker Desktop.
* No cluster: no `node.sh`, no follower, no replication, no off-site copy. One database, in a docker volume.
* **The public address is part of every picture link.** `up.sh <address>` writes it into `.env`
  (`PUBLIC_URL`, `S3_PUBLIC_ENDPOINT`); after a new tunnel address the app must be built for it and old
  picture links stop working (the rows stay; a fresh read signs new links).
* Mac-only tuning, written by `up.sh` into this Mac's own database: `llm_concurrency` 2, `image_concurrency` 2,
  and one picture per option instead of three (`MAC_IMAGES_PER_POST`), because one GPU renders a picture in
  about 50 s.
* `smoke.sh` passes, but its last clean-up line fails on macOS (`paste` without a file argument), so the
  smoke accounts stay in the database.
* Never put the `boostcontent.io` tunnel token in this `.env`: two machines would answer for one name with
  two different databases.
