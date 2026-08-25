import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final dataDirectory = await Directory.systemTemp.createTemp('mujing-nas-library-test-');
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
    final serverInfo = await _request(baseUrl, 'GET', '/api/v1/server-info');
    final token = await _pairViewer(
      baseUrl,
      (serverInfo.json['data'] as Map<String, dynamic>)['serverId'] as String,
      config.pairingCode!,
    );

    final noToken = await _request(baseUrl, 'GET', '/api/v1/movies');
    _expectError(noToken, HttpStatus.unauthorized, 'authentication_required');

    final movies = await _request(baseUrl, 'GET', '/api/v1/movies', token: token);
    _expect(movies.statusCode == HttpStatus.ok, 'viewer can list movies');
    final movie = ((movies.json['data'] as Map<String, dynamic>)['items'] as List<dynamic>).single
        as Map<String, dynamic>;
    _expect(movie['id'] == NasFixtureLibrary.movieId, 'summary has stable service-local id');
    _expect(movie['posterUrl'] == '/api/v1/assets/posters/${NasFixtureLibrary.movieId}', 'poster URL is relative');
    _expect(movie['category'] is Map<String, dynamic>, 'summary has nullable-compatible category DTO');
    _expect(movie['tagPaths'] is List<dynamic>, 'summary has tag paths');
    _expect(!jsonEncode(movie).contains(config.mediaDir), 'summary does not expose a media path');

    final filtered = await _request(baseUrl, 'GET', '/api/v1/movies?query=不存在', token: token);
    _expect(((filtered.json['data'] as Map<String, dynamic>)['items'] as List<dynamic>).isEmpty, 'query filters fixture results');

    final details = await _request(baseUrl, 'GET', '/api/v1/movies/${NasFixtureLibrary.movieId}', token: token);
    _expect(details.statusCode == HttpStatus.ok, 'viewer can read movie details');
    final detailsData = details.json['data'] as Map<String, dynamic>;
    final episode = (detailsData['episodes'] as List<dynamic>).single as Map<String, dynamic>;
    _expect(episode['isAvailable'] == false, 'fixture has no real media file');
    _expect(!jsonEncode(detailsData).contains(config.mediaDir), 'details do not expose a media path');

    final tagPaths = await _request(baseUrl, 'GET', '/api/v1/tag-paths', token: token);
    _expect(tagPaths.statusCode == HttpStatus.ok, 'viewer can read tag paths');
    _expect(((tagPaths.json['data'] as Map<String, dynamic>)['items'] as List<dynamic>).isNotEmpty, 'tag path list is nonempty');

    final poster = await _request(
      baseUrl,
      'GET',
      '/api/v1/assets/posters/${NasFixtureLibrary.movieId}',
      token: token,
    );
    _expect(poster.statusCode == HttpStatus.ok, 'viewer can download poster');
    _expect(poster.contentType == 'image/png', 'poster has image MIME type');
    _expect(poster.bytes.isNotEmpty, 'poster has image bytes');
    final posterHead = await _request(
      baseUrl,
      'HEAD',
      '/api/v1/assets/posters/${NasFixtureLibrary.movieId}',
      token: token,
    );
    _expect(posterHead.statusCode == HttpStatus.ok, 'viewer can HEAD poster');
    _expect(posterHead.contentLength == poster.bytes.length, 'HEAD preserves poster Content-Length');

    final missingMovie = await _request(baseUrl, 'GET', '/api/v1/movies/missing', token: token);
    _expectError(missingMovie, HttpStatus.notFound, 'resource_not_found');
    final missingPoster = await _request(baseUrl, 'GET', '/api/v1/assets/posters/missing', token: token);
    _expectError(missingPoster, HttpStatus.notFound, 'resource_not_found');

    for (final path in const ['/api/v1/favorites', '/api/v1/history']) {
      final response = await _request(baseUrl, 'GET', path, token: token);
      _expect(response.statusCode == HttpStatus.ok, '$path is Android-compatible');
      _expect(((response.json['data'] as Map<String, dynamic>)['items'] as List<dynamic>).isEmpty, '$path is empty until task G');
    }
  } finally {
    await server.stop();
    await dataDirectory.delete(recursive: true);
  }

  stdout.writeln('library_api_test: PASS');
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
  _expect(confirmed.json['data']['scope'] == 'viewer', 'pairing defaults to viewer');
  return confirmed.json['data']['accessToken'] as String;
}

Future<_Response> _request(
  Uri baseUrl,
  String method,
  String path, {
  Object? body,
  String? token,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, baseUrl.resolve(path));
    if (token != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final bytes = await response.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    final text = utf8.decode(bytes, allowMalformed: true);
    final json = response.headers.contentType?.mimeType == 'application/json' && text.isNotEmpty
        ? jsonDecode(text) as Map<String, dynamic>
        : <String, dynamic>{};
    return _Response(
      response.statusCode,
      response.headers.contentLength,
      response.headers.contentType?.mimeType,
      bytes,
      json,
    );
  } finally {
    client.close(force: true);
  }
}

class _Response {
  const _Response(this.statusCode, this.contentLength, this.contentType, this.bytes, this.json);

  final int statusCode;
  final int contentLength;
  final String? contentType;
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
