import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('mujing-nas-range-test-');
  final mediaRoot = Directory('${directory.path}${Platform.pathSeparator}media');
  final mediaFile = File(
    '${mediaRoot.path}${Platform.pathSeparator}fixture${Platform.pathSeparator}sample.mp4',
  );
  await mediaFile.parent.create(recursive: true);
  final expectedBytes = List<int>.generate(64, (index) => index);
  await mediaFile.writeAsBytes(expectedBytes);
  final config = NasConfig(
    bindHost: '127.0.0.1',
    port: 0,
    serverName: 'Test NAS',
    advertiseUrl: null,
    pairingCode: 'test-pairing-code',
    fixtureMediaRelativePath: 'fixture/sample.mp4',
    mediaRootName: 'test',
    scanOnStart: true,
    dataDir: '${directory.path}${Platform.pathSeparator}data',
    mediaDir: mediaRoot.path,
    timezone: 'Asia/Shanghai',
    allowSourceRename: true,
  );
  final server = NasHealthServer(config);

  try {
    await server.start();
    final baseUrl = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await _request(baseUrl, 'GET', '/api/v1/server-info');
    final token = await _pairViewer(
      baseUrl,
      (info.json['data'] as Map<String, dynamic>)['serverId'] as String,
      config.pairingCode!,
    );

    final movies = await _request(
      baseUrl,
      'GET',
      '/api/v1/movies',
      token: token,
    );
    final movie = (movies.json['data'] as Map<String, dynamic>)['items'].single
        as Map<String, dynamic>;
    final movieId = movie['id'] as String;
    _expect(movie['playCount'] == 0, 'scanned movie starts with no plays');
    final details = await _request(
      baseUrl,
      'GET',
      '/api/v1/movies/$movieId',
      token: token,
    );
    final episode = ((details.json['data'] as Map<String, dynamic>)['episodes'] as List<dynamic>).single
        as Map<String, dynamic>;
    _expect(episode['isAvailable'] == true, 'configured media file is available');

    final noTokenSession = await _request(baseUrl, 'POST', '/api/v1/playback/sessions');
    _expectError(noTokenSession, HttpStatus.unauthorized, 'authentication_required');
    final playback = await _request(
      baseUrl,
      'POST',
      '/api/v1/playback/sessions',
      token: token,
      body: {'contentId': movieId, 'preferredPlayback': 'direct'},
    );
    _expect(playback.statusCode == HttpStatus.ok, 'viewer creates playback session');
    final playbackData = playback.json['data'] as Map<String, dynamic>;
    final sessionId = playbackData['sessionId'] as String;
    _expect(
      (playbackData['playbackVariants'] as List<dynamic>).single['url'] ==
          '/api/v1/playback/sessions/$sessionId/stream',
      'stream URL is service-relative',
    );

    final full = await _request(
      baseUrl,
      'GET',
      '/api/v1/playback/sessions/$sessionId/stream',
      token: token,
    );
    _expect(full.statusCode == HttpStatus.ok, 'full GET returns 200');
    _expect(full.headers[HttpHeaders.acceptRangesHeader] == 'bytes', 'full GET advertises ranges');
    _expect(full.bytes.toString() == expectedBytes.toString(), 'full GET streams file bytes');

    final started = await _request(
      baseUrl,
      'POST',
      '/api/v1/playback/sessions/$sessionId/started',
      token: token,
    );
    _expect(started.statusCode == HttpStatus.ok, 'formal playback start is accepted');
    final repeatedStarted = await _request(
      baseUrl,
      'POST',
      '/api/v1/playback/sessions/$sessionId/started',
      token: token,
    );
    _expect(repeatedStarted.statusCode == HttpStatus.ok, 'repeated start is idempotent');
    final afterStart = await _request(baseUrl, 'GET', '/api/v1/movies', token: token);
    _expect(
      ((afterStart.json['data'] as Map<String, dynamic>)['items'].single
              as Map<String, dynamic>)['playCount'] ==
          1,
      'formal playback increments the NAS SQLite play count once',
    );

    final headRange = await _request(
      baseUrl,
      'HEAD',
      '/api/v1/playback/sessions/$sessionId/stream',
      token: token,
      range: 'bytes=10-19',
    );
    _expect(headRange.statusCode == HttpStatus.partialContent, 'HEAD range returns 206');
    _expect(headRange.bytes.isEmpty, 'HEAD range has no body');
    _expect(headRange.headers[HttpHeaders.contentRangeHeader] == 'bytes 10-19/64', 'HEAD has Content-Range');
    _expect(headRange.headers[HttpHeaders.contentLengthHeader] == '10', 'HEAD has ranged Content-Length');

    final suffixRange = await _request(
      baseUrl,
      'GET',
      '/api/v1/playback/sessions/$sessionId/stream',
      token: token,
      range: 'bytes=-3',
    );
    _expect(suffixRange.statusCode == HttpStatus.partialContent, 'suffix range returns 206');
    _expect(suffixRange.bytes.toString() == [61, 62, 63].toString(), 'suffix range streams final bytes');

    final invalidRange = await _request(
      baseUrl,
      'GET',
      '/api/v1/playback/sessions/$sessionId/stream',
      token: token,
      range: 'bytes=64-65',
    );
    _expect(invalidRange.statusCode == HttpStatus.requestedRangeNotSatisfiable, 'invalid range returns 416');
    _expect(invalidRange.headers[HttpHeaders.contentRangeHeader] == 'bytes */64', '416 includes file length');

    final progress = await _request(
      baseUrl,
      'PATCH',
      '/api/v1/playback/sessions/$sessionId/progress',
      token: token,
      body: {'positionMs': 45000, 'durationMs': 100000, 'state': 'playing'},
    );
    _expect(progress.statusCode == HttpStatus.ok, 'progress is accepted');
    final resumed = await _request(
      baseUrl,
      'POST',
      '/api/v1/playback/sessions',
      token: token,
      body: {'contentId': movieId},
    );
    _expect(resumed.json['data']['resumePositionMs'] == 45000, 'next session resumes saved position');
    _expect(resumed.json['data']['durationMs'] == 100000, 'next session keeps saved duration');

    final preview = await _request(
      baseUrl,
      'POST',
      '/api/v1/playback/sessions',
      token: token,
      body: {
        'contentId': movieId,
        'episodeId': episode['id'],
        'purpose': 'preview',
      },
    );
    _expect(preview.statusCode == HttpStatus.ok, 'preview creates an isolated NAS stream session');
    final previewData = preview.json['data'] as Map<String, dynamic>;
    _expect(previewData['resumePositionMs'] == 0, 'preview never resumes formal playback state');
    final previewStream = await _request(
      baseUrl,
      'GET',
      previewData['playbackVariants'].single['url'] as String,
      token: token,
      range: 'bytes=0-9',
    );
    _expect(previewStream.statusCode == HttpStatus.partialContent, 'preview uses the NAS Range stream');
    final previewProgress = await _request(
      baseUrl,
      'PATCH',
      '/api/v1/playback/sessions/${previewData['sessionId']}/progress',
      token: token,
      body: {'positionMs': 8, 'durationMs': 100000, 'state': 'playing'},
    );
    _expect(previewProgress.statusCode == HttpStatus.ok, 'preview progress is ignored without failing playback');
    await _request(
      baseUrl,
      'DELETE',
      '/api/v1/playback/sessions/${previewData['sessionId']}',
      token: token,
    );
    final afterPreview = await _request(baseUrl, 'GET', '/api/v1/movies', token: token);
    _expect(
      ((afterPreview.json['data'] as Map<String, dynamic>)['items'].single
              as Map<String, dynamic>)['playCount'] ==
          1,
      'preview never increments playback count',
    );

    final closed = await _request(
      baseUrl,
      'DELETE',
      '/api/v1/playback/sessions/$sessionId',
      token: token,
    );
    _expect(closed.statusCode == HttpStatus.noContent, 'session can be closed');
    final closedStream = await _request(
      baseUrl,
      'GET',
      '/api/v1/playback/sessions/$sessionId/stream',
      token: token,
    );
    _expectError(closedStream, HttpStatus.notFound, 'resource_not_found');

    var pathRejected = false;
    try {
      NasConfig.fromEnvironment({'MUJING_FIXTURE_MEDIA_RELATIVE_PATH': '../outside.mp4'});
    } on ArgumentError {
      pathRejected = true;
    }
    _expect(pathRejected, 'relative media path rejects traversal');

    final adminToken = await _pairAdmin(
      baseUrl,
      (info.json['data'] as Map<String, dynamic>)['serverId'] as String,
      config.pairingCode!,
    );
    final sourceRename = await _request(
      baseUrl,
      'PATCH',
      '/api/v1/admin/episodes/${episode['id']}/source-name',
      token: adminToken,
      body: {'sourceName': 'renamed.mp4'},
    );
    _expect(sourceRename.statusCode == HttpStatus.ok, 'admin can rename a source file in place');
    _expect(sourceRename.json['data']['title'] == 'renamed', 'source rename updates NAS episode title');
    _expect(await File('${mediaFile.parent.path}${Platform.pathSeparator}renamed.mp4').exists(), 'source file is renamed in the same directory');
    _expect(!await mediaFile.exists(), 'original source file name is removed by rename');
    final renamedDetails = await _request(baseUrl, 'GET', '/api/v1/movies/$movieId', token: token);
    _expect(
      ((renamedDetails.json['data'] as Map<String, dynamic>)['episodes'] as List).single['title'] == 'renamed',
      'rename persists updated NAS SQLite episode metadata',
    );
    final extensionRejected = await _request(
      baseUrl,
      'PATCH',
      '/api/v1/admin/episodes/${episode['id']}/source-name',
      token: adminToken,
      body: {'sourceName': 'renamed.mkv'},
    );
    _expectError(extensionRejected, HttpStatus.badRequest, 'invalid_source_name');
  } finally {
    await server.stop();
    await directory.delete(recursive: true);
  }

  stdout.writeln('range_api_test: PASS');
}

Future<String> _pairViewer(Uri baseUrl, String serverId, String pairingCode) async {
  final session = await _request(
    baseUrl,
    'POST',
    '/api/v1/pairing/sessions',
    body: {'serverId': serverId},
  );
  final sessionId = (session.json['data'] as Map<String, dynamic>)['pairingSessionId'] as String;
  final confirmed = await _request(
    baseUrl,
    'POST',
    '/api/v1/pairing/sessions/$sessionId/confirm',
    body: {'pairingPassword': pairingCode},
  );
  return confirmed.json['data']['accessToken'] as String;
}

Future<String> _pairAdmin(Uri baseUrl, String serverId, String pairingCode) async {
  final session = await _request(
    baseUrl,
    'POST',
    '/api/v1/pairing/sessions',
    body: {'serverId': serverId, 'requestedScope': 'admin'},
  );
  final sessionId = (session.json['data'] as Map<String, dynamic>)['pairingSessionId'] as String;
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
  String? range,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, baseUrl.resolve(path));
    if (token != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final bytes = await response.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    final contentType = response.headers.contentType?.mimeType;
    final json = contentType == 'application/json' && bytes.isNotEmpty
        ? jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>
        : <String, dynamic>{};
    final headers = <String, String>{
      for (final name in [
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.contentLengthHeader,
      ])
        if (response.headers.value(name) case final value?) name: value,
    };
    return _Response(response.statusCode, headers, bytes, json);
  } finally {
    client.close(force: true);
  }
}

class _Response {
  const _Response(this.statusCode, this.headers, this.bytes, this.json);

  final int statusCode;
  final Map<String, String> headers;
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
