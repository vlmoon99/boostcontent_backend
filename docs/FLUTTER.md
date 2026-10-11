# Connecting the Flutter app to the BoostContent backend

Everything the app needs, in the order you will need it. The backend is live at **`https://boostcontent.io`**.

**What is proven.** The Dart client in this document (`client/dart/lib/bc_api.dart`) was run against the live
backend on 2026-10-10 with plain Dart + dio: 37 of 37 checks passed (guest sign-in, restart with the saved
session, token refresh with two parallel calls, onboarding flag, a business without a name, photo upload and
download, a round of three options, choosing one, the download link, the fixed profile shape, the learned
memory, edit, delete, deleting the account, the error codes, no-connection handling). Re-run it any time:

```
cd client/dart && dart pub get && dart run bin/main.dart ../../scripts/fixtures/product.jpg
```

**What is not proven.** Anything that needs the Flutter SDK was written but not run: the secure-storage class
in step 2 and the widget snippets. Treat those as a starting point. Photo upload from a browser was checked
only as far as the CORS preflight (it answers correctly for `PUT` with `content-type`).

---

## 0. What changed on 2026-10-10: answers to the app's ten requests

Copy the new `bc_api.dart` from the end of this document first: every change below is already in it.

| # | Request | Answer | What the app does now |
|---|---|---|---|
| 1 | Real sign-in (Apple, Google, email) | **Not now.** Guest mode is the only sign-in | Keep today's behaviour (below). Remove nothing, add nothing |
| 1 | Delete the account | **Done:** `api.deleteAccount()` | Add "Delete account" to Settings |
| 2 | Free / Pro plans, 7-day trial | **No Pro, no trial, no payments.** One plan, `free`; its limits come from `me` | Remove the Plans screen, the trial button and the `/subscriptions/trial` mock. Show usage from `me` |
| 3 | Posts that appear by themselves, new/seen | **Not now.** Instead: every "create post" gives a few options and the user keeps one | Build the options screen (section 4). Remove the "new posts this week" badge and the automatic first batch |
| 4 | Business without a name | **Done:** `name` is optional, the analysis fills it in | Stop inventing a name; read `name` after the profile is ready |
| 5 | Time zone | **Done:** `utc_offset` in minutes is accepted | Nothing: the client sends the device's offset by itself. No plugin needed |
| 6 | Onboarding finished | **Done:** `me.onboarded_at`, `api.completeOnboarding()` | Call it on "Here's what we found → Continue"; route by `me.onboarded_at` and drop the local flag |
| 7 | Fixed profile shape | **Done:** five keys always exist with fixed types | Drop the defensive reading for those keys |
| 8 | Save a picture; uploads from the web | **Done:** every picture has `download_url`. The upload preflight already works | Wire "Download image" to `download_url` and send the `downloaded` signal |
| 9 | Language of the posts | **A separate "Post language" setting**, and **Russian is added** (`en`, `uk`, `ru`) | Add the setting (calls `updateBusiness(language:)`); add Russian to the interface languages |
| 10 | Error codes | **Done:** the full list is in section 5 | Map the codes to translated texts |

### Sign-in: guest only, on purpose

There is no email, Google or Apple sign-in, and none is planned for this version. What that means in the app:

* **Create account** = create the guest on first launch (`api.start()` does it). Never a second one while a
  session is saved.
* **Sign out** stays local: hide the session, keep the tokens. Deleting the tokens destroys the account, because
  nothing else can open it. The server has `POST /auth/v1/logout`, but for a guest it only makes the account
  unreachable, so the app must not call it.
* **Sign in** on a device without a saved session cannot find an old account. Say so honestly ("There is no
  account on this device yet") and offer to start.
* **Reinstalling or changing the phone loses the account.** Don't promise otherwise anywhere in the interface,
  and remove landing copy such as "One tap and you're in" from sign-in screens that imply an identity.
* **Delete account** is real: `api.deleteAccount()` removes the businesses, photos, posts, pictures (on every
  server) and the sign-in itself, and clears the saved tokens. Ask for confirmation first; there is no undo. The next
  `api.start()` creates a new, empty guest.

### The plan: one, free, limits from the backend

Every account is on the plan `free`: 1000 posts and 3000 pictures a month today. These numbers are for the test
period and the owner changes them in the owner console at any time, so **never hard-code them**: read `me`.

```dart
final me = await api.me();
// plan: "free"
// limits: {posts_month: 1000, images_month: 3000, images_per_post: 3}
// used:   {posts: 4, images: 9}
// left:   {posts: 996, images: 2991}        // never below zero
```

* When the limit is reached `generatePosts` fails with `quota_exceeded` (402). Show "You have used this
  month's posts. More on <first day of next month>." There is nothing to buy: no upgrade button, no paywall.
* If the owner lowers a limit below what an account already used, nothing breaks and nothing is taken away:
  `left` is 0 and the account cannot generate until the next month. Old posts stay.
* The month is a calendar month in UTC (`me.month` is its first day).

### Creating a post: options, and a backend that learns

No posts are generated in the background. A post is made when the user asks for one, and each time the backend
writes a few different options. The user keeps one. What they keep, what they pass on and how they rewrite
captions is remembered per business, and the next options are written from that memory, so they get closer to
the user's taste with every round. Section 4 has the calls.

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

### Account, usage, onboarding

```dart
final me = await api.me();
// {account_id, is_anonymous: true, plan: "free", onboarded_at: null | "2026-10-10T15:01:07Z", month: "2026-10-01",
//  limits: {posts_month: 1000, images_month: 3000, images_per_post: 3},
//  used:   {posts: 0, images: 0},
//  left:   {posts: 1000, images: 3000}}

// usage banner
Text('${me['used']['posts']} of ${me['limits']['posts_month']} posts used this month');

// routing at start
if (me['onboarded_at'] == null) showOnboarding(); else showHome();

// last step of onboarding ("Here's what we found" → Continue)
await api.completeOnboarding();      // returns the new me; calling it again changes nothing

// Settings → Delete account (after a confirmation dialog)
await api.deleteAccount();
await api.start();                   // a new, empty guest
```

### Businesses

```dart
final list = await api.businesses();
// [{id, name, description, language, timezone, created_at, updated_at, profile_status}]

// onboarding: only a description (and photos). No name, no time zone.
final biz = await api.createBusiness(
  description: 'Homemade cakes in Kyiv, pickup and delivery',   // up to 4000; the more concrete, the better the posts
  language: 'uk',                             // en | uk | ru: the language of the captions
);
// biz['name'] == null until the profile analysis has run; then it is the detected name.

await api.updateBusiness(biz['id'], name: 'Sweet Corner');      // the user's own name always wins (1..120 characters)
await api.updateBusiness(biz['id'], description: 'New text');   // only what you pass changes
await api.updateBusiness(biz['id'], language: 'ru');            // the "Post language" setting: future posts only
await api.deleteBusiness(biz['id']);
```

* **Name.** Optional. While it is `null`, show the description's first words or "My business". After the
  analysis (`profile_status == 'ready'`) read `businesses()` again: `name` is filled in, and the same value is
  in the profile as `data['business_name']`. A name the user typed is never replaced.
* **Time zone.** The client sends the device's UTC offset by itself (`DateTime.now().timeZoneOffset`), so no
  native plugin is needed. The backend stores it as a zone like `<+03:00>-03:00` and returns that in
  `timezone`; don't show this value to the user. It is only used to tell the model today's date. If the app
  ever has an IANA name, pass `timezone: 'Europe/Kyiv'` instead; an unknown name fails with `bad_timezone`.
* **Post language** (`language`) is separate from the interface language: an owner with a Ukrainian interface
  may want English posts. Onboarding sends the interface language as the first value; Settings gets a
  "Post language" choice (English, Українська, Русский) that calls `updateBusiness(language:)`. Posts already
  written keep their language.
* An account can have 50 businesses.

### Photos

```dart
final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2048, imageQuality: 88);
final bytes = await picked!.readAsBytes();
final photoId = await api.uploadPhoto(biz['id'], bytes, contentType: 'image/jpeg');

final photos = await api.photos(biz['id']);   // [{id, business_id, content_type, created_at, url, download_url}]
await api.deletePhoto(photoId);
```

`uploadPhoto` does three things: asks the backend for a one-time upload address, sends the bytes straight to
storage, then confirms. A photo appears in `photos()` only after the confirmation.

* Accepted: `image/jpeg`, `image/png`, `image/webp`, `image/heic`. **Send JPEG**: let `image_picker` resize
  and convert as above. HEIC is accepted for upload but generation from HEIC has not been tested.
* 30 photos per business.
* Product photos matter: the generated pictures are restyled versions of these photos.

### Style profile ("Here's what we found")

The backend reads the description and the photos and writes a profile of the business. `generatePosts` starts
this by itself when there is no profile yet; onboarding starts it with `analyzeBusiness`.

```dart
await api.analyzeBusiness(biz['id']);         // (re)start the analysis
final p = await api.profile(biz['id']);
// status: none → analyzing → ready | failed
// data: {
//   business_name: "Sweet Corner",            always a string, '' when unknown
//   customers:     "Families and ...",        always a string
//   tone:          "warm, playful, homely",   always a string
//   best_days:     ["friday", "saturday"],    always a list; lower-case English day names, Monday first
//   brand_colors:  ["#f4c2c2", "#5a3e36"],    always a list; 0 to 5 colors as #rrggbb in lower case
//   summary, avoid, visual_style, products: [{name, photo, description}], content_pillars: [...]   // written by the model
// }
// learned: null | {likes: [...], dislikes: [...], topics: [...], voice: "...", notes: [...]}
await api.updateProfile(biz['id'], {...p['data'], 'tone': 'warm, playful'});   // the user's corrections
```

* Poll `profile()` every ~3 s while `status == 'analyzing'` (10 to 30 s).
* The five keys listed first **always exist with exactly these types**, also after `updateProfile` (the backend
  normalises what the app sends: a list given for `tone` becomes one string, an unknown day or a malformed
  color is dropped). An empty list is possible: hide the "Brand colors" block when `brand_colors` is empty.
* `best_days` are identifiers, not display text: translate them in the app (`friday` → "П'ятниця").
* The remaining keys are written by the model: keep reading those defensively.
* `learned` is what the backend has learned from the user's choices (next section). It is in English and
  read-only. Showing it ("What we know about your taste") is optional.

### Creating a post: a round of options

```dart
// 1. the user taps "Create post"
final queued = await api.generatePosts(biz['id'], n: 3);        // 3 options (1..10)
final batchId = queued.first['batch_id'];

// 2. show them as they get ready
await for (final options in api.watchBatch(batchId)) {           // asks every 3 s, ends when all are finished
  setState(() => this.options = options);
}

// 3. the user taps "Use this one"
final post = await api.choosePost(option['id']);                 // chosen_at is set; the others get passed_at
```

A post (an option is a post):

```
{id, business_id, batch_id,
 status:   queued → writing → rendering → ready | partial | failed,
 language, caption, hashtags: ["КиївськаПекарня", ...],   // no leading '#': add it when you show them
 error,                                                   // why, when failed
 created_at, ready_at,
 images: [{position, status: queued|rendering|ready|failed, url, download_url}],   // both null until that picture is ready
 chosen_at,                                               // set when the user kept this option
 passed_at}                                               // set when the user kept another option of the batch
```

* `ready` = text and all pictures. `partial` = text is there, some pictures failed: show it. `failed` = nothing
  usable.
* An option gets 1 to 3 pictures (the model decides), 1024×1280 PNG.
* Timing measured today: about 70 s until the first option is ready and about 2 min 15 s for a round of three options with nine pictures. Show progress from `status`, and show each option as soon as it is finished.
* `choosePost` works on a `ready` or `partial` option, also while the others are still rendering: their
  unfinished pictures are stopped. Before that it fails with `not_ready` (409).
* One choice per round. A second `choosePost` in the same batch fails with `already_chosen` (409); calling it
  again on the chosen option changes nothing.
* **What a round costs.** While the options render, the account holds all of them (3 posts, up to 9 pictures).
  When the user chooses, the others are given back: the round costs **1 post and the chosen option's pictures**.
  A round the user never decides stays counted in full, so always lead the user to a choice. Refresh `me`
  after `choosePost`.
* "None of these, show me others" = call `generatePosts` again and send
  `api.postSignal(anyOptionId, 'regenerated')`. The backend remembers the angles the user passed on and does
  not repeat them.
* The user may leave the screen: generation continues on the server. Come back with `api.batch(batchId)`; a
  batch where no post has `chosen_at` is still waiting for a choice.

**Why choose at all: the backend learns.** After every choice and every caption edit the backend updates a
memory of this business's taste (visible as `profile.learned`, usually within 10 to 20 s) and writes the next
options from it: most options follow what the user likes and one tries something new. So the app should:

* always send the choice (`choosePost`) rather than only letting the user copy text from an option;
* save caption edits with `editPost` (a rewrite is the strongest signal);
* send `postSignal` for copy and download.

History and actions:

```dart
final history = await api.posts(biz['id'], limit: 20, offset: 0);   // newest first, passed options left out
final one = await api.post(postId);                                 // one post by id, or null

await api.postSignal(post['id'], 'copied');       // the user copied the caption
await api.postSignal(post['id'], 'downloaded');   // saved a picture
await api.postSignal(post['id'], 'regenerated');  // asked for other options
final edited = await api.editPost(post['id'], 'My own caption', hashtags: ['cake', 'kyiv']);
await api.deletePost(post['id']);
```

`posts()` returns chosen posts and posts of rounds that are still undecided (`chosen_at == null`); show the
second kind as "pick one" or filter them out with `chosen_at != null`. There is no "new" or "seen" state and no
weekly batch: remove the "new posts this week" badge.

### Showing and saving pictures

`photos[].url`, `posts[].images[].url` and the matching `download_url` are temporary links, **valid for 1 hour**.

* `url` shows the picture. `download_url` is the same picture answered with
  `content-disposition: attachment; filename="post-….png"`, so a browser saves it instead of opening it.
* **Web:** "Download image" opens `download_url` (`launchUrl`, or an `<a href>`): the browser saves the file.
* **Android / iOS:** fetch the bytes from `url` and save them to the gallery with a gallery plugin (for example
  `gal`); `download_url` is not needed there.
* After a successful save send `api.postSignal(post['id'], 'downloaded')`.

* Don't store them in a database or in state that outlives the screen. Read the row again for a fresh link.
* `Image.network(url)` works. With `cached_network_image`, set `cacheKey` to something stable (the photo id,
  or `'$postId-$position'`), otherwise every fresh link is a cache miss.
* Send no `Authorization` header to these links: the link itself is the permission.

## 5. Errors

Every failure is an `ApiException` with `status`, `code`, `message`, `hint`.

| `code` | HTTP | Meaning | What to show |
|---|---|---|---|
| `network` | – | no answer (offline, timeout) | "No connection", retry button |
| `quota_exceeded` | 402 | this month's posts or pictures are used up (`hint`: `posts 1000/1000, images 2991/3000`) | "This month's posts are used up", with the date the month ends. No upgrade |
| `daily_cap` | 429 | the whole service is at its daily cap | "Busy, try again later" |
| `not_found` | 404 | the business, photo or post does not exist or is not this account's | refresh the list |
| `limit_businesses` | 409 | 50 businesses | "Delete one first" |
| `limit_photos` | 409 | 30 photos in this business | "Delete one first" |
| `not_ready` | 409 | `choosePost` on an option that is not finished | keep the button disabled until `ready` / `partial` |
| `already_chosen` | 409 | `choosePost` in a round that already has a choice | reload the batch |
| `bad_timezone` | 400 | unknown zone name or an impossible offset | a bug in the app's request: log it |
| `bad_content_type` | 400 | the upload is not jpeg / png / webp / heic | "Choose a photo" |
| `bad_n` | 400 | `n` outside 1..10 | a bug: log it |
| `bad_signal` | 400 | signal other than copied / downloaded / regenerated | a bug: log it |
| `bad_profile` | 400 | `updateProfile` data is not a JSON object | a bug: log it |
| `blocked` | 403 | the account was blocked by the owner | a blocked screen |
| `not_authenticated` | 401 | no valid token (the client refreshes and repeats by itself; the app sees `session_lost` if that fails) | – |
| `session_lost` | 400/401 | the saved session is no longer valid, or the account was deleted | see below |
| null | 400 | the database refused a value (name longer than 120, description longer than 4000, unknown language) | validate the form |
| null | 5xx | the backend is having a problem | "Try again in a minute" |

This is every code the API returns. The codes are stable: branch on `code`, never on `message`. `message` is
English and meant for logs; show the app's own translated text (English, Ukrainian, Russian) for each code.

```dart
try {
  await api.generatePosts(biz['id'], n: 3);
} on ApiException catch (e) {
  switch (e.code) {
    case 'quota_exceeded': showLimitReached(e.hint);
    case 'network': showRetry();
    default: showMessage(e.message);
  }
}
```

**`session_lost`** should be rare (the storage held a token the server no longer knows, or the account was
deleted from another copy of the app). The only way forward
is a new guest: `await store.clear(); await api.signInGuest();`. That is a new, empty account, so ask the user
before doing it.

**Short outages.** The backend runs on two machines; if the main one dies the second takes over in about a
minute or two. During that time calls fail with `network` or `5xx`. Nothing special is needed: a retry button
(or one automatic retry after a few seconds) is enough, and `watchBatch` already keeps asking through such a gap.

## 6. Facts to design around

| | |
|---|---|
| Base URL | `https://boostcontent.io` |
| Sign-in | guest only, created on first launch; no email / Google / Apple sign-in in this version |
| New guests | at most 30 per hour from one IP address (matters when testing on one network) |
| Access token | 1 hour, refreshed automatically by the client |
| Plan | one plan, `free`: 1000 posts and 3000 pictures a month today; the owner can change the numbers, so read `me` |
| Payments | none: no Pro, no trial, no purchase |
| Quota is taken | when `generatePosts` is called (n options + up to 3 pictures each); what was not made is returned, and so are the options the user did not choose |
| Automatic posts | none: a post is made only when the user asks |
| Languages | posts: `en`, `uk`, `ru` per business, changeable. Interface: the app's own, with the same three |
| Lists | at most 500 rows per request: use `limit` / `offset` |
| Privacy | an account sees only its own rows; asking for someone else's returns an empty list, not an error |
| Not available | push notifications, realtime updates, password or social sign-in, moving a guest account to another device, paid plans, weekly posts, new / seen marks |

## 7. Check the backend without the app

```
curl -s https://boostcontent.io/auth/v1/signup -H 'content-type: application/json' -d '{}'      # → access_token
curl -s https://boostcontent.io/rest/v1/rpc/me -X POST -H 'content-type: application/json' \
     -H "Authorization: Bearer <access_token>" -d '{}'                                          # → plan, limits, usage, left
```

The owner console (users, posts, the plan's limits, per-user limits, failed jobs) is at `http://<master's tailnet IP>:3200`, tailnet only.

## 8. Checklist

Changes from the previous version of this document are marked **new**.

- [ ] `dio`, `flutter_secure_storage`, a picker in `pubspec.yaml`; INTERNET permission in the Android release manifest
- [ ] **new** the current `bc_api.dart` copied in (it replaces the old one; `createBusiness` no longer requires `name`)
- [ ] `api.start()` once before `runApp`, with a retry screen for a first launch without internet
- [ ] **new** routing by `me['onboarded_at']`; `completeOnboarding()` at the end of onboarding; the local flag removed
- [ ] **new** onboarding creates the business with a description only (no invented name, no `Europe/Kyiv`)
- [ ] **new** the business name is read from `businesses()` after the profile is ready
- [ ] business form validates: name ≤ 120 (optional), description ≤ 4000, language en/uk/ru
- [ ] photos are resized and sent as JPEG
- [ ] **new** profile screen reads `customers`, `tone`, `best_days`, `brand_colors`, `business_name` without type checks and translates the day names
- [ ] **new** "Create post" shows a round of options (`generatePosts` + `watchBatch`), with `partial` and `failed` handled
- [ ] **new** "Use this one" calls `choosePost`; "show me others" generates again and sends `regenerated`
- [ ] **new** the first automatic batch, the "Make 3 new posts" shortcut without a choice and the "new posts this week" badge are removed
- [ ] hashtags shown with a `#` in front
- [ ] picture links never stored; caches keyed by id
- [ ] **new** "Download image" saves the picture (`download_url` on the web, gallery save on phones) and sends `downloaded`
- [ ] `postSignal` on copy / download / regenerate; caption edits saved with `editPost`
- [ ] **new** usage banner from `me` (`used`, `limits`, `left`); the Plans screen, the Pro trial and the `/subscriptions/trial` mock are removed
- [ ] **new** `quota_exceeded` shows "limit reached until next month", not a paywall
- [ ] **new** Settings: "Post language" (en / uk / ru → `updateBusiness(language:)`) and "Delete account" (`deleteAccount()` after confirmation)
- [ ] **new** Russian added to the interface languages; every error code in section 5 has a text in all three
- [ ] **new** "Sign in" / "Sign out" keep the guest behaviour described in section 0; no screen promises an account that survives a reinstall
- [ ] `network` and `session_lost` each have a screen or message

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

  /// {account_id, is_anonymous, plan, onboarded_at, month,
  ///  limits: {posts_month, images_month, images_per_post}, used: {posts, images}, left: {posts, images}}
  Future<Map<String, dynamic>> me() async => (await rpc('me')) as Map<String, dynamic>;

  /// Records that the user finished onboarding (the first call sets `onboarded_at`, later calls keep it).
  /// Returns the new me().
  Future<Map<String, dynamic>> completeOnboarding() async =>
      (await rpc('complete_onboarding')) as Map<String, dynamic>;

  /// Deletes the account for good: businesses, photos, posts, pictures and the sign-in itself.
  /// The saved tokens are cleared; the next start() creates a new, empty guest.
  Future<void> deleteAccount() async {
    await rpc('delete_account');
    _access = _refresh = null;
    await _store.clear();
  }

  // ---------------------------------------------------------------- businesses

  Future<List<Map<String, dynamic>>> businesses() => list('businesses', {'order': 'created_at.desc'});

  /// [name] may be left out: the profile analysis then names the business (read it from businesses()
  /// or from the profile's `business_name` once the profile is ready).
  /// Time zone: pass an IANA [timezone] if you have one; otherwise the device's UTC offset is sent.
  Future<Map<String, dynamic>> createBusiness({
    String? name,
    String description = '',
    String language = 'uk', // en | uk | ru: the language of the captions
    String? timezone,
    int? utcOffset, // minutes east of UTC
  }) async =>
      (await rpc('create_business', {
        if (name != null) 'name': name,
        'description': description,
        'language': language,
        if (timezone != null) 'timezone': timezone,
        if (timezone == null) 'utc_offset': utcOffset ?? DateTime.now().timeZoneOffset.inMinutes,
      })) as Map<String, dynamic>;

  /// Only the fields you pass are changed. [language] changes the language of FUTURE posts.
  Future<Map<String, dynamic>> updateBusiness(String id,
          {String? name, String? description, String? language, String? timezone, int? utcOffset}) async =>
      (await rpc('update_business', {
        'id': id,
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (language != null) 'language': language,
        if (timezone != null) 'timezone': timezone,
        if (utcOffset != null) 'utc_offset': utcOffset,
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

  /// [{id, business_id, content_type, created_at, url, download_url}]; both links work for 1 hour.
  /// `url` shows the picture, `download_url` makes a browser save it as a file.
  Future<List<Map<String, dynamic>>> photos(String businessId) =>
      list('photos', {'business_id': 'eq.$businessId', 'order': 'created_at.desc'});

  Future<void> deletePhoto(String mediaId) => rpc('delete_photo', {'media_id': mediaId});

  // ---------------------------------------------------------------- style profile

  /// {business_id, status: none|analyzing|ready|failed, data, edited, updated_at, error, learned, learned_at}
  /// `data` always has: business_name, customers, tone (strings), best_days (lower-case English day names),
  /// brand_colors ('#rrggbb'). `learned` is what the backend has learned from the user's choices, or null.
  Future<Map<String, dynamic>> profile(String businessId) async =>
      (await list('profiles', {'business_id': 'eq.$businessId'})).first;

  Future<void> analyzeBusiness(String businessId) => rpc('analyze_business', {'business_id': businessId});

  Future<Map<String, dynamic>> updateProfile(String businessId, Map<String, dynamic> data) async =>
      (await rpc('update_profile', {'business_id': businessId, 'data': data})) as Map<String, dynamic>;

  // ---------------------------------------------------------------- posts

  /// Queues [n] OPTIONS for one post (1..10). Returns them with status `queued` and one shared `batch_id`.
  /// Show them side by side when they finish and call [choosePost] with the one the user keeps.
  /// Optional: [itemId] (a round about one market item), [about] (the owner's subject, 500 characters) and
  /// [images] (pictures per option, 1 .. `me().limits.images_per_post`; out of range is clamped). With [images]
  /// every option gets exactly that many pictures; without it the model decides, up to the plan's number.
  Future<List<Map<String, dynamic>>> generatePosts(String businessId,
          {int n = 3, String? itemId, String? about, int? images}) async =>
      ((await rpc('generate_posts', {
        'business_id': businessId,
        'n': n,
        if (itemId != null) 'item_id': itemId,
        if (about != null) 'about': about,
        if (images != null) 'images': images,
      })) as List)
          .cast<Map<String, dynamic>>();

  Future<List<Map<String, dynamic>>> batch(String batchId) =>
      list('posts', {'batch_id': 'eq.$batchId', 'order': 'created_at.asc'});

  /// The history, newest first: every post except the options the user passed on.
  /// A post with `chosen_at == null` here belongs to a round the user has not decided yet.
  Future<List<Map<String, dynamic>>> posts(String businessId, {int limit = 50, int offset = 0}) => list('posts', {
        'business_id': 'eq.$businessId',
        'passed_at': 'is.null',
        'order': 'created_at.desc',
        'limit': limit,
        'offset': offset,
      });

  /// One post by id, or null when it does not exist (or is not this account's).
  Future<Map<String, dynamic>?> post(String postId) async => (await list('posts', {'id': 'eq.$postId'})).firstOrNull;

  /// The user keeps this option (it must be `ready` or `partial`). The other options of its batch are passed
  /// and the account gets them back: a round costs one post and the chosen option's pictures.
  /// Errors: 409 `not_ready`, 409 `already_chosen` (another option of this batch was chosen before).
  Future<Map<String, dynamic>> choosePost(String postId) async =>
      (await rpc('choose_post', {'post_id': postId})) as Map<String, dynamic>;

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
