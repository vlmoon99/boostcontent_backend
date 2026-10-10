# boostcontent_backend

Codeless backend for BoostContent: **Postgres is the backend.** PostgREST exposes it, GoTrue issues the
JWTs, Garage stores the pictures, Caddy is the only HTTP entry, and cloudflared publishes it. Generation
runs inside Postgres (pg_cron + pg_net → the inference gateway). One compose file; the same stack runs on the
Spark or a cloud VM.

```
cp .env.example .env            # fill it (see below)
docker compose up -d --build    # db → migrate → configure → auth, rest, rest-admin, garage, caddy, cloudflared
scripts/garage-init.sh          # first time only: layout, bucket, access key
scripts/test.sh                 # pgTAP: 38 assertions, all inside rolled-back transactions
./smoke.sh                      # the customer journey over HTTP (real LLM + images, ~2–4 min)
```

## For the app (Flutter)

Base URL `https://boostcontent.io`. Three path prefixes, nothing else:

| Prefix | What | Auth |
|---|---|---|
| `/auth/v1` | GoTrue: guest sign-in, token refresh | none |
| `/rest/v1` | PostgREST: the API below (schema `api`) | `Authorization: Bearer <access_token>` on every call |
| `/bc-media` | pictures, only through the pre-signed URLs the API hands out | the URL itself (send no `Authorization`) |

There is no anon key and no realtime: the app polls. CORS is open (`*`), so Flutter web works too.

### The calls

Views are read with `GET`; everything under `rpc/` is `POST` with a JSON body (`{}` when it takes nothing)
and `content-type: application/json`. Functions that return nothing answer `204` with an empty body.

| Step | Call | Returns |
|---|---|---|
| guest sign-in | `POST /auth/v1/signup` `{}` | `access_token` (1 h), `refresh_token`, `expires_at`, `user` |
| refresh | `POST /auth/v1/token?grant_type=refresh_token` `{"refresh_token": …}` | the same shape, with a **new** refresh token |
| me + quota | `rpc/me` | `{account_id, is_anonymous, month, limits: {posts_month, images_month, images_per_post}, used: {posts, images}}` |
| businesses | `GET /rest/v1/businesses` | `[{id, name, description, language, timezone, created_at, updated_at, profile_status}]` |
| | `rpc/create_business {name, description?, language?: en/uk/ru, timezone?}` | the business (defaults: `uk`, `Europe/Kyiv`) |
| | `rpc/update_business {id, name?, description?, language?, timezone?}` | the business |
| | `rpc/delete_business {id}` | `204` |
| photo upload | 1. `rpc/upload_url {business_id, content_type?}` | `{media_id, put_url, method: "PUT", expires_in: 900}` |
| | 2. `PUT put_url` with the raw bytes as the body | `200` |
| | 3. `rpc/photo_uploaded {media_id}` | `204`; the photo is listed only after this |
| photos | `GET /rest/v1/photos?business_id=eq.<id>` | `[{id, business_id, content_type, created_at, url}]` |
| | `rpc/delete_photo {media_id}` | `204` |
| style profile | `GET /rest/v1/profiles?business_id=eq.<id>` | `[{business_id, status, data, edited, updated_at, error}]` |
| | `rpc/analyze_business {business_id}` | `204`; poll the profile until `ready` / `failed` |
| | `rpc/update_profile {business_id, data}` | the profile (`data` is a JSON object, `edited` becomes true) |
| posts | `rpc/generate_posts {business_id, n?}` (1–10, default 3) | the `n` new posts, `status: queued`, one shared `batch_id` |
| | `GET /rest/v1/posts?batch_id=eq.<id>` (or `business_id=eq.<id>&order=created_at.desc`) | `[{id, business_id, batch_id, status, language, caption, hashtags, error, created_at, ready_at, images}]` |
| what the user did | `rpc/post_signal {post_id, kind: copied/downloaded/regenerated}` | `204` |
| | `rpc/edit_post {post_id, caption, hashtags?}` | the post |
| | `rpc/delete_post {post_id}` | `204` |

Things the app has to know:

* **The account is the device.** A guest has no email and no password: if the refresh token is lost, so is the
  account. Store both tokens in secure storage and refresh before `expires_at`.
* **Uploads**: jpeg, png, webp or heic; at most 30 photos per business and 50 businesses per account. The `PUT`
  goes straight to storage with only the bytes (no `Authorization` header, or the signature check fails), within
  15 minutes.
* **Picture URLs live 1 hour** (`photos.url`, `posts.images[].url`). Don't store them: read the row again for a
  fresh one.
* **Post status**: `queued` → `writing` → `rendering` → `ready`, `partial` (text is there, some pictures failed)
  or `failed` (`error` says why). Poll the batch every ~3 s until every post is in one of the last three; about
  a minute for a post with 3 pictures. `images` is `[{position, status, url}]`, with `url` null until that picture is `ready`.
* **Profile status**: `none` → `analyzing` → `ready` / `failed`. `generate_posts` starts the analysis by itself
  when there is no profile yet, so calling `analyze_business` first is optional.
* **Quota** is taken when `generate_posts` is called (n posts + n × `images_per_post` pictures) and what didn't
  get made is given back. The plan today: 1000 posts and 3000 pictures a month, 3 pictures per post.
  Pictures are 1024×1280 PNG.
* A row that isn't yours is simply not there: lists come back empty, they don't error.

### Errors

PostgREST's JSON: `{"code", "message", "details", "hint"}`. **Branch on `details`**, not on the HTTP status:

| `details` | HTTP | When |
|---|---|---|
| `quota_exceeded` | 400 | the month's posts or pictures are used up (`hint` has the numbers) |
| `daily_cap` | 400 | the whole service hit its daily picture cap: try later |
| `limit_businesses`, `limit_photos` | 400 | 50 businesses / 30 photos |
| `bad_content_type`, `bad_n`, `bad_signal`, `bad_profile` | 400 | wrong argument |
| `not_found` | **500** | the business / photo / post isn't yours or doesn't exist (PostgREST maps this SQL code to 500) |
| `blocked` | 403 | the owner blocked the account |
| *(null)*, `code` `42501` | 401 | no token |
| *(null)*, `code` `PGRST3xx` | 401 | token expired or malformed: refresh, then repeat the call |

### From Dart

Plain HTTP with `package:http`: no SDK is needed. This is your own PostgREST API; the only borrowed piece is the
auth server (GoTrue, open source, runs in this compose), and the app talks to it with the two calls above.

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;

const base = 'https://boostcontent.io';
String? accessToken, refreshToken;          // keep both in flutter_secure_storage

Future<void> _session(String path, Map body) async {
  final r = await http.post(Uri.parse('$base/auth/v1/$path'),
      headers: {'content-type': 'application/json'}, body: jsonEncode(body));
  final d = jsonDecode(r.body);
  accessToken = d['access_token'];
  refreshToken = d['refresh_token'];
}

Future<void> signInGuest() => _session('signup', {});
Future<void> refresh() => _session('token?grant_type=refresh_token', {'refresh_token': refreshToken});

Map<String, String> get _h => {'authorization': 'Bearer $accessToken', 'content-type': 'application/json'};

class ApiError implements Exception {
  ApiError(this.status, this.code, this.message);
  final int status;
  final String? code;                        // quota_exceeded, not_found, … (the `details` field)
  final String message;
}

dynamic _read(http.Response r) {
  if (r.statusCode < 300) return r.body.isEmpty ? null : jsonDecode(r.body);
  final e = jsonDecode(r.body);
  throw ApiError(r.statusCode, e['details'], e['message'] ?? '');
}

Future<dynamic> rpc(String fn, [Map<String, dynamic> args = const {}]) async =>
    _read(await http.post(Uri.parse('$base/rest/v1/rpc/$fn'), headers: _h, body: jsonEncode(args)));

Future<List> list(String view, [String query = '']) async =>
    _read(await http.get(Uri.parse('$base/rest/v1/$view?$query'), headers: _h));

// guest → business → photo → posts
await signInGuest();
final biz = await rpc('create_business', {'name': 'Bakery', 'language': 'uk'});
final up = await rpc('upload_url', {'business_id': biz['id'], 'content_type': 'image/jpeg'});
await http.put(Uri.parse(up['put_url']), body: bytes);          // the bytes only, no headers
await rpc('photo_uploaded', {'media_id': up['media_id']});
final posts = await rpc('generate_posts', {'business_id': biz['id'], 'n': 3});
final batch = await list('posts', 'batch_id=eq.${posts[0]['batch_id']}');   // poll every ~3 s
```

On a `401`, call `refresh()` and repeat the request once. The HTTP calls are what `./smoke.sh` runs on every
release; this Dart code itself has not been run against a real app yet.

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
Nothing in the code knows where it runs. Stages, numbers and the move step by step:
`../inference_system/docs/SCALING_AND_CLOUD.md`.
