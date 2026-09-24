import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('mujing-mdcng-batch-');
  final media = Directory('${root.path}${Platform.pathSeparator}media');
  final categoryDirectory = Directory(
      '${media.path}${Platform.pathSeparator}disk1${Platform.pathSeparator}影片');
  final seriesDirectory =
      Directory('${categoryDirectory.path}${Platform.pathSeparator}ABC-影集');
  await seriesDirectory.create(recursive: true);
  for (final name in ['ABC-A', 'ABC-B']) {
    await File('${seriesDirectory.path}${Platform.pathSeparator}$name.mp4')
        .writeAsBytes(const [0, 1, 2, 3]);
    await File('${seriesDirectory.path}${Platform.pathSeparator}$name.nfo')
        .writeAsString('''<movie>
<title>$name 的标题</title><num>ABC</num><plot>共同简介</plot>
<actor><name>未匹配演员</name></actor>
</movie>''');
  }
  for (final name in ['poster.jpg', 'fanart.jpg']) {
    await File('${seriesDirectory.path}${Platform.pathSeparator}$name')
        .writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
  }
  await File('${categoryDirectory.path}${Platform.pathSeparator}Solo.mp4')
      .writeAsBytes(const [0, 1, 2, 3]);
  final soloNfo =
      File('${categoryDirectory.path}${Platform.pathSeparator}Solo.nfo');
  await soloNfo.writeAsString('<movie>');

  final server = NasHealthServer(NasConfig(
    bindHost: '127.0.0.1',
    port: 0,
    serverName: 'Test NAS',
    advertiseUrl: null,
    pairingCode: 'test-pairing-code',
    fixtureMediaRelativePath: null,
    mediaRootName: '测试媒体根',
    scanOnStart: false,
    managedCategoryLibrary: true,
    dataDir: '${root.path}${Platform.pathSeparator}data',
    mediaDir: media.path,
    timezone: 'Asia/Shanghai',
  ));
  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await _request(base, 'GET', '/api/v1/server-info');
    final capabilities = info.data['capabilities'] as Map<String, dynamic>;
    if (capabilities['mdcngNfoBatch'] != true) {
      throw StateError('NAS must advertise MDCNG category batch import.');
    }
    final serverId = info.data['serverId'] as String;
    final admin = await _pair(base, serverId);
    final created = await _request(base, 'POST', '/api/v1/admin/categories',
        token: admin, body: {'name': '影片', 'directoryKey': 'disk1/影片'});
    _expect(created.status == HttpStatus.created, '分类创建成功');
    final categoryId = created.data['id'] as String;
    await _waitForScan(base, created.data['scanJob']['id'] as String, admin);
    await Directory('${media.path}${Platform.pathSeparator}disk1'
            '${Platform.pathSeparator}空分类')
        .create(recursive: true);
    final emptyCategory = await _request(
        base, 'POST', '/api/v1/admin/categories',
        token: admin, body: {'name': '空分类', 'directoryKey': 'disk1/空分类'});
    await _waitForScan(
        base, emptyCategory.data['scanJob']['id'] as String, admin);
    final emptyBatch = await _request(
        base, 'POST', '/api/v1/admin/mdcng-import-jobs',
        token: admin, body: {'categoryId': emptyCategory.data['id']});
    final emptyDone =
        await _waitForBatch(base, emptyBatch.data['id'] as String, admin);
    _expect(emptyDone['total'] == 0, '空分类任务会正常结束并释放运行状态');
    final movies = await _request(base, 'GET', '/api/v1/movies', token: admin);
    final items = (movies.data['items'] as List).cast<Map<String, dynamic>>();
    _expect(items.length == 2, '两个视频自动归为一部影片');
    final series = items.singleWhere((item) => item['entryType'] == 'series');
    final seriesId = series['id'] as String;

    final preview = await _request(
        base, 'POST', '/api/v1/admin/mdcng-imports/preview',
        token: admin, body: {'movieId': seriesId});
    _expect(preview.status == HttpStatus.ok, '多视频影集可预览 NFO');
    final sources =
        (preview.data['sources'] as List).cast<Map<String, dynamic>>();
    _expect(
        sources.length == 2 &&
            preview.data['movie']['nfoFileName'] == 'ABC-A.nfo',
        '默认选择排序第一份 NFO');
    final selected = await _request(
        base, 'POST', '/api/v1/admin/mdcng-imports/preview',
        token: admin,
        body: {'movieId': seriesId, 'episodeId': sources.last['episodeId']});
    _expect(selected.data['movie']['nfoFileName'] == 'ABC-B.nfo', '可指定另一份 NFO');
    final artwork = (selected.data['proposed']['artwork'] as List)
        .cast<Map<String, dynamic>>();
    _expect(
        artwork.any((item) => item['fileName'] == 'poster.jpg') &&
            artwork.any((item) => item['fileName'] == 'fanart.jpg'),
        '未在 NFO 声明图片时读取同目录共用图片');
    final applied = await _request(
        base, 'POST', '/api/v1/admin/mdcng-imports/apply',
        token: admin,
        body: {
          'movieId': seriesId,
          'episodeId': sources.last['episodeId'],
          'nfoContentHash': selected.data['movie']['nfoContentHash'],
          'fieldKeys': ['title', 'poster', 'fanart'],
          'overwriteFieldKeys': ['title'],
        });
    _expect(
        applied.status == HttpStatus.ok &&
            applied.data['movie']['posterUrl'] != null &&
            (applied.data['movie']['carouselImages'] as List).length == 1,
        '一份 NFO 和目录图片导入整部影片');
    final preferred = await _request(
        base, 'POST', '/api/v1/admin/mdcng-imports/preview',
        token: admin, body: {'movieId': seriesId});
    _expect(preferred.data['movie']['nfoFileName'] == 'ABC-B.nfo',
        '再次预览沿用人工选择的 NFO');
    await _request(base, 'PATCH', '/api/v1/admin/movies/$seriesId',
        token: admin, body: {'title': '人工标题'});

    final batchPreview = await _request(base, 'GET',
        '/api/v1/admin/mdcng-import-jobs/preview?categoryId=$categoryId',
        token: admin);
    _expect(batchPreview.data['movieCount'] == 2, '批量预览只统计分类内影片');
    final batch = await _request(
        base, 'POST', '/api/v1/admin/mdcng-import-jobs',
        token: admin, body: {'categoryId': categoryId});
    _expect(batch.status == HttpStatus.accepted, '分类批量任务已启动');
    final done = await _waitForBatch(base, batch.data['id'] as String, admin);
    _expect(
        done['processed'] == 2 &&
            done['failed'] == 1 &&
            done['warningCount'] == 1 &&
            (done['warnings'] as List)
                .single['fields']
                .contains('actors_unresolved'),
        '错误 NFO 单独记为失败，其他影片继续处理');
    final afterBatch =
        await _request(base, 'GET', '/api/v1/movies/$seriesId', token: admin);
    _expect(
        afterBatch.data['title'] == '人工标题' &&
            (afterBatch.data['carouselImages'] as List).length == 1,
        '批量导入保留人工标题且不复制重复图片');

    await soloNfo.writeAsString('<movie><title>Solo 正确标题</title></movie>');
    final retried = await _request(base, 'POST',
        '/api/v1/admin/mdcng-import-jobs/${batch.data['id']}/retry',
        token: admin);
    final retryDone =
        await _waitForBatch(base, retried.data['id'] as String, admin);
    _expect(
        retryDone['total'] == 1 &&
            retryDone['applied'] == 1 &&
            retryDone['failed'] == 0,
        '只重试失败项');

    final scan = await _request(base, 'POST', '/api/v1/admin/scan-jobs',
        token: admin, body: {'categoryId': categoryId});
    await _waitForScan(base, scan.data['id'] as String, admin);
    final rescanned =
        await _request(base, 'GET', '/api/v1/movies/$seriesId', token: admin);
    _expect(
        rescanned.data['title'] == '人工标题' &&
            rescanned.data['episodeCount'] == 2 &&
            rescanned.data['posterUrl'] != null,
        '二次扫描保留影片资料、海报和两段视频');
  } finally {
    await server.stop();
    await root.delete(recursive: true);
  }
  stdout.writeln('mdcng_batch_api_test: PASS');
}

Future<String> _pair(Uri base, String serverId) async {
  final session = await _request(base, 'POST', '/api/v1/pairing/sessions',
      body: {'serverId': serverId, 'requestedScope': 'admin'});
  final confirmed = await _request(base, 'POST',
      '/api/v1/pairing/sessions/${session.data['pairingSessionId']}/confirm',
      body: {'pairingPassword': 'test-pairing-code'});
  return confirmed.data['accessToken'] as String;
}

Future<void> _waitForScan(Uri base, String id, String token) async {
  for (var index = 0; index < 100; index++) {
    final response = await _request(base, 'GET', '/api/v1/admin/scan-jobs/$id',
        token: token);
    if (response.data['status'] == 'succeeded') return;
    if (response.data['status'] == 'failed') throw StateError('scan failed');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('scan timed out');
}

Future<Map<String, dynamic>> _waitForBatch(
    Uri base, String id, String token) async {
  for (var index = 0; index < 100; index++) {
    final response = await _request(
        base, 'GET', '/api/v1/admin/mdcng-import-jobs/$id',
        token: token);
    if (response.data['status'] == 'succeeded') return response.data;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('batch timed out');
}

Future<({int status, Map<String, dynamic> data})> _request(
    Uri base, String method, String path,
    {String? token, Object? body}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, base.resolve(path));
    if (token != null)
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final decoded = jsonDecode(await utf8.decoder.bind(response).join())
        as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      throw StateError('$method $path: ${response.statusCode} $decoded');
    }
    return (
      status: response.statusCode,
      data: decoded['data'] as Map<String, dynamic>
    );
  } finally {
    client.close(force: true);
  }
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('断言失败：$message');
}
