import 'package:sqlite3/sqlite3.dart';

import '../content_file_names.dart';
import '../novels/novel_repository.dart';
import 'library_values.dart';

/// Applies versioned schema changes; does not own the connection lifecycle.
class NasSchemaRepository {
  NasSchemaRepository(this._connection);

  final Database Function() _connection;
  Database get _db => _connection();
  static const currentSchemaVersion = 34;

  void migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      );
    ''');
    final current = _db
            .select('SELECT MAX(version) AS version FROM schema_migrations')
            .first['version'] as int? ??
        0;
    if (current > currentSchemaVersion) {
      throw StateError(
        'Unsupported database schema version $current; '
        'this service supports up to $currentSchemaVersion.',
      );
    }
    if (current < 1) {
      _db.execute('''
      CREATE TABLE media_roots (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        container_path TEXT NOT NULL UNIQUE,
        read_only INTEGER NOT NULL,
        enabled INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE movies (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        summary TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE episodes (
        id TEXT PRIMARY KEY,
        movie_id TEXT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
        media_root_id TEXT NOT NULL REFERENCES media_roots(id),
        title TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        duration_ms INTEGER,
        file_size INTEGER NOT NULL,
        is_available INTEGER NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(media_root_id, relative_path)
      );
      CREATE INDEX episodes_movie_id_idx ON episodes(movie_id);
      CREATE INDEX episodes_root_path_idx ON episodes(media_root_id, relative_path);
    ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [1, now()],
      );
    }
    if (current < 2) {
      _db.execute('ALTER TABLE media_roots ADD COLUMN last_scanned_at TEXT');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [2, now()],
      );
    }
    if (current < 3) {
      _db.execute('''
        CREATE TABLE library_categories (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL UNIQUE,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE tags (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL UNIQUE,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE tag_placements (
          id TEXT PRIMARY KEY,
          tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
          parent_placement_id TEXT REFERENCES tag_placements(id) ON DELETE CASCADE,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(tag_id, parent_placement_id)
        );
        CREATE TABLE movie_tag_placements (
          movie_id TEXT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
          tag_placement_id TEXT NOT NULL REFERENCES tag_placements(id) ON DELETE CASCADE,
          PRIMARY KEY(movie_id, tag_placement_id)
        );
        ALTER TABLE movies ADD COLUMN category_id TEXT REFERENCES library_categories(id) ON DELETE SET NULL;
        CREATE INDEX movies_category_id_idx ON movies(category_id);
        CREATE INDEX tag_placements_tag_id_idx ON tag_placements(tag_id);
        CREATE INDEX tag_placements_parent_id_idx ON tag_placements(parent_placement_id);
        CREATE INDEX movie_tag_placements_placement_idx ON movie_tag_placements(tag_placement_id);
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [3, now()],
      );
    }
    if (current < 4) {
      _db.execute('ALTER TABLE movies ADD COLUMN poster_file_name TEXT');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [4, now()],
      );
    }
    if (current < 5) {
      _db.execute('ALTER TABLE episodes ADD COLUMN video_width INTEGER');
      _db.execute('ALTER TABLE episodes ADD COLUMN video_height INTEGER');
      _db.execute('ALTER TABLE episodes ADD COLUMN resolution_label TEXT');
      _db.execute('ALTER TABLE episodes ADD COLUMN media_modified_at INTEGER');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [5, now()],
      );
    }
    if (current < 6) {
      _db.execute('''
        ALTER TABLE library_categories ADD COLUMN media_relative_path TEXT;
        CREATE UNIQUE INDEX library_categories_media_relative_path_idx
          ON library_categories(media_relative_path)
          WHERE media_relative_path IS NOT NULL;
        -- The previous global-root scan has no safe category assignment.
        -- Its metadata is intentionally reset; the read-only media mount is
        -- never touched and categories/tags are retained.
        DELETE FROM movies;
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [6, now()],
      );
    }
    if (current < 7) {
      _db.execute('''
        CREATE TABLE movie_carousel_images (
          id TEXT PRIMARY KEY,
          movie_id TEXT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
          file_name TEXT NOT NULL UNIQUE,
          created_at TEXT NOT NULL
        );
        CREATE INDEX movie_carousel_images_movie_id_idx
          ON movie_carousel_images(movie_id, created_at);
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [7, now()],
      );
    }
    if (current < 8) {
      _db.execute(
        "ALTER TABLE movies ADD COLUMN actors_json TEXT NOT NULL DEFAULT '[]'",
      );
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [8, now()],
      );
    }
    if (current < 9) {
      _db.execute('''
        ALTER TABLE movies ADD COLUMN play_count INTEGER NOT NULL DEFAULT 0;
        CREATE TABLE episode_playback_progress (
          movie_id TEXT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
          episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
          position_ms INTEGER NOT NULL,
          duration_ms INTEGER NOT NULL,
          updated_at TEXT NOT NULL,
          PRIMARY KEY(movie_id, episode_id)
        );
        CREATE INDEX episode_playback_progress_movie_idx
          ON episode_playback_progress(movie_id, updated_at);
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [9, now()],
      );
    }
    if (current < 10) {
      _db.execute('''
        ALTER TABLE library_categories ADD COLUMN color TEXT;
        ALTER TABLE tags ADD COLUMN color TEXT;
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [10, now()],
      );
    }
    if (current < 11) {
      _db.execute('''
        CREATE TABLE playback_history (
          id TEXT PRIMARY KEY,
          movie_id TEXT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
          episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
          started_at TEXT NOT NULL,
          ended_at TEXT,
          end_position_ms INTEGER,
          duration_ms INTEGER
        );
        CREATE INDEX playback_history_started_idx
          ON playback_history(started_at DESC, id DESC);
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [11, now()],
      );
    }
    if (current < 12) {
      _db.execute('''
        ALTER TABLE movies ADD COLUMN original_title TEXT;
        ALTER TABLE movies ADD COLUMN catalog_number TEXT;
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [12, now()],
      );
    }
    if (current < 13) {
      // Do not interpret or rewrite the former string-only actor payload.
      // Actors are NAS-native entities now; legacy movie payloads have no
      // value and are deliberately left untouched.
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [13, now()],
      );
    }
    if (current < 14) {
      _db.execute('''
        CREATE TABLE managed_assets (
          id TEXT PRIMARY KEY,
          purpose TEXT NOT NULL CHECK(purpose IN ('actor_photo', 'movie_poster')),
          file_name TEXT NOT NULL UNIQUE,
          mime_type TEXT NOT NULL,
          created_at TEXT NOT NULL
        );
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
        CREATE INDEX actors_archived_created_idx ON actors(archived_at, created_at DESC);
        CREATE INDEX movie_actor_links_actor_idx ON movie_actor_links(actor_id, movie_id);
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [14, now()],
      );
    }
    if (current < 15) {
      _db.execute('''
        CREATE TABLE ai_metadata_tasks (
          id TEXT PRIMARY KEY,
          movie_id TEXT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
          instructions TEXT NOT NULL DEFAULT '',
          status TEXT NOT NULL CHECK(status IN ('queued', 'running', 'succeeded', 'failed')),
          result_json TEXT,
          error_code TEXT,
          created_at TEXT NOT NULL,
          finished_at TEXT
        );
        CREATE INDEX ai_metadata_tasks_movie_created_idx
          ON ai_metadata_tasks(movie_id, created_at DESC);
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [15, now()],
      );
    }
    if (current < 16) {
      _db.execute('''
        ALTER TABLE movies ADD COLUMN publisher_name TEXT;
        ALTER TABLE movies ADD COLUMN series_name TEXT;
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [16, now()],
      );
    }
    if (current < 17) {
      // 旧版资产用途约束无法直接扩展，重建表但保留所有既有资产记录。
      _db.execute('PRAGMA foreign_keys = OFF');
      try {
        _db.execute('''
          CREATE TABLE managed_assets_v17 (
            id TEXT PRIMARY KEY,
            purpose TEXT NOT NULL CHECK(purpose IN (
              'actor_photo', 'movie_poster', 'publisher_logo', 'series_poster'
            )),
            file_name TEXT NOT NULL UNIQUE,
            mime_type TEXT NOT NULL,
            created_at TEXT NOT NULL
          );
          INSERT INTO managed_assets_v17(id, purpose, file_name, mime_type, created_at)
            SELECT id, purpose, file_name, mime_type, created_at FROM managed_assets;
          DROP TABLE managed_assets;
          ALTER TABLE managed_assets_v17 RENAME TO managed_assets;

          CREATE TABLE publishers (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            original_name TEXT,
            country_region TEXT,
            founded_date TEXT,
            logo_asset_id TEXT REFERENCES managed_assets(id) ON DELETE SET NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            archived_at TEXT
          );
          CREATE TABLE series (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            original_name TEXT,
            translated_name TEXT,
            publisher_id TEXT NOT NULL REFERENCES publishers(id) ON DELETE RESTRICT,
            release_date TEXT,
            poster_asset_id TEXT REFERENCES managed_assets(id) ON DELETE SET NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            archived_at TEXT
          );
          ALTER TABLE movies ADD COLUMN publisher_id TEXT REFERENCES publishers(id) ON DELETE SET NULL;
          ALTER TABLE movies ADD COLUMN series_id TEXT REFERENCES series(id) ON DELETE SET NULL;
          CREATE INDEX publishers_archived_created_idx
            ON publishers(archived_at, created_at DESC);
          CREATE INDEX series_publisher_archived_created_idx
            ON series(publisher_id, archived_at, created_at DESC);
          CREATE INDEX movies_publisher_id_idx ON movies(publisher_id);
          CREATE INDEX movies_series_id_idx ON movies(series_id);

          CREATE TRIGGER movies_series_publisher_insert
          BEFORE INSERT ON movies
          WHEN NEW.series_id IS NOT NULL AND (
            NEW.publisher_id IS NULL OR
            NEW.publisher_id != (SELECT publisher_id FROM series WHERE id = NEW.series_id)
          )
          BEGIN
            SELECT RAISE(ABORT, 'series_publisher_mismatch');
          END;
          CREATE TRIGGER movies_series_publisher_update
          BEFORE UPDATE OF publisher_id, series_id ON movies
          WHEN NEW.series_id IS NOT NULL AND (
            NEW.publisher_id IS NULL OR
            NEW.publisher_id != (SELECT publisher_id FROM series WHERE id = NEW.series_id)
          )
          BEGIN
            SELECT RAISE(ABORT, 'series_publisher_mismatch');
          END;
        ''');
      } finally {
        _db.execute('PRAGMA foreign_keys = ON');
      }
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [17, now()],
      );
    }
    if (current < 18) {
      _db.execute('''
        CREATE TABLE actor_publisher_links (
          actor_id TEXT NOT NULL REFERENCES actors(id) ON DELETE CASCADE,
          publisher_id TEXT NOT NULL REFERENCES publishers(id) ON DELETE RESTRICT,
          PRIMARY KEY(actor_id, publisher_id)
        );
        CREATE INDEX actor_publisher_links_publisher_idx
          ON actor_publisher_links(publisher_id, actor_id);
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [18, now()],
      );
    }
    if (current < 19) {
      // SQLite 不能直接移除 NOT NULL，重建系列表以支持未归属发行商的草稿系列。
      _db.execute('PRAGMA foreign_keys = OFF');
      try {
        _db.execute('''
          DROP TRIGGER IF EXISTS movies_series_publisher_insert;
          DROP TRIGGER IF EXISTS movies_series_publisher_update;
          CREATE TABLE series_v19 (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            original_name TEXT,
            translated_name TEXT,
            publisher_id TEXT REFERENCES publishers(id) ON DELETE RESTRICT,
            release_date TEXT,
            poster_asset_id TEXT REFERENCES managed_assets(id) ON DELETE SET NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            archived_at TEXT
          );
          INSERT INTO series_v19(
            id, display_name, original_name, translated_name, publisher_id,
            release_date, poster_asset_id, created_at, updated_at, archived_at
          ) SELECT
            id, display_name, original_name, translated_name, publisher_id,
            release_date, poster_asset_id, created_at, updated_at, archived_at
          FROM series;
          DROP TABLE series;
          ALTER TABLE series_v19 RENAME TO series;
          CREATE INDEX series_publisher_archived_created_idx
            ON series(publisher_id, archived_at, created_at DESC);

          CREATE TRIGGER movies_series_publisher_insert
          BEFORE INSERT ON movies
          WHEN NEW.series_id IS NOT NULL AND (
            (SELECT publisher_id FROM series WHERE id = NEW.series_id) IS NULL OR
            NEW.publisher_id IS NULL OR
            NEW.publisher_id != (SELECT publisher_id FROM series WHERE id = NEW.series_id)
          )
          BEGIN
            SELECT RAISE(ABORT, 'series_publisher_mismatch');
          END;
          CREATE TRIGGER movies_series_publisher_update
          BEFORE UPDATE OF publisher_id, series_id ON movies
          WHEN NEW.series_id IS NOT NULL AND (
            (SELECT publisher_id FROM series WHERE id = NEW.series_id) IS NULL OR
            NEW.publisher_id IS NULL OR
            NEW.publisher_id != (SELECT publisher_id FROM series WHERE id = NEW.series_id)
          )
          BEGIN
            SELECT RAISE(ABORT, 'series_publisher_mismatch');
          END;
        ''');
      } finally {
        _db.execute('PRAGMA foreign_keys = ON');
      }
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [19, now()],
      );
    }
    if (current < 20) {
      // 已获授权：仅清理旧标签定义、路径归属和影片路径关联，绝不触及影片或媒体数据。
      _db.execute('PRAGMA foreign_keys = OFF');
      try {
        _db.execute('''
          DROP TABLE IF EXISTS movie_tag_placements;
          DROP TABLE IF EXISTS tag_placements;
          DROP TABLE IF EXISTS tags;

          CREATE TABLE tags (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            normalized_name TEXT NOT NULL UNIQUE,
            level INTEGER NOT NULL CHECK(level IN (1, 2, 3)),
            description TEXT NOT NULL DEFAULT '',
            color TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            archived_at TEXT
          );
          CREATE TABLE tag_parent_links (
            child_tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE RESTRICT,
            parent_tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE RESTRICT,
            created_at TEXT NOT NULL,
            PRIMARY KEY(child_tag_id, parent_tag_id),
            CHECK(child_tag_id != parent_tag_id)
          );
          CREATE TABLE movie_tag_links (
            movie_id TEXT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
            tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE RESTRICT,
            PRIMARY KEY(movie_id, tag_id)
          );
          CREATE INDEX tags_level_active_name_idx
            ON tags(level, archived_at, name COLLATE NOCASE);
          CREATE INDEX tag_parent_links_parent_idx
            ON tag_parent_links(parent_tag_id, child_tag_id);
          CREATE INDEX movie_tag_links_tag_idx
            ON movie_tag_links(tag_id, movie_id);
        ''');
      } finally {
        _db.execute('PRAGMA foreign_keys = ON');
      }
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [20, now()],
      );
    }
    if (current < 21) {
      // 搜索页的观看状态和首次扫描排序都在 NAS 的全库 SQL 内完成。
      _db.execute('''
        CREATE INDEX playback_history_movie_started_idx
          ON playback_history(movie_id, started_at DESC, id DESC);
        CREATE INDEX movies_created_id_idx ON movies(created_at DESC, id);
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [21, now()],
      );
    }
    if (current < 22) {
      // 影集归属和盘状态只保存在 NAS：影片条目不再绑定某个物理盘。
      _db.execute('''
        ALTER TABLE media_roots ADD COLUMN is_online INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE movies ADD COLUMN entry_type TEXT NOT NULL DEFAULT 'single'
          CHECK(entry_type IN ('single', 'series'));
        ALTER TABLE movies ADD COLUMN collection_key TEXT;
        ALTER TABLE episodes ADD COLUMN natural_sort_key TEXT NOT NULL DEFAULT '';
        ALTER TABLE episodes ADD COLUMN manual_order INTEGER;

        CREATE TABLE category_media_sources (
          id TEXT PRIMARY KEY,
          category_id TEXT NOT NULL REFERENCES library_categories(id) ON DELETE CASCADE,
          media_root_id TEXT NOT NULL REFERENCES media_roots(id) ON DELETE RESTRICT,
          relative_path TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(category_id, media_root_id, relative_path)
        );
        CREATE UNIQUE INDEX movies_collection_key_idx
          ON movies(collection_key) WHERE collection_key IS NOT NULL;
        CREATE INDEX category_media_sources_category_idx
          ON category_media_sources(category_id, media_root_id, relative_path);
        CREATE INDEX episodes_movie_sort_idx
          ON episodes(movie_id, manual_order, natural_sort_key, relative_path, id);
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [22, now()],
      );
    }
    if (current < 23) {
      // 归并来源保留其审计关系和旧引用，但不再参与普通影视或资料统计。
      _db.execute('''
        ALTER TABLE movies ADD COLUMN lifecycle_state TEXT NOT NULL DEFAULT 'active'
          CHECK(lifecycle_state IN ('active', 'merged'));
        ALTER TABLE movies ADD COLUMN merged_into_movie_id TEXT
          REFERENCES movies(id) ON DELETE RESTRICT;
        ALTER TABLE movies ADD COLUMN merged_at TEXT;
        CREATE INDEX movies_lifecycle_state_idx
          ON movies(lifecycle_state, category_id, entry_type);
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [23, now()],
      );
    }
    if (current < 24) {
      // 在既有 playback_history 上原地扩展，旧记录仍可读取且不产生第二套历史数据。
      _db.execute('''
        ALTER TABLE playback_history ADD COLUMN last_reported_at TEXT;
        ALTER TABLE playback_history ADD COLUMN watch_duration_ms INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE playback_history ADD COLUMN last_position_ms INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE playback_history ADD COLUMN playback_status TEXT NOT NULL DEFAULT 'ended';
        ALTER TABLE playback_history ADD COLUMN device_id TEXT NOT NULL DEFAULT 'legacy';
        ALTER TABLE playback_history ADD COLUMN device_platform TEXT NOT NULL DEFAULT 'unknown';
        UPDATE playback_history
        SET last_reported_at = COALESCE(ended_at, started_at),
            last_position_ms = COALESCE(end_position_ms, 0),
            playback_status = CASE WHEN ended_at IS NULL THEN 'playing' ELSE 'ended' END;
        CREATE INDEX playback_history_filter_idx
          ON playback_history(device_platform, started_at DESC, id DESC);
        CREATE INDEX playback_history_episode_recent_idx
          ON playback_history(episode_id, last_reported_at DESC, id DESC);
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [24, now()],
      );
    }
    if (current < 25) {
      final hasMoviesTable = _db
          .select(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'movies'",
          )
          .isNotEmpty;
      if (hasMoviesTable) {
        _db.execute('''
          ALTER TABLE movies ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0;
          CREATE INDEX movies_favorite_active_idx
            ON movies(is_favorite, lifecycle_state, updated_at DESC, id);
        ''');
      }
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [25, now()],
      );
    }
    if (current < 26) {
      _db.execute('''
        ALTER TABLE actors ADD COLUMN profile_identity TEXT;
        ALTER TABLE publishers ADD COLUMN profile_identity TEXT;
        ALTER TABLE series ADD COLUMN profile_identity TEXT;
        UPDATE actors SET profile_identity = id WHERE profile_identity IS NULL;
        UPDATE publishers SET profile_identity = id WHERE profile_identity IS NULL;
        UPDATE series SET profile_identity = id WHERE profile_identity IS NULL;
        CREATE UNIQUE INDEX actors_profile_identity_idx
          ON actors(profile_identity);
        CREATE UNIQUE INDEX publishers_profile_identity_idx
          ON publishers(profile_identity);
        CREATE UNIQUE INDEX series_profile_identity_idx
          ON series(profile_identity);
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [26, now()],
      );
    }
    if (current < 27) {
      // 只存导入审计与字段来源，不保存 NFO 原文、原始文件路径或外部链接。
      _db.execute('''
        CREATE TABLE mdcng_import_records (
          id TEXT PRIMARY KEY,
          movie_id TEXT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
          episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE RESTRICT,
          nfo_file_name TEXT NOT NULL,
          nfo_content_hash TEXT NOT NULL,
          applied_fields_json TEXT NOT NULL,
          created_at TEXT NOT NULL
        );
        CREATE INDEX mdcng_import_records_movie_created_idx
          ON mdcng_import_records(movie_id, created_at DESC, id DESC);
        CREATE INDEX mdcng_import_records_episode_hash_idx
          ON mdcng_import_records(episode_id, nfo_content_hash);

        CREATE TABLE movie_metadata_field_sources (
          movie_id TEXT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
          field_key TEXT NOT NULL,
          source_kind TEXT NOT NULL CHECK(source_kind IN ('manual', 'mdcng')),
          import_record_id TEXT REFERENCES mdcng_import_records(id)
            ON DELETE SET NULL,
          source_content_hash TEXT,
          updated_at TEXT NOT NULL,
          PRIMARY KEY(movie_id, field_key)
        );
        CREATE INDEX movie_metadata_field_sources_record_idx
          ON movie_metadata_field_sources(import_record_id);
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [27, now()],
      );
    }
    if (current < 28) {
      // MDCNG actor imports retain all selected actor fields in the NAS-owned
      // database.  Source files remain read-only and are never referenced by
      // stored actor rows after confirmation.
      _db.execute('PRAGMA foreign_keys = OFF');
      try {
        _db.execute('''
          CREATE TABLE managed_assets_v28 (
            id TEXT PRIMARY KEY,
            purpose TEXT NOT NULL CHECK(purpose IN (
              'actor_photo', 'actor_backdrop', 'movie_poster',
              'publisher_logo', 'series_poster'
            )),
            file_name TEXT NOT NULL UNIQUE,
            mime_type TEXT NOT NULL,
            created_at TEXT NOT NULL
          );
          INSERT INTO managed_assets_v28(id, purpose, file_name, mime_type, created_at)
            SELECT id, purpose, file_name, mime_type, created_at FROM managed_assets;
          DROP TABLE managed_assets;
          ALTER TABLE managed_assets_v28 RENAME TO managed_assets;

          ALTER TABLE actors ADD COLUMN romanized_name TEXT;
          ALTER TABLE actors ADD COLUMN birth_date TEXT;
          ALTER TABLE actors ADD COLUMN birthplace TEXT;
          ALTER TABLE actors ADD COLUMN cup TEXT;
          ALTER TABLE actors ADD COLUMN career_period TEXT;
          ALTER TABLE actors ADD COLUMN account_url TEXT;
          ALTER TABLE actors ADD COLUMN official_site_url TEXT;
          ALTER TABLE actors ADD COLUMN backdrop_asset_id TEXT
            REFERENCES managed_assets(id) ON DELETE SET NULL;

          CREATE TABLE mdcng_actor_source_links (
            source_id TEXT NOT NULL,
            emby_id TEXT NOT NULL,
            actor_id TEXT NOT NULL REFERENCES actors(id) ON DELETE CASCADE,
            source_name TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY(source_id, emby_id)
          );
          CREATE INDEX mdcng_actor_source_links_actor_idx
            ON mdcng_actor_source_links(actor_id);

          CREATE TABLE mdcng_actor_import_records (
            id TEXT PRIMARY KEY,
            actor_id TEXT NOT NULL REFERENCES actors(id) ON DELETE CASCADE,
            source_id TEXT NOT NULL,
            task_id TEXT NOT NULL,
            emby_id TEXT NOT NULL,
            source_fingerprint TEXT NOT NULL,
            applied_fields_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            UNIQUE(source_id, task_id, source_fingerprint)
          );
          CREATE INDEX mdcng_actor_import_records_actor_created_idx
            ON mdcng_actor_import_records(actor_id, created_at DESC, id DESC);
        ''');
      } finally {
        _db.execute('PRAGMA foreign_keys = ON');
      }
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [28, now()],
      );
    }
    if (current < 29) {
      // A profile key is a SHA-256 derived by the NAS from MDCNG's stable
      // Actress.db href.  It lets a user-confirmed translated/native name
      // mapping participate in later batch runs without storing source URLs.
      _db.execute('''
        ALTER TABLE mdcng_actor_source_links ADD COLUMN profile_key TEXT;
        CREATE INDEX mdcng_actor_source_links_profile_key_idx
          ON mdcng_actor_source_links(source_id, profile_key);
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [29, now()],
      );
    }
    if (current < 30) {
      // A failed ffprobe is still a completed attempt. Without this marker an
      // unsupported or damaged file would be probed on every later scan.
      final hasEpisodesTable = _db
          .select(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'episodes'",
          )
          .isNotEmpty;
      if (hasEpisodesTable) {
        final episodeColumns = _db
            .select('PRAGMA table_info(episodes)')
            .map((row) => row['name'] as String)
            .toSet();
        _db.execute('ALTER TABLE episodes ADD COLUMN metadata_probed_at TEXT');
        if (episodeColumns.containsAll({
          'updated_at',
          'duration_ms',
          'video_width',
          'video_height',
        })) {
          _db.execute('''
            UPDATE episodes
            SET metadata_probed_at = updated_at
            WHERE duration_ms IS NOT NULL
               OR video_width IS NOT NULL
               OR video_height IS NOT NULL
          ''');
        }
      }
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [30, now()],
      );
    }
    if (current < 31) {
      migrateNovelSchema(_db);
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [31, now()],
      );
    }
    if (current < 32) {
      _db.execute('''
        CREATE TABLE mdcng_actor_deferred (
          source_id TEXT NOT NULL,
          emby_id TEXT NOT NULL,
          created_at TEXT NOT NULL,
          PRIMARY KEY(source_id, emby_id)
        );
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [32, now()],
      );
    }
    if (current < 33) {
      // Distinct MDCNG tasks may create actors with the same name. Keep every
      // import audit row, including later updates from the same task.
      _db.execute('PRAGMA foreign_keys = OFF');
      try {
        _db.execute('''
          CREATE TABLE mdcng_actor_import_records_v33 (
            id TEXT PRIMARY KEY,
            actor_id TEXT NOT NULL REFERENCES actors(id) ON DELETE CASCADE,
            source_id TEXT NOT NULL,
            task_id TEXT NOT NULL,
            emby_id TEXT NOT NULL,
            source_fingerprint TEXT NOT NULL,
            applied_fields_json TEXT NOT NULL,
            created_at TEXT NOT NULL
          );
          INSERT INTO mdcng_actor_import_records_v33(
            id, actor_id, source_id, task_id, emby_id, source_fingerprint,
            applied_fields_json, created_at
          )
          SELECT id, actor_id, source_id, task_id, emby_id, source_fingerprint,
                 applied_fields_json, created_at
          FROM mdcng_actor_import_records;
          DROP TABLE mdcng_actor_import_records;
          ALTER TABLE mdcng_actor_import_records_v33
            RENAME TO mdcng_actor_import_records;
          CREATE INDEX mdcng_actor_import_records_actor_created_idx
            ON mdcng_actor_import_records(actor_id, created_at DESC, id DESC);
        ''');
      } finally {
        _db.execute('PRAGMA foreign_keys = ON');
      }
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [33, now()],
      );
    }
    if (current < 34) {
      ContentFileNames.createSchema(_db);
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [34, now()],
      );
    }
  }
}
