import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/src/library/schema_repository.dart';
import '../lib/src/library_database.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

void mainMigration(int version, void Function(Database) body) {
  final raw = sqlite3.openInMemory();
  try {
    raw.execute('''
      CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT);
      INSERT INTO schema_migrations VALUES($version, 'fixture');
      CREATE TABLE movies(id TEXT PRIMARY KEY, title TEXT NOT NULL);
      INSERT INTO movies VALUES('old', '旧影片');
    ''');
    body(raw);
  } finally {
    raw.dispose();
  }
}

void _upgrade36() {
  mainMigration(36, (raw) {
    NasSchemaRepository(() => raw).migrate();
    check(
        raw
                .select('SELECT scan_grouping_mode FROM movies')
                .single
                .values
                .single ==
            'automatic',
        'v36 旧条目默认自动归组');
    raw.execute("INSERT INTO movies(id,title) VALUES('new','新影片')");
    check(
        raw
                .select("SELECT scan_grouping_mode FROM movies WHERE id='new'")
                .single
                .values
                .single ==
            'automatic',
        '新增条目沿用自动归组默认值');
    var rejectedInvalid = false;
    try {
      raw.execute("UPDATE movies SET scan_grouping_mode='other'");
    } on SqliteException {
      rejectedInvalid = true;
    }
    check(rejectedInvalid, '归组模式拒绝无效值');
    var rejectedNull = false;
    try {
      raw.execute('UPDATE movies SET scan_grouping_mode=NULL');
    } on SqliteException {
      rejectedNull = true;
    }
    check(rejectedNull, '归组模式不能为空');
    raw.execute("UPDATE movies SET scan_grouping_mode='manual' WHERE id='old'");
    NasSchemaRepository(() => raw).migrate();
    check(
        raw
                .select("SELECT scan_grouping_mode FROM movies WHERE id='old'")
                .single
                .values
                .single ==
            'manual',
        '重开迁移不覆盖人工归组标记');
    check(
        raw
                .select('SELECT MAX(version) AS v FROM schema_migrations')
                .single['v'] ==
            37,
        '迁移记录到 v37');
  });
}

void _upgrade35() {
  mainMigration(35, (raw) {
    raw.execute('''
      INSERT INTO movies VALUES('automatic', '自动排序');
      CREATE TABLE episodes(
        id TEXT PRIMARY KEY, movie_id TEXT, relative_path TEXT,
        natural_sort_key TEXT, manual_order INTEGER
      );
      INSERT INTO episodes VALUES('b','old','folder/B.mkv','old-key',10);
      INSERT INTO episodes VALUES('a','old','folder/a.mkv','old-key',NULL);
      INSERT INTO episodes VALUES('n10','automatic','folder/10.mkv','old-key',NULL);
      INSERT INTO episodes VALUES('n2','automatic','folder/2.mkv','old-key',NULL);
    ''');
    NasSchemaRepository(() => raw).migrate();
    final manual = raw.select("SELECT * FROM movies WHERE id='old'").single;
    check(
        manual['scan_grouping_mode'] == 'automatic' &&
            manual['episode_sort_mode'] == 'manual',
        '扫描归组默认值与已有人工分集排序独立');
    check(
        raw
                .select(
                    "SELECT id FROM episodes WHERE movie_id='old' ORDER BY manual_order")
                .map((row) => row['id'])
                .join(',') ==
            'b,a',
        'v35 连升保留原人工顺序及空尾');
    check(
        raw
                .select(
                    "SELECT manual_order FROM episodes WHERE movie_id='old' ORDER BY manual_order")
                .map((row) => row['manual_order'])
                .join(',') ==
            '0,1',
        '人工顺序归一化保留分集身份');
    check(
        raw
                .select(
                    "SELECT id FROM episodes WHERE movie_id='automatic' ORDER BY natural_sort_key")
                .map((row) => row['id'])
                .join(',') ==
            'n2,n10',
        '自动排序正常升级为自然序');
    final before = raw
        .select('SELECT * FROM episodes ORDER BY id')
        .map((row) => Map.of(row))
        .toList();
    NasSchemaRepository(() => raw).migrate();
    check(
        raw
                .select('SELECT * FROM episodes ORDER BY id')
                .map((row) => Map.of(row))
                .toList()
                .toString() ==
            before.toString(),
        '重复迁移不重写分集顺序');
  });
}

void _migrationRollback() {
  mainMigration(36, (raw) {
    raw.execute('''CREATE TRIGGER reject_v37 BEFORE INSERT ON schema_migrations
      WHEN NEW.version=37 BEGIN SELECT RAISE(ABORT, 'fixture failure'); END''');
    var rejected = false;
    try {
      NasSchemaRepository(() => raw).migrate();
    } on SqliteException {
      rejected = true;
    }
    check(
        rejected &&
            !raw
                .select('PRAGMA table_info(movies)')
                .any((row) => row['name'] == 'scan_grouping_mode'),
        'v37 失败时新列随事务整体回滚');
    check(
        raw
                .select('SELECT MAX(version) AS v FROM schema_migrations')
                .single['v'] ==
            36,
        '失败时不记入 v37');
    raw.execute('DROP TRIGGER reject_v37');
    NasSchemaRepository(() => raw).migrate();
    check(raw.select('PRAGMA integrity_check').single.values.single == 'ok',
        '回滚后可正常重试升级');
  });
}

Future<void> _splitManual() async {
  final temporary =
      await Directory.systemTemp.createTemp('scan-grouping-split-');
  final db = NasLibraryDatabase('${temporary.path}/data');
  Database? raw;
  try {
    await db.open();
    raw = sqlite3.open('${db.dataDir}/db/mujing.sqlite');
    raw.execute('PRAGMA foreign_keys=ON');
    final root = db.ensureConfiguredMediaRoot(
        rootName: 'disk', containerPath: '${temporary.path}/media');
    final category = db.createCategory('分类');
    final source = db.createEmptySeries(title: '待拆影集', categoryId: category.id);
    for (final id in ['one', 'two', 'three']) {
      raw.execute('''INSERT INTO episodes(
        id,movie_id,media_root_id,title,relative_path,file_size,is_available,updated_at
      ) VALUES(?,?,?,?,?,1,1,'fixture')''',
          [id, source.id, root.id, id, 'series/$id.mkv']);
    }
    final unrelated =
        db.createEmptySeries(title: '不参与影集', categoryId: category.id);
    check(
        db.splitEpisodesIntoSingles(
                    movieId: source.id, episodeIds: ['missing']) ==
                null &&
            raw.select('SELECT scan_grouping_mode FROM movies WHERE id=?',
                    [source.id]).single['scan_grouping_mode'] ==
                'automatic',
        '无效拆分不改变归组模式');
    final partial =
        db.splitEpisodesIntoSingles(movieId: source.id, episodeIds: ['one'])!;
    check(partial.length == 1 && db.findMovie(source.id)!.episodeCount == 2,
        '部分拆分保留原影集及剩余分集');
    for (final id in [source.id, partial.single.id]) {
      check(
          raw.select('SELECT scan_grouping_mode FROM movies WHERE id=?',
                  [id]).single['scan_grouping_mode'] ==
              'manual',
          '原影集与部分拆出影片标为人工归组');
    }
    final complete = db.splitEpisodesIntoSingles(
        movieId: source.id, episodeIds: ['two', 'three'])!;
    check(complete.length == 2 && db.findMovie(source.id) == null,
        '完整拆分仍隐藏空来源影集');
    check(
        raw.select('SELECT scan_grouping_mode FROM movies WHERE id!=?', [
          unrelated.id
        ]).every((row) => row['scan_grouping_mode'] == 'manual'),
        '完整拆分全部新旧条目均保留人工归组标记');
    check(
        raw.select('SELECT scan_grouping_mode FROM movies WHERE id=?',
                [unrelated.id]).single['scan_grouping_mode'] ==
            'automatic',
        '无关条目不受拆分影响');
    check(
        raw.select('PRAGMA foreign_key_check').isEmpty &&
            db.validateIntegrity(),
        '拆分后的外键与数据库完整性正常');
  } finally {
    raw?.dispose();
    await db.close();
    await temporary.delete(recursive: true);
  }
}

Future<void> main() async {
  _upgrade36();
  _upgrade35();
  _migrationRollback();
  await _splitManual();
  print('scan_grouping_mode_migration_test: PASS');
}
