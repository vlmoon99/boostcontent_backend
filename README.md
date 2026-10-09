# boostcontent_backend

Codeless backend for BoostContent: **Postgres is the backend.** PostgREST exposes it, GoTrue issues the
JWTs, Garage stores the pictures, Caddy is the only HTTP entry, and cloudflared publishes it. Generation
runs inside Postgres (pg_cron + pg_net → the inference gateway). One compose file; the same stack runs on the
Spark or a cloud VM.

```
cp .env.example .env            # fill it (see below)
docker compose up -d --build    # db → migrate → configure → auth, rest, rest-admin, garage, caddy, cloudflared
scripts/garage-init.sh          # first time only: layout, bucket, access key
scripts/test.sh                 # pgTAP: 36 assertions, all inside rolled-back transactions
./smoke.sh                      # the customer journey over HTTP (real LLM + images, ~2–4 min)
```

## For the app (Flutter)

Base URL `https://boostcontent.io`. Supabase client libraries work as-is (`supabase_flutter` with
`url = https://boostcontent.io`, `anonKey` = any JWT-shaped string; we don't use the anon key).

| Step | Call |
|---|---|
| guest sign-in | `POST /auth/v1/signup` `{}` → `access_token`, `refresh_token` (keep both on the device) |
| refresh | `POST /auth/v1/token?grant_type=refresh_token` `{"refresh_token": …}` |
| me + quota | `POST /rest/v1/rpc/me` |
| businesses | `GET /rest/v1/businesses` · `POST /rest/v1/rpc/create_business {name, description, language: en/uk/ru, timezone}` · `rpc/update_business` · `rpc/delete_business` |
| photo upload | `rpc/upload_url {business_id, content_type}` → `PUT put_url` with the bytes → `rpc/photo_uploaded {media_id}` |
| photos | `GET /rest/v1/photos?business_id=eq.…` (each has a 1-hour `url`) |
| style profile | `GET /rest/v1/profiles?business_id=eq.…` · `rpc/analyze_business` · `rpc/update_profile {business_id, data}` |
| posts | `rpc/generate_posts {business_id, n}` → poll `GET /rest/v1/posts?batch_id=eq.…` until `ready` / `partial` / `failed` |
| what the user did | `rpc/post_signal {post_id, kind: copied/downloaded/regenerated}` · `rpc/edit_post {post_id, caption, hashtags}` · `rpc/delete_post` |

Errors: HTTP 4xx with PostgREST's JSON; `details` holds a stable code (`quota_exceeded`, `not_found`,
`daily_cap`, `not_authenticated`, `blocked`, `bad_content_type`, `limit_photos`, …).

## How generation works

`generate_posts` reserves quota (posts + 3 images each) and queues jobs. Every 3 s `private.tick()`:

1. **profile**: the vision LLM reads the description + photos (pre-signed URLs) and writes a structured
   English style profile (customers, tone, best days, brand colors, products, pillars).
2. **ideas**: one LLM call per batch writes n posts in structured English (angle, product, photo,
   caption_en, hashtags, 1–3 image prompts).
3. **localize**: caption + hashtags into uk/ru (skipped for en).
4. **image**: Qwen-Edit restyles the chosen product photo; the inference box GETs the photo and PUTs the
   PNG with pre-signed URLs. Postgres never handles image bytes.

Failures retry with backoff (3 attempts); what didn't happen is refunded. Every model call is a row in
`private.gen_trace`; user actions are rows in `private.signals`, and `admin_api.training_export()` joins them
into fine-tuning data.

## Admin

`http://100.64.0.1:3200` (tailnet only). The first visit sets the password. Users, their businesses, photos,
posts, quotas (per-user override), plans, failed jobs. Backed by a second PostgREST on schema `admin_api`.

## .env

| Key | What |
|---|---|
| `CLOUDFLARE_TUNNEL_TOKEN` | the named tunnel (its public hostname → `http://localhost:3100`) |
| `TAILNET_IP` | where the admin (:3200) and Garage (:3900, for the inference boxes) listen |
| `INFERENCE_URL`, `INFERENCE_KEY` | the inference gateway + BoostContent's project key |
| `S3_PUBLIC_ENDPOINT` / `S3_INTERNAL_ENDPOINT` | what apps use (`https://boostcontent.io`) / what inference uses (`http://100.64.0.1:3900`) |
| `S3_ACCESS_KEY` (`GK` + 24 hex), `S3_SECRET_KEY` (64 hex) | imported into Garage by `garage-init.sh` |
| the rest | random secrets: DB/role passwords, `JWT_SECRET` (GoTrue ⇄ PostgREST), `ADMIN_JWT_SECRET`, Garage RPC/admin |

## Moving to the cloud

Same compose on a VM. Or: managed Postgres (must allow pg_net + pg_cron, e.g. Supabase) + R2
(`S3_*` endpoints → R2, same SigV4), and the inference gateway on its public domain (`INFERENCE_URL`).
Nothing in the code knows where it runs.
