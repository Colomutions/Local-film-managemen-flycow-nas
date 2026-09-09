import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final directory = await Directory.systemTemp
      .createTemp('mujing-nas-managed-category-test-');
  final mediaRoot =
      Directory('${directory.path}${Platform.pathSeparator}media');
  final originalVideo = File(
    '${mediaRoot.path}${Platform.pathSeparator}原目录${Platform.pathSeparator}old.mp4',
  );
  await originalVideo.parent.create(recursive: true);
  await originalVideo.writeAsBytes(List<int>.generate(8, (index) => index));
  final config = NasConfig(
    bindHost: '127.0.0.1',
    port: 0,
    serverName: 'Test NAS',
    advertiseUrl: null,
    pairingCode: 'test-pairing-code',
    fixtureMediaRelativePath: null,
    mediaRootName: '测试媒体根',
    scanOnStart: false,
    managedCategoryLibrary: true,
    dataDir: '${directory.path}${Platform.pathSeparator}data',
    mediaDir: mediaRoot.path,
    timezone: 'Asia/Shanghai',
  );
  final server = NasHealthServer(config);

  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await _request(base, 'GET', '/api/v1/server-info');
    final serverId =
        (info.json['data'] as Map<String, dynamic>)['serverId'] as String;
    final viewerToken = await _pair(base, serverId);
    final adminToken = await _pair(base, serverId, scope: 'admin');

    final created = await _request(
      base,
      'POST',
      '/api/v1/admin/categories',
      token: adminToken,
      body: {'name': '测试分类', 'directoryKey': '原目录'},
    );
    _expect(created.statusCode == HttpStatus.created, '创建目录分类成功');
    final category = created.json['data'] as Map<String, dynamic>;
    final firstJob = category['scanJob'] as Map<String, dynamic>;
    final firstFinished = await _waitForFinishedJob(
      base,
      firstJob['id'] as String,
      adminToken,
    );
    _expect(firstFinished['status'] == 'succeeded', '原目录扫描成功');
    _expect(firstFinished['availableEpisodes'] == 1, '原目录视频已建立索引');
    await _expectMovieTitles(base, viewerToken, const ['old']);

    await originalVideo.parent.delete(recursive: true);
    final replacementVideo = File(
      '${mediaRoot.path}${Platform.pathSeparator}新目录${Platform.pathSeparator}new.mp4',
    );
    await replacementVideo.parent.create(recursive: true);
    await replacementVideo
        .writeAsBytes(List<int>.generate(12, (index) => index));
    final rebound = await _request(
      base,
      'PATCH',
      '/api/v1/admin/categories/${category['id']}',
      token: adminToken,
      body: {'name': '测试分类', 'directoryKey': '新目录'},
    );
    _expect(rebound.statusCode == HttpStatus.ok, '重新绑定目录成功');
    final reboundJob = (rebound.json['data'] as Map<String, dynamic>)['scanJob']
        as Map<String, dynamic>;
    final reboundFinished = await _waitForFinishedJob(
      base,
      reboundJob['id'] as String,
      adminToken,
    );
    _expect(reboundFinished['status'] == 'succeeded', '新目录扫描成功');
    _expect(reboundFinished['availableEpisodes'] == 1, '新目录视频已建立索引');
    await _expectMovieTitles(base, viewerToken, const ['new']);

    final deleted = await _request(
      base,
      'DELETE',
      '/api/v1/admin/categories/${category['id']}',
      token: adminToken,
    );
    _expect(deleted.statusCode == HttpStatus.noContent, '删除目录分类成功');
    await _expectMovieTitles(base, viewerToken, const []);
  } finally {
    await server.stop();
    await directory.delete(recursive: true);
  }

  stdout.writeln('managed_category_library_api_test: PASS');
}

Future<void> _expectMovieTitles(
  Uri base,
  String token,
  List<String> expected,
) async {
  final response = await _request(base, 'GET', '/api/v1/movies', token: token);
  _expect(response.statusCode == HttpStatus.ok, '读取影片列表成功');
  final titles = ((response.json['data'] as Map<String, dynamic>)['items']
          as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .map((item) => item['title'] as String)
      .toList();
  _expect(titles.toString() == expected.toString(), '影片列表与目录扫描结果一致');
}

Future<String> _pair(Uri base, String serverId, {String? scope}) async {
  final session = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions',
    body: {'serverId': serverId, if (scope != null) 'requestedScope': scope},
  );
  final id = (session.json['data'] as Map<String, dynamic>)['pairingSessionId']
      as String;
  final confirmed = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions/$id/confirm',
    body: {'pairingPassword': 'test-pairing-code'},
  );
  return (confirmed.json['data'] as Map<String, dynamic>)['accessToken']
      as String;
}

Future<Map<String, dynamic>> _waitForFinishedJob(
  Uri base,
  String jobId,
  String token,
) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    final response = await _request(
      base,
      'GET',
      '/api/v1/admin/scan-jobs/$jobId',
      token: token,
    );
    _expect(response.statusCode == HttpStatus.ok, '读取扫描任务成功');
    final job = response.json['data'] as Map<String, dynamic>;
    if (job['status'] == 'succeeded' || job['status'] == 'failed') return job;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('扫描任务未在预期时间内结束。');
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

class _Response {
  const _Response(this.statusCode, this.json);

  final int statusCode;
  final Map<String, dynamic> json;
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('断言失败：$message');
}
