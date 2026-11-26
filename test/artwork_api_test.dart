import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final ffmpeg = Platform.environment['MUJING_TEST_FFMPEG'];
  final directory =
      await Directory.systemTemp.createTemp('mujing-nas-artwork-test-');
  final mediaRoot =
      Directory('${directory.path}${Platform.pathSeparator}media');
  final video = File('${mediaRoot.path}${Platform.pathSeparator}sample.mp4');
  await video.parent.create(recursive: true);
  if (ffmpeg == null) {
    await video.writeAsBytes(List<int>.generate(12, (index) => index));
  }
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
  var server = NasHealthServer(config);

  try {
    if (ffmpeg != null) {
      final generated = await Process.run(ffmpeg, [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=1280x720:rate=12',
        '-t',
        '3',
        '-c:v',
        'mpeg4',
        video.path,
      ]);
      _expect(
          generated.exitCode == 0, 'creates sample video: ${generated.stderr}');
    }
    await server.start();
    var base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await _request(base, 'GET', '/api/v1/server-info');
    final serverId =
        (info.json['data'] as Map<String, dynamic>)['serverId'] as String;
    final viewerToken = await _pair(base, serverId);
    final adminToken = await _pair(base, serverId, scope: 'admin');
    final movies =
        await _request(base, 'GET', '/api/v1/movies', token: viewerToken);
    final movie = ((movies.json['data'] as Map<String, dynamic>)['items']
            as List<dynamic>)
        .single as Map<String, dynamic>;
    final posterPath = '/api/v1/admin/movies/${movie['id']}/poster';

    final noToken = await _request(base, 'POST', posterPath,
        bytes: _pngOne, contentType: 'image/png');
    _expectError(noToken, HttpStatus.unauthorized, 'authentication_required');
    final viewerUpload = await _request(base, 'POST', posterPath,
        token: viewerToken, bytes: _pngOne, contentType: 'image/png');
    _expectError(viewerUpload, HttpStatus.forbidden, 'insufficient_scope');
    final invalidPayload = await _request(base, 'POST', posterPath,
        token: adminToken, bytes: [1, 2, 3], contentType: 'image/png');
    _expectError(invalidPayload, HttpStatus.badRequest, 'invalid_request');
    final invalidMime = await _request(base, 'POST', posterPath,
        token: adminToken,
        bytes: _pngOne,
        contentType: 'application/octet-stream');
    _expectError(invalidMime, HttpStatus.badRequest, 'invalid_request');
    final oversized = await _request(
      base,
      'POST',
      posterPath,
      token: adminToken,
      bytes: List<int>.filled(NasArtworkService.maxPosterBytes + 1, 0),
      contentType: 'image/png',
    );
    _expectError(oversized, HttpStatus.badRequest, 'invalid_request');

    final uploaded = await _request(base, 'POST', posterPath,
        token: adminToken, bytes: _pngOne, contentType: 'image/png');
    _expect(uploaded.statusCode == HttpStatus.ok, 'admin uploads poster');
    _expect(
        uploaded.json['data']['posterUrl'] ==
            '/api/v1/assets/posters/${movie['id']}',
        'upload returns relative poster URL');
    final firstPoster = await _request(
        base, 'GET', '/api/v1/assets/posters/${movie['id']}',
        token: viewerToken);
    _expect(firstPoster.statusCode == HttpStatus.ok,
        'viewer reads uploaded poster');
    _expect(
        firstPoster.contentType == 'image/png', 'poster preserves image MIME');
    _expect(firstPoster.bytes.toString() == _pngOne.toString(),
        'poster returns uploaded bytes');

    final carouselUpload = await _request(
      base,
      'POST',
      '/api/v1/admin/movies/${movie['id']}/carousel-images',
      token: adminToken,
      bytes: _pngOne,
      contentType: 'image/png',
    );
    _expect(carouselUpload.statusCode == HttpStatus.created,
        'admin uploads carousel image');
    final carouselUrl =
        (carouselUpload.json['data'] as Map<String, dynamic>)['url'] as String;
    final carousel =
        await _request(base, 'GET', carouselUrl, token: viewerToken);
    _expect(carousel.statusCode == HttpStatus.ok,
        'viewer reads carousel image for UUID movie id');
    _expect(carousel.bytes.toString() == _pngOne.toString(),
        'carousel returns uploaded bytes');

    final movieDetail = await _request(
        base, 'GET', '/api/v1/movies/${movie['id']}',
        token: viewerToken);
    final episodeId =
        (movieDetail.json['data']['episodes'] as List).single['id'] as String;
    final previewPath =
        '/api/v1/admin/movies/${movie['id']}/episodes/$episodeId/video-poster';
    _expectError(
        await _request(base, 'GET', '$previewPath?startMs=0',
            token: viewerToken),
        HttpStatus.forbidden,
        'insufficient_scope');
    _expectError(
        await _request(base, 'GET', '$previewPath?startMs=0&durationMs=9000',
            token: adminToken),
        HttpStatus.badRequest,
        'invalid_request');
    if (ffmpeg != null) {
      final frame = await _request(base, 'GET', '$previewPath?startMs=500',
          token: adminToken);
      _expect(frame.statusCode == 200 && frame.contentType == 'image/png',
          'admin can preview source frame: ${frame.json}');
      final animation = await _request(
        base,
        'GET',
        '$previewPath?startMs=500&durationMs=2000&x=400&y=0&width=480&height=720',
        token: adminToken,
      );
      _expect(
          animation.statusCode == 200 && animation.contentType == 'image/webp',
          'admin can render animated poster: ${animation.json}');
      final container = latin1.decode(animation.bytes);
      _expect(
          'ANMF'.allMatches(container).length > 1, 'WebP has multiple frames');
      final canvas = container.indexOf('VP8X');
      _expect(canvas == 12, 'animated WebP has extended canvas');
      int u24(int index) =>
          animation.bytes[index] |
          (animation.bytes[index + 1] << 8) |
          (animation.bytes[index + 2] << 16);
      _expect(u24(canvas + 12) == 599 && u24(canvas + 15) == 899,
          'animated WebP canvas is 600 by 900');
      final animatedUpload = await _request(base, 'POST', posterPath,
          token: adminToken, bytes: animation.bytes, contentType: 'image/webp');
      _expect(animatedUpload.statusCode == 200, 'admin saves animated poster');
      final saved = await _request(
          base, 'GET', '/api/v1/assets/posters/${movie['id']}',
          token: viewerToken);
      _expect(
          saved.contentType == 'image/webp' &&
              saved.bytes.toString() == animation.bytes.toString(),
          'saved poster keeps animation bytes');
    }
    final playback = await _request(base, 'POST', '/api/v1/playback/sessions',
        token: viewerToken,
        body: {'contentId': movie['id'], 'episodeId': episodeId});
    final playbackPath =
        '/api/v1/playback/sessions/${playback.json['data']['sessionId']}';
    final screenshotPath = '$playbackPath/screenshot';
    Future<_Response> screenshot(String token) =>
        _request(base, 'POST', screenshotPath,
            token: token, bytes: _pngTwo, contentType: 'image/png');
    _expectError(await screenshot(viewerToken), HttpStatus.notFound,
        'resource_not_found');
    final stream =
        await _request(base, 'GET', '$playbackPath/stream', token: viewerToken);
    _expect(stream.statusCode == HttpStatus.ok, 'viewer requests media stream');
    final started = await _request(base, 'POST', '$playbackPath/started',
        token: viewerToken);
    _expect(started.statusCode == HttpStatus.ok, 'viewer starts playback');
    _expectError(await screenshot(adminToken), HttpStatus.notFound,
        'resource_not_found');
    final added = await screenshot(viewerToken);
    _expect(added.statusCode == HttpStatus.created,
        'viewer can add image for owned playback');
    final screenshotUrl = added.json['data']['url'] as String;
    final readScreenshot =
        await _request(base, 'GET', screenshotUrl, token: viewerToken);
    _expect(readScreenshot.bytes.toString() == _pngTwo.toString(),
        'saved screenshot is readable');
    final withScreenshot = await _request(
        base, 'GET', '/api/v1/movies/${movie['id']}',
        token: viewerToken);
    _expect(
        (withScreenshot.json['data']['carouselImages'] as List)
            .any((image) => image['url'] == screenshotUrl),
        'movie detail contains new screenshot');
    await _request(base, 'DELETE', playbackPath, token: viewerToken);
    _expectError(await screenshot(viewerToken), HttpStatus.notFound,
        'resource_not_found');

    final replaced = await _request(base, 'POST', posterPath,
        token: adminToken, bytes: _pngTwo, contentType: 'image/png');
    _expect(replaced.statusCode == HttpStatus.ok, 'admin replaces poster');
    final replacement = await _request(
        base, 'HEAD', '/api/v1/assets/posters/${movie['id']}',
        token: viewerToken);
    _expect(replacement.statusCode == HttpStatus.ok,
        'viewer HEADs replaced poster');
    _expect(replacement.contentLength == _pngTwo.length,
        'HEAD returns replacement length');
    final detail = await _request(base, 'GET', '/api/v1/movies/${movie['id']}',
        token: viewerToken);
    _expect(
        detail.json['data']['posterUrl'] ==
            '/api/v1/assets/posters/${movie['id']}',
        'details keep relative poster URL');
    _expect(!jsonEncode(detail.json).contains(directory.path),
        'poster DTO hides data path');

    await server.stop();
    server = NasHealthServer(config);
    await server.start();
    base = Uri.parse('http://127.0.0.1:${server.port}');
    final persistedPoster = await _request(
        base, 'GET', '/api/v1/assets/posters/${movie['id']}',
        token: viewerToken);
    _expect(persistedPoster.statusCode == HttpStatus.ok,
        'poster survives server restart');
    _expect(persistedPoster.bytes.toString() == _pngTwo.toString(),
        'replacement survives restart');
  } finally {
    await server.stop();
    await directory.delete(recursive: true);
  }

  stdout.writeln('artwork_api_test: PASS');
}

final _pngOne = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL8DwAAAABJRU5ErkJggg==');
final _pngTwo = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9JbMcAAAAASUVORK5CYII=');

Future<String> _pair(Uri base, String serverId, {String? scope}) async {
  final session = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions',
    body: {'serverId': serverId, if (scope != null) 'requestedScope': scope},
  );
  final sessionId = (session.json['data']
      as Map<String, dynamic>)['pairingSessionId'] as String;
  final confirmed = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions/$sessionId/confirm',
    body: {'pairingPassword': 'test-pairing-code'},
  );
  return (confirmed.json['data'] as Map<String, dynamic>)['accessToken']
      as String;
}

Future<_Response> _request(
  Uri base,
  String method,
  String path, {
  Object? body,
  List<int>? bytes,
  String? contentType,
  String? token,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, base.resolve(path));
    if (token != null)
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    } else if (bytes != null) {
      request.headers.contentType = ContentType.parse(contentType!);
      request.add(bytes);
    }
    final response = await request.close();
    final responseBytes = await response
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    final text = utf8.decode(responseBytes, allowMalformed: true);
    return _Response(
      response.statusCode,
      response.headers.contentType?.mimeType,
      response.headers.contentLength,
      responseBytes,
      response.headers.contentType?.mimeType == 'application/json' &&
              text.isNotEmpty
          ? jsonDecode(text) as Map<String, dynamic>
          : <String, dynamic>{},
    );
  } finally {
    client.close(force: true);
  }
}

class _Response {
  const _Response(this.statusCode, this.contentType, this.contentLength,
      this.bytes, this.json);
  final int statusCode;
  final String? contentType;
  final int contentLength;
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
