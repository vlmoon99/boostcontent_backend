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
