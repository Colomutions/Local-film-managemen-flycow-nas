import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import '../lib/mujing_nas.dart';
import '../lib/src/disk_work_queue.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  var playing = true;
  var simultaneous = 0;
  var maximum = 0;
  var reservedMicros = 0;
  final paced = DiskWorkQueue(
      playbackActive: () => playing,
      backgroundBytesPerSecond: 1024,
      delay: (duration) async {
        simultaneous++;
        if (simultaneous > maximum) maximum = simultaneous;
        reservedMicros += duration.inMicroseconds;
        await Future<void>.delayed(Duration.zero);
        simultaneous--;
      });
  await Future.wait([
    paced.read(Stream.value(List<int>.filled(512, 0))).drain<void>(),
    paced.read(Stream.value(List<int>.filled(512, 1))).drain<void>(),
  ]);
  check(maximum == 1 && reservedMicros == 1000000,
      'background streams share one read budget');
  playing = false;
  await paced.pace(1024);
  check(reservedMicros == 1000000,
      'idle playback does not delay background work');
  final queue = DiskWorkQueue();
  final gate = Completer<void>();
  final calls = <String>[];
  final first = queue.run('scan', () async {
    calls.add('first');
    await gate.future;
    return 1;
  });
  final duplicate = queue.run('scan', () async {
    calls.add('duplicate');
    return 2;
  });
  final next = queue.run('next', () async {
    calls.add('next');
    return 3;
  });
  await Future<void>.delayed(Duration.zero);
  check(calls.join(',') == 'first', 'one storage job at a time');
  gate.complete();
  check(await first == 1 && await duplicate == 1 && await next == 3,
      'duplicate jobs share result');
  check(await queue.run('after', () async => 4) == 4,
      'failed jobs do not poison queue');

  final root = await Directory.systemTemp.createTemp('mujing-io-test-');
  final media = Directory('${root.path}/media');
  final video = File('${media.path}/test/one.mp4');
  await video.parent.create(recursive: true);
  await video.writeAsBytes(List.generate(32, (i) => i));
  final data = '${root.path}/data';
  final db = NasLibraryDatabase(data);
  final state = NasPersistentState(serverId: 'io-test', tokens: {
    sha256.convert(utf8.encode('test-token')).toString(): NasDeviceToken(
        deviceId: 'test-device',
        scope: 'admin',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 1))),
  });
  await NasPersistentStateStore(data).save(state);
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
      logger: NasDiagnosticLogger(minimumLevel: 'ERROR'));
  try {
    await server.start();
    final disk = db.listMediaRoots().first;
    final category = db.createCategory('test');
    db.replaceCategoryMediaSources(categoryId: category.id, sources: [
      NasCategoryMediaSourceInput(mediaRootId: disk.id, relativePath: 'test')
    ]);
    var probes = 0;
    final probe = NasMediaMetadataProbe(runner: (_, __) async {
      probes++;
      return ProcessResult(
          0,
          0,
          '{"streams":[{"width":1920,"height":1080}],"format":{"duration":"120"}}',
          '');
    });
    Future<void> scan() async {
      await db.scanCategory(
          categoryId: category.id,
          mediaRootId: disk.id,
          mediaService:
              NasMediaService(mediaDir: media.path, fixtureRelativePath: null),
          metadataProbe: probe);
    }

    await scan();
    final raw = sqlite3.open('$data/db/mujing.sqlite');
    try {
      final before = raw.select('SELECT * FROM episodes').single;
      await scan();
      final after = raw.select('SELECT * FROM episodes').single;
      check(jsonEncode(before) == jsonEncode(after),
          'unchanged scan does not rewrite episodes');
      check(probes == 1, 'unchanged scan does not probe video');
    } finally {
      raw.dispose();
    }
    final revisions = db.revisions;
    try {
      db.transaction(() {
        db.createCategory('rolled back');
        throw StateError('rollback');
      });
    } catch (_) {}
    check(jsonEncode(revisions) == jsonEncode(db.revisions),
        'revision counters roll back with transaction');
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    Future<Reply> request(String method, String path,
            {Object? body, String? etag, bool authorized = true}) =>
        call(base, method, path,
            body: body, etag: etag, authorized: authorized);
    final home = await request('GET', '/api/v1/cinema-home');
    check(home.status == 200 && home.etag != null,
        'home is available with revision');
    check(
        (await request('GET', '/api/v1/cinema-home', etag: home.etag)).status ==
            304,
        'unchanged home has no payload');
    check(
        (await request('GET', '/api/v1/cinema-home',
                    etag: home.etag, authorized: false))
                .status ==
            401,
        '304 cannot bypass auth');
    final movie = db.listMovies().single;
    final episode = db.episodesForMovie(movie.id).single;
    final session = await request('POST', '/api/v1/playback/sessions', body: {
      'contentId': movie.id,
      'episodeId': episode.id,
      'purpose': 'playback'
    });
    final id = (session.json['data'] as Map)['sessionId'];
    check(id != null, 'playback session created');
    await request('GET', '/api/v1/playback/sessions/$id/stream');
    check(
        (await request('POST', '/api/v1/playback/sessions/$id/started'))
                .status ==
            200,
        'playback starts');
    final body = {'positionMs': 45000, 'durationMs': 120000, 'state': 'paused'};
    await request('PATCH', '/api/v1/playback/sessions/$id/progress',
        body: body);
    final pausedRevision = db.revisions['watch'];
    await request('PATCH', '/api/v1/playback/sessions/$id/progress',
        body: body);
    check(db.revisions['watch'] == pausedRevision,
        'paused duplicate does not write');
    final finished = await request(
        'POST', '/api/v1/playback/sessions/$id/finish',
        body: {'positionMs': 10000, 'durationMs': 120000});
    check(finished.status == 204, 'finish commits final backwards seek');
    check(
        db.resumePositionMsForEpisode(
                movieId: movie.id, episodeId: episode.id) ==
            10000,
        'final position saved');
    final finishRevision = db.revisions['watch'];
    check(
        (await request('POST', '/api/v1/playback/sessions/$id/finish',
                    body: body))
                .status ==
            204,
        'finish retry is idempotent');
    check(db.revisions['watch'] == finishRevision,
        'finish retry does not rewrite history');
    check(
        (await request('GET', '/api/v1/cinema-home', etag: home.etag)).status ==
            200,
        'real library change invalidates home');
    await video.delete();
    await scan();
    check(!db.episodesForMovie(movie.id).single.isAvailable,
        'missing file becomes unavailable after complete scan');
    print('disk_io_optimization_test: PASS');
  } finally {
    await server.stop();
    await root.delete(recursive: true);
  }
}

class Reply {
  Reply(this.status, this.bytes, this.etag);
  final int status;
  final List<int> bytes;
  final String? etag;
  Map<String, dynamic> get json =>
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
}

Future<Reply> call(Uri base, String method, String path,
    {Object? body, String? etag, bool authorized = true}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, base.resolve(path));
    if (authorized) request.headers.set('authorization', 'Bearer test-token');
    if (etag != null) request.headers.set('if-none-match', etag);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    return Reply(
        response.statusCode,
        await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
        response.headers.value('etag'));
  } finally {
    client.close(force: true);
  }
}
