import 'dart:io';

import 'package:bc_client/bc_api.dart';

class MemoryStore implements TokenStore {
  ({String access, String refresh})? t;
  String lastAccess = '';
  int writes = 0;
  @override
  Future<({String access, String refresh})?> read() async => t;
  @override
  Future<void> write(String a, String r) async {
    t = (access: a, refresh: r);
    lastAccess = a;
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
  check('me(): plan, limits, what is left', me['plan'] == 'free' && me['left']['posts'] == me['limits']['posts_month'] && me['onboarded_at'] == null,
      '${me['plan']} ${me['limits']}');
  final onb = await api.completeOnboarding();
  check('completeOnboarding', onb['onboarded_at'] != null && (await api.completeOnboarding())['onboarded_at'] == onb['onboarded_at']);

  // a second instance on the same store = an app restart: same account, no new sign-up
  final again = BcApi(store, baseUrl: args.length > 1 ? args[1] : 'https://boostcontent.io');
  await again.start();
  check('restart keeps the account', (await again.me())['account_id'] == me['account_id'] && store.writes == 1);

  api.debugBreakAccessToken();
  final both = await Future.wait([api.me(), api.businesses()]);
  check('expired token: two parallel calls, one refresh, both succeed', store.writes == 2 && both.length == 2, 'writes=${store.writes}');

  final named = await api.createBusiness(name: 'Dart check bakery', description: 'Homemade cakes in Kyiv', language: 'ru', timezone: 'Europe/Kyiv');
  check('createBusiness with a name and a zone', named['name'] == 'Dart check bakery' && named['timezone'] == 'Europe/Kyiv');
  check('updateBusiness (one field)', (await api.updateBusiness(named['id'], name: 'Dart bakery'))['description'] == 'Homemade cakes in Kyiv');
  check('updateBusiness (post language)', (await api.updateBusiness(named['id'], language: 'en'))['language'] == 'en');
  check('400 bad_timezone', await codeOf(() => api.updateBusiness(named['id'], timezone: 'Mars/Phobos')) == '400 bad_timezone');
  await api.deleteBusiness(named['id']);

  // the onboarding path: no name, the device's UTC offset
  final biz = await api.createBusiness(description: 'Sweet Corner: homemade cakes and pastries in Kyiv, pickup and delivery', language: 'uk', utcOffset: 180);
  check('createBusiness without a name, with a UTC offset', biz['name'] == null && biz['timezone'] == '<+03:00>-03:00' && biz['profile_status'] == 'none', biz['timezone']);
  check('businesses()', (await api.businesses()).single['id'] == biz['id']);
  print('BUSINESS ${biz['id']}');

  final bytes = await File(args[0]).readAsBytes();
  final mediaId = await api.uploadPhoto(biz['id'], bytes);
  final photos = await api.photos(biz['id']);
  check('uploadPhoto + photos()', photos.single['id'] == mediaId);
  final got = await HttpClient().getUrl(Uri.parse(photos.single['url'])).then((r) => r.close());
  check('photo url downloads the same bytes', got.statusCode == 200 && got.contentLength == bytes.length, '${got.contentLength} bytes');

  check('404 not_found', await codeOf(() => api.deleteBusiness('00000000-0000-0000-0000-000000000000')) == '404 not_found');
  check('400 bad_n', await codeOf(() => api.generatePosts(biz['id'], n: 99)) == '400 bad_n');
  check('400 bad_content_type', await codeOf(() => api.uploadPhoto(biz['id'], bytes, contentType: 'application/pdf')) == '400 bad_content_type');

  // a round of options: three are written, the user keeps one
  final t0 = DateTime.now();
  final queued = await api.generatePosts(biz['id'], n: 3);
  check('generatePosts queued 3 options', queued.length == 3 && queued.every((p) => p['status'] == 'queued'));
  final batchId = queued.first['batch_id'] as String;
  check('409 not_ready', await codeOf(() => api.choosePost(queued.first['id'])) == '409 not_ready');
  final seen = <String>{};
  List<Map<String, dynamic>> last = [];
  await for (final rows in api.watchBatch(batchId)) {
    last = rows;
    seen.addAll(rows.map((r) => r['status'] as String));
  }
  final usable = last.where((p) => p['status'] == 'ready' || p['status'] == 'partial').toList();
  check('options finished in ${DateTime.now().difference(t0).inSeconds}s, statuses seen $seen', usable.length >= 2,
      last.map((p) => '${p['status']}/${(p['images'] as List).where((i) => i['status'] == 'ready').length} img').toList());
  final post = usable.firstWhere((p) => (p['images'] as List).any((i) => i['status'] == 'ready'));
  final images = (post['images'] as List).where((i) => i['status'] == 'ready').toList();
  check('caption', (post['caption'] as String).length > 20, (post['caption'] as String).substring(0, 50));
  final dl = await HttpClient().getUrl(Uri.parse(images.first['download_url'])).then((r) => r.close());
  check('download_url answers as an attachment', dl.statusCode == 200 && (dl.headers.value('content-disposition') ?? '').startsWith('attachment'),
      dl.headers.value('content-disposition'));
  final prof = await api.profile(biz['id']);
  final data = prof['data'] as Map;
  check('profile ready, fixed shape', prof['status'] == 'ready' && data['customers'] is String && data['tone'] is String &&
      data['best_days'] is List && data['brand_colors'] is List && data['business_name'] is String,
      'best_days ${data['best_days']} brand_colors ${data['brand_colors']}');
  final nowNamed = (await api.businesses()).single['name'];
  check('the analysis named the business', nowNamed is String && nowNamed.isNotEmpty && nowNamed == data['business_name'], nowNamed);

  final before = (await api.me())['used'];
  final chosen = await api.choosePost(post['id']);
  final after = (await api.me())['used'];
  check('choosePost', chosen['chosen_at'] != null && chosen['passed_at'] == null);
  check('a round costs one post and the chosen pictures', after['posts'] == 1 && after['images'] == images.length, 'before $before, after $after');
  check('409 already_chosen', await codeOf(() => api.choosePost(usable.firstWhere((p) => p['id'] != post['id'])['id'])) == '409 already_chosen');
  check('history shows the chosen post only', (await api.posts(biz['id'])).single['id'] == post['id'] && (await api.batch(batchId)).length == 3);
  check('post(id)', (await api.post(post['id']))?['id'] == post['id'] && await api.post('00000000-0000-0000-0000-000000000000') == null);

  await api.postSignal(post['id'], 'copied');
  check('editPost', (await api.editPost(post['id'], 'Мій текст. Коротко, тепло і без знижок.', hashtags: ['#a', '#b']))['hashtags'].length == 2);
  Map<String, dynamic>? learned;
  for (var i = 0; i < 40 && learned == null; i++) {
    await Future<void>.delayed(const Duration(seconds: 3));
    learned = (await api.profile(biz['id']))['learned'] as Map<String, dynamic>?;
  }
  check('the backend learned from the choice', learned != null && learned['likes'] is List && learned['dislikes'] is List, learned);

  await api.deletePost(post['id']);
  check('deletePost', (await api.posts(biz['id'])).isEmpty);
  await api.deletePhoto(mediaId);
  check('deletePhoto', (await api.photos(biz['id'])).isEmpty);

  final photoUrl = photos.single['download_url'] as String; // never fetched before, so no CDN copy of it exists
  await api.deleteAccount();
  check('deleteAccount clears the tokens', store.t == null);
  final gone = BcApi(MemoryStore()..t = (access: both.isEmpty ? '' : store.lastAccess, refresh: 'none'), baseUrl: args.length > 1 ? args[1] : 'https://boostcontent.io');
  await gone.start();
  final goneCode = await codeOf(() => gone.me());
  check('a deleted account is closed to its old token', goneCode?.endsWith('session_lost') ?? false, goneCode);
  var status = 200;
  for (var i = 0; i < 10 && status == 200; i++) {
    await Future<void>.delayed(const Duration(seconds: 2));
    status = (await HttpClient().getUrl(Uri.parse(photoUrl)).then((r) => r.close())).statusCode;
  }
  check('its pictures are gone from storage', status == 404, 'HTTP $status');

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
