import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite;
import '../lib/mujing_nas.dart';
import 'scrape_api_test.dart' show request;

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('mujing-series-poster-');
  final media = Directory('${temp.path}${Platform.pathSeparator}media');
  await media.create(recursive: true);
  for (final name in ['Older', 'Newer', 'Blank']) {
    await File('${media.path}${Platform.pathSeparator}$name.mp4')
        .writeAsBytes([1, 2, 3]);
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
    dataDir: '${temp.path}${Platform.pathSeparator}data',
    mediaDir: media.path,
  );
  final db = NasLibraryDatabase(config.dataDir);
  await db.open();
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
  final older = movies['Older']!,
      newer = movies['Newer']!,
      blank = movies['Blank']!;
  final artwork = NasArtworkService(config.dataDir);
  Future<void> poster(String id) async {
    final file = await artwork.savePoster(
      movieId: id,
      mimeType: 'image/jpeg',
      bytes: [0xff, 0xd8, 0xff, 0xd9],
    );
    db.updateMoviePosterFileName(movieId: id, posterFileName: file);
  }

  await poster(older.id);
  await poster(newer.id);
  final databasePath =
      '${config.dataDir}${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite';
  final dates = sqlite.sqlite3.open(databasePath);
  dates.execute(
      'UPDATE movies SET created_at=? WHERE id=?', ['2000-01-01', older.id]);
  dates.execute(
      'UPDATE movies SET created_at=? WHERE id=?', ['2001-01-01', newer.id]);
  dates.execute(
      'UPDATE movies SET created_at=? WHERE id=?', ['2002-01-01', blank.id]);
  dates.dispose();
  final publisher = db.createPublisher(displayName: '测试厂商');
  final series =
      db.createSeries(displayName: '测试系列', publisherId: publisher.id);
  final server = NasHealthServer(config, libraryDatabase: db);
  var running = false;
  try {
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
    Future<void> link(String movieId, String? seriesId) async {
      final result = await request(
          base, 'PATCH', '/api/v1/admin/movies/$movieId',
          token: token, body: {'seriesId': seriesId});
      check(result.$1 == 200, 'movie series association succeeds');
    }

    Future<Map> details() async {
      final response = await request(base, 'GET', '/api/v1/series/${series.id}',
          token: token);
      check(response.$1 == 200, 'series details succeed');
      return response.$2['data'] as Map;
    }

    String? posterMovie(Map data) {
      final url = data['posterUrl'] as String?;
      return url == null ? null : Uri.parse(url).pathSegments.last;
    }

    await link(blank.id, series.id);
    await link(newer.id, series.id);
    await link(older.id, series.id);
    var data = await details();
    check(data['movieCount'] == 3 && posterMovie(data) == newer.id,
        'first associated movie with a poster wins regardless of library order');
    final listed = await request(base, 'GET', '/api/v1/series', token: token);
    check(
        posterMovie((listed.$2['data']['items'] as List).single as Map) ==
            newer.id,
        'series wall uses the same inherited poster');
    final client = HttpClient();
    try {
      final req =
          await client.getUrl(base.resolve(data['posterUrl'] as String));
      req.headers.set('Authorization', 'Bearer $token');
      final response = await req.close();
      check(response.statusCode == 200,
          'inherited poster URL serves the original image');
      await response.drain<void>();
    } finally {
      client.close(force: true);
    }
    await request(base, 'PATCH', '/api/v1/admin/movies/${newer.id}',
        token: token, body: {'title': '编辑后的影片'});
    check(posterMovie(await details()) == newer.id,
        'editing does not reorder associations');
    await link(newer.id, null);
    check(posterMovie(await details()) == older.id,
        'removal falls back to the next poster');
    await link(newer.id, series.id);
    check(posterMovie(await details()) == older.id,
        'reattachment goes to the end');
    await poster(blank.id);
    check(posterMovie(await details()) == blank.id,
        'an earlier member can receive its first poster later');

    final ownFile = await artwork.saveManagedAsset(
      assetId: 'series-own-poster',
      mimeType: 'image/jpeg',
      bytes: [0xff, 0xd8, 0xff, 0xd9],
    );
    db.addManagedAsset(
        id: 'series-own-poster',
        purpose: 'series_poster',
        fileName: ownFile,
        mimeType: 'image/jpeg');
    db.updateSeries(series.id, {'poster_asset_id': 'series-own-poster'});
    data = await details();
    check(
        data['posterAsset']['id'] == 'series-own-poster' &&
            data['posterUrl'] == null,
        'explicit series poster takes precedence');
    db.updateSeries(series.id, {'poster_asset_id': null});

    await server.stop();
    running = false;
    await db.close();
    final legacy = sqlite.sqlite3.open(databasePath);
    legacy.execute('DROP TRIGGER movie_series_order_insert');
    legacy.execute('DROP TRIGGER movie_series_order_update');
    legacy.execute('DROP INDEX movies_series_link_order_idx');
    legacy.execute('ALTER TABLE movies DROP COLUMN series_link_order');
    legacy.execute('DELETE FROM schema_migrations WHERE version=40');
    legacy.dispose();
    final migrated = NasLibraryDatabase(config.dataDir);
    try {
      await migrated.open();
      check(migrated.firstPosterMovieForSeries(series.id)?.id == older.id,
          'legacy associations receive a deterministic order by library creation time');
      check(migrated.findSeries(series.id)?.movieCount == 3,
          'migration preserves every series association');
      check(migrated.validateIntegrity(),
          'migration preserves database integrity');
    } finally {
      await migrated.close();
    }
  } finally {
    if (running) await server.stop();
    await db.close();
    await temp.delete(recursive: true);
  }
  stdout.writeln('series_poster_api_test: PASS');
}
