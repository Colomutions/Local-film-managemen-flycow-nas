import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-nas-mdcng-actor-api-');
  final mdcngData = Directory(
    '${directory.path}${Platform.pathSeparator}mdcng-data',
  );
  final photos = Directory(
    '${mdcngData.path}${Platform.pathSeparator}photos${Platform.pathSeparator}graphis',
  );
  final media = Directory('${directory.path}${Platform.pathSeparator}media');
  await photos.create(recursive: true);
  await media.create(recursive: true);
  _createTaskDatabase('${mdcngData.path}${Platform.pathSeparator}mdc_ng.db');
  _createProfileDatabase(
      '${mdcngData.path}${Platform.pathSeparator}Actress.db');
  await File('${photos.path}${Platform.pathSeparator}涼森れむ-old.jpg')
      .writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
  await File('${photos.path}${Platform.pathSeparator}涼森れむ-big-old.jpg')
      .writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
  await File('${photos.path}${Platform.pathSeparator}高橋しょう子-old.jpg')
      .writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
  final config = NasConfig(
    bindHost: '127.0.0.1',
    port: 0,
    serverName: 'Test NAS',
    advertiseUrl: null,
    pairingCode: 'test-pairing-code',
    fixtureMediaRelativePath: null,
    mediaRootName: '测试媒体根',
    scanOnStart: false,
    dataDir: '${directory.path}${Platform.pathSeparator}service-data',
    mediaDir: media.path,
    timezone: 'Asia/Shanghai',
    mdcngDataDir: mdcngData.path,
    mdcngSourceId: 'test-emby',
  );
  final server = NasHealthServer(config);
  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await _request(base, 'GET', '/api/v1/server-info');
    final serverId =
        (info.json['data'] as Map<String, dynamic>)['serverId'] as String;
    final viewer = await _pair(base, serverId);
    final admin = await _pair(base, serverId, scope: 'admin');

    final denied = await _request(
      base,
      'GET',
      '/api/v1/admin/mdcng-actor-imports',
      token: viewer,
    );
    _expect(denied.statusCode == HttpStatus.forbidden,
        'actor import requires admin');

    final listed = await _request(
      base,
      'GET',
      '/api/v1/admin/mdcng-actor-imports',
      token: admin,
    );
    _expect(listed.statusCode == HttpStatus.ok,
        'lists completed MDCNG actor tasks');
    _expect(!jsonEncode(listed.json).contains(directory.path),
        'list does not leak NAS paths');
    final listedItems = ((listed.json['data'] as Map<String, dynamic>)['items']
            as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final item = listedItems.where((item) => item['taskId'] == '1').single;
    _expect(item['profileName'] == null,
        'translated task does not auto-resolve an actress profile');
    final candidate = ((item['candidates'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((candidate) => candidate['name'] == '涼森れむ')).single;
    _expect(candidate['key'] is String,
        'returns candidates only for an explicit user selection');
    _expect(item['syncState'] == 'new', 'unlinked actor is a new import');

    final batchPreview = await _request(
      base,
      'GET',
      '/api/v1/admin/mdcng-actor-imports/batch-preview',
      token: admin,
    );
    _expect(batchPreview.statusCode == HttpStatus.ok,
        'admin can preview safe batch actor imports');
    final batchData = batchPreview.json['data'] as Map<String, dynamic>;
    final batchSummary = batchData['summary'] as Map<String, dynamic>;
    _expect(batchSummary['eligibleCreate'] == 1,
        'only the direct profile match is batch-eligible');
    _expect(batchSummary['needsProfileResolution'] == 1,
        'translated name is kept for manual profile selection');
    final batchItem = (batchData['items'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((item) => item['taskId'] == '2')
        .single;
    _expect(batchItem['status'] == 'eligible_create',
        'unique source profile is eligible for a safe create');

    final batchApplied = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-actor-imports/batch-apply',
      token: admin,
      body: {
        'items': [
          {
            'taskId': batchItem['taskId'],
            'fingerprint': batchItem['fingerprint']
          },
        ],
      },
    );
    _expect(batchApplied.statusCode == HttpStatus.ok,
        'admin can apply the reviewed safe batch items');
    final batchResult = batchApplied.json['data'] as Map<String, dynamic>;
    _expect(batchResult['created'] == 1 && batchResult['failed'] == 0,
        'batch imports one directly resolved actress');

    final preview = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-actor-imports/preview',
      token: admin,
      body: {'taskId': item['taskId']},
    );
    _expect(
        preview.statusCode == HttpStatus.ok, 'admin can preview actor import');
    _expect(!jsonEncode(preview.json).contains(directory.path),
        'preview does not leak NAS paths');
    _expect(
        (preview.json['data'] as Map<String, dynamic>)['profileResolution'] ==
            'unresolved',
        'unselected candidate cannot be imported');

    final selectedPreview = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-actor-imports/preview',
      token: admin,
      body: {
        'taskId': item['taskId'],
        'selectedProfileKey': candidate['key'],
      },
    );
    _expect(selectedPreview.statusCode == HttpStatus.ok,
        'admin can preview an explicitly selected profile');
    final previewData = selectedPreview.json['data'] as Map<String, dynamic>;
    final source = previewData['source'] as Map<String, dynamic>;
    final fingerprint = source['fingerprint'] as String;
    _expect(fingerprint.length == 64, 'preview returns stale-read protection');
    _expect(source['selectedProfileKey'] == candidate['key'],
        'preview records the explicit source profile choice');
    _expect(
      (previewData['proposed'] as Map<String, dynamic>)['birthDate'] ==
          '1997-12-03 00:00:00',
      'preview contains full birthday',
    );

    const fields = [
      'stageName',
      'originalName',
      'translatedName',
      'aliases',
      'gender',
      'romanizedName',
      'birthDate',
      'birthMonth',
      'heightCm',
      'measurements',
      'country',
      'debutMonth',
      'debutDescription',
      'photo',
      'backdrop',
    ];
    final applied = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-actor-imports/apply',
      token: admin,
      body: {
        'taskId': source['taskId'],
        'fingerprint': fingerprint,
        'fieldKeys': fields,
        'overwriteFieldKeys': const [],
        'targetActorId': null,
        'createNew': true,
        'selectedProfileKey': candidate['key'],
      },
    );
    _expect(
        applied.statusCode == HttpStatus.ok, 'confirmed actor data imports');
    final appliedData = applied.json['data'] as Map<String, dynamic>;
    final actor = appliedData['actor'] as Map<String, dynamic>;
    _expect(actor['stageName'] == '凉森玲梦',
        'writes the library Chinese common name as the display name');
    _expect(actor['originalName'] == '涼森れむ',
        'writes the native-language actress name');
    _expect(
        actor['translatedName'] == '凉森玲梦', 'writes the Chinese translation');
    _expect(actor['country'] == '日本',
        'derives Japan from a Japanese prefecture birthplace');
    _expect(
        actor['birthDate'] == '1997-12-03 00:00:00', 'writes full birthday');
    _expect(actor['photoAsset'] != null, 'copies portrait into managed assets');
    _expect(
        actor['backdropAsset'] != null, 'copies backdrop into managed assets');

    final repeated = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-actor-imports/apply',
      token: admin,
      body: {
        'taskId': source['taskId'],
        'fingerprint': fingerprint,
        'fieldKeys': fields,
        'overwriteFieldKeys': const [],
        'targetActorId': null,
        'createNew': false,
        'selectedProfileKey': candidate['key'],
      },
    );
    _expect(
      repeated.statusCode == HttpStatus.ok &&
          repeated.json['data']['status'] == 'no_changes',
      'same source snapshot is never imported twice',
    );
  } finally {
    await server.stop();
    await directory.delete(recursive: true);
  }
  stdout.writeln('mdcng_actor_import_api_test: PASS');
}

Future<String> _pair(Uri base, String serverId, {String? scope}) async {
  final session = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions',
    body: {
      'serverId': serverId,
      if (scope != null) 'requestedScope': scope,
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
  return (confirmed.json['data'] as Map<String, dynamic>)['accessToken']
      as String;
}

Future<_Response> _request(
  Uri base,
  String method,
  String path, {
  String? token,
  Object? body,
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
        response.statusCode, jsonDecode(text) as Map<String, dynamic>);
  } finally {
    client.close(force: true);
  }
}

void _createTaskDatabase(String path) {
  final database = sqlite3.open(path);
  try {
    database.execute('''
      CREATE TABLE actress_task (
        id INTEGER PRIMARY KEY, name TEXT NOT NULL, status INTEGER NOT NULL,
        stage INTEGER NOT NULL, emby_id TEXT, year INTEGER, has_pic INTEGER,
        has_backdrop INTEGER, end_at TEXT
      );
      INSERT INTO actress_task VALUES (
        1, '凉森玲梦', 2, 1000, '1536', 1997, 1, 1,
        '2026-09-14T07:50:01.000000000+00:00'
      );
      INSERT INTO actress_task VALUES (
        2, '高橋しょう子', 2, 1000, '1537', 1993, 1, 0,
        '2026-09-14T08:00:01.000000000+00:00'
      );
    ''');
  } finally {
    database.dispose();
  }
}

void _createProfileDatabase(String path) {
  final database = sqlite3.open(path);
  try {
    database.execute('''
      CREATE TABLE Info (
        Name TEXT, Roma TEXT, Href TEXT PRIMARY KEY, Birthday TEXT, Height INTEGER,
        Bust INTEGER, Waist INTEGER, Hip INTEGER, Cup TEXT, Birthplace TEXT,
        CareerPeriod TEXT, DebutWork TEXT, Account TEXT, OfficialSite TEXT,
        UpdateTime TEXT, Completeness INTEGER
      );
      CREATE TABLE Names (Alias TEXT PRIMARY KEY, Name TEXT, Roma TEXT);
      INSERT INTO Info VALUES (
        '涼森れむ', 'Suzumori Remu', 'actress533604.html?涼森れむ',
        '1997-12-03 00:00:00', 160, 87, 58, 85, 'F', '三重県', '2019年 -',
        '出道作品(2019年03月 09日)', 'https://example.invalid/social',
        'https://example.invalid/official', '2023-11-23 17:53:16', 8
      );
      INSERT INTO Names VALUES ('涼森れむ', '涼森れむ', 'Suzumori Remu');
      INSERT INTO Info VALUES (
        '高橋しょう子', 'Takahashi Shoko', 'actress000002.html?高橋しょう子',
        '1993-05-13 00:00:00', 161, 85, 59, 86, 'E', '愛知県', '2013年 -',
        '出道作品', NULL, NULL, '2023-11-23 17:53:16', 8
      );
      INSERT INTO Names VALUES ('高橋しょう子', '高橋しょう子', 'Takahashi Shoko');
    ''');
  } finally {
    database.dispose();
  }
}

class _Response {
  const _Response(this.statusCode, this.json);

  final int statusCode;
  final Map<String, dynamic> json;
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
