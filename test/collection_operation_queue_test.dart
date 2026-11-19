import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/mujing_nas.dart';
import '../lib/src/disk_work_queue.dart';
import '../lib/src/http/movies.dart';
import '../lib/src/http/presenter.dart';
import '../lib/src/library/library_values.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

class _ObservedQueue extends DiskWorkQueue {
  String? _prefix;
  Completer<void>? _observed;

  Future<void> watch(String prefix) {
    _prefix = prefix;
    _observed = Completer<void>();
    return _observed!.future;
  }

  @override
  Future<T> run<T>(String key, Future<T> Function() action) {
    if (_prefix != null && key.startsWith(_prefix!)) {
      _prefix = null;
      _observed!.complete();
    }
    return super.run(key, action);
  }
}

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('collection-queue-');
  final db = NasLibraryDatabase('${temp.path}/data');
  await db.open();
  final queue = _ObservedQueue();
  final client = HttpClient();
  final config = NasConfig(
    bindHost: '127.0.0.1',
    port: 0,
    serverName: 'test',
    advertiseUrl: null,
    pairingCode: null,
    fixtureMediaRelativePath: null,
    mediaRootName: 'media',
    scanOnStart: false,
    managedCategoryLibrary: true,
    dataDir: db.dataDir,
    mediaDir: temp.path,
    timezone: 'Asia/Shanghai',
    allowSourceRename: true,
  );
  final api = NasMoviesHttpApi(
    libraryDatabase: db,
    library: NasFixtureLibrary(),
    mediaService:
        NasMediaService(mediaDir: temp.path, fixtureRelativePath: null),
    config: config,
    presenter: NasLibraryPresenter(db, config),
    artworkService: NasArtworkService(db.dataDir),
    hasActivePlayback: (_) => false,
    diskWork: queue,
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    try {
      final path = request.uri.path;
      if (path.endsWith('/source-name')) {
        await api.renameAdminEpisodeSource(request);
      } else if (path.endsWith('/episodes')) {
        await api.mergeAdminCollectionEpisodes(request);
      } else if (path.endsWith('/split')) {
        await api.splitAdminCollectionEpisodes(request);
      } else if (path.endsWith('/apply')) {
        await api.applyCollectionMigration(request);
      } else if (path.endsWith('/preview')) {
        await api.composeAdminMovies(request, preview: true);
      } else {
        await api.composeAdminMovies(request, preview: false);
      }
    } catch (error) {
      request.response.statusCode = 500;
      request.response.write(jsonEncode({'error': error.toString()}));
      await request.response.close();
    }
  });
  final raw = sqlite3.open('${db.dataDir}/db/mujing.sqlite');
  try {
    final category = db.createCategory('Films');
    final media = db.ensureConfiguredMediaRoot(
        rootName: 'disk', containerPath: temp.path);
    db.replaceCategoryMediaSources(categoryId: category.id, sources: [
      NasCategoryMediaSourceInput(
          mediaRootId: media.id, relativePath: 'library'),
    ]);
    String movie(String title, {bool single = false}) {
      final value = db.createEmptySeries(title: title, categoryId: category.id);
      if (single)
        raw.execute(
            "UPDATE movies SET entry_type='single' WHERE id=?", [value.id]);
      return value.id;
    }

    final first = movie('first', single: true);
    final second = movie('second', single: true);
    final target = movie('target');
    void episode(String id, String movieId, String path) {
      raw.execute("""INSERT INTO episodes(
        id,movie_id,media_root_id,title,relative_path,file_size,is_available,updated_at,natural_sort_key)
        VALUES(?,?,?,?,?,1,1,'now',?)""",
          [id, movieId, media.id, path, path, naturalSortKey(path)]);
    }

    episode('e2', first, 'library/work/2.mkv');
    episode('e10', second, 'library/work/10.mkv');
    Future<(int, Map)> request(String path, Object body) async {
      final req = await client
          .postUrl(Uri.parse('http://127.0.0.1:${server.port}/api/v1/$path'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final response = await req.close();
      return (
        response.statusCode,
        jsonDecode(await utf8.decoder.bind(response).join()) as Map
      );
    }

    Future<Map> queued(String prefix, String path, Object body,
        void Function() unchanged) async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      final scan = queue.run<void>('active-scan', () async {
        entered.complete();
        await gate.future;
      });
      await entered.future;
      final observed = queue.watch(prefix);
      final response = request(path, body);
      await observed.timeout(const Duration(seconds: 5));
      unchanged();
      gate.complete();
      await scan;
      final result = await response;
      check(result.$1 == 200,
          'queued operation succeeds: $path -> ${result.$1} ${result.$2}');
      return result.$2;
    }

    await queued(
        'collection-merge:',
        'admin/collections/$target/episodes',
        {
          'episodeIds': ['e2', 'e10'],
          'metadataSourceMovieId': first,
        },
        () => check(
            db.findEpisode('e2')!.movieId == first, 'merge waits for scan'));
    check(db.episodesForMovie(target).length == 2, 'merge applied after scan');
    final split = await queued(
        'collection-split:',
        'admin/collections/$target/split',
        {
          'episodeIds': ['e2', 'e10'],
        },
        () => check(
            db.episodesForMovie(target).length == 2, 'split waits for scan'));
    final singles =
        (split['data']['items'] as List).map((m) => m['id'] as String).toSet();
    check(singles.length == 2, 'split produced singles');
    final candidate = db.collectionMigrationPreview().single;
    final migrated = await queued(
        'collection-migration:',
        'admin/collection-migrations/apply',
        {
          'key': candidate.key,
          'metadataSourceMovieId': candidate.sourceMovieIds.first,
        },
        () => check(singles.contains(db.findEpisode('e2')!.movieId),
            'migration waits for scan'));
    final series = migrated['data']['id'] as String;
    check(
        db.setCollectionEpisodeOrder(
            movieId: series, mode: 'manual', episodeIds: ['e10', 'e2']),
        'fixture manual order');
    final extra = movie('extra', single: true);
    episode('e1', extra, 'library/other/1.mkv');
    final selection = {
      'movieIds': [series, extra],
      'metadataSourceMovieId': series
    };
    final preview =
        await request('admin/collection-compositions/preview', selection);
    check(preview.$1 == 200, 'preview succeeds');
    final plan = preview.$2['data'] as Map;
    final ordered =
        (plan['episodes'] as List).map((e) => e['id'] as String).toList();
    check(ordered.join(',') == 'e1,e2,e10',
        'automatic preview ignores source manual order');
    final composed = await request('admin/collection-compositions', {
      ...selection,
      'previewToken': plan['previewToken'],
      'episodeOrder': ordered.reversed.toList(),
      'sortMode': 'automatic',
    });
    check(composed.$1 == 201, 'automatic composition succeeds');
    final composedId = composed.$2['data']['movieId'] as String;
    check(
        db.episodesForMovie(composedId).map((e) => e.id).join(',') ==
            ordered.join(','),
        'preview and automatic final order agree');
    final source = File('${temp.path}/library/other/1.mkv');
    await source.parent.create(recursive: true);
    await source.writeAsBytes([1, 2, 3]);
    await queued('source-rename:', 'admin/episodes/e1/source-name', {
      'sourceName': 'renamed.mkv',
    }, () {
      check(source.existsSync(), 'source rename waits for scan');
      check(db.findEpisode('e1')!.relativePath.endsWith('/1.mkv'),
          'source rename index waits for scan');
    });
    final renamed = File('${source.parent.path}/renamed.mkv');
    check(renamed.existsSync() && !source.existsSync(),
        'queued rename changes the same source file after scan');
    raw.execute(
        "CREATE TRIGGER reject_rename BEFORE UPDATE OF relative_path ON episodes BEGIN SELECT RAISE(ABORT,'injected rename failure'); END");
    final failedRename = await request('admin/episodes/e1/source-name', {
      'sourceName': 'rollback.mkv',
    });
    raw.execute('DROP TRIGGER reject_rename');
    check(
        failedRename.$1 == 500 &&
            (failedRename.$2['error'] as Map)['code'] ==
                'source_metadata_update_failed',
        'database failure is reported');
    check(
        renamed.existsSync() &&
            !File('${source.parent.path}/rollback.mkv').existsSync() &&
            db.findEpisode('e1')!.relativePath.endsWith('/renamed.mkv'),
        'failed queued rename restores source filename and database index');
    check(db.validateIntegrity(), 'database integrity');
    stdout.writeln('collection operation queue tests passed');
  } finally {
    client.close(force: true);
    raw.dispose();
    await server.close(force: true);
    await db.close();
    await temp.delete(recursive: true);
  }
}
