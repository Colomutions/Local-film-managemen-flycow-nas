import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import '../lib/mujing_nas.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

class _RequestStartSink implements NasLogSink {
  String? _suffix;
  Completer<void>? _entered;

  Future<void> waitFor(String suffix) {
    _suffix = suffix;
    _entered = Completer<void>();
    return _entered!.future;
  }

  @override
  Future<void> write(String line) async {
    final record = jsonDecode(line) as Map;
    if (record['event'] == 'http.request.start' &&
        _suffix != null &&
        (record['route'] as String).endsWith(_suffix!)) {
      _suffix = null;
      _entered!.complete();
    }
  }
}

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('mujing-compose-');
  final media = Directory('${root.path}${Platform.pathSeparator}media');
  final data = '${root.path}/data';
  for (final path in [
    'disk1/films/001.mp4',
    'disk2/films/002.mp4',
    'disk1/films/原影集 - 影集/003.mp4'
  ]) {
    final file = File(
        '${media.path}${Platform.pathSeparator}${path.replaceAll('/', Platform.pathSeparator)}');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3, 4]);
  }
  final db = NasLibraryDatabase(data);
  await NasPersistentStateStore(data)
      .save(NasPersistentState(serverId: 'compose-test', tokens: {
    for (final scope in ['admin', 'viewer'])
      sha256.convert(utf8.encode('$scope-token')).toString(): NasDeviceToken(
          deviceId: scope,
          scope: scope,
          expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)))
  }));
  final requestLog = _RequestStartSink();
  final server = NasHealthServer(
      NasConfig(
          bindHost: '127.0.0.1',
          port: 0,
          serverName: 'test',
          advertiseUrl: null,
          pairingCode: null,
          fixtureMediaRelativePath: null,
          mediaRootName: 'media',
          scanOnStart: false,
          managedCategoryLibrary: true,
          dataDir: data,
          mediaDir: media.path,
          timezone: 'Asia/Shanghai'),
      libraryDatabase: db,
      logger: NasDiagnosticLogger(stdoutSink: requestLog));
  final client = HttpClient();
  Database? raw;
  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    Future<(int, Map<String, dynamic>)> request(String path, Object? body,
        {String method = 'POST', String token = 'admin-token'}) async {
      final req = await client.openUrl(method, base.resolve('/api/v1/$path'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final response = await req.close();
      final text = await utf8.decoder.bind(response).join();
      return (
        response.statusCode,
        text.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(text) as Map<String, dynamic>
      );
    }

    final one = db.ensureConfiguredMediaRoot(
        rootName: 'disk1',
        containerPath: '${media.path}${Platform.pathSeparator}disk1');
    final two = db.ensureConfiguredMediaRoot(
        rootName: 'disk2',
        containerPath: '${media.path}${Platform.pathSeparator}disk2');
    final category = db.createCategory('Films');
    db.replaceCategoryMediaSources(categoryId: category.id, sources: [
      NasCategoryMediaSourceInput(mediaRootId: one.id, relativePath: 'films'),
      NasCategoryMediaSourceInput(mediaRootId: two.id, relativePath: 'films')
    ]);
    final probe = NasMediaMetadataProbe(
        runner: (_, __) async => ProcessResult(
            0,
            0,
            '{"streams":[{"width":1920,"height":1080}],"format":{"duration":"60"}}',
            ''));
    Future<void> scan() => db.scanCategory(
        categoryId: category.id,
        mediaRootId: one.id,
        mediaService:
            NasMediaService(mediaDir: media.path, fixtureRelativePath: null),
        metadataProbe: probe);
    await scan();
    final movies = db.listMovies();
    check(movies.length == 3,
        'three source movies: ${movies.map((m) => '${m.title}:${m.episodeCount}').join(',')}');
    final first = movies.singleWhere((m) => m.title == '001');
    final second = movies.singleWhere((m) => m.title == '002');
    final existingSeries = movies.singleWhere((m) => m.entryType == 'series');
    final ids = [first.id, second.id, existingSeries.id];
    final firstEpisode = db.episodesForMovie(first.id).single;
    final secondEpisode = db.episodesForMovie(second.id).single;
    raw = sqlite3.open('$data/db/mujing.sqlite');
    for (final actor in ['a', 'b'])
      raw.execute(
          '''INSERT INTO actors(id,profile_identity,stage_name,created_at,updated_at)
      VALUES (?,?,?,?,?)''', [actor, actor, 'Actor $actor', 'now', 'now']);
    for (final link in [(first.id, 'a'), (second.id, 'a'), (second.id, 'b')]) {
      raw.execute(
          'INSERT INTO movie_actor_links VALUES (?,?)', [link.$1, link.$2]);
    }
    final tags = [
      for (final name in ['Tag A', 'Tag B'])
        db.createTag(name: name, level: 1, description: '', parentIds: [])
    ];
    for (final link in [
      (first.id, tags.first.id),
      (second.id, tags.first.id),
      (second.id, tags.last.id)
    ]) {
      raw.execute(
          'INSERT INTO movie_tag_links VALUES (?,?)', [link.$1, link.$2]);
    }
    db.updateMovieMetadata(
        movieId: first.id,
        catalogNumber: 'FIRST-001',
        updateCatalogNumber: true);
    db.updateMovieMetadata(
        movieId: second.id,
        title: 'Main title',
        summary: 'Main summary',
        catalogNumber: 'SECOND-002',
        updateCatalogNumber: true);
    db.setMovieFavorite(movieId: first.id, isFavorite: true);
    final publisher = db.createPublisher(displayName: 'Main publisher');
    raw.execute(
        'INSERT INTO movie_company_links(movie_id,company_id,role) VALUES (?,?,?)',
        [second.id, publisher.id, 'maker']);
    db.saveScrapeMovieProfile(second.id, {'source': 'main source'});
    raw.execute('UPDATE movies SET poster_file_name=? WHERE id=?',
        ['main.png', second.id]);
    for (final image in [
      ('same1.png', first.id, [1, 2, 3]),
      ('same2.png', second.id, [1, 2, 3]),
      ('unique.png', existingSeries.id, [4, 5, 6])
    ]) {
      await File('$data/artwork/carousel/${image.$1}').writeAsBytes(image.$3);
      db.addCarouselImage(movieId: image.$2, fileName: image.$1);
    }
    db.recordPlaybackStarted(movieId: first.id, episodeId: firstEpisode.id);
    db.savePlaybackProgress(
        movieId: first.id,
        episodeId: firstEpisode.id,
        positionMs: 15000,
        durationMs: 60000);
    Map<String, Object?> selection({String? source}) =>
        {'movieIds': ids, 'metadataSourceMovieId': source ?? second.id};
    const previewPath = 'admin/collection-compositions/preview';
    const applyPath = 'admin/collection-compositions';
    final job = db.createScrapeJob('pending composition check');
    final task = db.enqueueScrapeTask(
        [job], 'movie', 'compose-fixture', {'movieId': first.id});
    final pending = await request(previewPath, selection());
    check(
        pending.$1 == 409 &&
            jsonEncode(pending.$2).contains('collection_task_active'),
        'pending scraping prevents stale composition');
    raw.execute("UPDATE scrape_tasks SET status='done' WHERE id=?", [task]);
    final defaultPlan =
        (await request(previewPath, selection(source: first.id))).$2['data']
            as Map;
    check(defaultPlan['catalogNumber'] == 'FIRST-001',
        'current movie can supply main metadata');
    check(
        (await request(previewPath, selection(), token: 'viewer-token')).$1 ==
            403,
        'viewer cannot preview');
    check((await request(applyPath, {}, token: 'viewer-token')).$1 == 403,
        'viewer cannot compose');
    check(
        (await request(previewPath, {
              'movieIds': [first.id, first.id],
              'metadataSourceMovieId': first.id
            }))
                .$1 ==
            400,
        'duplicate selection rejected');
    final empty = db.createEmptySeries(title: 'empty', categoryId: category.id);
    check(
        (await request(previewPath, {
              'movieIds': [first.id, empty.id],
              'metadataSourceMovieId': first.id
            }))
                .$1 ==
            409,
        'empty series rejected');
    final wrongCategory = db.createCategory('Other');
    raw.execute('UPDATE movies SET category_id=? WHERE id=?',
        [wrongCategory.id, second.id]);
    check((await request(previewPath, selection())).$1 == 409,
        'cross-category rejected');
    raw.execute(
        'UPDATE movies SET category_id=? WHERE id=?', [category.id, second.id]);
    raw.execute('UPDATE media_roots SET is_online=0 WHERE id=?', [two.id]);
    final offlinePlan =
        (await request(previewPath, selection())).$2['data'] as Map;
    check((offlinePlan['episodes'] as List).any((e) => e['available'] == false),
        'offline episodes retained');
    raw.execute('UPDATE media_roots SET is_online=1 WHERE id=?', [two.id]);
    final started = await request('playback/sessions', {
      'contentId': second.id,
      'episodeId': secondEpisode.id,
      'purpose': 'preview'
    });
    check(started.$1 == 200, 'preview session created');
    final plan = (await request(previewPath, selection())).$2['data'] as Map;
    check(plan['title'] == 'Main title' && plan['imageCount'] == 2,
        'main metadata and content gallery dedup');
    check(
        (plan['actors'] as List).length == 2 &&
            (plan['tags'] as List).length == 2,
        'actor and tag union');
    check(plan['isFavorite'] == true, 'favorite union');
    Map<String, Object?> apply(Map preview) => {
          ...selection(),
          'previewToken': preview['previewToken'],
          'sortMode': 'manual',
          'episodeOrder': [
            (preview['episodes'] as List)[2]['id'],
            (preview['episodes'] as List)[0]['id'],
            (preview['episodes'] as List)[1]['id']
          ]
        };
    final active = await request(applyPath, apply(plan));
    check(
        active.$1 == 409 &&
            jsonEncode(active.$2).contains('collection_playback_active'),
        'active preview prevents merge');
    final sessionId = (started.$2['data'] as Map)['sessionId'];
    check(
        (await request('playback/sessions/$sessionId', null, method: 'DELETE'))
                .$1 ==
            204,
        'close active preview');
    final stalePlan =
        (await request(previewPath, selection())).$2['data'] as Map;
    db.updateMovieMetadata(movieId: first.id, summary: 'Concurrent edit');
    check((await request(applyPath, apply(stalePlan))).$1 == 409,
        'concurrent metadata edit rejected');
    final fresh = (await request(previewPath, selection())).$2['data'] as Map;
    final invalidOrder = {
      ...apply(fresh),
      'episodeOrder': [firstEpisode.id, firstEpisode.id]
    };
    check((await request(applyPath, invalidOrder)).$1 == 400,
        'incomplete or repeated episode order rejected');
    final revisionsBeforeRollback = jsonEncode(db.revisions);
    final originalCount =
        raw.select('SELECT COUNT(*) n FROM movies').single['n'];
    raw.execute(
        "CREATE TRIGGER fail_compose BEFORE UPDATE OF movie_id ON episodes BEGIN SELECT RAISE(ABORT,'injected failure'); END");
    check((await request(applyPath, apply(fresh))).$1 == 500,
        'injected transaction failure');
    check(jsonEncode(db.revisions) == revisionsBeforeRollback,
        'rolled back composition does not invalidate resource versions');
    check(
        raw.select('SELECT COUNT(*) n FROM movies').single['n'] ==
                originalCount &&
            db.episodesForMovie(first.id).single.id == firstEpisode.id,
        'no orphan target or partial moves after rollback');
    raw.execute('DROP TRIGGER fail_compose');
    final playback = await request('playback/sessions', {
      'contentId': first.id,
      'episodeId': firstEpisode.id,
    });
    final playbackId = (playback.$2['data'] as Map)['sessionId'];
    final streamRequest = await client
        .getUrl(base.resolve('/api/v1/playback/sessions/$playbackId/stream'));
    streamRequest.headers.set('authorization', 'Bearer admin-token');
    await (await streamRequest.close()).drain<void>();
    check(
        (await request('playback/sessions/$playbackId/started', null)).$1 ==
            200,
        'real playback starts before the delayed-body race');
    // Flush request headers and a partial body, then wait until the handler is
    // reading it. Closing the session and merging must invalidate both captured
    // sessions before those bodies finish arriving.
    final delayedRequests = <HttpClientRequest>[];
    for (final suffix in ['progress', 'finish']) {
      final entered = requestLog.waitFor('/$suffix');
      final delayed = await client.postUrl(
          base.resolve('/api/v1/playback/sessions/$playbackId/$suffix'));
      delayed.headers.set('authorization', 'Bearer admin-token');
      delayed.headers.contentType = ContentType.json;
      delayed.bufferOutput = false;
      delayed.write('{"positionMs":');
      await delayed.flush();
      await entered.timeout(const Duration(seconds: 5));
      delayedRequests.add(delayed);
    }
    check(
        (await request('playback/sessions/$playbackId', null, method: 'DELETE'))
                .$1 ==
            204,
        'close playback while progress and finish bodies are incomplete');
    // Starting playback changed the selected movies' play counts.
    final racePlan =
        (await request(previewPath, selection())).$2['data'] as Map;
    final result = await request(applyPath, apply(racePlan));
    check(result.$1 == 201, 'compose succeeds');
    final targetId = (result.$2['data'] as Map)['movieId'] as String;
    final target = db.findMovieForAdmin(targetId)!;
    check(target.playCount == 2, 'play count preserved');
    final watchRevision = db.revisions['watch'];
    for (final delayed in delayedRequests) {
      delayed.write('59000,"durationMs":60000}');
      final reply = await delayed.close();
      check(reply.statusCode == 404, 'closed captured session is rejected');
      await reply.drain<void>();
    }
    check(db.revisions['watch'] == watchRevision,
        'late requests cannot rewrite progress or history after composition');
    check(
        db.movieCompanies(targetId).single['id'] == publisher.id &&
            db.scrapeMovieProfile(targetId)?['source'] == 'main source',
        'main company and source details preserved');
    final detailsReply = await request('movies/$targetId', null, method: 'GET');
    check(
        ((detailsReply.$2['data'] as Map)['compositionSources'] as List)
                .length ==
            3,
        'original titles and catalog numbers remain visible in collection details');
    check(
        target.title == 'Main title' &&
            target.summary == 'Main summary' &&
            target.isFavorite &&
            target.entryType == 'series' &&
            target.episodeCount == 3,
        'target metadata retained');
    check(
        db.actorsForMovie(targetId).length == 2 &&
            db.tagsForMovie(targetId).length == 2,
        'relations migrated');
    check(db.carouselImagesForMovie(targetId).length == 2,
        'deduplicated gallery transferred');
    check(
        db.episodesForMovie(targetId).map((e) => e.id).join(',') ==
            (apply(fresh)['episodeOrder'] as List).join(','),
        'explicit episode order retained');
    check(
        db
                .playbackProgressForEpisode(
                    movieId: targetId, episodeId: firstEpisode.id)
                ?.positionMs ==
            15000,
        'resume position retained');
    check(
        raw
            .select('SELECT movie_id FROM playback_history')
            .every((r) => r['movie_id'] == targetId),
        'history retargeted');
    check(ids.every((id) => db.findMovie(id) == null),
        'source movies hidden from wall');
    check(
        raw.select('SELECT catalog_number FROM movies WHERE id=?',
                [first.id]).single['catalog_number'] ==
            'FIRST-001',
        'original metadata audit preserved');
    check(
        db
            .metadataFieldSourcesForMovie(targetId)
            .values
            .every((f) => f.sourceKind == 'manual'),
        'manual metadata protected');
    check((await request(applyPath, apply(fresh))).$1 == 409,
        'repeat submit cannot duplicate collection');
    await scan();
    check(
        db.findMovieForAdmin(targetId)!.episodeCount == 3 &&
            ids.every((id) => db.findMovie(id) == null),
        'rescan preserves manual cross-disk composition');
    check(
        await File('${media.path}/disk1/films/001.mp4').exists() &&
            await File('${media.path}/disk2/films/002.mp4').exists(),
        'video files unchanged');
    check(db.validateIntegrity(), 'database integrity');
    stdout.writeln('collection composition API tests passed');
  } finally {
    client.close(force: true);
    raw?.dispose();
    await server.stop();
    await root.delete(recursive: true);
  }
}
