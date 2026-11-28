import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite;
import '../lib/mujing_nas.dart';

void check(bool ok, String reason) {
  if (!ok) throw StateError(reason);
}

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('mujing-delete-test-');
  final media = Directory('${temp.path}/media')..createSync();
  final library = NasLibraryDatabase('${temp.path}/data');
  final server = NasHealthServer(
      NasConfig(
        bindHost: '127.0.0.1',
        port: 0,
        serverName: 'Test',
        advertiseUrl: null,
        pairingCode: 'test-pairing-code',
        fixtureMediaRelativePath: null,
        mediaRootName: 'test',
        scanOnStart: false,
        managedCategoryLibrary: true,
        allowSourceDelete: true,
        logLevel: 'ERROR',
        dataDir: library.dataDir,
        mediaDir: media.path,
        timezone: 'Asia/Shanghai',
      ),
      libraryDatabase: library);
  sqlite.Database? db;
  final client = HttpClient();
  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}/api/v1/');
    Future<(int, Map<String, dynamic>)> request(String method, String path,
        {String? token, Map<String, Object?>? body}) async {
      final req = await client.openUrl(method, base.resolve(path));
      if (token != null) req.headers.set('Authorization', 'Bearer $token');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close();
      final text = await utf8.decoder.bind(res).join();
      return (
        res.statusCode,
        text.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(text) as Map<String, dynamic>
      );
    }

    final info = await request('GET', 'server-info');
    final manifest = info.$2['data'];
    check(
        manifest['capabilities']['sourceDelete'] == true, 'delete capability');
    Future<String> pair(String scope) async {
      final session = await request('POST', 'pairing/sessions',
          body: {'serverId': manifest['serverId'], 'requestedScope': scope});
      final result = await request('POST',
          'pairing/sessions/${session.$2['data']['pairingSessionId']}/confirm',
          body: {'pairingPassword': 'test-pairing-code'});
      return result.$2['data']['accessToken'] as String;
    }

    final admin = await pair('admin'), viewer = await pair('viewer');
    final raw = db = sqlite.sqlite3.open('${library.dataDir}/db/mujing.sqlite');
    final roots = <String, NasMediaRoot>{};
    for (final disk in ['disk1', 'disk2']) {
      final dir = Directory('${media.path}/$disk')..createSync();
      roots[disk] = library.ensureConfiguredMediaRoot(
          rootName: disk, containerPath: dir.path);
    }
    raw.execute('UPDATE media_roots SET is_online=1');
    final category = library.createCategory('Films');
    File asset(String path, String contents) {
      final file = File('${media.path}/$path');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(contents);
      return file;
    }

    void movie(String id) => raw.execute(
        "INSERT INTO movies(id,title,category_id,created_at,updated_at) VALUES (?,?,?,'now','now')",
        [id, id, category.id]);
    void episode(String id, String movieId, String disk, String path) {
      final file = asset('$disk/$path', id);
      raw.execute(
          '''INSERT INTO episodes(id,movie_id,media_root_id,title,relative_path,file_size,
      media_modified_at,is_available,updated_at) VALUES (?,?,?,?,?,?,?,1,'now')''',
          [
            id,
            movieId,
            roots[disk]!.id,
            id,
            path,
            file.lengthSync(),
            file.statSync().modified.microsecondsSinceEpoch
          ]);
    }

    Future<Map<String, dynamic>> preview(String id) async {
      final res = await request('GET', 'admin/movies/$id/source-deletion',
          token: admin);
      check(res.$1 == 200, 'preview $id: ${res.$2}');
      return res.$2['data'] as Map<String, dynamic>;
    }

    Future<(int, Map<String, dynamic>)> commit(
            String id, Map<String, dynamic> plan) =>
        request('POST', 'admin/movies/$id/source-deletion',
            token: admin, body: {'previewToken': plan['previewToken']});
    movie('group');
    movie('kept');
    episode('a', 'group', 'disk1', 'work/A.mp4');
    episode('b', 'group', 'disk2', 'mixed/B.mkv');
    episode('c', 'kept', 'disk2', 'mixed/C.mp4');
    final nfo = asset(
        'disk1/work/A.nfo', '<movie><poster>custom.webp</poster></movie>');
    final own = asset('disk1/work/custom.webp', 'image');
    final gallery = asset('disk1/work/extrafanart/one.jpg', 'image');
    final unknown = asset('disk1/work/extrafanart/notes.txt', 'keep');
    final shared = asset('disk2/mixed/poster.jpg', 'image');
    final common = asset('disk2/mixed/extrafanart/one.jpg', 'image');
    final otherReference = asset('disk2/mixed/B-poster.jpg', 'also used by C');
    asset('disk2/mixed/C.nfo', '<movie><poster>B-poster.jpg</poster></movie>');
    final poster = File('${library.dataDir}/artwork/posters/shared.webp')
      ..writeAsStringSync('animated');
    raw.execute("UPDATE movies SET poster_file_name='shared.webp'");
    final screenshot =
        File('${library.dataDir}/artwork/carousel/group-still.png')
          ..writeAsStringSync('image');
    raw.execute(
        "INSERT INTO movie_carousel_images(id,movie_id,file_name,created_at) VALUES ('still','group','group-still.png','now')");
    movie('merged-source');
    final mergedPoster = File('${library.dataDir}/artwork/posters/old.webp')
      ..writeAsStringSync('original poster');
    raw.execute(
        "UPDATE movies SET lifecycle_state='merged', merged_into_movie_id='group', poster_file_name='old.webp' WHERE id='merged-source'");
    const endpoint = 'admin/movies/group/source-deletion';
    check((await request('GET', endpoint)).$1 == 401, 'requires pairing');
    check((await request('POST', endpoint, token: viewer)).$1 == 403,
        'viewer denied');
    check((await request('POST', endpoint, token: admin, body: {})).$1 == 400,
        'requires explicit token');
    final first = await preview('group');
    check(
        first['episodeCount'] == 2 && nfo.existsSync() && gallery.existsSync(),
        'preview reads only');
    raw.execute(
        "UPDATE media_roots SET is_online=0 WHERE id=?", [roots['disk2']!.id]);
    check((await commit('group', first)).$1 == 409 && nfo.existsSync(),
        'offline disk blocks all');
    raw.execute(
        "UPDATE media_roots SET is_online=1 WHERE id=?", [roots['disk2']!.id]);
    own.writeAsStringSync('changed artwork');
    check((await commit('group', first)).$1 == 409 && nfo.existsSync(),
        'stale preview blocks all');
    final result = await commit('group', await preview('group'));
    check(result.$1 == 200, 'cross disk commit: ${result.$2}');
    for (final path in ['disk1/work/A.mp4', 'disk2/mixed/B.mkv']) {
      check(!File('${media.path}/$path').existsSync(), 'removed $path');
    }
    check(
        !nfo.existsSync() &&
            !own.existsSync() &&
            !gallery.existsSync() &&
            !screenshot.existsSync() &&
            !mergedPoster.existsSync(),
        'owned assets removed');
    check(
        shared.existsSync() &&
            common.existsSync() &&
            unknown.existsSync() &&
            otherReference.existsSync() &&
            poster.existsSync() &&
            library.findMovie('kept') != null,
        'preserved shared assets');
    check(library.findMovie('group') == null, 'index removed');
    // Only the video and a manually uploaded animated poster; force DB failure after unlink.
    movie('bare');
    episode('bare-ep', 'bare', 'disk2', '3D/bare.mp4');
    final animated = File('${library.dataDir}/artwork/posters/bare.webp')
      ..writeAsStringSync('animated');
    raw.execute(
        "UPDATE movies SET poster_file_name='bare.webp' WHERE id='bare'");
    raw.execute(
        "CREATE TRIGGER fail_finish BEFORE DELETE ON movies WHEN OLD.id='bare' BEGIN SELECT RAISE(ABORT,'test'); END");
    check(
        (await commit('bare', await preview('bare'))).$1 == 500 &&
            !animated.existsSync() &&
            library.findMovie('bare') != null,
        'keep index for retry after DB failure');
    raw.execute('DROP TRIGGER fail_finish');
    final retry = await preview('bare');
    check((retry['alreadyDeleted'] as List).length == 1, 'journaled video');
    check(
        (await commit('bare', retry)).$1 == 200 &&
            library.findMovie('bare') == null,
        'retry finishes');
    check(
        (await request('DELETE', 'admin/movies/kept', token: admin)).$1 ==
                204 &&
            File('${media.path}/disk2/mixed/C.mp4').existsSync() &&
            !poster.existsSync(),
        'legacy index-only and last poster owner');
    check(raw.select('PRAGMA foreign_key_check').isEmpty, 'db integrity');
    stdout.writeln('movie_source_deletion_api_test: PASS');
  } finally {
    client.close(force: true);
    db?.dispose();
    await server.stop();
    if (temp.parent.absolute.path == Directory.systemTemp.absolute.path)
      await temp.delete(recursive: true);
  }
}
