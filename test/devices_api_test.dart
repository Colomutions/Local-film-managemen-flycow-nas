import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-nas-devices-api-test-');
  final server = NasHealthServer(
    NasConfig(
      bindHost: '127.0.0.1',
      port: 0,
      serverName: 'Test NAS',
      advertiseUrl: null,
      pairingCode: 'test-pairing-code',
      fixtureMediaRelativePath: null,
      mediaRootName: '测试媒体根',
      scanOnStart: false,
      dataDir: '${directory.path}${Platform.pathSeparator}data',
      mediaDir: '${directory.path}${Platform.pathSeparator}media',
      timezone: 'Asia/Shanghai',
    ),
  );

  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final serverInfo = await _request(base, 'GET', '/api/v1/server-info');
    final serverId =
        (serverInfo.json['data'] as Map<String, dynamic>)['serverId'] as String;
    final viewer = await _pair(base, serverId);
    final admin = await _pair(base, serverId, requestedScope: 'admin');

    final unauthenticatedList =
        await _request(base, 'GET', '/api/v1/admin/devices');
    _expectError(unauthenticatedList, HttpStatus.unauthorized,
        'authentication_required');
    final viewerList = await _request(
      base,
      'GET',
      '/api/v1/admin/devices',
      token: viewer.accessToken,
    );
    _expectError(viewerList, HttpStatus.forbidden, 'insufficient_scope');

    final devices = await _request(
      base,
      'GET',
      '/api/v1/admin/devices',
      token: admin.accessToken,
    );
    _expect(
        devices.statusCode == HttpStatus.ok, 'admin can list paired devices');
    final items = ((devices.json['data'] as Map<String, dynamic>)['items']
            as List<dynamic>)
        .cast<Map<String, dynamic>>();
    _expect(items.length == 2, 'each paired device is listed once');
    _expect(
      items.every((item) =>
          item.keys
              .toSet()
              .containsAll(const {'deviceId', 'scope', 'expiresAt'}) &&
          item.keys.length == 3 &&
          item['deviceId'] is String &&
          item['scope'] is String &&
          DateTime.tryParse(item['expiresAt'] as String? ?? '') != null),
      'device list contains only parseable, non-sensitive metadata',
    );
    final listedViewer =
        items.singleWhere((item) => item['deviceId'] == viewer.deviceId);
    _expect(listedViewer['scope'] == 'viewer', 'viewer scope is preserved');
    _expect(
      !jsonEncode(devices.json).contains('accessToken') &&
          !jsonEncode(devices.json).contains('tokenHash') &&
          !jsonEncode(devices.json).contains('pairingCode'),
      'device list does not disclose secrets',
    );

    final unauthenticatedRevoke = await _request(
      base,
      'DELETE',
      '/api/v1/admin/devices/${viewer.deviceId}',
    );
    _expectError(unauthenticatedRevoke, HttpStatus.unauthorized,
        'authentication_required');
    final viewerRevoke = await _request(
      base,
      'DELETE',
      '/api/v1/admin/devices/${viewer.deviceId}',
      token: viewer.accessToken,
    );
    _expectError(viewerRevoke, HttpStatus.forbidden, 'insufficient_scope');
    final missingDevice = await _request(
      base,
      'DELETE',
      '/api/v1/admin/devices/missing-device',
      token: admin.accessToken,
    );
    _expectError(missingDevice, HttpStatus.notFound, 'resource_not_found');

    final revoked = await _request(
      base,
      'DELETE',
      '/api/v1/admin/devices/${viewer.deviceId}',
      token: admin.accessToken,
    );
    _expect(revoked.statusCode == HttpStatus.noContent,
        'admin can revoke a paired device');
    final revokedViewerRequest = await _request(
      base,
      'GET',
      '/api/v1/movies',
      token: viewer.accessToken,
    );
    _expectError(revokedViewerRequest, HttpStatus.unauthorized,
        'authentication_required');
    final remainingDevices = await _request(
      base,
      'GET',
      '/api/v1/admin/devices',
      token: admin.accessToken,
    );
    final remainingItems = ((remainingDevices.json['data']
            as Map<String, dynamic>)['items'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    _expect(
      remainingItems.length == 1 &&
          remainingItems.single['deviceId'] == admin.deviceId,
      'revoked device is no longer listed',
    );
  } finally {
    await server.stop();
    await directory.delete(recursive: true);
  }

  stdout.writeln('devices_api_test: PASS');
}

Future<_PairedDevice> _pair(
  Uri base,
  String serverId, {
  String? requestedScope,
}) async {
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
  final data = confirmed.json['data'] as Map<String, dynamic>;
  return _PairedDevice(
    deviceId: data['deviceId'] as String,
    accessToken: data['accessToken'] as String,
  );
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
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
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

class _PairedDevice {
  const _PairedDevice({required this.deviceId, required this.accessToken});

  final String deviceId;
  final String accessToken;
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
