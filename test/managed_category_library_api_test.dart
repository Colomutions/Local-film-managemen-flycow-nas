import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final directory = await Directory.systemTemp
      .createTemp('mujing-nas-managed-category-test-');
  final mediaRoot =
      Directory('${directory.path}${Platform.pathSeparator}media');
  final originalVideo = File(
    '${mediaRoot.path}${Platform.pathSeparator}disk1${Platform.pathSeparator}原目录${Platform.pathSeparator}old.mp4',
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
      body: {'name': '测试分类', 'directoryKey': 'disk1/原目录'},
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

    final movies = await _request(
      base,
      'GET',
      '/api/v1/movies',
      token: viewerToken,
    );
    final movie = ((movies.json['data'] as Map<String, dynamic>)['items']
            as List<dynamic>)
        .single as Map<String, dynamic>;
    final details = await _request(
      base,
      'GET',
      '/api/v1/movies/${movie['id']}',
      token: viewerToken,
    );
    final episode = ((details.json['data'] as Map<String, dynamic>)['episodes']
            as List<dynamic>)
        .single as Map<String, dynamic>;
    final missingCategory = await _request(
      base,
      'POST',
      '/api/v1/admin/collections',
      token: adminToken,
      body: {'title': '未分类影集'},
    );
    _expect(missingCategory.statusCode == HttpStatus.badRequest, '新建空影集必须明确指定分类');
    final sameCategoryCollection = await _request(
      base,
      'POST',
      '/api/v1/admin/collections',
      token: adminToken,
      body: {'title': '同类目标影集', 'categoryId': category['id']},
    );
    _expect(sameCategoryCollection.statusCode == HttpStatus.created, '可创建明确分类的空影集');
    final collections = await _request(
      base,
      'GET',
      '/api/v1/collections?categoryId=${category['id']}&q=同类&page=1&pageSize=20',
      token: viewerToken,
    );
    _expect(collections.statusCode == HttpStatus.ok, '普通影视用户可按页查询同分类影集');
    final collectionItems = ((collections.json['data'] as Map<String, dynamic>)['items']
            as List<dynamic>)
        .cast<Map<String, dynamic>>();
    _expect(
      collectionItems.single['title'] == '同类目标影集',
      '影集选择接口在 NAS 内按分类和关键词分页',
    );

    final otherDirectory = Directory(
      '${mediaRoot.path}${Platform.pathSeparator}disk1${Platform.pathSeparator}其他目录',
    );
    await otherDirectory.create(recursive: true);
    final otherCategoryResponse = await _request(
      base,
      'POST',
      '/api/v1/admin/categories',
      token: adminToken,
      body: {'name': '其他分类', 'directoryKey': 'disk1/其他目录'},
    );
    _expect(otherCategoryResponse.statusCode == HttpStatus.created, '创建第二个分类成功');
    final otherCategory = otherCategoryResponse.json['data'] as Map<String, dynamic>;
    final otherJob = otherCategory['scanJob'] as Map<String, dynamic>;
    await _waitForFinishedJob(base, otherJob['id'] as String, adminToken);
    final otherCollection = await _request(
      base,
      'POST',
      '/api/v1/admin/collections',
      token: adminToken,
      body: {'title': '异类目标影集', 'categoryId': otherCategory['id']},
    );
    final otherCollectionId =
        ((otherCollection.json['data'] as Map<String, dynamic>)['id'] as String);
    final rejectedCrossCategoryMerge = await _request(
      base,
      'POST',
      '/api/v1/admin/collections/$otherCollectionId/episodes',
      token: adminToken,
      body: {
        'episodeIds': [episode['id']],
        'metadataSourceMovieId': movie['id'],
      },
    );
    _expect(
      rejectedCrossCategoryMerge.statusCode == HttpStatus.conflict,
      '服务端拒绝跨分类合并',
    );
    final preservedTarget = await _request(
      base,
      'GET',
      '/api/v1/movies/$otherCollectionId',
      token: viewerToken,
    );
    final preservedCategory = (preservedTarget.json['data']
        as Map<String, dynamic>)['category'] as Map<String, dynamic>;
    _expect(
      preservedCategory['id'] == otherCategory['id'],
      '被拒绝的跨分类合并不会覆盖目标影集分类',
    );
    final playback = await _request(
      base,
      'POST',
      '/api/v1/playback/sessions',
      token: viewerToken,
      body: {'contentId': movie['id'], 'episodeId': episode['id']},
    );
    _expect(playback.statusCode == HttpStatus.ok, '多盘分集可创建播放会话');
    final sessionId =
        (playback.json['data'] as Map<String, dynamic>)['sessionId'] as String;
    final stream = await _bytesRequest(
      base,
      'GET',
      '/api/v1/playback/sessions/$sessionId/stream',
      token: viewerToken,
      range: 'bytes=2-5',
    );
    _expect(stream.statusCode == HttpStatus.partialContent, '多盘分集可读取播放流');
    _expect(stream.bytes.toString() == [2, 3, 4, 5].toString(), '播放流来自来源盘');
    final started = await _request(
      base,
      'POST',
      '/api/v1/playback/sessions/$sessionId/started',
      token: viewerToken,
    );
    _expect(started.statusCode == HttpStatus.ok, '播放流开启后可确认正式播放');
    final progress = await _request(
      base,
      'PATCH',
      '/api/v1/playback/sessions/$sessionId/progress',
      token: viewerToken,
      body: {'positionMs': 4, 'durationMs': 8, 'state': 'playing'},
    );
    _expect(progress.statusCode == HttpStatus.ok, '多盘分集可保存续播进度');
    final resumedDetails = await _request(
      base,
      'GET',
      '/api/v1/movies/${movie['id']}',
      token: viewerToken,
    );
    final resume = (resumedDetails.json['data']
        as Map<String, dynamic>)['continuePlayback'] as Map<String, dynamic>;
    _expect(resume['episodeId'] == episode['id'], '详情返回最后续播的分集');
    _expect(resume['positionMs'] == 4, '详情返回最后续播的位置');

    await originalVideo.parent.delete(recursive: true);
    final replacementVideo = File(
      '${mediaRoot.path}${Platform.pathSeparator}disk1${Platform.pathSeparator}新目录${Platform.pathSeparator}new.mp4',
    );
    await replacementVideo.parent.create(recursive: true);
    await replacementVideo
        .writeAsBytes(List<int>.generate(12, (index) => index));
    final rebound = await _request(
      base,
      'PATCH',
      '/api/v1/admin/categories/${category['id']}',
      token: adminToken,
      body: {'name': '测试分类', 'directoryKey': 'disk1/新目录'},
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
    await _expectMovieTitles(
      base,
      viewerToken,
      const ['new', 'old', '同类目标影集', '异类目标影集'],
    );

    final deleted = await _request(
      base,
      'DELETE',
      '/api/v1/admin/categories/${category['id']}',
      token: adminToken,
    );
    _expect(deleted.statusCode == HttpStatus.noContent, '删除目录分类成功');
    await _expectMovieTitles(base, viewerToken, const ['异类目标影集']);
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
  titles.sort();
  final expectedTitles = [...expected]..sort();
  _expect(
    titles.toString() == expectedTitles.toString(),
    '影片列表与目录扫描结果一致',
  );
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

Future<_ByteResponse> _bytesRequest(
  Uri base,
  String method,
  String path, {
  required String token,
  String? range,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, base.resolve(path));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    final bytes = await response
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    return _ByteResponse(response.statusCode, bytes);
  } finally {
    client.close(force: true);
  }
}

class _Response {
  const _Response(this.statusCode, this.json);

  final int statusCode;
  final Map<String, dynamic> json;
}

class _ByteResponse {
  const _ByteResponse(this.statusCode, this.bytes);

  final int statusCode;
  final List<int> bytes;
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('断言失败：$message');
}
