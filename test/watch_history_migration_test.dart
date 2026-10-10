import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final directory = await Directory.systemTemp
      .createTemp('mujing-nas-watch-history-migration-test-');
  final databaseDirectory = Directory(
    '${directory.path}${Platform.pathSeparator}db',
  );
  await databaseDirectory.create(recursive: true);
  final path =
      '${databaseDirectory.path}${Platform.pathSeparator}mujing.sqlite';
  final legacy = sqlite3.open(path);
  try {
    legacy.execute('''
      CREATE TABLE schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      );
      INSERT INTO schema_migrations(version, applied_at)
      VALUES (23, '2026-09-01T00:00:00.000Z');
      CREATE TABLE playback_history (
        id TEXT PRIMARY KEY,
        movie_id TEXT NOT NULL,
        episode_id TEXT NOT NULL,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        end_position_ms INTEGER,
        duration_ms INTEGER
      );
      INSERT INTO playback_history(
        id, movie_id, episode_id, started_at, ended_at, end_position_ms, duration_ms
      ) VALUES (
        'legacy-record', 'legacy-movie', 'legacy-episode',
        '2026-09-01T10:00:00.000Z', '2026-09-01T10:02:00.000Z', 120000, 300000
      );
      -- 保留 v23 影片关系供启动查询使用，后续 migration 会扩展这些表。
      CREATE TABLE movies (
        id TEXT PRIMARY KEY,
        lifecycle_state TEXT NOT NULL DEFAULT 'active',
        updated_at TEXT NOT NULL
      );
      CREATE TABLE episodes (
        id TEXT PRIMARY KEY,
        movie_id TEXT NOT NULL REFERENCES movies(id) ON DELETE CASCADE
      );
      -- v23 已包含资料实体与资产表；保留 migration 26/28 所需结构。
      CREATE TABLE managed_assets (
        id TEXT PRIMARY KEY,
        purpose TEXT NOT NULL,
        file_name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
      -- v14 的演员资料与关联表在启动时也会被查询，不能简化为只有 id。
      CREATE TABLE actors (
        id TEXT PRIMARY KEY,
        stage_name TEXT,
        original_name TEXT,
        translated_name TEXT,
        aliases_json TEXT NOT NULL DEFAULT '[]',
        gender TEXT CHECK(gender IN ('female', 'intersex', 'male')),
        birth_month TEXT,
        height_cm INTEGER,
        weight_kg INTEGER,
        measurements TEXT,
        body_type TEXT,
        country TEXT,
        debut_month TEXT,
        debut_description TEXT,
        photo_asset_id TEXT REFERENCES managed_assets(id) ON DELETE SET NULL,
        publisher_names_json TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        archived_at TEXT
      );
      CREATE TABLE movie_actor_links (
        movie_id TEXT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
        actor_id TEXT NOT NULL REFERENCES actors(id) ON DELETE RESTRICT,
        PRIMARY KEY(movie_id, actor_id)
      );
      CREATE TABLE publishers (id TEXT PRIMARY KEY);
      CREATE TABLE series (id TEXT PRIMARY KEY);
      -- v7 已包含画廊表；启动时会查询它以补记旧图片来源。
      CREATE TABLE movie_carousel_images (
        id TEXT PRIMARY KEY,
        movie_id TEXT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
        file_name TEXT NOT NULL UNIQUE,
        created_at TEXT NOT NULL
      );
    ''');
  } finally {
    legacy.dispose();
  }

  final database = NasLibraryDatabase(directory.path);
  try {
    await database.open();
  } finally {
    await database.close();
  }

  final upgraded = sqlite3.open(path);
  try {
    final row = upgraded.select('''
      SELECT last_reported_at, watch_duration_ms, last_position_ms,
             playback_status, device_id, device_platform
      FROM playback_history WHERE id = 'legacy-record'
    ''').single;
    _expect(
      row['last_reported_at'] == '2026-09-01T10:02:00.000Z' &&
          row['last_position_ms'] == 120000 &&
          row['playback_status'] == 'ended',
      '旧 playback_history 原地迁移为可展示的稳定观影记录',
    );
    _expect(
      row['watch_duration_ms'] == 0 &&
          row['device_id'] == 'legacy' &&
          row['device_platform'] == 'unknown',
      '旧记录保留兼容的设备和观看时长默认值',
    );
    final version = upgraded
        .select('SELECT MAX(version) AS version FROM schema_migrations')
        .single['version'];
    _expect(version == NasLibraryDatabase.currentSchemaVersion, '数据库版本升级完成');
  } finally {
    upgraded.dispose();
    await directory.delete(recursive: true);
  }

  stdout.writeln('watch_history_migration_test: PASS');
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('断言失败：$message');
}
