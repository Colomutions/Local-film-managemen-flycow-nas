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
  final library = NasLibraryDatabase(config.dataDir);
  final server = NasHealthServer(config, libraryDatabase: library);
  try {
    await server.start();
    await File('${media.path}/ABC-001.mp4').writeAsBytes([0, 1, 2]);
    await library.scanConfiguredRoot(
        rootName: '测试盘', containerPath: media.path,
        mediaService: NasMediaService(mediaDir: media.path, fixtureRelativePath: null),
        metadataProbe: NasMediaMetadataProbe(runner: (command, args) async =>
            ProcessResult(1, 0, '{"streams":[],"format":{}}', '')));
    final movieId = library.listMovies().single.id;
    library.saveScrapeMovieProfile(movieId, {'actors': [{'name': '凉森玲梦'}]});
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
    _expect(item['sourceHasPhoto'] == true && item['hasPhoto'] == false,
        'separates MDCNG photo flags from locally matched image files');
    final candidate = ((item['candidates'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((candidate) => candidate['name'] == '涼森れむ')).single;
    _expect(candidate['key'] is String,
        'returns candidates only for an explicit user selection');
    _expect(candidate['hasPhoto'] == true,
        'candidate summary reports an available portrait');
    _expect(candidate['missingFieldCount'] == 0,
        'candidate summary reports missing profile fields');
    _expect(item['syncState'] == 'new', 'unlinked actor is a new import');

    final viewerDecision = await _request(
      base,
      'PUT',
      '/api/v1/admin/mdcng-actor-imports/decision',
      token: viewer,
      body: {'taskId': '2', 'deferred': true},
    );
    _expect(viewerDecision.statusCode == HttpStatus.forbidden,
        'only admins can defer actor imports');
    final deferred = await _request(
      base,
      'PUT',
      '/api/v1/admin/mdcng-actor-imports/decision',
      token: admin,
      body: {'taskId': '2', 'deferred': true},
    );
    _expect(deferred.statusCode == HttpStatus.ok,
        'admin can mark an actor as not to import');
    final storedDecisions = sqlite3.open(
      '${config.dataDir}${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite',
      mode: OpenMode.readOnly,
    );
    try {
      _expect(
        storedDecisions.select('''
          SELECT emby_id FROM mdcng_actor_deferred WHERE source_id = ?
        ''', [config.mdcngSourceId]).single['emby_id'] == '1537',
        'decision is persisted in the NAS database',
      );
    } finally {
      storedDecisions.dispose();
    }
    final deferredList = await _request(
      base,
      'GET',
      '/api/v1/admin/mdcng-actor-imports',
      token: admin,
    );
    final deferredItems =
        ((deferredList.json['data'] as Map<String, dynamic>)['items'] as List)
            .cast<Map<String, dynamic>>();
    _expect(
        deferredItems
                .where((item) => item['taskId'] == '2')
                .single['syncState'] ==
            'deferred',
        'list shows the persisted decision');
    final deferredPreview = await _request(
      base,
      'GET',
      '/api/v1/admin/mdcng-actor-imports/batch-preview',
      token: admin,
    );
    final deferredData = deferredPreview.json['data'] as Map<String, dynamic>;
    _expect((deferredData['summary'] as Map<String, dynamic>)['deferred'] == 1,
        'batch preview counts deferred actors');
    _expect(
        (deferredData['summary'] as Map<String, dynamic>)['eligibleTotal'] == 1,
        'deferred actors stay out while other raw records remain eligible');
    final restored = await _request(
      base,
      'PUT',
      '/api/v1/admin/mdcng-actor-imports/decision',
      token: admin,
      body: {'taskId': '2', 'deferred': false},
    );
    _expect(restored.statusCode == HttpStatus.ok,
        'admin can restore an actor for later import');

    final existingActor = await _request(
      base,
      'POST',
      '/api/v1/admin/actors',
      token: admin,
      body: {'stageName': '高橋しょう子'},
    );
    _expect(existingActor.statusCode == HttpStatus.created,
        'creates an existing actor with the same MDCNG name');

    final duplicate = library.createActor(stageName: '重名测试演员', aliases: ['高橋しょう子']);
    final ambiguous = await _request(base, 'GET', '/api/v1/admin/mdcng-actor-imports/batch-preview', token: admin);
    _expect(((ambiguous.json['data']['items'] as List).cast<Map>()
        .singleWhere((row) => row['taskId'] == '2'))['status'] == 'needs_target_resolution',
        'batch leaves ambiguous identities for explicit review');
    final ambiguousPreview = await _request(base, 'POST', '/api/v1/admin/mdcng-actor-imports/preview',
        token: admin, body: {'taskId': '2'});
    _expect(ambiguousPreview.json['data']['current'] == null &&
        (ambiguousPreview.json['data']['similarActors'] as List).length == 2,
        'single preview exposes both candidates without choosing one');
    library.deleteActor(duplicate.id);

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
    _expect(batchSummary['eligibleCreate'] == 1 && batchSummary['eligibleUpdate'] == 1,
        'unique exact match enriches an existing actor instead of duplicating it');
    _expect(batchSummary['needsProfileResolution'] == 0,
        'a missing Actress.db match no longer blocks batch import');
    final batchItem = (batchData['items'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((item) => item['taskId'] == '2')
        .single;
    _expect(batchItem['status'] == 'eligible_update',
        'unique source profile reuses the existing actor');

    await _request(
      base,
      'PUT',
      '/api/v1/admin/mdcng-actor-imports/decision',
      token: admin,
      body: {'taskId': '2', 'deferred': true},
    );
    final staleBatch = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-actor-imports/batch-apply',
      token: admin,
      body: {
        'items': [
          {
            'taskId': batchItem['taskId'],
            'fingerprint': batchItem['fingerprint']
          }
        ]
      },
    );
    _expect((staleBatch.json['data'] as Map<String, dynamic>)['skipped'] == 1,
        'execution rechecks a decision made after batch preview');
    await _request(
      base,
      'PUT',
      '/api/v1/admin/mdcng-actor-imports/decision',
      token: admin,
      body: {'taskId': '2', 'deferred': false},
    );

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
    _expect(batchResult['updated'] == 1 && batchResult['created'] == 0 && batchResult['failed'] == 0,
        'batch fills the existing actor without creating a duplicate');
    final importedPreview = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-actor-imports/preview',
      token: admin,
      body: {'taskId': '2'},
    );
    final importedData = importedPreview.json['data'] as Map<String, dynamic>;
    final batchActorId =
        (importedData['current'] as Map<String, dynamic>)['id'] as String;
    _expect(batchActorId == existingActor.json['data']['actor']['id'],
        'cross-source import preserves the canonical actor ID');
    _expect(importedData['recommendedAction'] == 'update',
        'single preview finds the actor already bound to this source');
    final secondBatchPreview = await _request(
      base,
      'GET',
      '/api/v1/admin/mdcng-actor-imports/batch-preview',
      token: admin,
    );
    final secondBatchData =
        secondBatchPreview.json['data'] as Map<String, dynamic>;
    final importedBatchItem = (secondBatchData['items'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((item) => item['taskId'] == '2')
        .single;
    _expect(importedBatchItem['status'] == 'already_imported',
        'second batch preview does not offer the same task as a new actor');
    final repeatedBatch = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-actor-imports/batch-apply',
      token: admin,
      body: {
        'items': [
          {
            'taskId': batchItem['taskId'],
            'fingerprint': batchItem['fingerprint']
          }
        ]
      },
    );
    final repeatedBatchResult =
        repeatedBatch.json['data'] as Map<String, dynamic>;
    _expect(
        repeatedBatchResult['created'] == 0 &&
            repeatedBatchResult['skipped'] == 1,
        'reapplying a stale batch selection cannot duplicate a linked actor');
    final editedBatchActor = await _request(
      base,
      'PATCH',
      '/api/v1/admin/actors/$batchActorId',
      token: admin,
      body: {'stageName': '自定义名字', 'romanizedName': null},
    );
    _expect(editedBatchActor.statusCode == HttpStatus.ok,
        'sets up one missing field and a manually edited field');
    final updateBatchPreview = await _request(
      base,
      'GET',
      '/api/v1/admin/mdcng-actor-imports/batch-preview',
      token: admin,
    );
    final updateBatchItem = ((updateBatchPreview.json['data']
            as Map<String, dynamic>)['items'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((item) => item['taskId'] == '2')
        .single;
    _expect(
        updateBatchItem['status'] == 'eligible_update' &&
            updateBatchItem['fieldCount'] == 1,
        'second preview offers only the missing field on the linked actor');
    final batchUpdated = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-actor-imports/batch-apply',
      token: admin,
      body: {
        'items': [
          {
            'taskId': updateBatchItem['taskId'],
            'fingerprint': updateBatchItem['fingerprint']
          }
        ]
      },
    );
    final updateResult = batchUpdated.json['data'] as Map<String, dynamic>;
    _expect(updateResult['created'] == 0 && updateResult['updated'] == 1,
        'batch fills the linked actor instead of creating a copy');
    final updatedPreview = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-actor-imports/preview',
      token: admin,
      body: {'taskId': '2'},
    );
    final updatedActor =
        (updatedPreview.json['data']['current'] as Map<String, dynamic>);
    _expect(
        updatedActor['id'] == batchActorId &&
            updatedActor['stageName'] == '自定义名字' &&
            updatedActor['romanizedName'] == 'Takahashi Shoko',
        'batch update preserves edited fields and restores missing data');
    final importedDecision = await _request(
      base,
      'PUT',
      '/api/v1/admin/mdcng-actor-imports/decision',
      token: admin,
      body: {'taskId': '2', 'deferred': true},
    );
    _expect(importedDecision.statusCode == HttpStatus.ok,
        'an imported actor can be imported again later');

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
            'raw',
        'unselected candidate still imports using the raw MDCNG record');

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

    final mergeTarget = await _request(
      base,
      'POST',
      '/api/v1/admin/actors',
      token: admin,
      body: {'stageName': '涼森れむ', 'originalName': '旧原名'},
    );
    _expect(mergeTarget.statusCode == HttpStatus.created,
        'creates a similar actor for merge preview');
    final mergeTargetId = mergeTarget.json['data']['actor']['id'] as String;
    final mergePreview = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-actor-imports/preview',
      token: admin,
      body: {
        'taskId': item['taskId'],
        'selectedProfileKey': candidate['key'],
        'targetActorId': mergeTargetId,
      },
    );
    _expect(mergePreview.statusCode == HttpStatus.ok,
        'admin can preview against the selected merge target');
    final mergeData = mergePreview.json['data'] as Map<String, dynamic>;
    _expect(mergeData['comparisonActorId'] == mergeTargetId,
        'merge preview identifies the compared actor');
    final mergeDiffs =
        (mergeData['fieldDiffs'] as List<dynamic>).cast<Map<String, dynamic>>();
    _expect(
      mergeDiffs
              .where((diff) => diff['key'] == 'originalName')
              .single['status'] ==
          'replace_requires_confirmation',
      'merge preview flags the target actor field that would be replaced',
    );
    final originalNameDiff =
        mergeDiffs.where((diff) => diff['key'] == 'originalName').single;
    _expect(
      originalNameDiff['currentValue'] == '旧原名' &&
          originalNameDiff['proposedValue'] == '涼森れむ',
      'merge preview shows both text values',
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
    final missingConfirmation = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-actor-imports/apply',
      token: admin,
      body: {
        'taskId': source['taskId'],
        'fingerprint': fingerprint,
        'fieldKeys': fields,
        'overwriteFieldKeys': const [],
        'targetActorId': mergeTargetId,
        'createNew': false,
        'selectedProfileKey': candidate['key'],
      },
    );
    _expect(
      missingConfirmation.statusCode == HttpStatus.conflict &&
          missingConfirmation.json['error']['code'] ==
              'mdcng_actor_overwrite_confirmation_required',
      'merging without field confirmation is rejected',
    );
    final overwriteFieldKeys = mergeDiffs
        .where((diff) => diff['requiresConfirmation'] == true)
        .map((diff) => diff['key'] as String)
        .toList(growable: false);
    final applied = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-actor-imports/apply',
      token: admin,
      body: {
        'taskId': source['taskId'],
        'fingerprint': fingerprint,
        'fieldKeys': fields,
        'overwriteFieldKeys': overwriteFieldKeys,
        'targetActorId': mergeTargetId,
        'createNew': false,
        'selectedProfileKey': candidate['key'],
      },
    );
    _expect(
        applied.statusCode == HttpStatus.ok, 'confirmed actor data imports');
    final appliedData = applied.json['data'] as Map<String, dynamic>;
    final actor = appliedData['actor'] as Map<String, dynamic>;
    _expect(actor['id'] == mergeTargetId,
        'confirmed fields merge into the selected actor');
    _expect(library.actorsForMovie(movieId).single.id == mergeTargetId &&
        actor['movieCount'] == 1,
        'import backfills saved movie credits and returns the updated count');
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

    final clearedMergeField = await _request(
      base,
      'PATCH',
      '/api/v1/admin/actors/$mergeTargetId',
      token: admin,
      body: {'romanizedName': null},
    );
    _expect(clearedMergeField.statusCode == HttpStatus.ok,
        'clears one field on the linked actor');
    final repeated = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-actor-imports/apply',
      token: admin,
      body: {
        'taskId': source['taskId'],
        'fingerprint': fingerprint,
        'fieldKeys': ['romanizedName'],
        'overwriteFieldKeys': const [],
        'targetActorId': null,
        'createNew': true,
        'selectedProfileKey': candidate['key'],
      },
    );
    _expect(repeated.statusCode == HttpStatus.ok,
        'same source snapshot can fill an existing actor field');
    final repeatedActor =
        repeated.json['data']['actor'] as Map<String, dynamic>;
    _expect(repeatedActor['id'] == actor['id'],
        'repeated import updates the actor bound to the MDCNG source');

    final reset = await _request(
      base,
      'POST',
      '/api/v1/admin/mdcng-actor-imports/reset',
      token: admin,
      body: const <String, dynamic>{},
    );
    _expect(reset.statusCode == HttpStatus.ok,
        'admin can clear all MDCNG actors for a fresh import');
    final resetData = reset.json['data'] as Map<String, dynamic>;
    _expect((resetData['deletedActors'] as int) == 2,
        'reset deletes every existing actor record');
    _expect((resetData['deletedImages'] as int) >= 2,
        'reset deletes imported actor images');
    final actorsAfterReset = await _request(
      base,
      'GET',
      '/api/v1/actors',
      token: admin,
    );
    _expect(
      ((actorsAfterReset.json['data'] as Map<String, dynamic>)['items'] as List)
          .isEmpty,
      'reset removes all actors from the library',
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
