import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/mujing_nas.dart';
import '../lib/src/auth.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-nas-backups-api-test-');
  final dataDir = Directory('${directory.path}${Platform.pathSeparator}data');
  final mediaDir = Directory('${directory.path}${Platform.pathSeparator}media');
  await File('${mediaDir.path}${Platform.pathSeparator}source.mp4')
      .create(recursive: true);
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
      dataDir: dataDir.path,
      mediaDir: mediaDir.path,
      timezone: 'Asia/Shanghai',
    ),
  );

  try {
    await server.start();
    final configFile = File(
      '${dataDir.path}${Platform.pathSeparator}config${Platform.pathSeparator}config.json',
    );
    await configFile.parent.create(recursive: true);
    await configFile.writeAsString(
        '{"backupTest":true,"pairingCode":"do-not-back-up","accessToken":"secret"}');
    final posterFile = File(
      '${dataDir.path}${Platform.pathSeparator}artwork${Platform.pathSeparator}posters${Platform.pathSeparator}test.png',
    );
    await posterFile.parent.create(recursive: true);
    await posterFile.writeAsBytes(const [137, 80, 78, 71, 13, 10, 26, 10]);

    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final serverInfo = await _request(base, 'GET', '/api/v1/server-info');
    final serverId =
        (serverInfo.json['data'] as Map<String, dynamic>)['serverId'] as String;
    final viewer = await _pair(base, serverId);
    final admin = await _pair(base, serverId, requestedScope: 'admin');

    final unauthenticatedList =
        await _request(base, 'GET', '/api/v1/admin/backups');
    _expectError(unauthenticatedList, HttpStatus.unauthorized,
        'authentication_required');
    final viewerList = await _request(
      base,
      'GET',
      '/api/v1/admin/backups',
      token: viewer,
    );
    _expectError(viewerList, HttpStatus.forbidden, 'insufficient_scope');
    final unauthenticatedCreate =
        await _request(base, 'POST', '/api/v1/admin/backups');
    _expectError(unauthenticatedCreate, HttpStatus.unauthorized,
        'authentication_required');
    final viewerCreate = await _request(
      base,
      'POST',
      '/api/v1/admin/backups',
      token: viewer,
    );
    _expectError(viewerCreate, HttpStatus.forbidden, 'insufficient_scope');
    final missingBackup = await _request(
      base,
      'GET',
      '/api/v1/admin/backups/missing-backup',
      token: admin,
    );
    _expectError(missingBackup, HttpStatus.notFound, 'resource_not_found');

    final created = await _request(
      base,
      'POST',
      '/api/v1/admin/backups',
      token: admin,
    );
    _expect(created.statusCode == HttpStatus.created,
        'admin can create a NAS backup');
    final backup = created.json['data'] as Map<String, dynamic>;
    _expect(
      backup.keys.toSet().containsAll(const {'id', 'createdAt', 'sizeBytes'}) &&
          backup.keys.length == 3 &&
          backup['id'] is String &&
          DateTime.tryParse(backup['createdAt'] as String? ?? '') != null &&
          backup['sizeBytes'] is int &&
          (backup['sizeBytes'] as int) > 0,
      'backup response contains only non-sensitive metadata',
    );
    _expect(
      !jsonEncode(created.json).contains(dataDir.path) &&
          !jsonEncode(created.json).contains(mediaDir.path) &&
          !jsonEncode(created.json).contains('accessToken') &&
          !jsonEncode(created.json).contains('tokenHash'),
      'backup response does not disclose paths or credentials',
    );

    final backupId = backup['id'] as String;
    final listed = await _request(
      base,
      'GET',
      '/api/v1/admin/backups',
      token: admin,
    );
    final items = ((listed.json['data'] as Map<String, dynamic>)['items']
            as List<dynamic>)
        .cast<Map<String, dynamic>>();
    _expect(items.length == 1 && items.single['id'] == backupId,
        'admin can list the completed backup');
    final detail = await _request(
      base,
      'GET',
      '/api/v1/admin/backups/$backupId',
      token: admin,
    );
    _expect(detail.statusCode == HttpStatus.ok,
        'admin can read backup metadata by service ID');
    _expect(detail.json['data']['id'] == backupId,
        'backup detail keeps the service-generated ID');

    final backupDir = Directory(
        '${dataDir.path}${Platform.pathSeparator}backups${Platform.pathSeparator}$backupId');
    final snapshot = File(
      '${backupDir.path}${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite',
    );
    _expect(await snapshot.exists(), 'backup contains an SQLite snapshot');
    final database = sqlite3.open(snapshot.path);
    try {
      _expect(
        database.select('SELECT version FROM schema_migrations').isNotEmpty,
        'SQLite snapshot is readable while the service database is open',
      );
    } finally {
      database.dispose();
    }
    final backupState = File(
      '${backupDir.path}${Platform.pathSeparator}state${Platform.pathSeparator}server.json',
    );
    _expect(
        await backupState.exists(), 'backup contains persistent service state');
    final stateText = await backupState.readAsString();
    final stateJson = jsonDecode(stateText) as Map<String, dynamic>;
    _expect(
        stateJson['serverId'] is String, 'backup preserves server identity');
    _expect(
        !stateJson.containsKey('tokens') &&
            !stateText.contains('tokenHash') &&
            !stateText.contains(sha256Hex(viewer)),
        'backup state omits token material');

    final backupConfig = File(
      '${backupDir.path}${Platform.pathSeparator}config${Platform.pathSeparator}config.json',
    );
    _expect(await backupConfig.exists(),
        'backup contains persisted configuration when present');
    final configText = await backupConfig.readAsString();
    _expect(
        configText.contains('backupTest') &&
            !configText.contains('pairingCode') &&
            !configText.contains('accessToken') &&
            !configText.contains('do-not-back-up'),
        'backup config omits credential fields');
    _expect(
      await File(
        '${backupDir.path}${Platform.pathSeparator}artwork${Platform.pathSeparator}posters${Platform.pathSeparator}test.png',
      ).exists(),
      'backup contains persisted poster assets',
    );
    _expect(
      !await Directory('${backupDir.path}${Platform.pathSeparator}media')
          .exists(),
      'backup never copies source media files',
    );
  } finally {
    await server.stop();
    await directory.delete(recursive: true);
  }

  stdout.writeln('backups_api_test: PASS');
}

Future<String> _pair(
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
  return (confirmed.json['data'] as Map<String, dynamic>)['accessToken']
      as String;
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
