import 'dart:io';

import 'package:bc_client/bc_api.dart';

class MemoryStore implements TokenStore {
  ({String access, String refresh})? t;
  int writes = 0;
  @override
  Future<({String access, String refresh})?> read() async => t;
  @override
  Future<void> write(String a, String r) async {
    t = (access: a, refresh: r);
    writes++;
  }
  @override
  Future<void> clear() async => t = null;
}

int pass = 0, fail = 0;
void check(String what, bool ok, [Object? detail]) {
  ok ? pass++ : fail++;
  print('  ${ok ? 'PASS' : 'FAIL'}  $what${detail == null ? '' : ': $detail'}');
}

Future<String?> codeOf(Future<void> Function() f) async {
  try {
    await f();
    return null;
  } on ApiException catch (e) {
    return '${e.status} ${e.code}';
  }
}

Future<void> main(List<String> args) async {
  final store = MemoryStore();
  final api = BcApi(store, baseUrl: args.length > 1 ? args[1] : 'https://boostcontent.io');
  await api.start();
  check('guest created, tokens stored', store.writes == 1);

  final me = await api.me();
  print('ACCOUNT ${me['account_id']}');
  check('me()', me['limits']['posts_month'] > 0, me['limits']);

  // a second instance on the same store = an app restart: same account, no new sign-up
  final again = BcApi(store, baseUrl: args.length > 1 ? args[1] : 'https://boostcontent.io');
  await again.start();
  check('restart keeps the account', (await again.me())['account_id'] == me['account_id'] && store.writes == 1);

  api.debugBreakAccessToken();
  final both = await Future.wait([api.me(), api.businesses()]);
  check('expired token: two parallel calls, one refresh, both succeed', store.writes == 2 && both.length == 2, 'writes=${store.writes}');

  final biz = await api.createBusiness(name: 'Dart check bakery', description: 'Homemade cakes in Kyiv', language: 'uk');
  check('createBusiness', biz['profile_status'] == 'none');
  check('updateBusiness (one field)', (await api.updateBusiness(biz['id'], name: 'Dart bakery'))['description'] == 'Homemade cakes in Kyiv');
  check('businesses()', (await api.businesses()).single['name'] == 'Dart bakery');

  final bytes = await File(args[0]).readAsBytes();
  final mediaId = await api.uploadPhoto(biz['id'], bytes);
  final photos = await api.photos(biz['id']);
  check('uploadPhoto + photos()', photos.single['id'] == mediaId);
  final got = await HttpClient().getUrl(Uri.parse(photos.single['url'])).then((r) => r.close());
  check('photo url downloads the same bytes', got.statusCode == 200 && got.contentLength == bytes.length, '${got.contentLength} bytes');

  check('404 not_found', await codeOf(() => api.deleteBusiness('00000000-0000-0000-0000-000000000000')) == '404 not_found');
  check('400 bad_n', await codeOf(() => api.generatePosts(biz['id'], n: 99)) == '400 bad_n');
  check('400 bad_content_type', await codeOf(() => api.uploadPhoto(biz['id'], bytes, contentType: 'application/pdf')) == '400 bad_content_type');

  final t0 = DateTime.now();
  final queued = await api.generatePosts(biz['id'], n: 1);
  check('generatePosts queued', queued.single['status'] == 'queued');
  final seen = <String>{};
  List<Map<String, dynamic>> last = [];
  await for (final rows in api.watchBatch(queued.single['batch_id'])) {
    last = rows;
    seen.add(rows.single['status']);
  }
  final post = last.single;
  final images = (post['images'] as List).where((i) => i['status'] == 'ready').toList();
  check('post finished in ${DateTime.now().difference(t0).inSeconds}s, statuses seen $seen', post['status'] == 'ready' && images.isNotEmpty,
      '${images.length} images, hashtags ${post['hashtags']}');
  check('caption', (post['caption'] as String).length > 20, (post['caption'] as String).substring(0, 50));
  final prof = await api.profile(biz['id']);
  check('profile ready', prof['status'] == 'ready', (prof['data'] as Map).keys.toList());

  await api.postSignal(post['id'], 'copied');
  check('editPost', (await api.editPost(post['id'], 'Мій текст', hashtags: ['#a', '#b']))['hashtags'].length == 2);
  check('me() counts usage', (await api.me())['used']['posts'] == 1);
  await api.deletePost(post['id']);
  check('deletePost', (await api.posts(biz['id'])).isEmpty);
  await api.deletePhoto(mediaId);
  check('deletePhoto', (await api.photos(biz['id'])).isEmpty);
  await api.deleteBusiness(biz['id']);
  check('deleteBusiness', (await api.businesses()).isEmpty);

  final offline = BcApi(MemoryStore()..t = (access: 'x', refresh: 'y'), baseUrl: 'http://127.0.0.1:9');
  await offline.start();
  check('no connection → network', (await codeOf(() => offline.me()))?.endsWith('network') ?? false);

  final dead = BcApi(MemoryStore()..t = (access: 'broken.token.value', refresh: 'not-a-real-refresh-token'), baseUrl: args.length > 1 ? args[1] : 'https://boostcontent.io');
  await dead.start();
  final lost = await codeOf(() => dead.me());
  check('invalid refresh token → session_lost', lost?.endsWith('session_lost') ?? false, lost);

  print('\nRESULT: $pass passed, $fail failed');
  exit(fail == 0 ? 0 : 1);
}
