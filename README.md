# boostcontent_backend

Codeless backend for BoostContent: **Postgres is the backend.** PostgREST exposes it, GoTrue issues the
JWTs, Garage stores the pictures, Caddy is the only HTTP entry, and cloudflared publishes it. Generation
runs inside Postgres (pg_cron + pg_net → the inference gateway). One compose file; the same stack runs on the
Spark or a cloud VM.

```
cp .env.example .env            # fill it (see below)
docker compose --profile master up -d --build   # db → migrate → configure → auth, rest, rest-admin, garage, caddy, cloudflared
                                # (on a clustered node deploy/node.sh does this: see "More than one machine")
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

PostgREST's JSON: `{"code", "message", "details", "hint"}`. The HTTP status says what kind of failure it is;
`details` is the stable code to branch on.

| HTTP | `details` | When |
|---|---|---|
| 400 | `bad_content_type`, `bad_n`, `bad_signal`, `bad_profile` | wrong argument |
| 401 | `not_authenticated`, or null with `code` `42501` / `PGRST3xx` | no token, or it expired / is malformed: refresh, then repeat the call |
| 402 | `quota_exceeded` | the month's posts or pictures are used up (`hint` has the numbers) |
| 403 | `blocked` | the owner blocked the account |
| 404 | `not_found` | the business / photo / post isn't yours or doesn't exist |
| 409 | `limit_businesses`, `limit_photos` | 50 businesses / 30 photos |
| 429 | `daily_cap` | the whole service hit its daily picture cap: try later |
| 5xx | | the backend itself is broken: show "try again later" |

### From Dart (dio)

Plain HTTP: no SDK is needed. This is your own PostgREST API; the only borrowed piece is the auth server
(GoTrue, open source, runs in this compose), and the app talks to it with the two calls above.

```dart
import 'package:dio/dio.dart';

final dio = Dio(BaseOptions(baseUrl: 'https://boostcontent.io', contentType: 'application/json'));
String? accessToken, refreshToken;          // keep both in flutter_secure_storage

Future<void> _session(String path, Map body) async {
  final d = (await dio.post('/auth/v1/$path', data: body)).data;
  accessToken = d['access_token'];
  refreshToken = d['refresh_token'];
}

Future<void> signInGuest() => _session('signup', {});
Future<void> refresh() => _session('token?grant_type=refresh_token', {'refresh_token': refreshToken});

void setupAuth() => dio.interceptors.add(InterceptorsWrapper(
      onRequest: (o, h) {                    // the token goes only to the API, never to /auth or to storage
        if (o.path.startsWith('/rest/v1/') && accessToken != null) {
          o.headers['authorization'] = 'Bearer $accessToken';
        }
        h.next(o);
      },
      onError: (e, h) async {                // expired token: refresh once, repeat the call
        final o = e.requestOptions;
        if (e.response?.statusCode == 401 && o.path.startsWith('/rest/v1/') &&
            o.extra['retried'] != true && refreshToken != null) {
          try {
            await refresh();
            o.extra['retried'] = true;
            return h.resolve(await dio.fetch(o));
          } on DioException catch (again) {
            return h.next(again);
          }
        }
        h.next(e);
      },
    ));

/// The stable error code (quota_exceeded, not_found, …) of a failed call, or null.
String? apiCode(DioException e) => e.response?.data is Map ? e.response!.data['details'] as String? : null;

Future<dynamic> rpc(String fn, [Map<String, dynamic> args = const {}]) async =>
    (await dio.post('/rest/v1/rpc/$fn', data: args)).data;        // '' for the 204 answers

Future<List> list(String view, [Map<String, dynamic>? query]) async =>
    (await dio.get('/rest/v1/$view', queryParameters: query)).data as List;

// guest → business → photo → posts
setupAuth();
await signInGuest();
final biz = await rpc('create_business', {'name': 'Bakery', 'language': 'uk'});
final up = await rpc('upload_url', {'business_id': biz['id'], 'content_type': 'image/jpeg'});
await dio.put(up['put_url'], data: bytes,                          // Uint8List; the URL is absolute
    options: Options(contentType: 'image/jpeg', headers: {Headers.contentLengthHeader: bytes.length}));
await rpc('photo_uploaded', {'media_id': up['media_id']});
final posts = await rpc('generate_posts', {'business_id': biz['id'], 'n': 3});
final batch = await list('posts', {'batch_id': 'eq.${posts[0]['batch_id']}'});   // poll every ~3 s

try {
  await rpc('generate_posts', {'business_id': biz['id'], 'n': 10});
} on DioException catch (e) {
  if (e.response?.statusCode == 402) { /* apiCode(e) == 'quota_exceeded': show the paywall */ }
}
```

The HTTP calls are what `./smoke.sh` runs on every release; this Dart code itself has not been run against a
real app yet.

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
| `REPL_PASSWORD`, `NODES` | the cluster: followers stream with the first; the second is every node in priority order |
| the rest | random secrets: DB/role passwords, `JWT_SECRET` (GoTrue ⇄ PostgREST), `ADMIN_JWT_SECRET`, Garage RPC/admin |

## More than one machine: master, followers, takeover

Every node runs this same compose file with the same `.env` (only `TAILNET_IP` differs). `deploy/node.sh`,
a user systemd unit (`deploy/bc-node.service`), decides what each node is and is the only thing that starts
the stack:

| Role | Runs | |
|---|---|---|
| master | everything: read-write Postgres, the API, the entry, the Cloudflare tunnel | exactly one |
| follower | Postgres as a live standby of the master (about a second behind), its own Garage fed with the master's pictures every minute, the daily dump | all the others |

`NODES` in `.env` lists the nodes in priority order. When the master's machine stops answering on every path
(database port, tailnet ping, LAN ping) for `NODE_FAIL_SECS` (60), the next node in the list promotes its
copy, starts the API and the tunnel, and boostcontent.io is served from there: about 40 s after the decision.
A node that comes back finds a newer master, saves its own database to `.data/backups/before-reclone-*.dump`,
throws its copy away and re-clones as a follower. It does not take the master role back.

```
deploy/node.sh status     # every node's role, replication state, this node's containers
deploy/node.sh promote    # make this node the master now (planned move; the old master yields by itself)
journalctl --user -u bc-node -f
```

Adding a node: clone the repo, copy `.env` (change `TAILNET_IP`, drop `S3_INTERNAL_ENDPOINT`), add the node to
`NODES` on every node, `docker compose --profile master --profile follower build`, `docker compose up -d garage`,
`scripts/garage-init.sh`, install + start the unit. It clones itself from the master.

Proven on the two Sparks (2026-10-10): takeover in both directions with the full smoke test passing on the new
master through Cloudflare, the returning node yielding and re-cloning, pictures present on both. Limits:

* **Deliberately no voting.** All nodes sit in one room on one switch. If two live nodes ever lose sight of
  each other completely, both are masters until they meet again, and the one promoted first loses what it wrote
  meanwhile (it is dumped first, not merged). Nodes in different sites need a quorum instead (Patroni).
* **A master whose machine is alive is never replaced**, even if its database is down: Docker restarts
  containers, and `node.sh promote` on a follower is the manual override.
* **Up to a minute of pictures** can be missing after a takeover (the sync interval); changes in the database
  from the last second or so.
* **Generation needs the inference gateway** (`INFERENCE_URL`, on dgx-spark). With that machine off, the site,
  sign-in and existing posts work from the new master, and new posts wait in the queue.
* The admin console is on the master: `http://<master's tailnet IP>:3200`.
* Takeover was tested by stopping the stack and telling the follower to treat that as a dead host
  (`NODE_NO_PING=1`); a real power-off of the master has not been done yet.

## Moving to the cloud

Same compose on a VM. Or: managed Postgres (must allow pg_net + pg_cron, e.g. Supabase) + R2
(`S3_*` endpoints → R2, same SigV4), and the inference gateway on its public domain (`INFERENCE_URL`).
Nothing in the code knows where it runs. Stages, numbers and the move step by step:
`../inference_system/docs/SCALING_AND_CLOUD.md`.
