import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-nas-mdcng-preview-');
  final mediaDirectory =
      Directory(directory.path + Platform.pathSeparator + 'media');
  final filmDirectory = Directory(
    mediaDirectory.path +
        Platform.pathSeparator +
        'test-library' +
        Platform.pathSeparator +
        'ABF-094',
  );
  final video = File(
    filmDirectory.path + Platform.pathSeparator + 'ABF-094-SD.mp4',
  );
  await filmDirectory.create(recursive: true);
  await video.writeAsBytes(List<int>.generate(16, (index) => index));
  final config = NasConfig(
    bindHost: '127.0.0.1',
    port: 0,
    serverName: 'Test NAS',
    advertiseUrl: null,
    pairingCode: 'test-pairing-code',
    fixtureMediaRelativePath: null,
    mediaRootName: '测试媒体根',
    scanOnStart: false,
    dataDir: directory.path + Platform.pathSeparator + 'data',
    mediaDir: mediaDirectory.path,
    timezone: 'Asia/Shanghai',
  );
  final server = NasHealthServer(config);

  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:' + server.port.toString());
    final serverInfo = await _request(base, 'GET', '/api/v1/server-info');
    final serverId =
        (serverInfo.json['data'] as Map<String, dynamic>)['serverId'] as String;
    final viewerToken = await _pair(base, serverId);
    final adminToken = await _pair(base, serverId, scope: 'admin');

    final roots = await _request(
      base,
      'GET',
      '/api/v1/admin/media-roots',
      token: adminToken,
    );
    final rootId =
        ((roots.json['data'] as Map<String, dynamic>)['items'] as List<dynamic>)
            .single['id'] as String;
    final scan = await _request(
      base,
      'POST',
      '/api/v1/admin/scan-jobs',
      token: adminToken,
      body: {'mediaRootId': rootId},
    );
    final scanId = (scan.json['data'] as Map<String, dynamic>)['id'] as String;
    await _waitForScan(base, scanId, adminToken);
    final movies =
        await _request(base, 'GET', '/api/v1/movies', token: viewerToken);
    final movie = ((movies.json['data'] as Map<String, dynamic>)['items']
            as List<dynamic>)
        .single as Map<String, dynamic>;
    final actor = await _request(
      base,
      'POST',
      '/api/v1/admin/actors',
      token: adminToken,
      body: {'translatedName': '测试演员', 'gender': 'female'},
    );
    _expect(actor.statusCode == HttpStatus.created, '创建用于精确匹配的演员');
    final tag = await _request(
      base,
      'POST',
      '/api/v1/admin/tag-management/tags',
      token: adminToken,
      body: {
        'name': '测试标签',
        'description': '',
        'color': null,
        'level': 1,
        'parentIds': const [],
      },
    );
    _expect(tag.statusCode == HttpStatus.created, '创建用于精确匹配的标签');

    final nfo = File(
      filmDirectory.path + Platform.pathSeparator + 'ABF-094-SD.nfo',
    );
    await nfo.writeAsString('''
<movie>
  <title>ABF-094 测试标题</title>
  <originaltitle>ABF-094 Test title</originaltitle>
  <num>ABF-094</num>
  <plot>测试简介</plot>
  <actor><name>测试演员</name></actor>
  <tag>测试标签</tag>
  <genre>测试标签</genre>
  <poster>poster.jpg</poster>
  <fanart>fanart.jpg</fanart>
  <thumb>thumb.jpg</thumb>
  <cover>https://example.invalid/cover.jpg</cover>
</movie>
''');
    for (final name in const ['poster.jpg', 'fanart.jpg', 'thumb.jpg']) {
      await File(filmDirectory.path + Platform.pathSeparator + name)
          .writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
    }
    final originalNfo = await nfo.readAsString();

    final viewerPreview = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-imports/preview',
      token: viewerToken,
      body: {'movieId': movie['id']},
    );
    _expectError(viewerPreview, HttpStatus.forbidden, 'insufficient_scope');

    final preview = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-imports/preview',
      token: adminToken,
      body: {'movieId': movie['id']},
    );
    _expect(preview.statusCode == HttpStatus.ok, '管理员可以读取预览');
    final data = preview.json['data'] as Map<String, dynamic>;
    _expect(data['mode'] == 'preview_only', '接口明确是只读预览');
    _expect(data['movie']['nfoFileName'] == 'ABF-094-SD.nfo', '匹配视频基名');
    _expect(
      (data['movie']['nfoContentHash'] as String).length == 64,
      '预览返回可用于确认导入的 NFO 内容摘要',
    );
    _expect(data['proposed']['catalogNumber'] == 'ABF-094', '返回拟导入番号');
    _expect(
      (data['proposed']['actors'] as List<dynamic>).single == '测试演员',
      '返回拟导入演员',
    );
    _expect(
      (data['proposed']['tags'] as List<dynamic>).join('|') == '测试标签',
      '标签与类型在预览中去重',
    );
    _expect(
      data['proposed']['actorResolutions'].single['status'] == 'matched' &&
          data['proposed']['tagResolutions'].single['status'] == 'matched',
      '预览仅接受精确匹配的演员和标签',
    );
    _expect(
      (data['fieldDiffs'] as List<dynamic>).any((item) =>
          item['key'] == 'title' &&
          item['status'] == 'replace_requires_confirmation'),
      '已有标题替换要求显式确认',
    );
    _expect(
      (data['proposed']['artwork'] as List<dynamic>).length == 3,
      '返回三张本地图片的安全摘要',
    );
    _expect(
      data['notImported']['externalCoverUrlPresent'] == true,
      '外部封面只告知存在，不返回或下载 URL',
    );
    _expect(!jsonEncode(preview.json).contains(directory.path), '不泄露 NAS 路径');
    _expect(!jsonEncode(preview.json).contains('https://example.invalid'),
        '不泄露或使用外部封面 URL');

    final previewSource = data['movie'] as Map<String, dynamic>;
    final noOverwrite = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-imports/apply',
      token: adminToken,
      body: {
        'movieId': movie['id'],
        'episodeId': previewSource['episodeId'],
        'nfoContentHash': previewSource['nfoContentHash'],
        'fieldKeys': ['title'],
        'overwriteFieldKeys': const [],
      },
    );
    _expectError(
      noOverwrite,
      HttpStatus.conflict,
      'mdcng_overwrite_confirmation_required',
    );
    await nfo.writeAsString(originalNfo + '\n');
    final stalePreview = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-imports/apply',
      token: adminToken,
      body: {
        'movieId': movie['id'],
        'episodeId': previewSource['episodeId'],
        'nfoContentHash': previewSource['nfoContentHash'],
        'fieldKeys': ['title'],
        'overwriteFieldKeys': ['title'],
      },
    );
    _expectError(stalePreview, HttpStatus.conflict, 'mdcng_preview_stale');
    await nfo.writeAsString(originalNfo);

    const allFields = [
      'title',
      'originalTitle',
      'catalogNumber',
      'summary',
      'actors',
      'tags',
      'poster',
      'fanart',
    ];
    final applied = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-imports/apply',
      token: adminToken,
      body: {
        'movieId': movie['id'],
        'episodeId': previewSource['episodeId'],
        'nfoContentHash': previewSource['nfoContentHash'],
        'fieldKeys': allFields,
        'overwriteFieldKeys': ['title'],
      },
    );
    _expect(applied.statusCode == HttpStatus.ok, '确认后写入已选 MDCNG 字段');
    final appliedData = applied.json['data'] as Map<String, dynamic>;
    _expect(
      appliedData['status'] == 'applied' &&
          (appliedData['appliedFields'] as List<dynamic>).length ==
              allFields.length,
      '返回本次实际写入的字段',
    );
    final appliedMovie = appliedData['movie'] as Map<String, dynamic>;
    _expect(
      appliedMovie['title'] == 'ABF-094 测试标题' &&
          appliedMovie['originalTitle'] == 'ABF-094 Test title' &&
          appliedMovie['catalogNumber'] == 'ABF-094' &&
          appliedMovie['summary'] == '测试简介',
      '已确认的标量字段被原子写入',
    );
    _expect(
      (appliedMovie['actors'] as List<dynamic>).single['name'] == '测试演员' &&
          (appliedMovie['tags'] as List<dynamic>).single['name'] == '测试标签',
      '已精确匹配的演员和标签被关联',
    );
    _expect(
      appliedMovie['posterUrl'] != null &&
          (appliedMovie['carouselImages'] as List<dynamic>).length == 1,
      '本地海报和背景图被复制到 NAS 受管理资产目录',
    );

    final repeated = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-imports/apply',
      token: adminToken,
      body: {
        'movieId': movie['id'],
        'episodeId': previewSource['episodeId'],
        'nfoContentHash': previewSource['nfoContentHash'],
        'fieldKeys': allFields,
        'overwriteFieldKeys': ['title'],
      },
    );
    _expect(
      repeated.statusCode == HttpStatus.ok &&
          repeated.json['data']['status'] == 'no_changes',
      '相同 NFO 的重复确认不重复写入图片或记录',
    );

    final manualTitle = await _request(
      base,
      'PATCH',
      '/api/v1/admin/movies/${movie['id']}',
      token: adminToken,
      body: {'title': '人工标题'},
    );
    _expect(manualTitle.statusCode == HttpStatus.ok, '人工编辑会标记字段来源');
    await nfo.writeAsString('''
<movie>
  <title>ABF-094 更新标题</title>
  <num>ABF-094</num>
</movie>
''');
    final changedPreview = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-imports/preview',
      token: adminToken,
      body: {'movieId': movie['id']},
    );
    final changedData = changedPreview.json['data'] as Map<String, dynamic>;
    _expect(
      (changedData['fieldDiffs'] as List<dynamic>).any((item) =>
          item['key'] == 'title' &&
          item['currentSource'] == 'manual' &&
          item['status'] == 'replace_requires_confirmation'),
      '人工修改后，预览明确要求再次确认覆盖',
    );
    final changedSource = changedData['movie'] as Map<String, dynamic>;
    final manualOverwrite = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-imports/apply',
      token: adminToken,
      body: {
        'movieId': movie['id'],
        'episodeId': changedSource['episodeId'],
        'nfoContentHash': changedSource['nfoContentHash'],
        'fieldKeys': ['title'],
        'overwriteFieldKeys': const [],
      },
    );
    _expectError(
      manualOverwrite,
      HttpStatus.conflict,
      'mdcng_overwrite_confirmation_required',
    );
  } finally {
    await server.stop();
    await directory.delete(recursive: true);
  }

  stdout.writeln('mdcng_import_preview_api_test: PASS');
}

Future<String> _pair(Uri base, String serverId, {String? scope}) async {
  final session = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions',
    body: {
      'serverId': serverId,
      if (scope != null) 'requestedScope': scope,
    },
  );
  final sessionId = (session.json['data']
      as Map<String, dynamic>)['pairingSessionId'] as String;
  final confirmed = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions/' + sessionId + '/confirm',
    body: {'pairingPassword': 'test-pairing-code'},
  );
  return (confirmed.json['data'] as Map<String, dynamic>)['accessToken']
      as String;
}

Future<void> _waitForScan(Uri base, String jobId, String token) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    final response = await _request(
      base,
      'GET',
      '/api/v1/admin/scan-jobs/' + jobId,
      token: token,
    );
    final status = (response.json['data'] as Map<String, dynamic>)['status'];
    if (status == 'succeeded') return;
    if (status == 'failed') throw StateError('scan failed');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('scan did not finish in time');
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
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ' + token);
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

void _expectError(_Response response, int statusCode, String code) {
  _expect(response.statusCode == statusCode, '响应状态');
  _expect(response.json['error']['code'] == code, '错误码');
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('Assertion failed: ' + message);
}
