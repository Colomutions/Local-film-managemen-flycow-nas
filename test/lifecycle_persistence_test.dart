import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-nas-lifecycle-test-');
  final dataDir = Directory('${directory.path}${Platform.pathSeparator}data');
  final mediaDir = Directory('${directory.path}${Platform.pathSeparator}media');
  final sourceMedia =
      File('${mediaDir.path}${Platform.pathSeparator}sample.mp4');
  const sourceBytes = <int>[0, 1, 2, 3, 4, 5, 6, 7];
  await sourceMedia.parent.create(recursive: true);
  await sourceMedia.writeAsBytes(sourceBytes);

  NasHealthServer? server;
  try {
    server = _newServer(dataDir, mediaDir);
    await server.start();
    final firstBase = Uri.parse('http://127.0.0.1:${server.port}');
    final firstInfo = await _request(firstBase, 'GET', '/api/v1/server-info');
    final serverId = _serverId(firstInfo);
    final viewer = await _pair(firstBase, serverId);
    final admin = await _pair(firstBase, serverId, scope: 'admin');

    final poster = File(
      '${dataDir.path}${Platform.pathSeparator}artwork${Platform.pathSeparator}posters${Platform.pathSeparator}lifecycle.png',
    );
    await poster.writeAsBytes(const [137, 80, 78, 71, 13, 10, 26, 10]);
    final backup = await _request(
      firstBase,
      'POST',
      '/api/v1/admin/backups',
      token: admin.accessToken,
    );
    _expect(backup.statusCode == HttpStatus.created,
        'backup is created before restart');
    final backupId =
        (backup.json['data'] as Map<String, dynamic>)['id'] as String;

    // NasHealthServer.stop intentionally closes the listener with force:true,
    // which is the service-level counterpart of a container being rebuilt.
    await server.stop();
    server = null;

    final databaseFile = File(
      '${dataDir.path}${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite',
    );
    _expect(
        await databaseFile.exists(), 'SQLite database survives forced stop');
    final database = sqlite3.open(databaseFile.path);
    try {
      _expect(
        database.select('SELECT version FROM schema_migrations').isNotEmpty,
        'SQLite data remains readable before restart',
      );
    } finally {
      database.dispose();
    }

    server = _newServer(dataDir, mediaDir);
    await server.start();
    final secondBase = Uri.parse('http://127.0.0.1:${server.port}');
    final secondInfo = await _request(secondBase, 'GET', '/api/v1/server-info');
    _expect(
        _serverId(secondInfo) == serverId, 'server identity survives rebuild');

    final viewerMovies = await _request(
      secondBase,
      'GET',
      '/api/v1/movies',
      token: viewer.accessToken,
    );
    _expect(viewerMovies.statusCode == HttpStatus.ok,
        'viewer token survives rebuild');

    final devices = await _request(
      secondBase,
      'GET',
      '/api/v1/admin/devices',
      token: admin.accessToken,
    );
    _expect(
        devices.statusCode == HttpStatus.ok, 'admin token survives rebuild');
    final deviceItems = ((devices.json['data'] as Map<String, dynamic>)['items']
            as List<dynamic>)
        .cast<Map<String, dynamic>>();
    _expect(
      deviceItems.length == 2 &&
          deviceItems.any((item) => item['deviceId'] == viewer.deviceId) &&
          deviceItems.any((item) => item['deviceId'] == admin.deviceId),
      'paired devices survive rebuild without exposing token material',
    );

    final backups = await _request(
      secondBase,
      'GET',
      '/api/v1/admin/backups',
      token: admin.accessToken,
    );
    _expect(backups.statusCode == HttpStatus.ok,
        'backup list is available after rebuild');
    final backupItems = ((backups.json['data'] as Map<String, dynamic>)['items']
            as List<dynamic>)
        .cast<Map<String, dynamic>>();
    _expect(
      backupItems.length == 1 && backupItems.single['id'] == backupId,
      'existing backup survives rebuild',
    );
    _expect(await poster.exists(), 'artwork survives rebuild');
    _expect(
      _sameBytes(
          await poster.readAsBytes(), const [137, 80, 78, 71, 13, 10, 26, 10]),
      'artwork content remains unchanged',
    );
    _expect(
      _sameBytes(await sourceMedia.readAsBytes(), sourceBytes),
      'service never writes the mounted source media',
    );
  } finally {
    if (server != null) await server.stop();
    await directory.delete(recursive: true);
  }

  stdout.writeln('lifecycle_persistence_test: PASS');
}

NasHealthServer _newServer(Directory dataDir, Directory mediaDir) =>
    NasHealthServer(
      NasConfig(
        bindHost: '127.0.0.1',
        port: 0,
        serverName: 'Test NAS',
        advertiseUrl: null,
        pairingCode: 'test-pairing-code',
        fixtureMediaRelativePath: null,
        mediaRootName: '测试媒体根',
        scanOnStart: false,
        dataDir: dataDir.path,
        mediaDir: mediaDir.path,
        timezone: 'Asia/Shanghai',
      ),
    );

String _serverId(_Response response) =>
    (response.json['data'] as Map<String, dynamic>)['serverId'] as String;

Future<_PairedDevice> _pair(Uri base, String serverId, {String? scope}) async {
  final session = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions',
    body: {
      'serverId': serverId,
      if (scope != null) 'requestedScope': scope,
    },
  );
  _expect(session.statusCode == HttpStatus.ok, 'pairing session is created');
  final sessionId = (session.json['data']
      as Map<String, dynamic>)['pairingSessionId'] as String;
  final confirmed = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions/$sessionId/confirm',
    body: {'pairingPassword': 'test-pairing-code'},
  );
  _expect(confirmed.statusCode == HttpStatus.ok, 'pairing is confirmed');
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

bool _sameBytes(List<int> actual, List<int> expected) =>
    actual.length == expected.length &&
    actual.asMap().entries.every((entry) => entry.value == expected[entry.key]);

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

void _expect(bool condition, String message) {
  if (!condition) throw StateError('Assertion failed: $message');
}
