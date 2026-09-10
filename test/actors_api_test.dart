import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final dataDirectory =
      await Directory.systemTemp.createTemp('mujing-nas-actors-test-');
  final config = NasConfig(
    bindHost: '127.0.0.1',
    port: 0,
    serverName: 'Test NAS',
    advertiseUrl: null,
    pairingCode: 'test-pairing-code',
    fixtureMediaRelativePath: null,
    mediaRootName: 'test',
    scanOnStart: false,
    dataDir: dataDirectory.path,
    mediaDir: '/not-exposed',
    timezone: 'Asia/Shanghai',
  );
  final server = NasHealthServer(config);

  try {
    await server.start();
    final baseUrl = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await _request(baseUrl, 'GET', '/api/v1/server-info');
    final serverId =
        (info.json['data'] as Map<String, dynamic>)['serverId'] as String;
    final token = await _pairAdmin(baseUrl, serverId, config.pairingCode!);
    final uploadedPhoto = await _request(
      baseUrl,
      'POST',
      '/api/v1/admin/assets/images?purpose=actor_photo',
      token: token,
      requestBytes: const [137, 80, 78, 71, 13, 10, 26, 10],
      contentType: 'image/png',
    );
    _expect(
      uploadedPhoto.statusCode == HttpStatus.created,
      'admin can upload actor photo',
    );
    final photoId = uploadedPhoto.json['data']['id'] as String;
    final publisher = await _request(
      baseUrl,
      'POST',
      '/api/v1/admin/publishers',
      token: token,
      body: {'displayName': '测试发行商'},
    );
    _expect(publisher.statusCode == HttpStatus.created,
        'admin can create publisher entity');
    final publisherId = publisher.json['data']['id'] as String;

    final created = await _request(
      baseUrl,
      'POST',
      '/api/v1/admin/actors',
      token: token,
      body: {
        'stageName': '测试演员',
        'originalName': 'Test Actor',
        'aliases': ['Test-Actor'],
        'gender': 'female',
        'bodyType': '柔弱',
        'publisherIds': [publisherId],
        'photoAssetId': photoId,
      },
    );
    _expect(created.statusCode == HttpStatus.created, 'admin can create actor');
    final actor = (created.json['data'] as Map<String, dynamic>)['actor']
        as Map<String, dynamic>;
    final actorId = actor['id'] as String;
    _expect(actor['movieCount'] == 0, 'new actor has no movie relation');
    _expect(
      (actor['publishers'] as List<dynamic>).single['id'] == publisherId,
      'actor stores publisher entity IDs instead of text',
    );

    final searched = await _request(
      baseUrl,
      'GET',
      '/api/v1/actors?q=test%20actor&gender=female&page=1&pageSize=24',
      token: token,
    );
    final items = (searched.json['data'] as Map<String, dynamic>)['items']
        as List<dynamic>;
    _expect(items.length == 1, 'English search ignores spaces and hyphens');

    final updated = await _request(
      baseUrl,
      'PATCH',
      '/api/v1/admin/actors/$actorId',
      token: token,
      body: {'heightCm': 168, 'birthMonth': '1996-04'},
    );
    _expect(updated.statusCode == HttpStatus.ok, 'admin can update actor');
    _expect(
        updated.json['data']['heightCm'] == 168, 'updated value is returned');
    _expect(
        updated.json['data']['age'] is int, 'age is derived from birth month');

    final archived = await _request(
      baseUrl,
      'POST',
      '/api/v1/admin/actors/$actorId/archive',
      token: token,
      body: const {},
    );
    _expect(archived.statusCode == HttpStatus.ok,
        'actor is archived instead of deleted');
    final visible =
        await _request(baseUrl, 'GET', '/api/v1/actors', token: token);
    _expect(
      ((visible.json['data'] as Map<String, dynamic>)['items'] as List<dynamic>)
          .isEmpty,
      'archived actor is excluded by default',
    );
    final archivedDelete = await _request(
      baseUrl,
      'DELETE',
      '/api/v1/admin/actors/$actorId',
      token: token,
    );
    _expect(archivedDelete.statusCode == HttpStatus.ok,
        'unlinked actor can be hard deleted after archive');
    final afterDelete = await _request(
      baseUrl,
      'GET',
      '/api/v1/actors?includeArchived=true',
      token: token,
    );
    _expect(
      ((afterDelete.json['data'] as Map<String, dynamic>)['items']
              as List<dynamic>)
          .isEmpty,
      'deleted actor is no longer listed even with includeArchived',
    );
    final photoCheck = await _request(
      baseUrl,
      'GET',
      '/api/v1/assets/$photoId',
      token: token,
    );
    _expect(photoCheck.statusCode == HttpStatus.notFound,
        'actor photo asset is removed together with actor');
  } finally {
    await server.stop();
    await dataDirectory.delete(recursive: true);
  }

  stdout.writeln('actors_api_test: PASS');
}

Future<String> _pairAdmin(
    Uri baseUrl, String serverId, String pairingCode) async {
  final session = await _request(
    baseUrl,
    'POST',
    '/api/v1/pairing/sessions',
    body: {'serverId': serverId, 'requestedScope': 'admin'},
  );
  final sessionId = (session.json['data']
      as Map<String, dynamic>)['pairingSessionId'] as String;
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
    if (token != null)
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (requestBytes != null) {
      request.headers.contentType = ContentType.parse(contentType!);
      request.add(requestBytes);
    } else if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final bytes = await response
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    final text = utf8.decode(bytes, allowMalformed: true);
    return _Response(
      response.statusCode,
      text.isEmpty ? const {} : jsonDecode(text) as Map<String, dynamic>,
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
  if (!condition) throw StateError('Assertion failed: $message');
}
