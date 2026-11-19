import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../lib/mujing_nas.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final temporary = await Directory.systemTemp.createTemp('mujing-filters-');
  final data = '${temporary.path}/data';
  final media = Directory('${temporary.path}/media');
  await media.create();
  await NasPersistentStateStore(data).save(NasPersistentState(
    serverId: 'filter-test',
    tokens: {
      sha256.convert(utf8.encode('viewer-token')).toString(): NasDeviceToken(
        deviceId: 'viewer',
        scope: 'viewer',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      ),
    },
  ));
  final db = NasLibraryDatabase(data);
  final server = NasHealthServer(
    NasConfig(
      bindHost: '127.0.0.1',
      port: 0,
      serverName: 'filter-test',
      advertiseUrl: null,
      pairingCode: null,
      fixtureMediaRelativePath: null,
      mediaRootName: 'filter-root',
      scanOnStart: false,
      managedCategoryLibrary: true,
      dataDir: data,
      mediaDir: media.path,
      timezone: 'Asia/Shanghai',
    ),
    libraryDatabase: db,
    logger: NasDiagnosticLogger(minimumLevel: 'ERROR'),
  );
  final client = HttpClient();
  Database? raw;
  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}/api/v1/');
    Future<(int, Map<String, dynamic>)> request(String path,
        {Object? body}) async {
      final req = await client.openUrl(
          body == null ? 'GET' : 'POST', base.resolve(path));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer viewer-token');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final response = await req.close();
      return (
        response.statusCode,
        jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>,
      );
    }

    final category = db.createCategory('Current');
    final other = db.createCategory('Other');
    final root = db.ensureConfiguredMediaRoot(
      rootName: 'filter-root',
      containerPath: media.path,
    );
    raw = sqlite3.open('$data/db/mujing.sqlite');
    NasLibraryMovie movie(String title,
        {bool series = false, String? categoryId, bool empty = false}) {
      final item = db.createEmptySeries(
          title: title, categoryId: categoryId ?? category.id);
      if (!series) {
        raw!.execute(
            "UPDATE movies SET entry_type='single' WHERE id=?", [item.id]);
      }
      if (!empty) {
        raw!.execute('''INSERT INTO episodes(
          id, movie_id, media_root_id, title, relative_path,
          file_size, is_available, updated_at
        ) VALUES(?,?,?,?,?,1,0,'now')''',
            ['episode-${item.id}', item.id, root.id, title, '$title.mp4']);
      }
      return item;
    }

    final offline = movie('01 Offline');
    final rawCast = movie('02 Unresolved cast');
    final variant = movie('03 AI variant');
    final series = movie('04 Unlinked series', series: true);
    final aiMovie = movie('05 AI');
    final linked = movie('06 Linked archived actor');
    final linkedSeries = movie('07 Linked series', series: true);
    final hidden = movie('08 Merged');
    movie('09 Other category', categoryId: other.id);
    movie('10 Empty single', empty: true);
    raw.execute(
        "UPDATE movies SET lifecycle_state='merged' WHERE id=?", [hidden.id]);
    db.saveScrapeMovieProfile(rawCast.id, {
      'actors': [
        {'name': 'Known source name without formal association'}
      ],
    });
    final ai = db.createTag(name: 'aI', level: 1);
    final aiVariant = db.createTag(name: 'AI换脸', level: 1);
    final child = db.createTag(
        name: 'AI child without direct AI link', level: 2, parentIds: [ai.id]);
    for (final link in [
      (aiMovie.id, ai.id),
      (variant.id, aiVariant.id),
      (series.id, child.id)
    ]) {
      raw.execute(
          'INSERT INTO movie_tag_links VALUES(?,?)', [link.$1, link.$2]);
    }
    db.archiveTag(ai.id);

    final freeFemale =
        db.createActor(stageName: 'Free Female', gender: 'female');
    final freeUnknown = db.createActor(stageName: 'Free Unknown');
    final freeMale = db.createActor(stageName: 'Free Male', gender: 'male');
    final freeIntersex =
        db.createActor(stageName: 'Free Intersex', gender: 'intersex');
    final mergedActor =
        db.createActor(stageName: 'Merged only', gender: 'female');
    final offlineActor =
        db.createActor(stageName: 'Offline linked', gender: 'female');
    final seriesActor =
        db.createActor(stageName: 'Series linked', gender: 'female');
    final archivedActor =
        db.createActor(stageName: 'Archived linked', gender: 'female');
    final archivedFree =
        db.createActor(stageName: 'Archived free', gender: 'female');
    for (final link in [
      (hidden.id, mergedActor.id),
      (linked.id, archivedActor.id),
      (linkedSeries.id, seriesActor.id)
    ]) {
      raw.execute(
          'INSERT INTO movie_actor_links VALUES(?,?)', [link.$1, link.$2]);
    }
    // An offline film remains a real association even when no media is mounted.
    final offlineLinked = movie('11 Offline linked');
    raw.execute('INSERT INTO movie_actor_links VALUES(?,?)',
        [offlineLinked.id, offlineActor.id]);
    db.archiveActor(archivedActor.id);
    db.archiveActor(archivedFree.id);

    Map<String, Object?> search({Object? missingActors = true, int page = 1}) =>
        {
          'q': '',
          'categoryId': category.id,
          'resolutions': [],
          'watchStates': [],
          'sort': 'title',
          'order': 'asc',
          'page': page,
          'pageSize': 2,
          'tagConditions': {'all': [], 'any': [], 'exclude': []},
          'missingActors': missingActors,
        };
    List<String> ids(Map<String, dynamic> json) =>
        ((json['data'] as Map)['items'] as List)
            .map((item) => (item as Map)['id'] as String)
            .toList();
    Map page(Map<String, dynamic> json) => json['page'] as Map;

    final first = await request('movies/search', body: search());
    check(
        first.$1 == 200 &&
            page(first.$2)['total'] == 4 &&
            page(first.$2)['hasMore'] == true,
        'missing-actor count and pagination include every matching record');
    check(ids(first.$2).join(',') == [offline.id, rawCast.id].join(','),
        'offline movies and unresolved cast names qualify without formal actor links');
    final second = await request('movies/search', body: search(page: 2));
    check(
        ids(second.$2).join(',') == [variant.id, series.id].join(',') &&
            page(second.$2)['hasMore'] == false,
        'exact AI label is excluded; other AI names and descendant-only links are not');
    final get = await request(
        'movies?categoryId=${category.id}&missingActors=true&sort=title&pageSize=100');
    check(
        get.$1 == 200 &&
            ids(get.$2).join(',') ==
                [offline.id, rawCast.id, variant.id, series.id].join(','),
        'GET browsing applies the same complete SQL filter');
    final ordinary =
        await request('movies/search', body: search(missingActors: false));
    check(page(ordinary.$2)['total'] == 8,
        'false preserves the existing category search');
    for (final invalid in ['true', 1, null]) {
      check(
          (await request('movies/search', body: search(missingActors: invalid)))
                  .$1 ==
              400,
          'POST missingActors accepts only booleans');
    }
    check((await request('movies?missingActors=1')).$1 == 400,
        'GET missingActors rejects invalid booleans');

    final zeroIds = {
      freeFemale.id,
      freeUnknown.id,
      freeMale.id,
      freeIntersex.id,
      mergedActor.id
    };
    final unlinked = await request('actors?unlinkedOnly=true&pageSize=100');
    check(
        unlinked.$1 == 200 &&
            page(unlinked.$2)['total'] == 5 &&
            ids(unlinked.$2).toSet().containsAll(zeroIds),
        'zero-link actors include unknown and other genders plus merged-only associations');
    check(
        ((unlinked.$2['data'] as Map)['items'] as List)
            .every((item) => (item as Map)['movieCount'] == 0),
        'zero-link results retain consistent movie counts');
    final females =
        await request('actors?unlinkedOnly=true&gender=female&pageSize=100');
    check(
        page(females.$2)['total'] == 2 &&
            ids(females.$2)
                .toSet()
                .containsAll({freeFemale.id, mergedActor.id}),
        'zero-link filtering composes with existing gender selection');
    final searched = await request('actors?unlinkedOnly=true&q=free%20female');
    check(ids(searched.$2).single == freeFemale.id,
        'zero-link filtering composes with normalized actor search');
    final archived = await request(
        'actors?unlinkedOnly=true&includeArchived=true&pageSize=100');
    check(
        page(archived.$2)['total'] == 6 &&
            ids(archived.$2).contains(archivedFree.id) &&
            !ids(archived.$2).contains(archivedActor.id),
        'archive visibility does not erase live associations');
    final paged = await request('actors?unlinkedOnly=true&pageSize=2&page=2');
    check(
        page(paged.$2)['total'] == 5 &&
            ids(paged.$2).length == 2 &&
            page(paged.$2)['hasMore'] == true,
        'actor pagination and totals are based on the filtered set');
    for (final invalid in ['1', 'True', '']) {
      check((await request('actors?unlinkedOnly=$invalid')).$1 == 400,
          'actor filter rejects invalid booleans');
    }
    for (final actor in [offlineActor, seriesActor]) {
      final details = await request('actors/${actor.id}');
      check((details.$2['data'] as Map)['movieCount'] == 1,
          'offline movies and series still count as live associations');
    }
    check(
        (await request('actors?unlinkedOnly=false&pageSize=100')).$2['page']
                ['total'] ==
            7,
        'false keeps all nonarchived actors');
    check(raw.select('PRAGMA integrity_check').single.values.single == 'ok',
        'filters do not mutate library data');
  } finally {
    raw?.dispose();
    client.close(force: true);
    await server.stop();
    await temporary.delete(recursive: true);
  }
  stdout.writeln('management_filter_api_test: PASS');
}
