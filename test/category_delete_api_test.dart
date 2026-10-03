import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import '../lib/mujing_nas.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('mujing-category-delete-');
  final media = Directory('${temp.path}/media');
  await media.create();
  final source = File('${media.path}/target.mp4');
  await source.writeAsBytes([1, 2, 3]);
  final db = NasLibraryDatabase('${temp.path}/data');
  final server = NasHealthServer(NasConfig(bindHost: '127.0.0.1', port: 0,
    serverName: 'Test', advertiseUrl: null, pairingCode: 'test-pairing-code',
    fixtureMediaRelativePath: null, mediaRootName: '测试', scanOnStart: false,
    managedCategoryLibrary: true, dataDir: db.dataDir, mediaDir: media.path,
    timezone: 'Asia/Shanghai'), libraryDatabase: db);
  sqlite.Database? raw;
  try {
    await server.start();
    final root = db.ensureConfiguredMediaRoot(rootName: 'test', containerPath: media.path);
    final category = db.createCategory('删除目标');
    final other = db.createCategory('保留分类');
    final empty = db.createEmptySeries(title: '空影集', categoryId: category.id);
    raw = sqlite.sqlite3.open('${db.dataDir}/db/mujing.sqlite');
    raw.execute('PRAGMA foreign_keys=ON');
    for (final id in ['target', 'kept']) {
      raw.execute('''INSERT INTO movies(id,title,category_id,created_at,updated_at,is_favorite)
        VALUES (?,?,?,'now','now',1)''', [id, id, id == 'target' ? category.id : other.id]);
      raw.execute('''INSERT INTO episodes(id,movie_id,media_root_id,title,relative_path,file_size,is_available,updated_at)
        VALUES (?,?,?,? ,?,3,1,'now')''', ['ep-$id', id, root.id, id, '$id.mp4']);
      raw.execute('''INSERT INTO mdcng_import_records(id,movie_id,episode_id,nfo_file_name,
        nfo_content_hash,applied_fields_json,created_at) VALUES (?,?,?,'file.nfo','hash','[]','now')''',
        ['nfo-$id', id, 'ep-$id']);
      raw.execute('''INSERT INTO movie_metadata_field_sources(movie_id,field_key,source_kind,import_record_id,updated_at)
        VALUES (?,'summary','mdcng',?,'now')''', [id, 'nfo-$id']);
      raw.execute('''INSERT INTO playback_history(id,movie_id,episode_id,started_at)
        VALUES (?,?,?,'now')''', ['history-$id', id, 'ep-$id']);
      raw.execute("INSERT INTO episode_playback_progress VALUES (?,?,1,3,'now')", [id, 'ep-$id']);
      raw.execute("INSERT INTO scrape_fields VALUES ('movie',?,'summary','value',0,'now')", [id]);
    }
    raw.execute('''INSERT INTO movies(id,title,category_id,created_at,updated_at,lifecycle_state,merged_into_movie_id)
      VALUES ('merged','旧归并',?,'now','now','merged','target')''', [category.id]);
    final actor = db.createActor(stageName: '保留演员');
    db.setMovieActorIds(movieId: 'target', actorIds: [actor.id]);
    db.setMovieActorIds(movieId: 'kept', actorIds: [actor.id]);
    final artwork = NasArtworkService(db.dataDir);
    final poster = await artwork.savePoster(movieId: 'target', mimeType: 'image/jpeg', bytes: [255, 216, 255]);
    raw.execute('UPDATE movies SET poster_file_name=? WHERE id=?', [poster, 'target']);
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    Future<(int, Map<String, dynamic>)> request(String method, String path,
        {String? token, Map<String, dynamic>? body}) async {
      final client = HttpClient();
      try {
        final req = await client.openUrl(method, base.resolve(path));
        if (token != null) req.headers.set('Authorization', 'Bearer $token');
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
        }
        final res = await req.close();
        final content = await utf8.decoder.bind(res).join();
        return (res.statusCode, content.isEmpty ? <String, dynamic>{} : jsonDecode(content) as Map<String, dynamic>);
      } finally { client.close(force: true); }
    }
    final info = await request('GET', '/api/v1/server-info');
    Future<String> pair(String scope) async {
      final session = await request('POST', '/api/v1/pairing/sessions',
        body: {'serverId': info.$2['data']['serverId'], 'requestedScope': scope});
      final result = await request('POST', '/api/v1/pairing/sessions/${session.$2['data']['pairingSessionId']}/confirm',
        body: {'pairingPassword': 'test-pairing-code'});
      return result.$2['data']['accessToken'] as String;
    }
    final admin = await pair('admin'), viewer = await pair('viewer');
    final path = '/api/v1/admin/categories/${category.id}';
    check((await request('DELETE', path)).$1 == 401, '未认证不能删除');
    check((await request('DELETE', path, token: viewer)).$1 == 403, '普通用户不能删除');
    // 在最后一步注入数据库失败，验证之前的影片与审计清理会一起回滚。
    raw.execute('''CREATE TRIGGER fail_category_delete BEFORE DELETE ON library_categories
      BEGIN SELECT RAISE(ABORT, '模拟删除失败'); END''');
    check((await request('DELETE', path, token: admin)).$1 == 500, '模拟数据库失败');
    check(db.findCategory(category.id) != null && db.findMovie('target') != null &&
        db.findMovie(empty.id) != null, '失败回滚分类、影片和空影集');
    check(raw.select('SELECT * FROM mdcng_import_records').length == 2 &&
        raw.select("SELECT merged_into_movie_id FROM movies WHERE id='merged'").single['merged_into_movie_id'] == 'target',
        '失败回滚导入审计与归并引用');
    check(await artwork.poster(poster) != null, '数据库失败不删除海报副本');
    raw.execute('DROP TRIGGER fail_category_delete');
    final removed = await request('DELETE', path, token: admin);
    check(removed.$1 == 204, '含归并与 MDCNG 审计的分类应成功删除，实际 ${removed.$1}');
    check(db.findCategory(category.id) == null && db.findMovie(empty.id) == null, '分类及空影集移除');
    check(raw.select('SELECT id FROM movies').single['id'] == 'kept', '移除目标和归并来源，保留其他分类');
    for (final table in ['episodes', 'mdcng_import_records', 'movie_metadata_field_sources',
        'playback_history', 'episode_playback_progress', 'scrape_fields']) {
      check(raw.select('SELECT * FROM $table').length == 1, '$table 仅保留其他分类记录');
    }
    check(db.findActor(actor.id)!.movieCount == 1, '演员资料保留，影片关联减少');
    check(await artwork.poster(poster) == null, '清理 NAS 内部海报副本');
    check(await source.exists(), '保留源视频');
    check(raw.select('PRAGMA foreign_key_check').isEmpty, '外键完整性');
    check((await request('DELETE', path, token: admin)).$1 == 404, '重复删除返回不存在');
    check(db.removeMovieFromIndex('kept') != null && db.findCategory(other.id) != null,
        '同一清理逻辑也支持导入过 MDCNG 的单部影片，保留所属分类');
    check(raw.select('PRAGMA foreign_key_check').isEmpty, '单片删除后外键完整');
    stdout.writeln('category_delete_api_test: PASS');
  } finally {
    raw?.dispose();
    await server.stop();
    if (!temp.absolute.path.startsWith('${Directory.systemTemp.absolute.path}${Platform.pathSeparator}')) {
      throw StateError('临时目录边界无效');
    }
    await temp.delete(recursive: true);
  }
}
