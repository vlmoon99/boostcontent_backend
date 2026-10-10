# Connecting the Flutter app to the BoostContent backend

Everything the app needs, in the order you will need it. The backend is live at **`https://boostcontent.io`**.

**What is proven.** The Dart client in this document (`client/dart/lib/bc_api.dart`) was run against the live
backend on 2026-10-10 with plain Dart + dio: 23 of 23 checks passed (guest sign-in, restart with the saved
session, token refresh with two parallel calls, business, photo upload and download, a generated post with
its picture, style profile, edit, delete, every error code below, no-connection handling). Re-run it any time:

```
cd client/dart && dart pub get && dart run bin/main.dart ../../scripts/fixtures/product.jpg
```

**What is not proven.** Anything that needs the Flutter SDK was written but not run: the secure-storage class
in step 2 and the widget snippets. Treat those as a starting point.

---

## 1. Add the packages

```yaml
# pubspec.yaml
dependencies:
  dio: ^5.7.0
  flutter_secure_storage: ^9.2.2
  image_picker: ^1.1.2          # or any picker that gives you bytes
```

Platform setup:

* **Android**: `android/app/src/main/AndroidManifest.xml` needs
  `<uses-permission android:name="android.permission.INTERNET"/>` (the debug manifest has it, the release one
  does not by default).
* **iOS**: nothing for the network (it is HTTPS). `image_picker` needs `NSPhotoLibraryUsageDescription` and
  `NSCameraUsageDescription` in `Info.plist`.
* **Web**: works; the backend answers CORS for any origin.

There is no API key, no SDK and no realtime socket. The app sends HTTPS requests and polls.

## 2. Copy the client and give it a place to keep the tokens

Copy `client/dart/lib/bc_api.dart` into your app (for example `lib/api/bc_api.dart`). The full file is at the
end of this document. Then add the storage for the two tokens:

```dart
// lib/api/secure_token_store.dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'bc_api.dart';

class SecureTokenStore implements TokenStore {
  static const _s = FlutterSecureStorage();

  @override
  Future<({String access, String refresh})?> read() async {
    final a = await _s.read(key: 'bc_access'), r = await _s.read(key: 'bc_refresh');
    return (a == null || r == null) ? null : (access: a, refresh: r);
  }

  @override
  Future<void> write(String access, String refresh) async {
    await _s.write(key: 'bc_access', value: access);
    await _s.write(key: 'bc_refresh', value: refresh);
  }

  @override
  Future<void> clear() async {
    await _s.delete(key: 'bc_access');
    await _s.delete(key: 'bc_refresh');
  }
}
```

> **The account is the device.** A guest has no email and no password. The refresh token in secure storage is
> the only key to the account: if the app is uninstalled or the storage is cleared, the businesses, posts and
> quota of that guest cannot be reached again. Never call `signInGuest()` while a saved session exists.

## 3. Start it once

```dart
late final BcApi api;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  api = BcApi(SecureTokenStore());
  try {
    await api.start();          // restores the saved guest, or creates one on the very first launch
  } on ApiException catch (e) {
    // first launch without internet: show a retry screen and call api.start() again
  }
  runApp(const MyApp());
}
```

After `start()` every call carries the token by itself. The access token lives 1 hour; when a call gets a
`401` the client refreshes once and repeats the call, so the app never handles tokens.

## 4. Screen by screen

### Account and quota

```dart
final me = await api.me();
// {account_id, is_anonymous: true, month: "2026-10-01",
//  limits: {posts_month: 1000, images_month: 3000, images_per_post: 3},
//  used:   {posts: 0, images: 0}}
final postsLeft = me['limits']['posts_month'] - me['used']['posts'];
```

### Businesses

```dart
final list = await api.businesses();
// [{id, name, description, language, timezone, created_at, updated_at, profile_status}]

final biz = await api.createBusiness(
  name: 'Sweet Corner',                       // 1..120 characters
  description: 'Homemade cakes in Kyiv, pickup and delivery',   // up to 4000; the more concrete, the better the posts
  language: 'uk',                             // en | uk | ru: the language of the captions
  timezone: 'Europe/Kyiv',
);
await api.updateBusiness(biz['id'], description: 'New text');   // only what you pass changes
await api.deleteBusiness(biz['id']);
```

An account can have 50 businesses.

### Photos

```dart
final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2048, imageQuality: 88);
final bytes = await picked!.readAsBytes();
final photoId = await api.uploadPhoto(biz['id'], bytes, contentType: 'image/jpeg');

final photos = await api.photos(biz['id']);   // [{id, business_id, content_type, created_at, url}]
await api.deletePhoto(photoId);
```

`uploadPhoto` does three things: asks the backend for a one-time upload address, sends the bytes straight to
storage, then confirms. A photo appears in `photos()` only after the confirmation.

* Accepted: `image/jpeg`, `image/png`, `image/webp`, `image/heic`. **Send JPEG**: let `image_picker` resize
  and convert as above. HEIC is accepted for upload but generation from HEIC has not been tested.
* 30 photos per business.
* Product photos matter: the generated pictures are restyled versions of these photos.

### Style profile (optional screen)

The backend reads the description and the photos and writes a profile of the business. `generatePosts` starts
this by itself when there is no profile yet, so this screen is optional.

```dart
await api.analyzeBusiness(biz['id']);         // (re)start the analysis
final p = await api.profile(biz['id']);
// status: none → analyzing → ready | failed
// data:   {summary, customers, tone, avoid, visual_style, best_days: [...], brand_colors: ["#rrggbb"],
//          products: [{name, photo, description}], content_pillars: [...]}
await api.updateProfile(biz['id'], {...p['data'], 'tone': 'warm, playful'});   // the user's corrections
```

Poll `profile()` every ~3 s while `status == 'analyzing'`. The keys inside `data` are written by the model, so
read them defensively (`data['tone'] ?? ''`).

### Generating posts

```dart
final queued = await api.generatePosts(biz['id'], n: 3);        // 1..10
final batchId = queued.first['batch_id'];

await for (final posts in api.watchBatch(batchId)) {             // asks every 3 s, ends when all are finished
  setState(() => this.posts = posts);
}
```

A post:

```
{id, business_id, batch_id,
 status:   queued → writing → rendering → ready | partial | failed,
 language, caption, hashtags: ["КиївськаПекарня", ...],   // no leading '#': add it when you show them
 error,                                                   // why, when failed
 created_at, ready_at,
 images: [{position, status: queued|rendering|ready|failed, url}]}   // url is null until that picture is ready
```

* `ready` = text and all pictures. `partial` = text is there, some pictures failed: show it. `failed` = nothing
  usable; the quota for it was given back.
* A post gets 1 to 3 pictures (the model decides), 1024×1280 PNG.
* Timing measured today: 40 to 65 s for one post with its pictures. Show progress from `status`.
* The user may leave the screen: generation continues on the server. Come back with
  `api.batch(batchId)` or `api.posts(biz['id'])`.

History and actions:

```dart
final history = await api.posts(biz['id'], limit: 20, offset: 0);   // newest first

await api.postSignal(post['id'], 'copied');       // the user copied the caption
await api.postSignal(post['id'], 'downloaded');   // saved a picture
await api.postSignal(post['id'], 'regenerated');  // asked for another one
final edited = await api.editPost(post['id'], 'My own caption', hashtags: ['cake', 'kyiv']);
await api.deletePost(post['id']);
```

Send the signals: they are what the model will later be trained on.

### Showing pictures

`photos[].url` and `posts[].images[].url` are temporary links, **valid for 1 hour**.

* Don't store them in a database or in state that outlives the screen. Read the row again for a fresh link.
* `Image.network(url)` works. With `cached_network_image`, set `cacheKey` to something stable (the photo id,
  or `'$postId-$position'`), otherwise every fresh link is a cache miss.
* Send no `Authorization` header to these links: the link itself is the permission.

## 5. Errors

Every failure is an `ApiException` with `status`, `code`, `message`, `hint`.

| `code` | HTTP | Meaning | What to show |
|---|---|---|---|
| `network` | – | no answer (offline, timeout) | "No connection", retry button |
| `quota_exceeded` | 402 | this month's posts or pictures are used up (`hint` has the numbers) | the limit / upgrade screen |
| `daily_cap` | 429 | the whole service is at its daily cap | "Busy, try again later" |
| `not_found` | 404 | the business, photo or post does not exist or is not this account's | refresh the list |
| `limit_businesses`, `limit_photos` | 409 | 50 businesses / 30 photos | "Delete one first" |
| `bad_content_type`, `bad_n`, `bad_signal`, `bad_profile` | 400 | a bug in the app's request | log it |
| `blocked` | 403 | the account was blocked by the owner | a blocked screen |
| `session_lost` | 400/401 | the saved session is no longer valid | see below |
| null | 400 | the database refused a value (e.g. name longer than 120, unknown language) | validate the form |
| null | 5xx | the backend is having a problem | "Try again in a minute" |

```dart
try {
  await api.generatePosts(biz['id'], n: 3);
} on ApiException catch (e) {
  switch (e.code) {
    case 'quota_exceeded': showPaywall(e.hint);
    case 'network': showRetry();
    default: showMessage(e.message);
  }
}
```

**`session_lost`** should be rare (the storage held a token the server no longer knows). The only way forward
is a new guest: `await store.clear(); await api.signInGuest();`. That is a new, empty account, so ask the user
before doing it.

**Short outages.** The backend runs on two machines; if the main one dies the second takes over in about a
minute or two. During that time calls fail with `network` or `5xx`. Nothing special is needed: a retry button
(or one automatic retry after a few seconds) is enough, and `watchBatch` already keeps asking through such a gap.

## 6. Facts to design around

| | |
|---|---|
| Base URL | `https://boostcontent.io` |
| Sign-in | guest only, created on first launch; email / Google / Apple do not exist yet |
| New guests | at most 30 per hour from one IP address (matters when testing on one network) |
| Access token | 1 hour, refreshed automatically by the client |
| Plan today | 1000 posts and 3000 pictures per account per month |
| Quota is taken | when `generatePosts` is called (n posts + up to 3 pictures each); what was not made is returned |
| Languages | `en`, `uk`, `ru` per business |
| Lists | at most 500 rows per request: use `limit` / `offset` |
| Privacy | an account sees only its own rows; asking for someone else's returns an empty list, not an error |
| Not available | push notifications, realtime updates, password or social sign-in, moving a guest account to another device |

## 7. Check the backend without the app

```
curl -s https://boostcontent.io/auth/v1/signup -H 'content-type: application/json' -d '{}'      # → access_token
curl -s https://boostcontent.io/rest/v1/rpc/me -X POST -H 'content-type: application/json' \
     -H "Authorization: Bearer <access_token>" -d '{}'                                          # → limits + usage
```

The owner console (users, posts, quotas, failed jobs) is at `http://<master's tailnet IP>:3200`, tailnet only.

## 8. Checklist

- [ ] `dio`, `flutter_secure_storage`, a picker in `pubspec.yaml`; INTERNET permission in the Android release manifest
- [ ] `bc_api.dart` and `secure_token_store.dart` copied in
- [ ] `api.start()` once before `runApp`, with a retry screen for a first launch without internet
- [ ] business form validates: name 1–120, description ≤ 4000, language en/uk/ru
- [ ] photos are resized and sent as JPEG
- [ ] generation screen driven by `watchBatch`, with `partial` and `failed` handled
- [ ] hashtags shown with a `#` in front
- [ ] picture links never stored; caches keyed by id
- [ ] `postSignal` on copy / download / regenerate
- [ ] `quota_exceeded`, `network` and `session_lost` each have a screen or message

---

## The client: `bc_api.dart`

A copy of `client/dart/lib/bc_api.dart` (that file is the one the test runs).

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Where the two tokens live between app starts. The account IS these tokens:
/// a guest who loses the refresh token loses the account.
abstract class TokenStore {
  Future<({String access, String refresh})?> read();
  Future<void> write(String access, String refresh);
  Future<void> clear();
}

/// Every failed call ends up as one of these.
/// [code] is the backend's stable code (`quota_exceeded`, `not_found`, ...);
/// `network` = no answer at all, `session_lost` = the refresh token is no longer valid.
class ApiException implements Exception {
  ApiException(this.status, this.code, this.message, [this.hint]);
  final int? status;
  final String? code;
  final String message;
  final String? hint;
  @override
  String toString() => 'ApiException($status, $code, $message)';
}

class BcApi {
  BcApi(this._store, {String baseUrl = 'https://boostcontent.io'})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          contentType: 'application/json',
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 30),
        )),
        _plain = Dio(BaseOptions(
          baseUrl: baseUrl,
          contentType: 'application/json',
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 30),
        )) {
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (o, h) {
        if (_access != null) o.headers['authorization'] = 'Bearer $_access';
        h.next(o);
      },
      onError: (e, h) async {
        // An expired access token: refresh once, then repeat the same call.
        final o = e.requestOptions;
        if (e.response?.statusCode == 401 && o.extra['retried'] != true && _refresh != null) {
          try {
            await _refreshSession();
            o.extra['retried'] = true;
            return h.resolve(await _dio.fetch(o));
          } on DioException catch (again) {
            return h.next(again);
          } on ApiException catch (lost) {
            return h.reject(DioException(requestOptions: o, error: lost));
          }
        }
        h.next(e);
      },
    ));
  }

  final TokenStore _store;
  final Dio _dio; // the API: carries the token
  final Dio _plain; // sign-in, refresh and storage uploads: never carries it
  String? _access, _refresh;
  Future<void>? _refreshing;

  // ---------------------------------------------------------------- session

  /// Call once at app start. Restores the saved guest, or creates a new one.
  Future<void> start() async {
    final saved = await _store.read();
    if (saved != null) {
      _access = saved.access;
      _refresh = saved.refresh;
    } else {
      await signInGuest();
    }
  }

  /// A NEW account. Only call when there is no saved session (or the user asked to start over).
  Future<void> signInGuest() => _session('/auth/v1/signup', const {});

  Future<void> _refreshSession() {
    // Refresh tokens are single-use: parallel 401s must share one refresh.
    return _refreshing ??= _session('/auth/v1/token?grant_type=refresh_token', {'refresh_token': _refresh})
        .whenComplete(() => _refreshing = null);
  }

  Future<void> _session(String path, Map<String, dynamic> body) async {
    try {
      final d = (await _plain.post(path, data: body)).data as Map;
      _access = d['access_token'] as String;
      _refresh = d['refresh_token'] as String;
      await _store.write(_access!, _refresh!);
    } on DioException catch (e) {
      final s = e.response?.statusCode;
      if (s != null && s >= 400 && s < 500 && s != 429 && path.contains('grant_type=refresh_token')) {
        throw ApiException(s, 'session_lost', 'the saved session is no longer valid');
      }
      throw _wrap(e);
    }
  }

  // ---------------------------------------------------------------- plumbing

  ApiException _wrap(DioException e) {
    if (e.error is ApiException) return e.error as ApiException;
    final r = e.response;
    if (r == null) return ApiException(null, 'network', e.message ?? 'no connection');
    final d = r.data;
    if (d is Map) {
      return ApiException(r.statusCode, d['details'] as String?, (d['message'] ?? d['msg'] ?? '').toString(),
          d['hint'] as String?);
    }
    return ApiException(r.statusCode, null, 'HTTP ${r.statusCode}');
  }

  Future<T> _try<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// A function of the API. Returns the decoded JSON, or null for the ones that answer 204.
  Future<dynamic> rpc(String fn, [Map<String, dynamic> args = const {}]) => _try(() async {
        final r = await _dio.post('/rest/v1/rpc/$fn', data: args);
        return r.data == '' ? null : r.data;
      });

  /// Rows of a view. [query] is PostgREST's filter syntax, e.g. {'business_id': 'eq.<uuid>'}.
  Future<List<Map<String, dynamic>>> list(String view, [Map<String, dynamic>? query]) => _try(() async {
        final r = await _dio.get('/rest/v1/$view', queryParameters: query);
        return (r.data as List).cast<Map<String, dynamic>>();
      });

  // ---------------------------------------------------------------- account

  /// {account_id, is_anonymous, month, limits: {posts_month, images_month, images_per_post}, used: {posts, images}}
  Future<Map<String, dynamic>> me() async => (await rpc('me')) as Map<String, dynamic>;

  // ---------------------------------------------------------------- businesses

  Future<List<Map<String, dynamic>>> businesses() => list('businesses', {'order': 'created_at.desc'});

  Future<Map<String, dynamic>> createBusiness({
    required String name,
    String description = '',
    String language = 'uk', // en | uk | ru
    String timezone = 'Europe/Kyiv',
  }) async =>
      (await rpc('create_business',
          {'name': name, 'description': description, 'language': language, 'timezone': timezone})) as Map<String, dynamic>;

  /// Only the fields you pass are changed.
  Future<Map<String, dynamic>> updateBusiness(String id,
          {String? name, String? description, String? language, String? timezone}) async =>
      (await rpc('update_business', {
        'id': id,
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (language != null) 'language': language,
        if (timezone != null) 'timezone': timezone,
      })) as Map<String, dynamic>;

  Future<void> deleteBusiness(String id) => rpc('delete_business', {'id': id});

  // ---------------------------------------------------------------- photos

  /// The three steps of an upload. [contentType]: image/jpeg, image/png, image/webp or image/heic.
  /// Returns the photo's id.
  Future<String> uploadPhoto(String businessId, Uint8List bytes, {String contentType = 'image/jpeg'}) async {
    final up = (await rpc('upload_url', {'business_id': businessId, 'content_type': contentType})) as Map;
    await _try(() => _plain.put(
          up['put_url'] as String, // absolute, pre-signed, valid 15 minutes
          data: Stream.fromIterable([bytes]),
          options: Options(
            contentType: contentType,
            headers: {Headers.contentLengthHeader: bytes.length},
            sendTimeout: const Duration(minutes: 2),
          ),
        ));
    await rpc('photo_uploaded', {'media_id': up['media_id']});
    return up['media_id'] as String;
  }

  /// [{id, business_id, content_type, created_at, url}]; `url` works for 1 hour.
  Future<List<Map<String, dynamic>>> photos(String businessId) =>
      list('photos', {'business_id': 'eq.$businessId', 'order': 'created_at.desc'});

  Future<void> deletePhoto(String mediaId) => rpc('delete_photo', {'media_id': mediaId});

  // ---------------------------------------------------------------- style profile

  /// {business_id, status: none|analyzing|ready|failed, data, edited, updated_at, error}
  Future<Map<String, dynamic>> profile(String businessId) async =>
      (await list('profiles', {'business_id': 'eq.$businessId'})).first;

  Future<void> analyzeBusiness(String businessId) => rpc('analyze_business', {'business_id': businessId});

  Future<Map<String, dynamic>> updateProfile(String businessId, Map<String, dynamic> data) async =>
      (await rpc('update_profile', {'business_id': businessId, 'data': data})) as Map<String, dynamic>;

  // ---------------------------------------------------------------- posts

  /// Queues [n] posts (1..10). Returns them with status `queued` and one shared `batch_id`.
  Future<List<Map<String, dynamic>>> generatePosts(String businessId, {int n = 3}) async =>
      ((await rpc('generate_posts', {'business_id': businessId, 'n': n})) as List).cast<Map<String, dynamic>>();

  Future<List<Map<String, dynamic>>> batch(String batchId) =>
      list('posts', {'batch_id': 'eq.$batchId', 'order': 'created_at.asc'});

  Future<List<Map<String, dynamic>>> posts(String businessId, {int limit = 50, int offset = 0}) => list('posts',
      {'business_id': 'eq.$businessId', 'order': 'created_at.desc', 'limit': limit, 'offset': offset});

  static bool isFinished(Map<String, dynamic> post) =>
      const {'ready', 'partial', 'failed'}.contains(post['status']);

  /// Emits the batch every [every] until all its posts are ready / partial / failed.
  /// A network blip is skipped, not fatal: the next tick asks again.
  Stream<List<Map<String, dynamic>>> watchBatch(String batchId,
      {Duration every = const Duration(seconds: 3), Duration giveUpAfter = const Duration(minutes: 10)}) async* {
    final deadline = DateTime.now().add(giveUpAfter);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final rows = await batch(batchId);
        yield rows;
        if (rows.isNotEmpty && rows.every(isFinished)) return;
      } on ApiException catch (e) {
        if (e.code != 'network' && (e.status ?? 0) < 500) rethrow;
      }
      await Future<void>.delayed(every);
    }
  }

  /// kind: copied | downloaded | regenerated
  Future<void> postSignal(String postId, String kind) => rpc('post_signal', {'post_id': postId, 'kind': kind});

  Future<Map<String, dynamic>> editPost(String postId, String caption, {List<String>? hashtags}) async =>
      (await rpc('edit_post', {'post_id': postId, 'caption': caption, if (hashtags != null) 'hashtags': hashtags}))
          as Map<String, dynamic>;

  Future<void> deletePost(String postId) => rpc('delete_post', {'post_id': postId});

  // for tests: pretend the access token expired
  void debugBreakAccessToken() => _access = 'broken.token.value';
}
```
