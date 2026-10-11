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

## boostcontent.io and api.vramhouse.com from the Mac (2026-10-10)

```
deploy/mac/tunnel.sh named https://boostcontent.io     # tunnel `bc-mac` of the owner's Cloudflare account
```

Both names are DNS records that point at the tunnel `bc-mac` (id 7c903b26-…), which runs on the Mac; `.env` has
`INFERENCE_PUBLIC_HOST=api.vramhouse.com` and `INFERENCE_UPSTREAMS=http://host.docker.internal:8000`. Before this
they pointed at the Sparks' tunnel, `test_ads_client` (id b76c35fe-…). **While they point here the Sparks get no
public traffic, even when they are up**, which is on purpose: two machines with two databases must not answer
for one name. To give the names back to the Sparks, on a machine with the Cloudflare login
(`~/.cloudflared/cert.pem` is boostcontent.io, `cert-vramhouse.pem` is vramhouse.com):

```
cloudflared tunnel route dns --overwrite-dns test_ads_client boostcontent.io
cloudflared --origincert ~/.cloudflared/cert-vramhouse.pem tunnel route dns --overwrite-dns test_ads_client api.vramhouse.com
deploy/mac/tunnel.sh stop
```

The Mac's database is its own: accounts and posts made here do not exist on the Sparks, and the other way round.
The inference API on the Mac has one key (this `.env`'s `INFERENCE_KEY`), not the Sparks' project keys.
Left over from the first try: a record `boostcontent.io.vramhouse.com` (harmless; delete it in the dashboard).

## Model calls: the Sparks or this Mac (2026-10-10)

```
deploy/mac/inference.sh sparks   # the backend stays on the Mac, the models run on the Sparks (tailnet)
deploy/mac/inference.sh mac      # everything on the Mac (inference_system/hosts/mac must be running)
deploy/mac/inference.sh status
```

`deploy/mac/inference.sh cloud` is `mac` with the Sparks' tuning (4 + 4 jobs, up to 3 pictures per option): use it
when the Mac's gateway sends the work to clouds (`inference_system/hosts/mac`: `LLM_PROVIDER=nearai`,
`IMAGE_PROVIDER=comfy_cloud`, `IMAGE_QUALITY`). Which cloud, which model and which picture quality are settings
of the inference system; the backend only knows one gateway address.

With `sparks` Postgres calls the first gateway of `SPARK_GATEWAYS` with `SPARK_INFERENCE_KEY` (the Sparks' project
key `boostcontent`); that gateway spreads the work over both Sparks. The Mac's storage also listens on its tailnet
address (`compose.mac.tailnet.yaml`), because the Sparks fetch the product photo and put the picture themselves.
`api.vramhouse.com` then reaches the Sparks' gateways again, with their own project keys. The tuning goes back to
the Sparks' values: 4 + 4 jobs in flight, up to 3 pictures per option.

Measured through boostcontent.io with the backend on the Mac: a round of three options about one item, 251 s with
the Mac's models, 73 s with the Sparks'. `smoke.sh` 16/16 (one post with 3 pictures in 116 s).
If the first gateway is down, generation fails until `SPARK_GATEWAYS` is reordered and the command is run again:
Postgres calls one address, there is no failover on this side.

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
