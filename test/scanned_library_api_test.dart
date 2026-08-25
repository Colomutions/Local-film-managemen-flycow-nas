import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('mujing-nas-scanned-api-test-');
  final mediaRoot = Directory('${directory.path}${Platform.pathSeparator}media');
  final video = File('${mediaRoot.path}${Platform.pathSeparator}真人${Platform.pathSeparator}sample.mp4');
  await video.parent.create(recursive: true);
  await video.writeAsBytes(List<int>.generate(8, (index) => index));
  final config = NasConfig(
    bindHost: '127.0.0.1',
    port: 0,
    serverName: 'Test NAS',
    advertiseUrl: null,
    pairingCode: 'test-pairing-code',
    fixtureMediaRelativePath: null,
    mediaRootName: '测试媒体根',
    scanOnStart: true,
    dataDir: '${directory.path}${Platform.pathSeparator}data',
    mediaDir: mediaRoot.path,
    timezone: 'Asia/Shanghai',
  );
  final server = NasHealthServer(config);
  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await _request(base, 'GET', '/api/v1/server-info');
    final token = await _pair(base, (info.json['data'] as Map<String, dynamic>)['serverId'] as String);
    final movies = await _request(base, 'GET', '/api/v1/movies', token: token);
    final item = ((movies.json['data'] as Map<String, dynamic>)['items'] as List<dynamic>).single as Map<String, dynamic>;
    _expect(item['title'] == 'sample', 'API reads scanned SQLite movie, not memory fixture');
    _expect(!jsonEncode(item).contains(mediaRoot.path), 'API does not expose container path');
    final details = await _request(base, 'GET', '/api/v1/movies/${item['id']}', token: token);
    final episode = ((details.json['data'] as Map<String, dynamic>)['episodes'] as List<dynamic>).single as Map<String, dynamic>;
    _expect(episode['isAvailable'] == true, 'scanned episode is available through controlled root');
    _expect(episode['fileSize'] == 8, 'details expose file size but not path');
  } finally {
    await server.stop();
    await directory.delete(recursive: true);
  }
  stdout.writeln('scanned_library_api_test: PASS');
}

Future<String> _pair(Uri base, String serverId) async {
  final session = await _request(base, 'POST', '/api/v1/pairing/sessions', body: {'serverId': serverId});
  final id = (session.json['data'] as Map<String, dynamic>)['pairingSessionId'] as String;
  final confirmed = await _request(base, 'POST', '/api/v1/pairing/sessions/$id/confirm', body: {'pairingPassword': 'test-pairing-code'});
  return confirmed.json['data']['accessToken'] as String;
}

Future<_Response> _request(Uri base, String method, String path, {Object? body, String? token}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, base.resolve(path));
    if (token != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return _Response(response.statusCode, text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>);
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
