import 'dart:io';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import '../lib/mujing_nas.dart';
import 'scrape_api_test.dart' show request;

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('mujing-category-counts-');
  final db = NasLibraryDatabase('${temp.path}/data');
  final server = NasHealthServer(NasConfig(bindHost: '127.0.0.1', port: 0,
      serverName: 'Test', advertiseUrl: null, pairingCode: 'test-pairing-code',
      fixtureMediaRelativePath: null, mediaRootName: '测试', scanOnStart: false,
      dataDir: db.dataDir, mediaDir: '${temp.path}/media', timezone: 'Asia/Shanghai'),
      libraryDatabase: db);
  sqlite.Database? raw;
  try {
    await server.start();
    final root = db.ensureConfiguredMediaRoot(rootName: 'test', containerPath: '${temp.path}/media');
    final big = db.createCategory('AV'), empty = db.createCategory('空分类');
    raw = sqlite.sqlite3.open('${db.dataDir}/db/mujing.sqlite');
    raw.execute('PRAGMA foreign_keys=ON');
    raw.execute('BEGIN');
    for (var i = 0; i < 864; i++) {
      raw.execute('INSERT INTO movies(id,title,category_id,created_at,updated_at) VALUES (?,?,?,?,?)',
          ['movie-$i', '影片$i', big.id, 'now', 'now']);
      raw.execute('''INSERT INTO episodes(id,movie_id,media_root_id,title,relative_path,file_size,is_available,updated_at)
          VALUES (?,?,?,?,?,1,1,'now')''', ['ep-$i', 'movie-$i', root.id, '分集$i', '$i.mp4']);
    }
    raw.execute("UPDATE movies SET entry_type='series' WHERE id='movie-0'");
    raw.execute('''INSERT INTO episodes(id,movie_id,media_root_id,title,relative_path,file_size,is_available,updated_at)
        VALUES ('extra','movie-0',?,'额外分集','extra.mp4',1,0,'now')''', [root.id]);
    raw.execute('''INSERT INTO movies(id,title,category_id,lifecycle_state,created_at,updated_at)
        VALUES ('merged','旧归并',?,'merged','now','now'), ('orphan','无文件单片',?,'active','now','now')''',
        [big.id, big.id]);
    raw.execute('COMMIT');
    check(db.findCategory(big.id)!.movieCount == 864 && db.categoryForMovie('movie-0')!.movieCount == 864,
        '总数按逻辑影片计，不受分页、多分集、归并记录影响');
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await request(base, 'GET', '/api/v1/server-info');
    Future<String> pair(String scope) async {
      final session = await request(base, 'POST', '/api/v1/pairing/sessions',
          body: {'serverId': info.$2['data']['serverId'], 'requestedScope': scope});
      final result = await request(base, 'POST', '/api/v1/pairing/sessions/${session.$2['data']['pairingSessionId']}/confirm',
          body: {'pairingPassword': 'test-pairing-code'});
      return result.$2['data']['accessToken'] as String;
    }
    final viewer = await pair('viewer'), admin = await pair('admin');
    check((await request(base, 'GET', '/api/v1/categories')).$1 == 401, '统计沿用认证');
    check((await request(base, 'GET', '/api/v1/admin/categories', token: viewer)).$1 == 403,
        '分类管理继续限制管理员');
    for (final path in ['/api/v1/categories', '/api/v1/admin/categories']) {
      final result = await request(base, 'GET', '$path?sort=movieCount', token: path.contains('/admin/') ? admin : viewer);
      final items = (result.$2['data']['items'] as List).cast<Map>();
      check(items.first['id'] == big.id && items.first['movieCount'] == 864 && items.last['movieCount'] == 0,
          '公共及管理接口返回完整数量并按 NAS 统计排序');
    }
    final preview = await request(base, 'GET', '/api/v1/admin/mdcng-import-jobs/preview?categoryId=${big.id}', token: admin);
    check(preview.$1 == 200 && preview.$2['data']['movieCount'] == 864, '普通片库与 MDCNG 预览总数一致');
    raw.execute('UPDATE media_roots SET is_online=0 WHERE id=?', [root.id]);
    check(db.findCategory(big.id)!.movieCount == 864, '离线不使影片总数下降');
    db.removeMovieFromIndex('movie-1');
    check(db.findCategory(big.id)!.movieCount == 863, '移除索引后即刻更新统计');
    db.createEmptySeries(title: '手动空影集', categoryId: empty.id);
    check(db.findCategory(empty.id)!.movieCount == 1, '与影片墙一致，手动空影集按一部计');
    check((await request(base, 'GET', '/api/v1/categories?sort=invalid', token: viewer)).$1 == 400,
        '排序白名单校验');
    stdout.writeln('category_counts_api_test: PASS');
  } finally {
    raw?.dispose();
    await server.stop();
    if (!temp.absolute.path.startsWith('${Directory.systemTemp.absolute.path}${Platform.pathSeparator}')) {
      throw StateError('临时目录边界无效');
    }
    await temp.delete(recursive: true);
  }
}
