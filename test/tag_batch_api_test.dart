import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../lib/mujing_nas.dart';
import '../lib/src/library/tag_batch_repository.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('mujing-tag-batch-');
  final data = '${root.path}/data';
  final db = NasLibraryDatabase(data);
  final state = NasPersistentState(serverId: 'batch-test', tokens: {
    for (final scope in ['admin', 'viewer'])
      sha256.convert(utf8.encode('$scope-token')).toString(): NasDeviceToken(
        deviceId: scope,
        scope: scope,
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      ),
  });
  await NasPersistentStateStore(data).save(state);
  await Directory('${root.path}/media').create();
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
        managedCategoryLibrary: true,
        dataDir: data,
        mediaDir: '${root.path}/media',
        timezone: 'Asia/Shanghai',
      ),
      libraryDatabase: db,
      logger: NasDiagnosticLogger(minimumLevel: 'ERROR'));
  final client = HttpClient();
  Database? raw;
  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    Future<(int, Map<String, dynamic>)> request(String path, Object body,
        {String token = 'admin-token'}) async {
      final req = await client
          .postUrl(base.resolve('/api/v1/admin/tag-management/$path'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final response = await req.close();
      final text = await utf8.decoder.bind(response).join();
      return (response.statusCode, jsonDecode(text) as Map<String, dynamic>);
    }

    final category = db.createCategory('batch');
    final first = db.createEmptySeries(title: 'First', categoryId: category.id);
    final second =
        db.createEmptySeries(title: 'Second', categoryId: category.id);
    final third = db.createEmptySeries(title: 'Third', categoryId: category.id);
    db.updateMovieMetadata(
        movieId: first.id,
        catalogNumber: ' ABF_001 ',
        updateCatalogNumber: true);
    db.updateMovieMetadata(
        movieId: second.id, catalogNumber: 'DUP-1', updateCatalogNumber: true);
    db.updateMovieMetadata(
        movieId: third.id, catalogNumber: 'dup_1', updateCatalogNumber: true);
    final parent =
        db.createTag(name: 'parent', level: 1, description: '', parentIds: []);
    final child = db.createTag(
        name: 'child', level: 2, description: '', parentIds: [parent.id]);
    final leaf = db.createTag(
        name: 'leaf', level: 3, description: '', parentIds: [child.id]);
    final archived = db
        .createTag(name: 'archived', level: 1, description: '', parentIds: []);
    db.archiveTag(archived.id);
    db.setMovieTaxonomy(
        movieId: first.id,
        updateCategory: false,
        categoryId: null,
        updateTagIds: true,
        tagIds: [parent.id]);
    raw = sqlite3.open('$data/db/mujing.sqlite');
    final hidden =
        db.createEmptySeries(title: 'Merged', categoryId: category.id);
    db.setMovieTaxonomy(
        movieId: hidden.id,
        updateCategory: false,
        categoryId: null,
        updateTagIds: true,
        tagIds: [leaf.id]);
    raw.execute("UPDATE movies SET lifecycle_state = 'merged' WHERE id = ?",
        [hidden.id]);

    for (final operation in ['clearMovieLinks', 'deleteTags']) {
      final denied = await request('cleanup', {'operation': operation},
          token: 'viewer-token');
      check(denied.$1 == 403, 'viewer cannot perform bulk cleanup');
    }
    check(
        (await request('movie-associations', {}, token: 'viewer-token')).$1 ==
            403,
        'viewer cannot import relationships');
    check((await request('cleanup', {'operation': 'unknown'})).$1 == 400,
        'invalid operations are rejected');
    check(
        (await request('cleanup',
                    {'operation': 'clearMovieLinks', 'extra': 'x' * 2048}))
                .$1 ==
            400,
        'bulk request body is bounded');

    Map<String, Object?> payload(List<Object?> films) => {
          'format': 'mujing-adult-tag-enrichment-review',
          'version': 1,
          'films': films,
        };
    final response = await request(
        'movie-associations',
        payload([
          {
            'code': 'abf-001',
            'previewTags': ['leaf', 'leaf']
          },
          {
            'code': 'dup-1',
            'previewTags': ['leaf']
          },
          {
            'code': 'MISSING',
            'previewTags': ['leaf']
          },
        ]));
    check(response.$1 == 200, 'valid association batch succeeds');
    final report = response.$2['data'] as Map;
    check(
        report['updated'] == 1 &&
            report['ambiguous'] == 1 &&
            report['unmatched'] == 1,
        'normalized match, ambiguity and missing films are reported');
    check(
        db
            .tagsForMovie(first.id)
            .map((t) => t.id)
            .toSet()
            .containsAll([parent.id, leaf.id]),
        'existing relationships are preserved');
    final source = raw.select(
        'SELECT source_kind FROM movie_metadata_field_sources '
        "WHERE movie_id = ? AND field_key = 'tags'",
        [first.id]);
    check(source.single['source_kind'] == 'manual',
        'import protects manual tag choices');
    final revisions = db.revisions;
    final retry = await request(
        'movie-associations',
        payload([
          {
            'code': 'ABF001',
            'previewTags': ['leaf']
          },
        ]));
    check(
        (retry.$2['data'] as Map)['unchanged'] == 1 &&
            db.revisions.entries.every((e) => e.value == revisions[e.key]),
        'repeated import performs no business writes');
    final missingTag = await request(
        'movie-associations',
        payload([
          {
            'code': 'ABF001',
            'previewTags': ['child', 'not-found']
          },
        ]));
    check(
        (missingTag.$2['data'] as Map)['failed'] == 1 &&
            !db.tagsForMovie(first.id).any((t) => t.id == child.id),
        'one missing tag prevents a partially applied film');
    check(
        (await request(
                    'movie-associations',
                    payload([
                      {'code': 'ABF001', 'previewTags': []},
                      {'code': 'abf_001', 'previewTags': []},
                    ])))
                .$1 ==
            400,
        'duplicate normalized codes are rejected');
    check(
        (await request(
                    'movie-associations',
                    payload(List.filled(
                      501,
                      {'code': 'ABF001', 'previewTags': []},
                    ))))
                .$1 ==
            400,
        'association transaction size is bounded');

    final fresh =
        db.createTag(name: 'fresh', level: 1, description: '', parentIds: []);
    raw.execute(
        '''CREATE TRIGGER fail_tag_batch BEFORE INSERT ON movie_tag_links
      WHEN NEW.tag_id = '${child.id}' BEGIN SELECT RAISE(ABORT, 'test failure'); END''');
    var rolledBack = false;
    try {
      db.associateMovieTags([
        NasMovieTagAssociation(code: 'ABF001', tagNames: ['fresh', 'child']),
      ]);
    } on SqliteException {
      rolledBack = true;
    }
    check(
        rolledBack &&
            !db
                .tagsForMovie(first.id)
                .any((t) => t.id == child.id || t.id == fresh.id),
        'database failures roll back the complete transaction');
    raw.execute('DROP TRIGGER fail_tag_batch');
    db.deleteTag(fresh.id);

    final deletion = await request('cleanup', {'operation': 'deleteTags'});
    final deleted = deletion.$2['data'] as Map;
    check(
        deleted['total'] == 3 &&
            deleted['completed'] == 0 &&
            deleted['failed'] == 3,
        'referenced tags and their parents remain protected');
    final clear = await request('cleanup', {'operation': 'clearMovieLinks'});
    final cleared = clear.$2['data'] as Map;
    check(
        cleared['total'] == 3 &&
            cleared['completed'] == 1 &&
            cleared['skipped'] == 2,
        'all active films are handled with accurate skipped counts');
    final afterClear = db.revisions;
    check(db.tagsForMovie(hidden.id).single.id == leaf.id,
        'clear links leaves merged source audit relationships intact');
    await request('cleanup', {'operation': 'clearMovieLinks'});
    check(db.revisions.entries.every((e) => e.value == afterClear[e.key]),
        'clearing already empty relationships performs no business writes');
    final removed = await request('cleanup', {'operation': 'deleteTags'});
    check(
        (removed.$2['data'] as Map)['completed'] == 3 &&
            db.findTag(archived.id) != null,
        'all three levels are removed and archived tags are kept');
    check(db.validateIntegrity(), 'bulk operations preserve SQLite integrity');
    stdout.writeln('tag_batch_api_test: PASS');
  } finally {
    client.close(force: true);
    raw?.dispose();
    await server.stop();
    await root.delete(recursive: true);
  }
}
