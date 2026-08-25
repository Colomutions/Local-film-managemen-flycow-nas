import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-nas-admin-api-test-');
  final mediaRoot =
      Directory('${directory.path}${Platform.pathSeparator}media');
  final video = File(
      '${mediaRoot.path}${Platform.pathSeparator}Movies${Platform.pathSeparator}sample.mp4');
  await video.parent.create(recursive: true);
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
    dataDir: '${directory.path}${Platform.pathSeparator}data',
    mediaDir: mediaRoot.path,
    timezone: 'Asia/Shanghai',
  );
  final server = NasHealthServer(config);

  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final serverInfo = await _request(base, 'GET', '/api/v1/server-info');
    final serverId =
        (serverInfo.json['data'] as Map<String, dynamic>)['serverId'] as String;
    final viewerToken = await _pair(base, serverId);
    final adminToken = await _pair(base, serverId, requestedScope: 'admin');

    final unauthenticatedRoots =
        await _request(base, 'GET', '/api/v1/admin/media-roots');
    _expectError(unauthenticatedRoots, HttpStatus.unauthorized,
        'authentication_required');
    final viewerRoots = await _request(
      base,
      'GET',
      '/api/v1/admin/media-roots',
      token: viewerToken,
    );
    _expectError(viewerRoots, HttpStatus.forbidden, 'insufficient_scope');

    final roots = await _request(
      base,
      'GET',
      '/api/v1/admin/media-roots',
      token: adminToken,
    );
    _expect(roots.statusCode == HttpStatus.ok, 'admin can list media roots');
    final root =
        ((roots.json['data'] as Map<String, dynamic>)['items'] as List<dynamic>)
            .single as Map<String, dynamic>;
    final rootId = root['id'] as String;
    _expect(root['name'] == '测试媒体根', 'root keeps its configured display name');
    _expect(root['readOnly'] == true, 'media root is reported as read-only');
    _expect(
        root['lastScannedAt'] == null, 'unscanned root has no scan timestamp');
    _expect(!jsonEncode(root).contains(mediaRoot.path),
        'media root response hides container path');

    final invalidScan = await _request(
      base,
      'POST',
      '/api/v1/admin/scan-jobs',
      token: adminToken,
      body: {'mediaRootId': 'not-a-media-root'},
    );
    _expectError(invalidScan, HttpStatus.badRequest, 'invalid_request');
    final viewerScan = await _request(
      base,
      'POST',
      '/api/v1/admin/scan-jobs',
      token: viewerToken,
      body: {'mediaRootId': rootId},
    );
    _expectError(viewerScan, HttpStatus.forbidden, 'insufficient_scope');

    final created = await _request(
      base,
      'POST',
      '/api/v1/admin/scan-jobs',
      token: adminToken,
      body: {'mediaRootId': rootId},
    );
    _expect(created.statusCode == HttpStatus.accepted,
        'admin scan job is accepted');
    final jobId =
        (created.json['data'] as Map<String, dynamic>)['id'] as String;
    final finished = await _waitForFinishedJob(base, jobId, adminToken);
    _expect(finished['status'] == 'succeeded', 'scan job succeeds');
    _expect(finished['scannedFiles'] == 1, 'scan job reports scanned files');
    _expect(finished['availableEpisodes'] == 1,
        'scan job reports available episodes');
    _expect(!jsonEncode(finished).contains(mediaRoot.path),
        'scan job hides container path');

    final missingJob = await _request(
      base,
      'GET',
      '/api/v1/admin/scan-jobs/missing',
      token: adminToken,
    );
    _expectError(missingJob, HttpStatus.notFound, 'resource_not_found');
    final movies =
        await _request(base, 'GET', '/api/v1/movies', token: viewerToken);
    final movie = ((movies.json['data'] as Map<String, dynamic>)['items']
            as List<dynamic>)
        .single as Map<String, dynamic>;
    _expect(movie['title'] == 'sample',
        'viewer sees the movie scanned by the admin job');
    _expect(!jsonEncode(movie).contains(mediaRoot.path),
        'viewer movie response hides container path');
  } finally {
    await server.stop();
    await directory.delete(recursive: true);
  }

  stdout.writeln('admin_api_test: PASS');
}

Future<String> _pair(Uri base, String serverId,
    {String? requestedScope}) async {
  final session = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions',
    body: {
      'serverId': serverId,
      if (requestedScope != null) 'requestedScope': requestedScope,
    },
  );
  final sessionId = (session.json['data']
      as Map<String, dynamic>)['pairingSessionId'] as String;
  final confirmed = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions/$sessionId/confirm',
    body: {'pairingPassword': 'test-pairing-code'},
  );
  _expect(confirmed.statusCode == HttpStatus.ok, 'pairing succeeds');
  return (confirmed.json['data'] as Map<String, dynamic>)['accessToken']
      as String;
}

Future<Map<String, dynamic>> _waitForFinishedJob(
    Uri base, String jobId, String token) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    final response = await _request(
      base,
      'GET',
      '/api/v1/admin/scan-jobs/$jobId',
      token: token,
    );
    _expect(response.statusCode == HttpStatus.ok, 'admin can read scan job');
    final job = response.json['data'] as Map<String, dynamic>;
    if (job['status'] == 'succeeded' || job['status'] == 'failed') return job;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Scan job did not finish in time.');
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
    if (token != null)
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
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
  _expect(response.statusCode == statusCode, 'response status is $statusCode');
  _expect(response.json['error']['code'] == code, 'error code is $code');
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('Assertion failed: $message');
}
