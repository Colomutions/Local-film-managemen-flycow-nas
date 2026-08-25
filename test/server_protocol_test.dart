import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final dataDirectory = await Directory.systemTemp.createTemp('mujing-nas-test-');
  final config = NasConfig(
    bindHost: '127.0.0.1',
    port: 0,
    serverName: 'Test NAS',
    advertiseUrl: 'http://192.168.1.20:48291',
    pairingCode: 'test-pairing-code',
    fixtureMediaRelativePath: null,
    mediaRootName: 'test',
    scanOnStart: false,
    dataDir: dataDirectory.path,
    mediaDir: '/unused-media',
    timezone: 'Asia/Shanghai',
  );
  var server = NasHealthServer(config);

  try {
    await server.start();
    final baseUrl = Uri.parse('http://127.0.0.1:${server.port}');

    final health = await _request(baseUrl, 'GET', '/health');
    _expect(health.statusCode == HttpStatus.ok, 'GET /health is 200');
    _expect(health.json['data']['status'] == 'ok', 'health reports ok');
    _expect(!jsonEncode(health.json).contains(dataDirectory.path), 'health hides paths');
    _expect(!jsonEncode(health.json).contains(config.pairingCode!), 'health hides pairing code');

    final info = await _request(baseUrl, 'GET', '/api/v1/server-info');
    final infoData = info.json['data'] as Map<String, dynamic>;
    final serverId = infoData['serverId'] as String;
    _expect(info.statusCode == HttpStatus.ok, 'server-info is 200');
    _expect(serverId.isNotEmpty, 'server-info has a serverId');
    _expect(infoData['apiVersion'] == '1.0', 'server-info is Android 1.x compatible');
    _expect(infoData['capabilities']['movies'] == true, 'server-info declares movie capability');
    _expect(infoData['connection']['endpoint'] == config.advertiseUrl, 'endpoint uses explicit advertiseUrl');
    _expect(!jsonEncode(info.json).contains(dataDirectory.path), 'server-info hides paths');

    final invalidSession = await _request(
      baseUrl,
      'POST',
      '/api/v1/pairing/sessions',
      body: {'serverId': 'wrong-server'},
    );
    _expectError(invalidSession, HttpStatus.badRequest, 'invalid_request');

    final failedSession = await _newSession(baseUrl, serverId);
    final failedConfirm = await _request(
      baseUrl,
      'POST',
      '/api/v1/pairing/sessions/$failedSession/confirm',
      body: {'pairingPassword': 'wrong-code'},
    );
    _expectError(failedConfirm, HttpStatus.unauthorized, 'pairing_failed');

    final viewerSession = await _newSession(baseUrl, serverId);
    final viewerConfirm = await _request(
      baseUrl,
      'POST',
      '/api/v1/pairing/sessions/$viewerSession/confirm',
      body: {'pairingPassword': config.pairingCode},
    );
    _expect(viewerConfirm.statusCode == HttpStatus.ok, 'viewer pairing succeeds');
    _expect(viewerConfirm.json['data']['scope'] == 'viewer', 'Android-compatible pairing defaults to viewer');
    final viewerToken = viewerConfirm.json['data']['accessToken'] as String;

    final unauthenticated = await _request(baseUrl, 'GET', '/api/v1/future-route');
    _expectError(unauthenticated, HttpStatus.unauthorized, 'authentication_required');
    final authenticated = await _request(baseUrl, 'GET', '/api/v1/future-route', token: viewerToken);
    _expectError(authenticated, HttpStatus.notFound, 'resource_not_found');

    final adminSession = await _newSession(baseUrl, serverId, scope: 'admin');
    final adminConfirm = await _request(
      baseUrl,
      'POST',
      '/api/v1/pairing/sessions/$adminSession/confirm',
      body: {'pairingPassword': config.pairingCode},
    );
    _expect(adminConfirm.statusCode == HttpStatus.ok, 'admin pairing succeeds');
    _expect(adminConfirm.json['data']['scope'] == 'admin', 'admin scope is explicit');
    final adminToken = adminConfirm.json['data']['accessToken'] as String;

    final viewerAdminRoute = await _request(baseUrl, 'GET', '/api/v1/admin/future-route', token: viewerToken);
    _expectError(viewerAdminRoute, HttpStatus.forbidden, 'insufficient_scope');
    final adminRoute = await _request(baseUrl, 'GET', '/api/v1/admin/future-route', token: adminToken);
    _expectError(adminRoute, HttpStatus.notFound, 'resource_not_found');

    await server.stop();
    server = NasHealthServer(config);
    await server.start();
    final restartedBaseUrl = Uri.parse('http://127.0.0.1:${server.port}');
    final restartedInfo = await _request(restartedBaseUrl, 'GET', '/api/v1/server-info');
    _expect(restartedInfo.json['data']['serverId'] == serverId, 'serverId survives restart');
    final persistedToken = await _request(restartedBaseUrl, 'GET', '/api/v1/future-route', token: viewerToken);
    _expectError(persistedToken, HttpStatus.notFound, 'resource_not_found');

    final stateFile = File('${dataDirectory.path}${Platform.pathSeparator}state${Platform.pathSeparator}server.json');
    final stateContents = await stateFile.readAsString();
    _expect(!stateContents.contains(viewerToken), 'persistent state does not contain viewer token');
    _expect(!stateContents.contains(config.pairingCode!), 'persistent state does not contain pairing code');

    _expect(NasConfig.fromEnvironment(const {}).advertiseUrl == null, 'advertiseUrl can be unset');
    var dockerAddressRejected = false;
    try {
      NasConfig.fromEnvironment({'MUJING_ADVERTISE_URL': 'http://172.17.0.2:48291'});
    } on ArgumentError {
      dockerAddressRejected = true;
    }
    _expect(dockerAddressRejected, 'Docker bridge advertiseUrl is rejected');
  } finally {
    await server.stop();
    await dataDirectory.delete(recursive: true);
  }

  stdout.writeln('server_protocol_test: PASS');
}

Future<String> _newSession(Uri baseUrl, String serverId, {String? scope}) async {
  final response = await _request(
    baseUrl,
    'POST',
    '/api/v1/pairing/sessions',
    body: {'serverId': serverId, if (scope != null) 'requestedScope': scope},
  );
  _expect(response.statusCode == HttpStatus.ok, 'pairing session is created');
  return response.json['data']['pairingSessionId'] as String;
}

Future<_Response> _request(Uri baseUrl, String method, String path, {Object? body, String? token}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, baseUrl.resolve(path));
    if (token != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    final json = text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
    return _Response(response.statusCode, json);
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
