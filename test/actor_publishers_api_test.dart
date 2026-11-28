import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite;
import '../lib/mujing_nas.dart';
import 'scrape_api_test.dart' show request;

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final temp =
      await Directory.systemTemp.createTemp('mujing-actor-publishers-');
  final media = await Directory('${temp.path}/media').create();
  for (final name in ['Direct', 'Series']) {
    await File('${media.path}/$name.mp4').writeAsBytes([1, 2, 3]);
  }
  final config = NasConfig(
    bindHost: '127.0.0.1',
    port: 0,
    serverName: 'Test',
    advertiseUrl: null,
    pairingCode: 'test-code',
    fixtureMediaRelativePath: null,
    mediaRootName: '媒体',
    scanOnStart: false,
    timezone: 'Asia/Shanghai',
    dataDir: '${temp.path}/data',
    mediaDir: media.path,
  );
  final db = NasLibraryDatabase(config.dataDir);
  await db.open();
  final server = NasHealthServer(config, libraryDatabase: db);
  var running = false;
  try {
    await db.scanConfiguredRoot(
      rootName: '媒体',
      containerPath: media.path,
      mediaService:
          NasMediaService(mediaDir: media.path, fixtureRelativePath: null),
      metadataProbe: NasMediaMetadataProbe(
          runner: (command, arguments) async =>
              ProcessResult(1, 0, '{"streams":[],"format":{}}', '')),
    );
    final movies = {for (final movie in db.listMovies()) movie.title: movie};
    final direct = movies['Direct']!, grouped = movies['Series']!;
    final publisher = db.createPublisher(displayName: '影片发行商');
    final seriesPublisher = db.createPublisher(displayName: '系列发行商');
    final manual = db.createPublisher(displayName: '历史手工发行商');
    final company = db.createPublisher(displayName: '刮削厂牌');
    final series =
        db.createSeries(displayName: '系列', publisherId: seriesPublisher.id);
    final actor = db.createActor(stageName: '演员');
    final otherActor = db.createActor(stageName: '手工关联演员');
    db.setActorPublisherIds(actorId: actor.id, publisherIds: [manual.id]);
    db.setMovieActorIds(
        movieId: direct.id, actorIds: [actor.id, otherActor.id]);
    db.setMovieActorIds(movieId: grouped.id, actorIds: [actor.id]);
    db.updateMovieRelations(
        movieId: direct.id,
        publisherId: publisher.id,
        seriesId: null,
        updatePublisherId: true,
        updateSeriesId: false);
    db.updateMovieRelations(
        movieId: grouped.id,
        seriesId: series.id,
        publisherId: null,
        updateSeriesId: true,
        updatePublisherId: false);
    final tag = db.createTag(name: '手工标签', level: 1, color: '#FF8800');
    db.setMovieTaxonomy(
        movieId: direct.id,
        updateCategory: false,
        categoryId: null,
        updateTagIds: true,
        tagIds: [tag.id]);
    db.addCarouselImage(movieId: direct.id, fileName: 'manual-capture.jpg');
    db.updateMovieMetadata(movieId: direct.id, summary: '手工简介');
    final raw = sqlite.sqlite3.open('${config.dataDir}/db/mujing.sqlite');
    raw.execute(
        'INSERT INTO movie_company_links(movie_id,company_id,role) VALUES (?,?,?)',
        [direct.id, company.id, 'label']);
    raw.execute(
        'INSERT INTO movie_company_links(movie_id,company_id,role) VALUES (?,?,?)',
        [direct.id, publisher.id, 'distributor']);
    raw.dispose();

    await server.start();
    running = true;
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await request(base, 'GET', '/api/v1/server-info');
    final session =
        await request(base, 'POST', '/api/v1/pairing/sessions', body: {
      'serverId': info.$2['data']['serverId'],
      'requestedScope': 'admin',
    });
    final paired = await request(base, 'POST',
        '/api/v1/pairing/sessions/${session.$2['data']['pairingSessionId']}/confirm',
        body: {'pairingPassword': 'test-code'});
    final token = paired.$2['data']['accessToken'] as String;
    Future<Set<String>> publishers() async {
      final response = await request(base, 'GET', '/api/v1/actors/${actor.id}',
          token: token);
      check(response.$1 == 200, 'actor details succeed');
      return (response.$2['data']['publishers'] as List)
          .map((p) => p['id'] as String)
          .toSet();
    }

    check(
        (await publishers())
                .containsAll([publisher.id, seriesPublisher.id, company.id]) &&
            (await publishers()).length == 3,
        'derive and deduplicate movie, series and company publishers');
    check(
        db
            .findActor(actor.id)!
            .publisherIds
            .toSet()
            .containsAll([publisher.id, seriesPublisher.id, company.id]),
        'database actor model also exposes derived publishers');
    check(db.publisherIdsForActor(actor.id).single == manual.id,
        'legacy manual links remain intact for compatibility and export');
    final listed = await request(base, 'GET', '/api/v1/actors', token: token);
    final listedActor = (listed.$2['data']['items'] as List)
        .singleWhere((a) => a['id'] == actor.id);
    check((listedActor['publishers'] as List).length == 3,
        'list and details use the same associations');
    check(db.actorsForPublisher(seriesPublisher.id).single.actor.id == actor.id,
        'reverse series publisher relation finds actor');

    db.setMovieActorIds(movieId: grouped.id, actorIds: []);
    check(!(await publishers()).contains(seriesPublisher.id),
        'unlinking a movie updates derived publishers immediately');
    db.archivePublisher(company.id);
    check(!(await publishers()).contains(company.id),
        'archived publishers are hidden');
    db.setMovieActorIds(movieId: grouped.id, actorIds: [actor.id]);
    final lifecycle = sqlite.sqlite3.open('${config.dataDir}/db/mujing.sqlite');
    lifecycle.execute(
        "UPDATE movies SET lifecycle_state='merged' WHERE id=?", [grouped.id]);
    lifecycle.dispose();
    check(!(await publishers()).contains(seriesPublisher.id),
        'merged source movies do not leave stale associations');

    check(db.findMovieForAdmin(direct.id)!.summary == '手工简介',
        'derived queries preserve manual summary');
    check(db.tagsForMovie(direct.id).single.id == tag.id,
        'derived queries preserve tags');
    check(db.findMovieForAdmin(direct.id)!.actors.length == 2,
        'derived queries preserve manual actors');
    final screenshots =
        sqlite.sqlite3.open('${config.dataDir}/db/mujing.sqlite');
    check(
        screenshots.select(
                'SELECT * FROM movie_carousel_images WHERE movie_id=?',
                [direct.id]).length ==
            1,
        'derived queries preserve viewing screenshots');
    screenshots.dispose();
    check(db.validateIntegrity(), 'database remains valid');
  } finally {
    if (running) await server.stop();
    await db.close();
    await temp.delete(recursive: true);
  }
  stdout.writeln('actor_publishers_api_test: PASS');
}
