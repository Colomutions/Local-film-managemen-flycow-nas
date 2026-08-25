import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final dataDirectory = await Directory.systemTemp.createTemp('mujing-nas-health-test-');
  final server = NasHealthServer(
    NasConfig(
      bindHost: '127.0.0.1',
      port: 0,
      serverName: 'test',
      advertiseUrl: null,
      pairingCode: null,
      fixtureMediaRelativePath: null,
      mediaRootName: 'test',
      scanOnStart: false,
      dataDir: dataDirectory.path,
      mediaDir: '/tmp/media',
      timezone: 'Asia/Shanghai',
    ),
  );
  await server.start();
  final client = HttpClient();

  try {
    final healthRequest = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/health'),
    );
    final healthResponse = await healthRequest.close();
    final healthPayload = jsonDecode(
      await utf8.decoder.bind(healthResponse).join(),
    ) as Map<String, dynamic>;
    _expect(healthResponse.statusCode == HttpStatus.ok, 'GET /health is 200');
    _expect(healthPayload['data']['status'] == 'ok', 'health reports ok');
    _expect(!healthPayload['data'].containsKey('dataDir'), 'health hides paths');

    final headRequest = await client.headUrl(
      Uri.parse('http://127.0.0.1:${server.port}/health'),
    );
    final headResponse = await headRequest.close();
    await headResponse.drain<void>();
    _expect(headResponse.statusCode == HttpStatus.ok, 'HEAD /health is 200');
    _expect(
      headResponse.headers.contentLength > 0,
      'HEAD /health supplies Content-Length',
    );

    final missingRequest = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/not-a-route'),
    );
    final missingResponse = await missingRequest.close();
    _expect(
      missingResponse.statusCode == HttpStatus.notFound,
      'unknown route is 404',
    );
  } finally {
    client.close(force: true);
    await server.stop();
    await dataDirectory.delete(recursive: true);
  }

  stdout.writeln('health_server_test: PASS');
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError('Assertion failed: $message');
  }
}
