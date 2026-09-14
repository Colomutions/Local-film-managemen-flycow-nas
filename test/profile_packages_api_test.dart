import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import '../lib/mujing_nas.dart';
import '../lib/src/library/profile_package.dart';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('mujing-nas-profile-package-test-');
  final config = NasConfig(
    bindHost: '127.0.0.1',
    port: 0,
    serverName: 'Test NAS',
    advertiseUrl: null,
    pairingCode: 'test-pairing-code',
    fixtureMediaRelativePath: null,
    mediaRootName: 'test',
    scanOnStart: false,
    dataDir: directory.path,
    mediaDir: '/not-exposed',
    timezone: 'Asia/Shanghai',
  );
  final server = NasHealthServer(config);
  try {
    await server.start();
    final baseUrl = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await _request(baseUrl, 'GET', '/api/v1/server-info');
    final serverId = info.json['data']['serverId'] as String;
    final adminToken = await _pair(baseUrl, serverId, config.pairingCode!, admin: true);
    final viewerToken = await _pair(baseUrl, serverId, config.pairingCode!, admin: false);

    final denied = await _request(
      baseUrl,
      'GET',
      '/api/v1/admin/profile-packages/actor/template',
      token: viewerToken,
    );
    _expect(denied.statusCode == HttpStatus.forbidden, '浏览权限不能读取资料包模板');

    final actorTemplate = await _request(
      baseUrl,
      'GET',
      '/api/v1/admin/profile-packages/actor/template',
      token: adminToken,
    );
    _expect(actorTemplate.statusCode == HttpStatus.ok, '管理员可以下载演员模板');
    _expect(
      NasProfilePackageCodec.decode(
        expectedKind: NasProfilePackageKind.actor,
        bytes: actorTemplate.bytes,
      ).entries.single.fields.containsKey('profileId') == false,
      '演员模板不要求用户填写资料标识',
    );

    final publisherPackage = _zip({
      'mujing-profile-package.txt': utf8.encode('format=1\nkind=publisher\n'),
      'publishers/publisher-001/profile.txt': utf8.encode(
        'displayName=资料发行商\n'
        'originalName=Profile Publisher\n'
        'countryRegion=日本\n'
        'foundedDate=2001-02-03\n',
      ),
      'publishers/publisher-001/image.png': _png,
    });
    final publisherImported = await _import(
      baseUrl,
      'publisher',
      publisherPackage,
      adminToken,
    );
    _expect(_itemStatus(publisherImported) == 'added', '发行商资料和 Logo 可以导入');

    final repeatedPublisher = await _import(
      baseUrl,
      'publisher',
      publisherPackage,
      adminToken,
    );
    _expect(_itemStatus(repeatedPublisher) == 'skipped', '同名发行商重复导入会跳过');

    final publisherNameRepeated = await _import(
      baseUrl,
      'publisher',
      _zip({
        'mujing-profile-package.txt': utf8.encode('format=1\nkind=publisher\n'),
        'publishers/publisher-002/profile.txt': utf8.encode(
          'displayName=资料发行商\n',
        ),
      }),
      adminToken,
    );
    _expect(_itemStatus(publisherNameRepeated) == 'skipped', '不同目录的同名发行商会跳过');

    final actorImported = await _import(
      baseUrl,
      'actor',
      _zip({
        'mujing-profile-package.txt': utf8.encode('format=1\nkind=actor\n'),
        'actors/actor-001/profile.txt': utf8.encode(
          'stageName=资料演员\n'
          'gender=female\n'
          'birthMonth=1990-01\n'
          'publisherNames=资料发行商\n',
        ),
        'actors/actor-001/image.png': _png,
        'actors/actor-002/profile.txt': utf8.encode(
          'stageName=失败演员\n'
          'publisherNames=不存在发行商\n',
        ),
      }),
      adminToken,
    );
    final actorItems = actorImported.json['data']['items'] as List<dynamic>;
    _expect(actorItems[0]['status'] == 'added', '合法演员可以在同包内新增');
    _expect(actorItems[1]['status'] == 'failed', '缺失发行商只使当前演员失败');
    final actors = await _request(baseUrl, 'GET', '/api/v1/actors', token: adminToken);
    final actor = (actors.json['data']['items'] as List<dynamic>).single as Map<String, dynamic>;
    _expect(actor['photoAsset'] != null, '演员导入图片写入受管理资产');
    _expect((actor['publishers'] as List<dynamic>).single['displayName'] == '资料发行商', '演员可以按发行商名称建立关系');

    final repeatedActor = await _import(
      baseUrl,
      'actor',
      _zip({
        'mujing-profile-package.txt': utf8.encode('format=1\nkind=actor\n'),
        'actors/repeated-actor/profile.txt': utf8.encode('stageName=资料演员\n'),
      }),
      adminToken,
    );
    _expect(_itemStatus(repeatedActor) == 'skipped', '同名演员重复导入会跳过');

    final seriesImported = await _import(
      baseUrl,
      'series',
      _zip({
        'mujing-profile-package.txt': utf8.encode('format=1\nkind=series\n'),
        'series/series-001/profile.txt': utf8.encode(
          'displayName=草稿系列\n',
        ),
        'series/series-002/profile.txt': utf8.encode(
          'displayName=关联系列\n'
          'publisherName=资料发行商\n',
        ),
        'series/series-003/profile.txt': utf8.encode(
          'displayName=失败系列\n'
          'publisherName=不存在发行商\n',
        ),
      }),
      adminToken,
    );
    final seriesItems = seriesImported.json['data']['items'] as List<dynamic>;
    _expect(seriesItems[0]['status'] == 'added', '未填写发行商可以新建草稿系列');
    _expect(seriesItems[1]['status'] == 'added', '系列可以关联已存在发行商名称');
    _expect(seriesItems[2]['status'] == 'failed', '缺失发行商只使当前系列失败');

    final repeatedSeries = await _import(
      baseUrl,
      'series',
      _zip({
        'mujing-profile-package.txt': utf8.encode('format=1\nkind=series\n'),
        'series/repeated-series/profile.txt': utf8.encode('displayName=草稿系列\n'),
      }),
      adminToken,
    );
    _expect(_itemStatus(repeatedSeries) == 'skipped', '同名系列重复导入会跳过');

    final exportedPublishers = await _request(
      baseUrl,
      'GET',
      '/api/v1/admin/profile-packages/publisher/export',
      token: adminToken,
    );
    final decodedPublishers = NasProfilePackageCodec.decode(
      expectedKind: NasProfilePackageKind.publisher,
      bytes: exportedPublishers.bytes,
    );
    _expect(
      decodedPublishers.entries.single.fields.containsKey('profileId') == false,
      '导出资料不暴露内部资料标识',
    );
    _expect(decodedPublishers.entries.single.imageBytes != null, '导出包含受管理 Logo');

    final actorCountBeforeInvalidPackage = (actors.json['data']['items'] as List<dynamic>).length;
    final invalidPackage = await _import(
      baseUrl,
      'actor',
      _zip({
        'mujing-profile-package.txt': utf8.encode('format=1\nkind=actor\n'),
        'actors/invalid/profile.txt': utf8.encode('stageName=不会写入\n'),
        'actors/invalid/image.png': const [0, 1, 2, 3],
      }),
      adminToken,
    );
    _expect(invalidPackage.statusCode == HttpStatus.badRequest, '非法图片会使整个资料包拒绝写入');
    final actorsAfterInvalidPackage = await _request(baseUrl, 'GET', '/api/v1/actors', token: adminToken);
    _expect(
      (actorsAfterInvalidPackage.json['data']['items'] as List<dynamic>).length == actorCountBeforeInvalidPackage,
      '异常资料包不会留下部分演员或图片资产',
    );

    final corruptZip = await _import(baseUrl, 'series', const [1, 2, 3], adminToken);
    _expect(corruptZip.statusCode == HttpStatus.badRequest, '损坏 ZIP 被安全拒绝');
  } finally {
    await server.stop();
    await directory.delete(recursive: true);
  }
  stdout.writeln('profile_packages_api_test: PASS');
}

const _png = [137, 80, 78, 71, 13, 10, 26, 10];

List<int> _zip(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive)!;
}

Future<_Response> _import(Uri baseUrl, String kind, List<int> bytes, String token) =>
    _request(
      baseUrl,
      'POST',
      '/api/v1/admin/profile-packages/$kind/import',
      token: token,
      requestBytes: bytes,
      contentType: 'application/zip',
    );

String _itemStatus(_Response response) =>
    (response.json['data']['items'] as List<dynamic>).single['status'] as String;

Future<String> _pair(
  Uri baseUrl,
  String serverId,
  String pairingCode, {
  required bool admin,
}) async {
  final session = await _request(
    baseUrl,
    'POST',
    '/api/v1/pairing/sessions',
    body: {
      'serverId': serverId,
      if (admin) 'requestedScope': 'admin',
    },
  );
  final sessionId = session.json['data']['pairingSessionId'] as String;
  final confirmed = await _request(
    baseUrl,
    'POST',
    '/api/v1/pairing/sessions/$sessionId/confirm',
    body: {'pairingPassword': pairingCode},
  );
  return confirmed.json['data']['accessToken'] as String;
}

Future<_Response> _request(
  Uri baseUrl,
  String method,
  String path, {
  Object? body,
  String? token,
  List<int>? requestBytes,
  String? contentType,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, baseUrl.resolve(path));
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (requestBytes != null) {
      request.headers.contentType = ContentType.parse(contentType!);
      request.add(requestBytes);
    } else if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final bytes = await response.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    final mimeType = response.headers.contentType?.mimeType;
    return _Response(
      response.statusCode,
      bytes,
      mimeType == 'application/json' && bytes.isNotEmpty
          ? jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>
          : const {},
    );
  } finally {
    client.close(force: true);
  }
}

class _Response {
  const _Response(this.statusCode, this.bytes, this.json);

  final int statusCode;
  final List<int> bytes;
  final Map<String, dynamic> json;
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('Assertion failed: $message');
}
