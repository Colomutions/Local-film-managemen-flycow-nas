import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-nas-watch-history-test-');
  final mediaRoot =
      Directory('${directory.path}${Platform.pathSeparator}media');
  final video = File(
    '${mediaRoot.path}${Platform.pathSeparator}disk1${Platform.pathSeparator}历史${Platform.pathSeparator}episode-01.mp4',
  );
  await video.parent.create(recursive: true);
  await video.writeAsBytes(List<int>.generate(16, (index) => index));
  final config = NasConfig(
    bindHost: '127.0.0.1',
    port: 0,
    serverName: 'Test NAS',
    advertiseUrl: null,
    pairingCode: 'test-pairing-code',
    fixtureMediaRelativePath: null,
    mediaRootName: 'disk1',
    scanOnStart: false,
    managedCategoryLibrary: true,
    dataDir: '${directory.path}${Platform.pathSeparator}data',
    mediaDir: mediaRoot.path,
    timezone: 'Asia/Shanghai',
  );
  var server = NasHealthServer(config);

  try {
    await server.start();
    var base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await _request(base, 'GET', '/api/v1/server-info');
    final serverId =
        (info.json['data'] as Map<String, dynamic>)['serverId'] as String;
    final windows = await _pair(base, serverId, platform: 'windows');
    final android = await _pair(base, serverId, platform: 'android');
    final admin = await _pair(base, serverId, scope: 'admin');

    final category = await _request(
      base,
      'POST',
      '/api/v1/admin/categories',
      token: admin.token,
      body: {'name': '历史测试', 'directoryKey': 'disk1/历史'},
    );
    _expect(category.statusCode == HttpStatus.created, '创建历史测试分类');
    final job = ((category.json['data'] as Map<String, dynamic>)['scanJob']
        as Map<String, dynamic>)['id'] as String;
    await _waitForFinishedJob(base, job, admin.token);
    final movies =
        await _request(base, 'GET', '/api/v1/movies', token: windows.token);
    final movie = ((movies.json['data'] as Map<String, dynamic>)['items']
            as List<dynamic>)
        .single as Map<String, dynamic>;
    final details = await _request(
      base,
      'GET',
      '/api/v1/movies/${movie['id']}',
      token: windows.token,
    );
    final episode = ((details.json['data'] as Map<String, dynamic>)['episodes']
            as List<dynamic>)
        .single as Map<String, dynamic>;

    await _playOnce(
      base,
      token: windows.token,
      movieId: movie['id'] as String,
      episodeId: episode['id'] as String,
      startTwice: true,
    );
    await _playOnce(
      base,
      token: windows.token,
      movieId: movie['id'] as String,
      episodeId: episode['id'] as String,
    );
    await _playOnce(
      base,
      token: android.token,
      movieId: movie['id'] as String,
      episodeId: episode['id'] as String,
    );

    final beforePreview = await _watchHistory(base, windows.token);
    _expect(beforePreview.total == 3, '同一影片的三次正式播放生成三条独立记录');
    _expect(
      beforePreview.items
              .where((item) => item['devicePlatform'] == 'windows')
              .length ==
          2,
      'Windows 播放来源写入历史',
    );
    _expect(
      beforePreview.items
              .where((item) => item['devicePlatform'] == 'android')
              .length ==
          1,
      'Android 播放来源写入同一 NAS 历史',
    );
    _expect(
      beforePreview.items.every(
        (item) =>
            item['movieId'] == movie['id'] &&
            item['episodeId'] == episode['id'] &&
            item['watchDurationMs'] is num &&
            item['lastReportedAt'] is String,
      ),
      '每条记录同时保存逻辑影视、具体分集及会话字段',
    );
    _expect(
      beforePreview.continueItems.single['episodeId'] == episode['id'] &&
          beforePreview.continueItems.single['sourceName'] == 'disk1',
      '继续观看从 NAS 聚合并携带具体分集和来源盘',
    );

    await _previewOnce(
      base,
      token: windows.token,
      movieId: movie['id'] as String,
      episodeId: episode['id'] as String,
    );
    final afterPreview = await _watchHistory(base, windows.token);
    _expect(afterPreview.total == 3, '预览不会新增历史记录');
    final windowsOnly = await _watchHistory(
      base,
      windows.token,
      query: 'episode',
      device: 'windows',
      pageSize: 1,
    );
    _expect(windowsOnly.total == 2 && windowsOnly.items.length == 1,
        '关键词、设备和分页由 NAS 执行');
    _expect(windowsOnly.hasMore, '稳定分页明确返回 hasMore');

    // 把一条已结束会话调整为跨午夜；历史仍以 startedAt 的日期归属。
    final crossMidnightId = beforePreview.items.last['recordId'] as String;
    await server.stop();
    final database = sqlite3.open(
      '${config.dataDir}${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite',
    );
    try {
      database.execute('''
        UPDATE playback_history
        SET started_at = '2026-09-10T23:58:00.000Z',
            last_reported_at = '2026-09-11T00:03:00.000Z',
            ended_at = '2026-09-11T00:03:00.000Z'
        WHERE id = ?
      ''', [crossMidnightId]);
    } finally {
      database.dispose();
    }
    server = NasHealthServer(config);
    await server.start();
    base = Uri.parse('http://127.0.0.1:${server.port}');
    final startedDay = await _watchHistory(
      base,
      windows.token,
      from: '2026-09-10',
      to: '2026-09-10',
    );
    final nextDay = await _watchHistory(
      base,
      windows.token,
      from: '2026-09-11',
      to: '2026-09-11',
    );
    _expect(startedDay.total == 1, '跨午夜连续播放按 startedAt 归入开始日期');
    _expect(nextDay.total == 0, '跨午夜记录不会拆成次日的新记录');
  } finally {
    await server.stop();
    await directory.delete(recursive: true);
  }

  stdout.writeln('watch_history_api_test: PASS');
}

Future<void> _playOnce(
  Uri base, {
  required String token,
  required String movieId,
  required String episodeId,
  bool startTwice = false,
}) async {
  final created = await _request(
    base,
    'POST',
    '/api/v1/playback/sessions',
    token: token,
    body: {'contentId': movieId, 'episodeId': episodeId, 'purpose': 'playback'},
  );
  _expect(created.statusCode == HttpStatus.ok, '创建正式播放会话');
  final sessionId =
      (created.json['data'] as Map<String, dynamic>)['sessionId'] as String;
  final stream = await _bytesRequest(
    base,
    'GET',
    '/api/v1/playback/sessions/$sessionId/stream',
    token: token,
  );
  _expect(stream.statusCode == HttpStatus.ok, '正式播放流已准备');
  final started = await _request(
    base,
    'POST',
    '/api/v1/playback/sessions/$sessionId/started',
    token: token,
  );
  _expect(started.statusCode == HttpStatus.ok, '正式播放创建历史记录');
  if (startTwice) {
    final repeated = await _request(
      base,
      'POST',
      '/api/v1/playback/sessions/$sessionId/started',
      token: token,
    );
    _expect(repeated.statusCode == HttpStatus.ok, '重复 started 请求幂等成功');
  }
  await Future<void>.delayed(const Duration(milliseconds: 2));
  final progress = await _request(
    base,
    'PATCH',
    '/api/v1/playback/sessions/$sessionId/progress',
    token: token,
    body: {'positionMs': 4, 'durationMs': 16, 'state': 'paused'},
  );
  _expect(progress.statusCode == HttpStatus.ok, '播放心跳更新当前会话记录');
  final closed = await _request(
    base,
    'DELETE',
    '/api/v1/playback/sessions/$sessionId',
    token: token,
  );
  _expect(closed.statusCode == HttpStatus.noContent, '播放结束更新当前会话记录');
}

Future<void> _previewOnce(
  Uri base, {
  required String token,
  required String movieId,
  required String episodeId,
}) async {
  final created = await _request(
    base,
    'POST',
    '/api/v1/playback/sessions',
    token: token,
    body: {'contentId': movieId, 'episodeId': episodeId, 'purpose': 'preview'},
  );
  _expect(created.statusCode == HttpStatus.ok, '创建预览会话');
  final sessionId =
      (created.json['data'] as Map<String, dynamic>)['sessionId'] as String;
  await _bytesRequest(
    base,
    'GET',
    '/api/v1/playback/sessions/$sessionId/stream',
    token: token,
  );
  await _request(
    base,
    'POST',
    '/api/v1/playback/sessions/$sessionId/started',
    token: token,
  );
  await _request(
    base,
    'PATCH',
    '/api/v1/playback/sessions/$sessionId/progress',
    token: token,
    body: {'positionMs': 10, 'durationMs': 16, 'state': 'playing'},
  );
  final closed = await _request(
    base,
    'DELETE',
    '/api/v1/playback/sessions/$sessionId',
    token: token,
  );
  _expect(closed.statusCode == HttpStatus.noContent, '预览可正常关闭');
}

Future<_HistoryPage> _watchHistory(
  Uri base,
  String token, {
  String query = '',
  String? device,
  String? from,
  String? to,
  int pageSize = 20,
}) async {
  final uri = Uri(
    path: '/api/v1/watch-history',
    queryParameters: {
      if (query.isNotEmpty) 'q': query,
      if (device != null) 'device': device,
      if (from != null) 'from': from,
      if (to != null) 'to': to,
      'page': '1',
      'pageSize': '$pageSize',
      'sort': 'startedAt',
      'order': 'desc',
    },
  );
  final response = await _request(base, 'GET', uri.toString(), token: token);
  _expect(response.statusCode == HttpStatus.ok, '普通影视用户可读取观影历史');
  final data = response.json['data'] as Map<String, dynamic>;
  final page = response.json['page'] as Map<String, dynamic>;
  return _HistoryPage(
    ((data['items'] as List<dynamic>).cast<Map<String, dynamic>>()),
    ((data['continueItems'] as List<dynamic>).cast<Map<String, dynamic>>()),
    page['total'] as int,
    page['hasMore'] as bool,
  );
}

Future<_PairedToken> _pair(
  Uri base,
  String serverId, {
  String? scope,
  String? platform,
}) async {
  final session = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions',
    body: {
      'serverId': serverId,
      if (scope != null) 'requestedScope': scope,
      if (platform != null) 'platform': platform,
    },
  );
  final sessionId = (session.json['data']
      as Map<String, dynamic>)['pairingSessionId'] as String;
  final confirmed = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions/$sessionId/confirm',
    body: {'pairingPassword': 'test-pairing-code'},
  );
  _expect(confirmed.statusCode == HttpStatus.ok, '设备配对成功');
  final data = confirmed.json['data'] as Map<String, dynamic>;
  _expect(
    data['platform'] == (platform ?? 'unknown'),
    '配对平台持久化并兼容未声明平台的旧客户端',
  );
  return _PairedToken(data['accessToken'] as String);
}

Future<void> _waitForFinishedJob(Uri base, String id, String token) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    final response = await _request(
      base,
      'GET',
      '/api/v1/admin/scan-jobs/$id',
      token: token,
    );
    final job = response.json['data'] as Map<String, dynamic>;
    if (job['status'] == 'succeeded') return;
    if (job['status'] == 'failed') throw StateError('扫描任务失败');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('扫描任务未在预期时间内结束');
}

Future<_Response> _request(
  Uri base,
  String method,
  String path, {
  Object? body,
  String? token,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, base.resolve(path));
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return _Response(
      response.statusCode,
      text.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>,
    );
  } finally {
    client.close(force: true);
  }
}

Future<_BytesResponse> _bytesRequest(
  Uri base,
  String method,
  String path, {
  required String token,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, base.resolve(path));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close();
    await response.drain<void>();
    return _BytesResponse(response.statusCode);
  } finally {
    client.close(force: true);
  }
}

class _PairedToken {
  const _PairedToken(this.token);

  final String token;
}

class _HistoryPage {
  const _HistoryPage(this.items, this.continueItems, this.total, this.hasMore);

  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> continueItems;
  final int total;
  final bool hasMore;
}

class _Response {
  const _Response(this.statusCode, this.json);

  final int statusCode;
  final Map<String, dynamic> json;
}

class _BytesResponse {
  const _BytesResponse(this.statusCode);

  final int statusCode;
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('断言失败：$message');
}
