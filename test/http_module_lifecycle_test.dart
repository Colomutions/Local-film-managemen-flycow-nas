import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('mujing-http-modules-');
  final config = NasConfig(
    bindHost: '127.0.0.1',
    port: 0,
    serverName: 'HTTP module lifecycle',
    advertiseUrl: null,
    pairingCode: 'test-pairing-code',
    fixtureMediaRelativePath: null,
    mediaRootName: 'media',
    scanOnStart: false,
    dataDir: '${root.path}/data',
    mediaDir: '${root.path}/media',
    novelDir: '${root.path}/novels',
    comicDir: '${root.path}/comics',
    timezone: 'Asia/Shanghai',
  );
  for (final directory in [
    config.mediaDir,
    config.novelDir!,
    config.comicDir!
  ]) {
    await Directory(directory).create(recursive: true);
  }
  final server = NasHealthServer(
    config,
    logger: NasDiagnosticLogger(minimumLevel: 'ERROR'),
  );
  final client = HttpClient();

  Future<Map<String, dynamic>> call(String method, String path,
      {String? token, Object? body, int status = HttpStatus.ok}) async {
    final request = await client.openUrl(
        method, Uri.parse('http://127.0.0.1:${server.port}$path'));
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != status) {
      throw StateError('$method $path: ${response.statusCode}, $text');
    }
    return text.isEmpty ? {} : jsonDecode(text) as Map<String, dynamic>;
  }

  try {
    await server.start();
    final info = await call('GET', '/api/v1/server-info');
    final serverId = info['data']['serverId'];
    Future<String> pendingPairing({String scope = 'viewer'}) async {
      final reply = await call('POST', '/api/v1/pairing/sessions', body: {
        'serverId': serverId,
        'requestedScope': scope,
      });
      return reply['data']['pairingSessionId'] as String;
    }

    Future<String> confirm(String session) async {
      final reply = await call(
          'POST', '/api/v1/pairing/sessions/$session/confirm',
          body: {'pairingPassword': config.pairingCode});
      return reply['data']['accessToken'] as String;
    }

    final admin = await confirm(await pendingPairing(scope: 'admin'));
    // Force router and both storage APIs to exist before the database reopens.
    await call('GET', '/api/v1/novels', token: admin);
    await call('GET', '/api/v1/comics', token: admin);
    await call('PUT', '/api/v1/admin/ai/settings', token: admin, body: {
      'provider': 'test',
      'endpoint': 'https://example.invalid/ai',
      'model': 'test-model',
      'apiKey': 'test-key',
    });
    // AI settings replace the persistent state object. Pairing and device
    // management must subsequently use that same live state.
    final viewer = await confirm(await pendingPairing());
    final devices = await call('GET', '/api/v1/admin/devices', token: admin);
    _expect((devices['data']['items'] as List).length == 2,
        'pairing and device modules share replaced state');
    final unfinished = await pendingPairing();

    await server.stop();
    await server.start();
    await call('POST', '/api/v1/pairing/sessions/$unfinished/confirm',
        body: {'pairingPassword': config.pairingCode},
        status: HttpStatus.unauthorized);
    final settings =
        await call('GET', '/api/v1/admin/ai/settings', token: admin);
    _expect(settings['data']['model'] == 'test-model',
        'AI module uses reloaded persistent state');
    // The same router must resolve fresh APIs, not repositories backed by the
    // disposed connection or the comic service closed during shutdown.
    await call('GET', '/api/v1/novels', token: viewer);
    await call('GET', '/api/v1/comics', token: viewer);
    await call('GET', '/api/v1/admin/devices',
        token: viewer, status: HttpStatus.forbidden);
    final persisted = await call('GET', '/api/v1/admin/devices', token: admin);
    _expect((persisted['data']['items'] as List).length == 2,
        'tokens created after state replacement survive reopening');
  } finally {
    client.close(force: true);
    await server.stop();
    await root.delete(recursive: true);
  }
  stdout.writeln('http_module_lifecycle_test: PASS');
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
