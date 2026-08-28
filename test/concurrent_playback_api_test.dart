import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';
import '../lib/src/persistent_state.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-nas-concurrency-test-');
  final mediaRoot = Directory('${directory.path}${Platform.pathSeparator}media');
  final mediaFile = File(
    '${mediaRoot.path}${Platform.pathSeparator}fixture${Platform.pathSeparator}sample.mp4',
  );
  final expectedBytes =
      List<int>.generate(512 * 1024, (index) => index % 251, growable: false);
  await mediaFile.parent.create(recursive: true);
  await mediaFile.writeAsBytes(expectedBytes);
  final config = NasConfig(
    bindHost: '127.0.0.1',
    port: 0,
    serverName: 'Concurrent Test NAS',
    advertiseUrl: null,
    pairingCode: 'test-pairing-code',
    fixtureMediaRelativePath: 'fixture/sample.mp4',
    mediaRootName: '测试媒体根',
    scanOnStart: false,
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

    final tokens = await _pairThreeViewersConcurrently(base, serverId);
    final persisted = await NasPersistentStateStore(config.dataDir).load();
    _expect(
      persisted?.tokens.length == 3,
      'all concurrently confirmed viewer tokens are persisted',
    );
    final sessions = await Future.wait(tokens.map(
      (token) async {
        final response = await _request(
          base,
          'POST',
          '/api/v1/playback/sessions',
          token: token,
          body: {'contentId': NasFixtureLibrary.movieId},
        );
        _expect(response.statusCode == HttpStatus.ok,
            'each viewer creates its own playback session');
        return (response.json['data'] as Map<String, dynamic>)['sessionId']
            as String;
      },
    ));

    const rangeLength = 64 * 1024;
    final requests = <Future<_Response>>[
      for (var index = 0; index < 3; index++)
        _request(
          base,
          'GET',
          '/api/v1/playback/sessions/${sessions[index]}/stream',
          token: tokens[index],
          range:
              'bytes=${4096 + index * rangeLength}-${4096 + index * rangeLength + rangeLength - 1}',
        ),
      for (var index = 0; index < 3; index++) _request(base, 'GET', '/health'),
    ];
    final responses = await Future.wait(requests);
    for (var index = 0; index < 3; index++) {
      final start = 4096 + index * rangeLength;
      final response = responses[index];
      _expect(response.statusCode == HttpStatus.partialContent,
          'parallel stream $index returns 206');
      _expect(response.bytes.length == rangeLength,
          'parallel stream $index returns its complete range');
      _expect(
        response.bytes.toString() ==
            expectedBytes.sublist(start, start + rangeLength).toString(),
        'parallel stream $index returns only its requested bytes',
      );
    }
    for (var index = 3; index < responses.length; index++) {
      _expect(responses[index].statusCode == HttpStatus.ok,
          'health remains responsive during three streams');
    }

    final crossDevice = await _request(
      base,
      'GET',
      '/api/v1/playback/sessions/${sessions.first}/stream',
      token: tokens[1],
      range: 'bytes=0-9',
    );
    _expectError(crossDevice, HttpStatus.notFound, 'resource_not_found');
  } finally {
    await server.stop();
    await directory.delete(recursive: true);
  }

  stdout.writeln('concurrent_playback_api_test: PASS');
}

Future<List<String>> _pairThreeViewersConcurrently(Uri base, String serverId) async {
  final sessions = await Future.wait(List<Future<String>>.generate(
    3,
    (_) async {
      final response = await _request(
        base,
        'POST',
        '/api/v1/pairing/sessions',
        body: {'serverId': serverId},
      );
      _expect(response.statusCode == HttpStatus.ok, 'pairing session is created');
      return (response.json['data'] as Map<String, dynamic>)['pairingSessionId']
          as String;
    },
  ));
  return Future.wait(sessions.map(
    (sessionId) async {
      final response = await _request(
        base,
        'POST',
        '/api/v1/pairing/sessions/$sessionId/confirm',
        body: {'pairingPassword': 'test-pairing-code'},
      );
      _expect(response.statusCode == HttpStatus.ok,
          'concurrent viewer confirmation succeeds');
      return (response.json['data'] as Map<String, dynamic>)['accessToken']
          as String;
    },
  ));
}

Future<_Response> _request(
  Uri base,
  String method,
  String path, {
  Object? body,
  String? token,
  String? range,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, base.resolve(path));
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    final contentType = response.headers.contentType?.mimeType;
    return _Response(
      response.statusCode,
      bytes,
      contentType == 'application/json' && bytes.isNotEmpty
          ? jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>
          : <String, dynamic>{},
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

void _expectError(_Response response, int statusCode, String code) {
  _expect(response.statusCode == statusCode, 'response status is $statusCode');
  _expect(response.json['error']['code'] == code, 'error code is $code');
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('Assertion failed: $message');
}
