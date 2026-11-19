import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import '../lib/mujing_nas.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('mujing-episode-order-');
  final data = '${temp.path}/data';
  final db = NasLibraryDatabase(data);
  await NasPersistentStateStore(data).save(NasPersistentState(
    serverId: 'order-test',
    tokens: {
      for (final scope in ['admin', 'viewer'])
        sha256.convert(utf8.encode('$scope-token')).toString(): NasDeviceToken(
          deviceId: scope,
          scope: scope,
          expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
        ),
    },
  ));
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
        mediaDir: temp.path,
        timezone: 'Asia/Shanghai',
      ),
      libraryDatabase: db);
  final client = HttpClient();
  Database? raw;
  try {
    await server.start();
    final category = db.createCategory('Films');
    final media = db.ensureConfiguredMediaRoot(
        rootName: 'disk', containerPath: temp.path);
    final series =
        db.createEmptySeries(title: 'Series', categoryId: category.id);
    raw = sqlite3.open('$data/db/mujing.sqlite');
    for (final pair in [('e10', '10.mkv'), ('e2', '2.mkv'), ('e1', '1.mkv')]) {
      raw.execute('''INSERT INTO episodes(
        id,movie_id,media_root_id,title,relative_path,file_size,is_available,updated_at,natural_sort_key)
        VALUES(?,?,?,?,?,1,1,'now','old')''',
          [pair.$1, series.id, media.id, pair.$2, 'work/${pair.$2}']);
    }
    final path = '/api/v1/admin/collections/${series.id}/episode-order';
    Future<(int, Map)> request(String route,
        {String method = 'PUT', Object? body, String scope = 'admin'}) async {
      final req = await client.openUrl(
          method, Uri.parse('http://127.0.0.1:${server.port}$route'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $scope-token');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final response = await req.close();
      return (
        response.statusCode,
        jsonDecode(await utf8.decoder.bind(response).join()) as Map
      );
    }

    final manual = {
      'mode': 'manual',
      'episodeIds': ['e10', 'e1', 'e2']
    };
    check((await request(path, body: manual, scope: 'viewer')).$1 == 403,
        'viewer cannot reorder');
    check(
        (await request(path, body: {
              'mode': 'manual',
              'episodeIds': ['e1']
            }))
                .$1 ==
            409,
        'partial order rejected');
    check(db.collectionEpisodeSortMode(series.id) == 'automatic',
        'failed update leaves mode intact');
    check((await request(path, body: manual)).$1 == 200, 'manual order saved');
    check(
        db.episodesForMovie(series.id).map((e) => e.id).join(',') ==
            'e10,e1,e2',
        'manual order applied');
    final page =
        await request('/api/v1/movies/${series.id}/episodes', method: 'GET');
    check(page.$2['data']['sortMode'] == 'manual', 'list publishes mode');
    final stamp = raw.select('SELECT updated_at FROM movies WHERE id=?',
        [series.id]).single['updated_at'];
    check(
        (await request(path, body: manual)).$1 == 200, 'repeat order accepted');
    check(
        raw.select('SELECT updated_at FROM movies WHERE id=?',
                [series.id]).single['updated_at'] ==
            stamp,
        'same order skips writes');
    check(
        (await request(path, body: {
              'mode': 'manual',
              'episodeIds': ['e1', 'e1', 'e2']
            }))
                .$1 ==
            409,
        'duplicate ID rejected');
    check(
        (await request(path, body: {'mode': 'automatic', 'episodeIds': []}))
                .$1 ==
            400,
        'automatic rejects irrelevant IDs');
    check((await request(path, body: {'mode': 'automatic'})).$1 == 200,
        'automatic reset saved');
    check(db.collectionEpisodeSortMode(series.id) == 'automatic',
        'reset mode persisted');
    check(
        db.episodesForMovie(series.id).map((e) => e.id).join(',') ==
            'e1,e2,e10',
        'natural numeric order rebuilt');
    check(
        raw
            .select('SELECT manual_order FROM episodes')
            .every((r) => r['manual_order'] == null),
        'reset clears manual positions');
    check(db.validateIntegrity(), 'integrity');
    stdout.writeln('episode order API tests passed');
  } finally {
    client.close(force: true);
    raw?.dispose();
    await server.stop();
    await temp.delete(recursive: true);
  }
}
