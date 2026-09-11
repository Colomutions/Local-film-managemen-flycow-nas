import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'auth.dart';
import 'library/taxonomy_transfer.dart';
import 'media_service.dart';
import 'metadata_probe.dart';
import 'movie_actor.dart';

String _normalizeCatalogNumber(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');

String? _nullableTrimmed(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String _tagLevelName(int level) => switch (level) {
      1 => '一级',
      2 => '二级',
      3 => '三级',
      _ => '未知',
    };

class NasLibraryMovie {
  const NasLibraryMovie({
    required this.id,
    required this.title,
    this.originalTitle,
    this.catalogNumber,
    this.publisherId,
    this.publisherName,
    this.seriesId,
    this.seriesName,
    required this.summary,
    required this.actors,
    required this.posterFileName,
    required this.episodeCount,
    required this.durationMs,
    required this.playCount,
    required this.updatedAt,
    this.videoWidth,
    this.videoHeight,
    this.resolutionLabel,
  });

  final String id;
  final String title;
  final String? originalTitle;
  final String? catalogNumber;
  final String? publisherId;
  final String? publisherName;
  final String? seriesId;
  final String? seriesName;
  final String summary;
  final List<NasMovieActor> actors;
  final String? posterFileName;
  final int episodeCount;
  final int? durationMs;
  final int playCount;
  final String updatedAt;
  final int? videoWidth;
  final int? videoHeight;
  final String? resolutionLabel;
}

class NasLibraryEpisode {
  const NasLibraryEpisode({
    required this.id,
    required this.movieId,
    required this.title,
    required this.relativePath,
    required this.fileSize,
    required this.isAvailable,
    required this.updatedAt,
    this.durationMs,
    this.videoWidth,
    this.videoHeight,
    this.resolutionLabel,
    this.mediaModifiedAt,
  });

  final String id;
  final String movieId;
  final String title;
  final String relativePath;
  final int fileSize;
  final bool isAvailable;
  final String updatedAt;
  final int? durationMs;
  final int? videoWidth;
  final int? videoHeight;
  final String? resolutionLabel;
  final int? mediaModifiedAt;
}

class NasMediaRoot {
  const NasMediaRoot({
    required this.id,
    required this.name,
    this.color,
    required this.containerPath,
    required this.readOnly,
    required this.enabled,
    required this.createdAt,
    required this.updatedAt,
    required this.lastScannedAt,
  });

  final String id;
  final String name;
  final String? color;
  final String containerPath;
  final bool readOnly;
  final bool enabled;
  final String createdAt;
  final String updatedAt;
  final String? lastScannedAt;
}

class NasLibraryCategory {
  const NasLibraryCategory({
    required this.id,
    required this.name,
    this.color,
    this.mediaRelativePath,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String? color;
  final String? mediaRelativePath;
  final String createdAt;
  final String updatedAt;
}

class NasLibraryTag {
  const NasLibraryTag({
    required this.id,
    required this.name,
    required this.level,
    this.description = '',
    this.color,
    required this.createdAt,
    required this.updatedAt,
    this.archivedAt,
  });

  final String id;
  final String name;
  final int level;
  final String description;
  final String? color;
  final String createdAt;
  final String updatedAt;
  final String? archivedAt;
}

class NasTagPath {
  const NasTagPath({
    required this.placementId,
    required this.tagId,
    required this.tagName,
    required this.names,
  });

  final String placementId;
  final String tagId;
  final String tagName;
  final List<String> names;
}

class NasTagOverview {
  const NasTagOverview({
    required this.total,
    required this.levelOne,
    required this.levelTwo,
    required this.levelThree,
    required this.movieLinks,
  });

  final int total;
  final int levelOne;
  final int levelTwo;
  final int levelThree;
  final int movieLinks;
}

class NasTagDirectoryRoot {
  const NasTagDirectoryRoot({
    required this.tag,
    required this.movieCount,
    required this.children,
  });

  final NasLibraryTag tag;
  final int movieCount;
  final List<NasTagDirectoryChild> children;
}

class NasTagDirectoryChild {
  const NasTagDirectoryChild({required this.tag, required this.movieCount});

  final NasLibraryTag tag;
  final int movieCount;
}

class NasTagDetails {
  const NasTagDetails({
    required this.tag,
    required this.parents,
    required this.directChildCount,
    required this.movieCount,
    required this.path,
  });

  final NasLibraryTag tag;
  final List<NasLibraryTag> parents;
  final int directChildCount;
  final int movieCount;
  final List<NasLibraryTag> path;
}

class NasTagChildSummary {
  const NasTagChildSummary({required this.tag, required this.movieCount});

  final NasLibraryTag tag;
  final int movieCount;
}

class NasTagChildPage {
  const NasTagChildPage({
    required this.items,
    required this.number,
    required this.size,
    required this.total,
    required this.hasMore,
  });

  final List<NasTagChildSummary> items;
  final int number;
  final int size;
  final int total;
  final bool hasMore;
}

class NasTagMoviePage {
  const NasTagMoviePage({
    required this.movieIds,
    required this.number,
    required this.size,
    required this.total,
    required this.hasMore,
  });

  final List<String> movieIds;
  final int number;
  final int size;
  final int total;
  final bool hasMore;
}

class NasScanResult {
  const NasScanResult(
      {required this.scannedFiles, required this.availableEpisodes});

  final int scannedFiles;
  final int availableEpisodes;
}

class NasCarouselImage {
  const NasCarouselImage({
    required this.id,
    required this.movieId,
    required this.fileName,
    required this.createdAt,
  });

  final String id;
  final String movieId;
  final String fileName;
  final String createdAt;
}

/// NAS 原生演员资料，不依赖任何客户端本地数据库或路径。
class NasActor {
  const NasActor({
    required this.id,
    required this.stageName,
    this.originalName,
    this.translatedName,
    required this.aliases,
    this.gender,
    this.birthMonth,
    this.heightCm,
    this.weightKg,
    this.measurements,
    this.bodyType,
    this.country,
    this.debutMonth,
    this.debutDescription,
    this.photoAssetId,
    required this.publisherIds,
    required this.movieCount,
    required this.createdAt,
    required this.updatedAt,
    this.archivedAt,
  });

  final String id;
  final String? stageName;
  final String? originalName;
  final String? translatedName;
  final List<String> aliases;
  final String? gender;
  final String? birthMonth;
  final int? heightCm;
  final int? weightKg;
  final String? measurements;
  final String? bodyType;
  final String? country;
  final String? debutMonth;
  final String? debutDescription;
  final String? photoAssetId;
  final List<String> publisherIds;
  final int movieCount;
  final String createdAt;
  final String updatedAt;
  final String? archivedAt;
}

/// 由 NAS 受管理目录保存的图片资产；文件系统绝对路径从不经 API 暴露。
class NasManagedAsset {
  const NasManagedAsset({
    required this.id,
    required this.purpose,
    required this.fileName,
    required this.mimeType,
    required this.createdAt,
  });

  final String id;
  final String purpose;
  final String fileName;
  final String mimeType;
  final String createdAt;
}

/// 由共同影片关系推导出的合作演员，不能手工写入。
class NasActorCoactor {
  const NasActorCoactor({required this.actor, required this.movieCount});

  final NasActor actor;
  final int movieCount;
}

/// NAS 原生发行商实体；统计值始终由关联影片和系列即时聚合。
class NasPublisher {
  const NasPublisher({
    required this.id,
    required this.displayName,
    this.originalName,
    this.countryRegion,
    this.foundedDate,
    this.logoAssetId,
    required this.movieCount,
    required this.seriesCount,
    required this.durationMs,
    required this.createdAt,
    required this.updatedAt,
    this.archivedAt,
  });

  final String id;
  final String displayName;
  final String? originalName;
  final String? countryRegion;
  final String? foundedDate;
  final String? logoAssetId;
  final int movieCount;
  final int seriesCount;
  final int? durationMs;
  final String createdAt;
  final String updatedAt;
  final String? archivedAt;
}

/// NAS 原生系列实体；总集数和总时长不允许客户端手工覆盖。
class NasSeries {
  const NasSeries({
    required this.id,
    required this.displayName,
    this.originalName,
    this.translatedName,
    this.publisherId,
    this.releaseDate,
    this.posterAssetId,
    required this.movieCount,
    required this.episodeCount,
    required this.durationMs,
    required this.createdAt,
    required this.updatedAt,
    this.archivedAt,
  });

  final String id;
  final String displayName;
  final String? originalName;
  final String? translatedName;

  /// 新建阶段允许暂不归属发行商，但关联影片前必须补齐。
  final String? publisherId;
  final String? releaseDate;
  final String? posterAssetId;
  final int movieCount;
  final int episodeCount;
  final int? durationMs;
  final String createdAt;
  final String updatedAt;
  final String? archivedAt;
}

/// 发行商或系列下演员的参演影片数，仅作聚合展示。
class NasRelatedActor {
  const NasRelatedActor({required this.actor, required this.movieCount});

  final NasActor actor;
  final int movieCount;
}

/// NAS 持久化的 AI 元数据任务；任务结果由 NAS 保存后再由管理员应用。
class NasAiTask {
  const NasAiTask({
    required this.id,
    required this.movieId,
    required this.instructions,
    required this.status,
    required this.createdAt,
    this.resultJson,
    this.errorCode,
    this.finishedAt,
  });

  final String id;
  final String movieId;
  final String instructions;
  final String status;
  final String createdAt;
  final String? resultJson;
  final String? errorCode;
  final String? finishedAt;
}

/// NAS 自身持久化的播放历史；不包含任何 Windows 本地路径或客户端令牌。
class NasPlaybackHistoryItem {
  const NasPlaybackHistoryItem({
    required this.id,
    required this.movieId,
    required this.episodeId,
    required this.title,
    this.originalTitle,
    this.catalogNumber,
    required this.posterFileName,
    required this.startedAt,
    required this.endedAt,
    required this.endPositionMs,
    required this.durationMs,
  });

  final String id;
  final String movieId;
  final String episodeId;
  final String title;
  final String? originalTitle;
  final String? catalogNumber;
  final String? posterFileName;
  final String startedAt;
  final String? endedAt;
  final int? endPositionMs;
  final int? durationMs;
}

class NasLibraryDatabase {
  static const currentSchemaVersion = 20;

  NasLibraryDatabase(this.dataDir);

  final String dataDir;
  Database? _database;

  Database get _db => _database ?? (throw StateError('Database is not open.'));

  Future<void> open() async {
    if (_database != null) return;
    final directory = Directory('$dataDir${Platform.pathSeparator}db');
    await directory.create(recursive: true);
    await Directory(
            '$dataDir${Platform.pathSeparator}artwork${Platform.pathSeparator}posters')
        .create(recursive: true);
    await Directory(
            '$dataDir${Platform.pathSeparator}artwork${Platform.pathSeparator}carousel')
        .create(recursive: true);
    final database =
        sqlite3.open('${directory.path}${Platform.pathSeparator}mujing.sqlite');
    try {
      database.execute('PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;');
      _database = database;
      _migrate();
    } catch (_) {
      database.dispose();
      _database = null;
      rethrow;
    }
  }

  Future<void> close() async {
    _database?.dispose();
    _database = null;
  }

  Future<void> createBackupSnapshot(File target) async {
    await target.parent.create(recursive: true);
    final escapedPath = target.absolute.path.replaceAll("'", "''");
    _db.execute("VACUUM INTO '$escapedPath'");
  }

  void _migrate() {
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
        [1, _now()],
      );
    }
    if (current < 2) {
      _db.execute('ALTER TABLE media_roots ADD COLUMN last_scanned_at TEXT');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [2, _now()],
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
        [3, _now()],
      );
    }
    if (current < 4) {
      _db.execute('ALTER TABLE movies ADD COLUMN poster_file_name TEXT');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [4, _now()],
      );
    }
    if (current < 5) {
      _db.execute('ALTER TABLE episodes ADD COLUMN video_width INTEGER');
      _db.execute('ALTER TABLE episodes ADD COLUMN video_height INTEGER');
      _db.execute('ALTER TABLE episodes ADD COLUMN resolution_label TEXT');
      _db.execute('ALTER TABLE episodes ADD COLUMN media_modified_at INTEGER');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [5, _now()],
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
        [6, _now()],
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
        [7, _now()],
      );
    }
    if (current < 8) {
      _db.execute(
        "ALTER TABLE movies ADD COLUMN actors_json TEXT NOT NULL DEFAULT '[]'",
      );
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [8, _now()],
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
        [9, _now()],
      );
    }
    if (current < 10) {
      _db.execute('''
        ALTER TABLE library_categories ADD COLUMN color TEXT;
        ALTER TABLE tags ADD COLUMN color TEXT;
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [10, _now()],
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
        [11, _now()],
      );
    }
    if (current < 12) {
      _db.execute('''
        ALTER TABLE movies ADD COLUMN original_title TEXT;
        ALTER TABLE movies ADD COLUMN catalog_number TEXT;
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [12, _now()],
      );
    }
    if (current < 13) {
      // Do not interpret or rewrite the former string-only actor payload.
      // Actors are NAS-native entities now; legacy movie payloads have no
      // value and are deliberately left untouched.
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [13, _now()],
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
        [14, _now()],
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
        [15, _now()],
      );
    }
    if (current < 16) {
      _db.execute('''
        ALTER TABLE movies ADD COLUMN publisher_name TEXT;
        ALTER TABLE movies ADD COLUMN series_name TEXT;
      ''');
      _db.execute(
        'INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)',
        [16, _now()],
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
        [17, _now()],
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
        [18, _now()],
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
        [19, _now()],
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
        [20, _now()],
      );
    }
  }

  NasMediaRoot ensureConfiguredMediaRoot({
    required String rootName,
    required String containerPath,
  }) {
    final existing = _db.select(
      'SELECT id FROM media_roots WHERE container_path = ?',
      [containerPath],
    );
    final timestamp = _now();
    if (existing.isEmpty) {
      _db.execute(
        '''INSERT INTO media_roots(
          id, name, container_path, read_only, enabled, created_at, updated_at
        ) VALUES (?, ?, ?, 1, 1, ?, ?)''',
        [newUuidV4(), rootName, containerPath, timestamp, timestamp],
      );
    } else {
      _db.execute(
        '''UPDATE media_roots
           SET name = ?, read_only = 1, enabled = 1, updated_at = ?
           WHERE id = ?''',
        [rootName, timestamp, existing.first['id']],
      );
    }
    return _mediaRootForContainerPath(containerPath)!;
  }

  List<NasMediaRoot> listMediaRoots() {
    final rows = _db.select('''
      SELECT id, name, container_path, read_only, enabled, created_at,
             updated_at, last_scanned_at
      FROM media_roots ORDER BY created_at
    ''');
    return rows.map(_mapMediaRoot).toList(growable: false);
  }

  NasMediaRoot? findMediaRoot(String mediaRootId) {
    final rows = _db.select('''
      SELECT id, name, container_path, read_only, enabled, created_at,
             updated_at, last_scanned_at
      FROM media_roots WHERE id = ?
    ''', [mediaRootId]);
    return rows.isEmpty ? null : _mapMediaRoot(rows.single);
  }

  Future<NasScanResult> scanConfiguredRoot({
    required String rootName,
    required String containerPath,
    required NasMediaService mediaService,
    NasMediaMetadataProbe metadataProbe = const NasMediaMetadataProbe(),
  }) async {
    final root = ensureConfiguredMediaRoot(
      rootName: rootName,
      containerPath: containerPath,
    );
    return scanMediaRoot(
      mediaRootId: root.id,
      mediaService: mediaService,
      metadataProbe: metadataProbe,
    );
  }

  Future<NasScanResult> scanMediaRoot({
    required String mediaRootId,
    required NasMediaService mediaService,
    String? categoryId,
    String? directoryRelativePath,
    NasMediaMetadataProbe metadataProbe = const NasMediaMetadataProbe(),
  }) async {
    final configuredRoot = findMediaRoot(mediaRootId);
    if (configuredRoot == null || !configuredRoot.enabled) {
      throw ArgumentError.value(mediaRootId, 'mediaRootId', 'is not enabled');
    }
    if (configuredRoot.containerPath != mediaService.mediaDir) {
      throw StateError(
          'Only the configured media service root can be scanned.');
    }
    if ((categoryId == null) != (directoryRelativePath == null)) {
      throw ArgumentError(
          'Category scan requires both category and directory.');
    }
    final rootId = configuredRoot.id;
    if (categoryId == null) {
      _db.execute(
        'UPDATE episodes SET is_available = 0, updated_at = ? WHERE media_root_id = ?',
        [_now(), rootId],
      );
    } else {
      _db.execute('''
        UPDATE episodes SET is_available = 0, updated_at = ?
        WHERE movie_id IN (SELECT id FROM movies WHERE category_id = ?)
      ''', [_now(), categoryId]);
    }
    final root = directoryRelativePath == null
        ? Directory(configuredRoot.containerPath)
        : (await mediaService.directoryForRelativePath(directoryRelativePath))
            ?.directory;
    if (root == null) {
      _markRootScanned(rootId);
      return const NasScanResult(scannedFiles: 0, availableEpisodes: 0);
    }
    if (!await root.exists()) {
      _markRootScanned(rootId);
      return const NasScanResult(scannedFiles: 0, availableEpisodes: 0);
    }
    final canonicalRoot = await root.resolveSymbolicLinks();
    final prefix = canonicalRoot.endsWith(Platform.pathSeparator)
        ? canonicalRoot
        : '$canonicalRoot${Platform.pathSeparator}';
    var scannedFiles = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File || !_isVideo(entity.path)) continue;
      final canonicalFile = await entity.resolveSymbolicLinks();
      if (!canonicalFile.startsWith(prefix)) continue;
      final scannedRelativePath = canonicalFile
          .substring(prefix.length)
          .replaceAll(Platform.pathSeparator, '/');
      final relativePath = directoryRelativePath == null
          ? scannedRelativePath
          : '$directoryRelativePath/$scannedRelativePath';
      final checkedFile = await mediaService.fileForRelativePath(relativePath);
      if (checkedFile == null) continue;
      final stat = await checkedFile.file.stat();
      final mediaModifiedAt = stat.modified.microsecondsSinceEpoch;
      final existing = _db.select(
        'SELECT file_size, media_modified_at, duration_ms, video_width, video_height, resolution_label FROM episodes WHERE media_root_id = ? AND relative_path = ?',
        [rootId, relativePath],
      );
      final fileSize = await checkedFile.length();
      final unchanged = existing.isNotEmpty &&
          existing.first['file_size'] == fileSize &&
          existing.first['media_modified_at'] == mediaModifiedAt &&
          (existing.first['duration_ms'] != null ||
              existing.first['video_width'] != null ||
              existing.first['video_height'] != null);
      NasMediaMetadata? metadata;
      if (!unchanged) {
        metadata = await metadataProbe.probe(checkedFile);
      }
      final movieId =
          'movie-${sha256Hex('$rootId:$relativePath').substring(0, 24)}';
      final episodeId =
          'episode-${sha256Hex('$rootId:$relativePath').substring(0, 24)}';
      final title = _titleFromPath(relativePath);
      final timestamp = _now();
      _db.execute(
        categoryId == null
            ? '''
              INSERT INTO movies(id, title, created_at, updated_at) VALUES (?, ?, ?, ?)
              ON CONFLICT(id) DO NOTHING
            '''
            : '''
              INSERT INTO movies(id, title, category_id, created_at, updated_at)
              VALUES (?, ?, ?, ?, ?)
              ON CONFLICT(id) DO UPDATE SET category_id = excluded.category_id
            ''',
        categoryId == null
            ? [movieId, title, timestamp, timestamp]
            : [movieId, title, categoryId, timestamp, timestamp],
      );
      _db.execute('''
        INSERT INTO episodes(id, movie_id, media_root_id, title, relative_path, duration_ms, video_width, video_height, resolution_label, media_modified_at, file_size, is_available, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
        ON CONFLICT(media_root_id, relative_path) DO UPDATE SET
          duration_ms = excluded.duration_ms,
          video_width = excluded.video_width,
          video_height = excluded.video_height,
          resolution_label = excluded.resolution_label,
          media_modified_at = excluded.media_modified_at,
          file_size = excluded.file_size, is_available = 1, updated_at = excluded.updated_at
      ''', [
        episodeId,
        movieId,
        rootId,
        title,
        relativePath,
        unchanged ? existing.first['duration_ms'] : metadata?.durationMs,
        unchanged ? existing.first['video_width'] : metadata?.width,
        unchanged ? existing.first['video_height'] : metadata?.height,
        unchanged
            ? existing.first['resolution_label']
            : metadata?.resolutionLabel,
        mediaModifiedAt,
        fileSize,
        timestamp,
      ]);
      scannedFiles++;
    }
    _markRootScanned(rootId);
    return NasScanResult(
        scannedFiles: scannedFiles, availableEpisodes: scannedFiles);
  }

  Future<NasScanResult> scanCategory({
    required String categoryId,
    required String mediaRootId,
    required NasMediaService mediaService,
    NasMediaMetadataProbe metadataProbe = const NasMediaMetadataProbe(),
  }) {
    final category = findCategory(categoryId);
    final directoryRelativePath = category?.mediaRelativePath;
    if (category == null ||
        directoryRelativePath == null ||
        directoryRelativePath.isEmpty) {
      throw ArgumentError.value(
          categoryId, 'categoryId', 'has no media directory');
    }
    return scanMediaRoot(
      mediaRootId: mediaRootId,
      mediaService: mediaService,
      categoryId: categoryId,
      directoryRelativePath: directoryRelativePath,
      metadataProbe: metadataProbe,
    );
  }

  List<NasLibraryMovie> listMovies({String query = ''}) {
    final queryLike = '%${query.trim()}%';
    final normalizedCatalogQuery = _normalizeCatalogNumber(query);
    final catalogQueryLike = '%$normalizedCatalogQuery%';
    final rows = _db.select('''
      SELECT m.id, m.title, m.original_title, m.catalog_number,
             m.publisher_id, p.display_name AS publisher_name,
             m.series_id, s.display_name AS series_name,
             m.summary, m.actors_json, m.poster_file_name, m.play_count,
             m.updated_at, COUNT(e.id) AS episode_count,
             SUM(CASE WHEN e.duration_ms IS NULL THEN 0 ELSE e.duration_ms END) AS duration_ms
      FROM movies m
      LEFT JOIN publishers p ON p.id = m.publisher_id
      LEFT JOIN series s ON s.id = m.series_id
      JOIN episodes e ON e.movie_id = m.id
      WHERE e.is_available = 1 AND (
        ? = '%%'
        OR lower(m.title) LIKE lower(?)
        OR lower(COALESCE(m.original_title, '')) LIKE lower(?)
        OR (? != '' AND lower(REPLACE(REPLACE(REPLACE(
          COALESCE(m.catalog_number, ''), '-', ''), '_', ''), ' ', '')) LIKE ?)
      )
      GROUP BY m.id ORDER BY m.title COLLATE NOCASE
    ''', [
      queryLike,
      queryLike,
      queryLike,
      normalizedCatalogQuery,
      catalogQueryLike,
    ]);
    return rows
        .map((row) => _withResolution(NasLibraryMovie(
              id: row['id'] as String,
              title: row['title'] as String,
              originalTitle: row['original_title'] as String?,
              catalogNumber: row['catalog_number'] as String?,
              publisherId: row['publisher_id'] as String?,
              publisherName: row['publisher_name'] as String?,
              seriesId: row['series_id'] as String?,
              seriesName: row['series_name'] as String?,
              summary: row['summary'] as String,
              actors: _movieActors(row['id'] as String),
              posterFileName: row['poster_file_name'] as String?,
              playCount: row['play_count'] as int,
              episodeCount: row['episode_count'] as int,
              durationMs: (row['duration_ms'] as int?) == 0
                  ? null
                  : row['duration_ms'] as int?,
              updatedAt: row['updated_at'] as String,
            )))
        .toList(growable: false);
  }

  List<NasPublisher> listPublishers({
    String query = '',
    bool includeArchived = false,
  }) {
    final queryLike = '%${query.trim()}%';
    final rows = _db.select('''
      SELECT p.id, p.display_name, p.original_name, p.country_region,
             p.founded_date, p.logo_asset_id, p.created_at, p.updated_at,
             p.archived_at,
             (SELECT COUNT(*) FROM movies m WHERE m.publisher_id = p.id) AS movie_count,
             (SELECT COUNT(*) FROM series s WHERE s.publisher_id = p.id) AS series_count,
             (SELECT SUM(COALESCE(e.duration_ms, 0))
                FROM movies m JOIN episodes e ON e.movie_id = m.id
               WHERE m.publisher_id = p.id AND e.is_available = 1) AS duration_ms
      FROM publishers p
      WHERE (? = 1 OR p.archived_at IS NULL)
        AND (? = '%%' OR lower(p.display_name) LIKE lower(?)
             OR lower(COALESCE(p.original_name, '')) LIKE lower(?))
      ORDER BY p.created_at DESC, p.id DESC
    ''', [includeArchived ? 1 : 0, queryLike, queryLike, queryLike]);
    return rows.map(_mapPublisher).toList(growable: false);
  }

  NasPublisher? findPublisher(String publisherId) {
    final rows = _db.select('''
      SELECT p.id, p.display_name, p.original_name, p.country_region,
             p.founded_date, p.logo_asset_id, p.created_at, p.updated_at,
             p.archived_at,
             (SELECT COUNT(*) FROM movies m WHERE m.publisher_id = p.id) AS movie_count,
             (SELECT COUNT(*) FROM series s WHERE s.publisher_id = p.id) AS series_count,
             (SELECT SUM(COALESCE(e.duration_ms, 0))
                FROM movies m JOIN episodes e ON e.movie_id = m.id
               WHERE m.publisher_id = p.id AND e.is_available = 1) AS duration_ms
      FROM publishers p WHERE p.id = ?
    ''', [publisherId]);
    return rows.isEmpty ? null : _mapPublisher(rows.single);
  }

  NasPublisher createPublisher({
    required String displayName,
    String? originalName,
    String? countryRegion,
    String? foundedDate,
    String? logoAssetId,
  }) {
    final id = newUuidV4();
    final timestamp = _now();
    _db.execute('''
      INSERT INTO publishers(
        id, display_name, original_name, country_region, founded_date,
        logo_asset_id, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      id,
      displayName.trim(),
      _nullableTrimmed(originalName),
      _nullableTrimmed(countryRegion),
      _nullableTrimmed(foundedDate),
      logoAssetId,
      timestamp,
      timestamp,
    ]);
    return findPublisher(id)!;
  }

  NasPublisher? updatePublisher(
      String publisherId, Map<String, Object?> values) {
    if (findPublisher(publisherId) == null) return null;
    if (values.isEmpty) return findPublisher(publisherId);
    final assignments = <String>[];
    final parameters = <Object?>[];
    values.forEach((key, value) {
      assignments.add('$key = ?');
      parameters.add(value);
    });
    assignments.add('updated_at = ?');
    parameters
      ..add(_now())
      ..add(publisherId);
    _db.execute(
      'UPDATE publishers SET ${assignments.join(', ')} WHERE id = ?',
      parameters,
    );
    return findPublisher(publisherId);
  }

  NasPublisher? archivePublisher(String publisherId) => updatePublisher(
        publisherId,
        {'archived_at': _now()},
      );

  bool publisherHasReferences(String publisherId) => _db.select('''
    SELECT 1
    WHERE EXISTS(SELECT 1 FROM movies WHERE publisher_id = ?)
       OR EXISTS(SELECT 1 FROM series WHERE publisher_id = ?)
       OR EXISTS(SELECT 1 FROM actor_publisher_links WHERE publisher_id = ?)
  ''', [publisherId, publisherId, publisherId]).isNotEmpty;

  bool deletePublisher(String publisherId) {
    if (findPublisher(publisherId) == null ||
        publisherHasReferences(publisherId)) {
      return false;
    }
    _db.execute('DELETE FROM publishers WHERE id = ?', [publisherId]);
    return true;
  }

  List<NasSeries> listSeries({
    String query = '',
    String? publisherId,
    bool includeArchived = false,
  }) {
    final queryLike = '%${query.trim()}%';
    final rows = _db.select('''
      SELECT s.id, s.display_name, s.original_name, s.translated_name,
             s.publisher_id, s.release_date, s.poster_asset_id, s.created_at,
             s.updated_at, s.archived_at,
             (SELECT COUNT(*) FROM movies m WHERE m.series_id = s.id) AS movie_count,
             (SELECT COUNT(e.id) FROM movies m JOIN episodes e ON e.movie_id = m.id
               WHERE m.series_id = s.id AND e.is_available = 1) AS episode_count,
             (SELECT SUM(COALESCE(e.duration_ms, 0))
                FROM movies m JOIN episodes e ON e.movie_id = m.id
               WHERE m.series_id = s.id AND e.is_available = 1) AS duration_ms
      FROM series s
      WHERE (? = 1 OR s.archived_at IS NULL)
        AND (? IS NULL OR s.publisher_id = ?)
        AND (? = '%%' OR lower(s.display_name) LIKE lower(?)
             OR lower(COALESCE(s.original_name, '')) LIKE lower(?)
             OR lower(COALESCE(s.translated_name, '')) LIKE lower(?))
      ORDER BY s.created_at DESC, s.id DESC
    ''', [
      includeArchived ? 1 : 0,
      publisherId,
      publisherId,
      queryLike,
      queryLike,
      queryLike,
      queryLike,
    ]);
    return rows.map(_mapSeries).toList(growable: false);
  }

  NasSeries? findSeries(String seriesId) {
    final rows = _db.select('''
      SELECT s.id, s.display_name, s.original_name, s.translated_name,
             s.publisher_id, s.release_date, s.poster_asset_id, s.created_at,
             s.updated_at, s.archived_at,
             (SELECT COUNT(*) FROM movies m WHERE m.series_id = s.id) AS movie_count,
             (SELECT COUNT(e.id) FROM movies m JOIN episodes e ON e.movie_id = m.id
               WHERE m.series_id = s.id AND e.is_available = 1) AS episode_count,
             (SELECT SUM(COALESCE(e.duration_ms, 0))
                FROM movies m JOIN episodes e ON e.movie_id = m.id
               WHERE m.series_id = s.id AND e.is_available = 1) AS duration_ms
      FROM series s WHERE s.id = ?
    ''', [seriesId]);
    return rows.isEmpty ? null : _mapSeries(rows.single);
  }

  NasSeries createSeries({
    required String displayName,
    String? publisherId,
    String? originalName,
    String? translatedName,
    String? releaseDate,
    String? posterAssetId,
  }) {
    final id = newUuidV4();
    final timestamp = _now();
    _db.execute('''
      INSERT INTO series(
        id, display_name, original_name, translated_name, publisher_id,
        release_date, poster_asset_id, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      id,
      displayName.trim(),
      _nullableTrimmed(originalName),
      _nullableTrimmed(translatedName),
      _nullableTrimmed(publisherId),
      _nullableTrimmed(releaseDate),
      posterAssetId,
      timestamp,
      timestamp,
    ]);
    return findSeries(id)!;
  }

  NasSeries? updateSeries(String seriesId, Map<String, Object?> values) {
    if (findSeries(seriesId) == null) return null;
    if (values.isEmpty) return findSeries(seriesId);
    final assignments = <String>[];
    final parameters = <Object?>[];
    values.forEach((key, value) {
      assignments.add('$key = ?');
      parameters.add(value);
    });
    assignments.add('updated_at = ?');
    parameters
      ..add(_now())
      ..add(seriesId);
    _db.execute(
      'UPDATE series SET ${assignments.join(', ')} WHERE id = ?',
      parameters,
    );
    return findSeries(seriesId);
  }

  NasSeries? archiveSeries(String seriesId) => updateSeries(
        seriesId,
        {'archived_at': _now()},
      );

  bool deleteSeries(String seriesId) {
    final series = findSeries(seriesId);
    if (series == null || series.movieCount > 0) return false;
    _db.execute('DELETE FROM series WHERE id = ?', [seriesId]);
    return true;
  }

  List<NasLibraryMovie> moviesForPublisher(String publisherId,
          {String query = ''}) =>
      listMovies(query: query)
          .where((movie) => movie.publisherId == publisherId)
          .toList(growable: false);

  List<NasLibraryMovie> moviesForSeries(String seriesId, {String query = ''}) =>
      listMovies(query: query)
          .where((movie) => movie.seriesId == seriesId)
          .toList(growable: false);

  List<NasSeries> seriesForPublisher(String publisherId, {String query = ''}) =>
      listSeries(query: query, publisherId: publisherId)
          .toList(growable: false);

  List<NasLibraryTag> tagsForPublisher(String publisherId) => _tagsForRelation(
        'm.publisher_id = ?',
        [publisherId],
      );

  List<NasLibraryTag> tagsForSeries(String seriesId) => _tagsForRelation(
        'm.series_id = ?',
        [seriesId],
      );

  List<NasRelatedActor> actorsForPublisher(String publisherId) =>
      _relatedActorsForMovies('m.publisher_id = ?', [publisherId]);

  List<NasRelatedActor> actorsForSeries(String seriesId) =>
      _relatedActorsForMovies('m.series_id = ?', [seriesId]);

  List<String> publisherIdsForActor(String actorId) => _db
      .select('''
        SELECT publisher_id FROM actor_publisher_links
        WHERE actor_id = ? ORDER BY publisher_id
      ''', [actorId])
      .map((row) => row['publisher_id'] as String)
      .toList(growable: false);

  List<NasPublisher> publishersForActor(String actorId) =>
      publisherIdsForActor(actorId)
          .map(findPublisher)
          .whereType<NasPublisher>()
          .toList(growable: false);

  bool setActorPublisherIds({
    required String actorId,
    required List<String> publisherIds,
  }) {
    if (findActor(actorId) == null ||
        publisherIds.length != publisherIds.toSet().length ||
        publisherIds.any((id) {
          final publisher = findPublisher(id);
          return publisher == null || publisher.archivedAt != null;
        })) {
      return false;
    }
    _db.execute('BEGIN');
    try {
      _db.execute(
          'DELETE FROM actor_publisher_links WHERE actor_id = ?', [actorId]);
      for (final publisherId in publisherIds) {
        _db.execute(
          'INSERT INTO actor_publisher_links(actor_id, publisher_id) VALUES (?, ?)',
          [actorId, publisherId],
        );
      }
      _db.execute('COMMIT');
      return true;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 统一解析影片关系，系列存在时始终以系列所属发行商为准。
  ({String? publisherId, String? seriesId})? resolveMovieRelations({
    required String movieId,
    String? publisherId,
    required bool updatePublisherId,
    String? seriesId,
    required bool updateSeriesId,
  }) {
    final movie = findMovieForAdmin(movieId);
    if (movie == null) return null;
    final resolvedSeriesId =
        updateSeriesId ? _nullableTrimmed(seriesId) : movie.seriesId;
    var resolvedPublisherId =
        updatePublisherId ? _nullableTrimmed(publisherId) : movie.publisherId;
    if (resolvedSeriesId != null) {
      final series = findSeries(resolvedSeriesId);
      final seriesPublisherId = series?.publisherId;
      if (series == null ||
          series.archivedAt != null ||
          seriesPublisherId == null) {
        return null;
      }
      if (updatePublisherId && resolvedPublisherId != seriesPublisherId)
        return null;
      resolvedPublisherId = seriesPublisherId;
    }
    if (resolvedPublisherId != null) {
      final publisher = findPublisher(resolvedPublisherId);
      if (publisher == null || publisher.archivedAt != null) return null;
    }
    return (publisherId: resolvedPublisherId, seriesId: resolvedSeriesId);
  }

  NasLibraryMovie? updateMovieRelations({
    required String movieId,
    required String? publisherId,
    required bool updatePublisherId,
    required String? seriesId,
    required bool updateSeriesId,
  }) {
    final relations = resolveMovieRelations(
      movieId: movieId,
      publisherId: publisherId,
      updatePublisherId: updatePublisherId,
      seriesId: seriesId,
      updateSeriesId: updateSeriesId,
    );
    if (relations == null) return null;
    if (!updatePublisherId && !updateSeriesId)
      return findMovieForAdmin(movieId);
    _db.execute(
      'UPDATE movies SET publisher_id = ?, series_id = ?, updated_at = ? WHERE id = ?',
      [relations.publisherId, relations.seriesId, _now(), movieId],
    );
    return findMovieForAdmin(movieId);
  }

  List<NasActor> listActors({
    String query = '',
    String? gender,
    bool includeArchived = false,
  }) {
    final rows = _db.select('''
      SELECT a.id, a.stage_name, a.original_name, a.translated_name,
             a.aliases_json, a.gender, a.birth_month, a.height_cm, a.weight_kg,
             a.measurements, a.body_type, a.country, a.debut_month,
             a.debut_description, a.photo_asset_id, a.publisher_names_json,
             a.created_at, a.updated_at, a.archived_at,
             COUNT(l.movie_id) AS movie_count
      FROM actors a
      LEFT JOIN movie_actor_links l ON l.actor_id = a.id
      WHERE (? = 1 OR a.archived_at IS NULL)
        AND (? IS NULL OR a.gender = ?)
      GROUP BY a.id
      ORDER BY a.created_at DESC, a.id DESC
    ''', [includeArchived ? 1 : 0, gender, gender]);
    final normalizedQuery = _normalizeActorSearch(query);
    return rows
        .map(_mapActor)
        .where((actor) =>
            normalizedQuery.isEmpty ||
            _actorSearchText(actor).contains(normalizedQuery))
        .toList(growable: false);
  }

  NasActor? findActor(String actorId) {
    final rows = _db.select('''
      SELECT a.id, a.stage_name, a.original_name, a.translated_name,
             a.aliases_json, a.gender, a.birth_month, a.height_cm, a.weight_kg,
             a.measurements, a.body_type, a.country, a.debut_month,
             a.debut_description, a.photo_asset_id, a.publisher_names_json,
             a.created_at, a.updated_at, a.archived_at,
             COUNT(l.movie_id) AS movie_count
      FROM actors a
      LEFT JOIN movie_actor_links l ON l.actor_id = a.id
      WHERE a.id = ?
      GROUP BY a.id
    ''', [actorId]);
    return rows.isEmpty ? null : _mapActor(rows.single);
  }

  List<NasActor> actorsForMovie(String movieId) {
    final ids = _db.select('''
      SELECT actor_id FROM movie_actor_links
      WHERE movie_id = ? ORDER BY actor_id
    ''', [movieId]);
    return ids
        .map((row) => findActor(row['actor_id'] as String))
        .whereType<NasActor>()
        .toList(growable: false);
  }

  List<NasLibraryMovie> moviesForActor(String actorId, {String query = ''}) {
    final movieIds = _db.select('''
      SELECT movie_id FROM movie_actor_links WHERE actor_id = ?
    ''', [actorId]).map((row) => row['movie_id'] as String).toSet();
    if (movieIds.isEmpty) return const [];
    return listMovies(query: query)
        .where((movie) => movieIds.contains(movie.id))
        .toList(growable: false);
  }

  List<NasActorCoactor> coactorsForActor(String actorId) {
    final rows = _db.select('''
      SELECT l2.actor_id, COUNT(*) AS movie_count
      FROM movie_actor_links l1
      JOIN movie_actor_links l2 ON l2.movie_id = l1.movie_id
      WHERE l1.actor_id = ? AND l2.actor_id != ?
      GROUP BY l2.actor_id
      ORDER BY movie_count DESC, l2.actor_id ASC
    ''', [actorId, actorId]);
    return rows
        .map((row) {
          final actor = findActor(row['actor_id'] as String);
          return actor == null
              ? null
              : NasActorCoactor(
                  actor: actor,
                  movieCount: row['movie_count'] as int,
                );
        })
        .whereType<NasActorCoactor>()
        .toList(growable: false);
  }

  List<NasActor> findSimilarActors({
    String? stageName,
    String? originalName,
    String? translatedName,
    List<String> aliases = const [],
  }) {
    final names = <String?>[
      stageName,
      originalName,
      translatedName,
      ...aliases,
    ];
    final queries = names
        .map(_nullableTrimmed)
        .whereType<String>()
        .map(_normalizeActorSearch)
        .where((value) => value.isNotEmpty)
        .toSet();
    if (queries.isEmpty) return const [];
    return listActors(includeArchived: true)
        .where((actor) => queries.any(_actorSearchText(actor).contains))
        .toList(growable: false);
  }

  NasActor createActor({
    String? stageName,
    String? originalName,
    String? translatedName,
    List<String> aliases = const [],
    String? gender,
    String? birthMonth,
    int? heightCm,
    int? weightKg,
    String? measurements,
    String? bodyType,
    String? country,
    String? debutMonth,
    String? debutDescription,
    String? photoAssetId,
    List<String> publisherNames = const [],
  }) {
    final timestamp = _now();
    final id = newUuidV4();
    _db.execute('''
      INSERT INTO actors(
        id, stage_name, original_name, translated_name, aliases_json, gender,
        birth_month, height_cm, weight_kg, measurements, body_type, country,
        debut_month, debut_description, photo_asset_id, publisher_names_json,
        created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      id,
      _nullableTrimmed(stageName),
      _nullableTrimmed(originalName),
      _nullableTrimmed(translatedName),
      jsonEncode(_cleanTextList(aliases)),
      gender,
      _nullableTrimmed(birthMonth),
      heightCm,
      weightKg,
      _nullableTrimmed(measurements),
      _nullableTrimmed(bodyType),
      _nullableTrimmed(country),
      _nullableTrimmed(debutMonth),
      _nullableTrimmed(debutDescription),
      photoAssetId,
      jsonEncode(_cleanTextList(publisherNames)),
      timestamp,
      timestamp,
    ]);
    return findActor(id)!;
  }

  NasActor? updateActor(String actorId, Map<String, Object?> values) {
    if (findActor(actorId) == null) return null;
    if (values.isEmpty) return findActor(actorId);
    final assignments = <String>[];
    final parameters = <Object?>[];
    values.forEach((key, value) {
      assignments.add('$key = ?');
      parameters.add(value);
    });
    assignments.add('updated_at = ?');
    parameters
      ..add(_now())
      ..add(actorId);
    _db.execute(
      'UPDATE actors SET ${assignments.join(', ')} WHERE id = ?',
      parameters,
    );
    return findActor(actorId);
  }

  NasActor? archiveActor(String actorId) => updateActor(actorId, {
        'archived_at': _now(),
      });

  /// 删除无影片关联的演员；有关联时由调用方先校验或由外键限制拒绝。
  bool deleteActor(String actorId) {
    if (findActor(actorId) == null) return false;
    _db.execute('DELETE FROM actors WHERE id = ?', [actorId]);
    return true;
  }

  bool setMovieActorIds({
    required String movieId,
    required List<String> actorIds,
  }) {
    if (findMovieForAdmin(movieId) == null ||
        actorIds.toSet().length != actorIds.length ||
        actorIds.any((id) => findActor(id) == null)) {
      return false;
    }
    _db.execute('BEGIN');
    try {
      _db.execute(
          'DELETE FROM movie_actor_links WHERE movie_id = ?', [movieId]);
      for (final actorId in actorIds) {
        _db.execute(
          'INSERT INTO movie_actor_links(movie_id, actor_id) VALUES (?, ?)',
          [movieId, actorId],
        );
      }
      _db.execute('COMMIT');
      return true;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  NasManagedAsset addManagedAsset({
    required String id,
    required String purpose,
    required String fileName,
    required String mimeType,
  }) {
    final asset = NasManagedAsset(
      id: id,
      purpose: purpose,
      fileName: fileName,
      mimeType: mimeType,
      createdAt: _now(),
    );
    _db.execute('''
      INSERT INTO managed_assets(id, purpose, file_name, mime_type, created_at)
      VALUES (?, ?, ?, ?, ?)
    ''', [
      asset.id,
      asset.purpose,
      asset.fileName,
      asset.mimeType,
      asset.createdAt
    ]);
    return asset;
  }

  NasManagedAsset? findManagedAsset(String assetId) {
    final rows = _db.select('''
      SELECT id, purpose, file_name, mime_type, created_at
      FROM managed_assets WHERE id = ?
    ''', [assetId]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    return NasManagedAsset(
      id: row['id'] as String,
      purpose: row['purpose'] as String,
      fileName: row['file_name'] as String,
      mimeType: row['mime_type'] as String,
      createdAt: row['created_at'] as String,
    );
  }

  /// 删除受管理资产记录，供演员删除等场景同步清理 NAS 资产目录。
  NasManagedAsset? removeManagedAsset(String assetId) {
    final asset = findManagedAsset(assetId);
    if (asset == null) return null;
    _db.execute('DELETE FROM managed_assets WHERE id = ?', [assetId]);
    return asset;
  }

  NasAiTask? createAiTask({
    required String movieId,
    required String instructions,
  }) {
    if (findMovieForAdmin(movieId) == null) return null;
    final task = NasAiTask(
      id: newUuidV4(),
      movieId: movieId,
      instructions: instructions,
      status: 'queued',
      createdAt: _now(),
    );
    _db.execute('''
      INSERT INTO ai_metadata_tasks(
        id, movie_id, instructions, status, created_at
      ) VALUES (?, ?, ?, ?, ?)
    ''', [
      task.id,
      task.movieId,
      task.instructions,
      task.status,
      task.createdAt
    ]);
    return task;
  }

  NasAiTask? findAiTask(String taskId) {
    final rows = _db.select('''
      SELECT id, movie_id, instructions, status, result_json, error_code,
             created_at, finished_at
      FROM ai_metadata_tasks WHERE id = ?
    ''', [taskId]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    return NasAiTask(
      id: row['id'] as String,
      movieId: row['movie_id'] as String,
      instructions: row['instructions'] as String,
      status: row['status'] as String,
      resultJson: row['result_json'] as String?,
      errorCode: row['error_code'] as String?,
      createdAt: row['created_at'] as String,
      finishedAt: row['finished_at'] as String?,
    );
  }

  NasAiTask? markAiTaskRunning(String taskId) {
    final existing = findAiTask(taskId);
    if (existing == null || existing.status != 'queued') return null;
    _db.execute('''
      UPDATE ai_metadata_tasks
      SET status = 'running', error_code = NULL, result_json = NULL,
          finished_at = NULL
      WHERE id = ? AND status = 'queued'
    ''', [taskId]);
    return findAiTask(taskId);
  }

  NasAiTask? completeAiTask(String taskId, Map<String, Object?> result) {
    final existing = findAiTask(taskId);
    if (existing == null || existing.status != 'running') return null;
    _db.execute('''
      UPDATE ai_metadata_tasks
      SET status = 'succeeded', result_json = ?, error_code = NULL,
          finished_at = ?
      WHERE id = ? AND status = 'running'
    ''', [jsonEncode(result), _now(), taskId]);
    return findAiTask(taskId);
  }

  NasAiTask? failAiTask(String taskId, String errorCode) {
    final existing = findAiTask(taskId);
    if (existing == null || existing.status != 'running') return null;
    _db.execute('''
      UPDATE ai_metadata_tasks
      SET status = 'failed', result_json = NULL, error_code = ?, finished_at = ?
      WHERE id = ? AND status = 'running'
    ''', [errorCode, _now(), taskId]);
    return findAiTask(taskId);
  }

  bool get hasMediaRoots =>
      _db.select('SELECT 1 FROM media_roots LIMIT 1').isNotEmpty;

  bool get hasScannedMediaRoots => _db
      .select(
          'SELECT 1 FROM media_roots WHERE last_scanned_at IS NOT NULL LIMIT 1')
      .isNotEmpty;

  NasLibraryMovie? findMovie(String movieId) {
    final movies = listMovies();
    for (final movie in movies) {
      if (movie.id == movieId) return movie;
    }
    return null;
  }

  NasLibraryMovie? findMovieForAdmin(String movieId) {
    final rows = _db.select('''
      SELECT m.id, m.title, m.original_title, m.catalog_number,
             m.publisher_id, p.display_name AS publisher_name,
             m.series_id, s.display_name AS series_name,
             m.summary, m.actors_json, m.poster_file_name, m.play_count,
             m.updated_at, COUNT(e.id) AS episode_count,
             SUM(CASE WHEN e.duration_ms IS NULL THEN 0 ELSE e.duration_ms END) AS duration_ms
      FROM movies m
      LEFT JOIN publishers p ON p.id = m.publisher_id
      LEFT JOIN series s ON s.id = m.series_id
      LEFT JOIN episodes e ON e.movie_id = m.id
      WHERE m.id = ?
      GROUP BY m.id
    ''', [movieId]);
    return rows.isEmpty ? null : _withResolution(_mapMovie(rows.single));
  }

  /// 统一替换影片可编辑元数据，供 Windows 手动管理与未来 AI 富化共用。
  NasLibraryMovie? updateMovieMetadata({
    required String movieId,
    String? title,
    String? originalTitle,
    bool updateOriginalTitle = false,
    String? catalogNumber,
    bool updateCatalogNumber = false,
    String? publisherName,
    bool updatePublisherName = false,
    String? seriesName,
    bool updateSeriesName = false,
    String? summary,
  }) {
    if (findMovieForAdmin(movieId) == null) return null;
    if (title == null &&
        !updateOriginalTitle &&
        !updateCatalogNumber &&
        !updatePublisherName &&
        !updateSeriesName &&
        summary == null) {
      return findMovieForAdmin(movieId);
    }
    final assignments = <String>[];
    final values = <Object?>[];
    if (title != null) {
      assignments.add('title = ?');
      values.add(title);
    }
    if (updateOriginalTitle) {
      assignments.add('original_title = ?');
      values.add(_nullableTrimmed(originalTitle));
    }
    if (updateCatalogNumber) {
      assignments.add('catalog_number = ?');
      values.add(_nullableTrimmed(catalogNumber));
    }
    if (updatePublisherName) {
      assignments.add('publisher_name = ?');
      values.add(_nullableTrimmed(publisherName));
    }
    if (updateSeriesName) {
      assignments.add('series_name = ?');
      values.add(_nullableTrimmed(seriesName));
    }
    if (summary != null) {
      assignments.add('summary = ?');
      values.add(summary);
    }
    assignments.add('updated_at = ?');
    values.add(_now());
    values.add(movieId);
    _db.execute(
      'UPDATE movies SET ${assignments.join(', ')} WHERE id = ?',
      values,
    );
    return findMovieForAdmin(movieId);
  }

  List<NasLibraryEpisode> episodesForMovie(String movieId) {
    final rows = _db.select('''
      SELECT id, movie_id, title, relative_path, file_size, is_available, duration_ms,
             video_width, video_height, resolution_label, media_modified_at, updated_at
      FROM episodes WHERE movie_id = ? ORDER BY title COLLATE NOCASE
    ''', [movieId]);
    return rows
        .map((row) => NasLibraryEpisode(
              id: row['id'] as String,
              movieId: row['movie_id'] as String,
              title: row['title'] as String,
              relativePath: row['relative_path'] as String,
              fileSize: row['file_size'] as int,
              isAvailable: (row['is_available'] as int) == 1,
              durationMs: row['duration_ms'] as int?,
              videoWidth: row['video_width'] as int?,
              videoHeight: row['video_height'] as int?,
              resolutionLabel: row['resolution_label'] as String?,
              mediaModifiedAt: row['media_modified_at'] as int?,
              updatedAt: row['updated_at'] as String,
            ))
        .toList(growable: false);
  }

  NasLibraryEpisode? findEpisode(String episodeId) {
    final rows = _db.select('''
      SELECT id, movie_id, title, relative_path, file_size, is_available, duration_ms
      FROM episodes WHERE id = ?
    ''', [episodeId]);
    return rows.isEmpty
        ? null
        : episodesForMovie(rows.first['movie_id'] as String)
            .firstWhere((episode) => episode.id == episodeId);
  }

  NasLibraryEpisode? updateEpisodeTitle({
    required String episodeId,
    required String title,
  }) {
    final episode = findEpisode(episodeId);
    if (episode == null) return null;
    _db.execute(
      'UPDATE episodes SET title = ?, updated_at = ? WHERE id = ?',
      [title, _now(), episodeId],
    );
    return findEpisode(episodeId);
  }

  List<NasLibraryCategory> listCategories() => _db
      .select(
          'SELECT id, name, color, media_relative_path, created_at, updated_at FROM library_categories ORDER BY name COLLATE NOCASE')
      .map(_mapCategory)
      .toList(growable: false);

  NasLibraryCategory? findCategory(String categoryId) {
    final rows = _db.select(
      'SELECT id, name, color, media_relative_path, created_at, updated_at FROM library_categories WHERE id = ?',
      [categoryId],
    );
    return rows.isEmpty ? null : _mapCategory(rows.single);
  }

  bool hasCategoryName(String name, {String? excludingId}) {
    final normalized = normalizeTaxonomyName(name);
    return listCategories().any(
      (category) =>
          category.id != excludingId &&
          normalizeTaxonomyName(category.name) == normalized,
    );
  }

  NasLibraryCategory createCategory(String name,
      {String? mediaRelativePath, String? color}) {
    _requireTaxonomyName(name, '分类');
    if (hasCategoryName(name)) {
      throw ArgumentError.value(name, 'name', 'already exists');
    }
    final timestamp = _now();
    final category = NasLibraryCategory(
      id: newUuidV4(),
      name: name,
      color: color,
      mediaRelativePath: mediaRelativePath,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    _db.execute(
      'INSERT INTO library_categories(id, name, color, media_relative_path, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
      [
        category.id,
        category.name,
        category.color,
        category.mediaRelativePath,
        category.createdAt,
        category.updatedAt
      ],
    );
    return category;
  }

  NasLibraryCategory? updateCategory(
    String categoryId, {
    required String name,
    String? mediaRelativePath,
    String? color,
    bool updateColor = false,
    required bool updateMediaRelativePath,
  }) {
    if (findCategory(categoryId) == null) return null;
    _requireTaxonomyName(name, '分类');
    if (hasCategoryName(name, excludingId: categoryId)) {
      throw ArgumentError.value(name, 'name', 'already exists');
    }
    if (updateMediaRelativePath) {
      _db.execute('DELETE FROM movies WHERE category_id = ?', [categoryId]);
    }
    _db.execute(
      updateMediaRelativePath
          ? 'UPDATE library_categories SET name = ?, color = ?, media_relative_path = ?, updated_at = ? WHERE id = ?'
          : 'UPDATE library_categories SET name = ?, color = ?, updated_at = ? WHERE id = ?',
      updateMediaRelativePath
          ? [
              name,
              updateColor ? color : findCategory(categoryId)!.color,
              mediaRelativePath,
              _now(),
              categoryId
            ]
          : [
              name,
              updateColor ? color : findCategory(categoryId)!.color,
              _now(),
              categoryId
            ],
    );
    return findCategory(categoryId);
  }

  bool deleteCategory(String categoryId, {bool deleteMovies = false}) {
    if (findCategory(categoryId) == null) return false;
    if (deleteMovies) {
      _db.execute('DELETE FROM movies WHERE category_id = ?', [categoryId]);
    }
    _db.execute('DELETE FROM library_categories WHERE id = ?', [categoryId]);
    return true;
  }

  NasCategoryTaxonomyTransfer exportCategoryTaxonomy() {
    final conflicts = categoryTaxonomyViolations();
    if (conflicts.isNotEmpty) throw StateError(conflicts.join('\n'));
    return NasCategoryTaxonomyTransfer(
      categories: [
        for (final category in listCategories())
          NasTaxonomyCategoryDefinition(
              name: category.name, color: category.color),
      ],
    );
  }

  NasTaxonomyTransferResult importCategoryTaxonomy(
    NasCategoryTaxonomyTransfer transfer,
  ) {
    final conflicts = categoryTaxonomyViolations();
    if (conflicts.isNotEmpty) {
      return NasTaxonomyTransferResult(
        added: const [],
        skipped: const [],
        conflicts: conflicts,
      );
    }
    final existing = {
      for (final category in listCategories())
        normalizeTaxonomyName(category.name): category,
    };
    final added = <String>[];
    final skipped = <String>[];
    _db.execute('BEGIN IMMEDIATE');
    try {
      for (final definition in transfer.categories) {
        final normalized = normalizeTaxonomyName(definition.name);
        if (existing.containsKey(normalized)) {
          skipped.add('分类：${existing[normalized]!.name}');
          continue;
        }
        createCategory(definition.name, color: definition.color);
        added.add('分类：${definition.name}');
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return NasTaxonomyTransferResult(
      added: added,
      skipped: skipped,
      conflicts: const [],
    );
  }

  List<NasLibraryTag> listTags({int? level, bool includeArchived = false}) {
    final conditions = <String>[if (!includeArchived) 'archived_at IS NULL'];
    final parameters = <Object?>[];
    if (level != null) {
      conditions.add('level = ?');
      parameters.add(level);
    }
    return _db.select('''
      SELECT id, name, level, description, color, created_at, updated_at, archived_at
      FROM tags
      ${conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}'}
      ORDER BY level, name COLLATE NOCASE, id
    ''', parameters).map(_mapTag).toList(growable: false);
  }

  NasLibraryTag? findTag(String tagId) {
    final rows = _db.select('''
      SELECT id, name, level, description, color, created_at, updated_at, archived_at
      FROM tags WHERE id = ?
    ''', [tagId]);
    return rows.isEmpty ? null : _mapTag(rows.single);
  }

  bool hasTagName(String name, {String? excludingId}) {
    final rows = _db.select(
      'SELECT id FROM tags WHERE normalized_name = ?',
      [normalizeTaxonomyName(name)],
    );
    return rows.any((row) => row['id'] != excludingId);
  }

  NasLibraryTag createTag({
    required String name,
    required int level,
    String description = '',
    String? color,
    List<String> parentIds = const [],
  }) {
    _requireWritableTaxonomy();
    _requireTagInput(
      name: name,
      level: level,
      color: color,
      parentIds: parentIds,
    );
    if (hasTagName(name)) {
      throw ArgumentError.value(name, 'name', '标签名称已存在');
    }
    final timestamp = _now();
    final tag = NasLibraryTag(
      id: newUuidV4(),
      name: name,
      level: level,
      description: description.trim(),
      color: color,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    _insertTag(tag);
    _replaceTagParents(tag.id, parentIds, timestamp);
    return tag;
  }

  NasLibraryTag? updateTag({
    required String tagId,
    required String name,
    required String description,
    String? color,
    required List<String> parentIds,
  }) {
    final current = findTag(tagId);
    if (current == null) return null;
    _requireWritableTaxonomy();
    _requireTagInput(
      name: name,
      level: current.level,
      color: color,
      parentIds: parentIds,
    );
    if (hasTagName(name, excludingId: tagId)) {
      throw ArgumentError.value(name, 'name', '标签名称已存在');
    }
    final timestamp = _now();
    _db.execute('''
      UPDATE tags
      SET name = ?, normalized_name = ?, description = ?, color = ?, updated_at = ?
      WHERE id = ?
    ''', [
      name,
      normalizeTaxonomyName(name),
      description.trim(),
      color,
      timestamp,
      tagId,
    ]);
    _replaceTagParents(tagId, parentIds, timestamp);
    return findTag(tagId);
  }

  bool archiveTag(String tagId) {
    if (findTag(tagId) == null) return false;
    _requireWritableTaxonomy();
    _db.execute(
      'UPDATE tags SET archived_at = ?, updated_at = ? WHERE id = ?',
      [_now(), _now(), tagId],
    );
    return true;
  }

  bool deleteTag(String tagId) {
    final tag = findTag(tagId);
    if (tag == null) return false;
    _requireWritableTaxonomy();
    final movieLinks = _db.select(
      'SELECT COUNT(*) AS count FROM movie_tag_links WHERE tag_id = ?',
      [tagId],
    ).single['count'] as int;
    final childLinks = _db.select(
      'SELECT COUNT(*) AS count FROM tag_parent_links WHERE parent_tag_id = ?',
      [tagId],
    ).single['count'] as int;
    if (movieLinks > 0 || childLinks > 0) {
      throw StateError('标签仍有关联影片或子级，只能归档');
    }
    _db.execute('DELETE FROM tag_parent_links WHERE child_tag_id = ?', [tagId]);
    _db.execute('DELETE FROM tags WHERE id = ?', [tagId]);
    return true;
  }

  NasTagOverview tagOverview() {
    final row = _db.select('''
      SELECT COUNT(*) AS total,
             SUM(CASE WHEN level = 1 THEN 1 ELSE 0 END) AS level_one,
             SUM(CASE WHEN level = 2 THEN 1 ELSE 0 END) AS level_two,
             SUM(CASE WHEN level = 3 THEN 1 ELSE 0 END) AS level_three
      FROM tags
    ''').single;
    final links = _db.select('SELECT COUNT(*) AS count FROM movie_tag_links')
        .single['count'] as int;
    return NasTagOverview(
      total: row['total'] as int,
      levelOne: (row['level_one'] as int?) ?? 0,
      levelTwo: (row['level_two'] as int?) ?? 0,
      levelThree: (row['level_three'] as int?) ?? 0,
      movieLinks: links,
    );
  }

  List<NasTagDirectoryRoot> tagDirectory({String query = ''}) {
    final tags = listTags();
    final byId = {for (final tag in tags) tag.id: tag};
    final childrenByParent = _tagChildrenByParent();
    final counts = _tagMovieCounts();
    final normalized = query.trim().toLowerCase();
    final roots = tags.where((tag) => tag.level == 1).toList(growable: false);
    return roots.map((root) {
      final children = (childrenByParent[root.id] ?? const <String>[])
          .map((id) => byId[id])
          .whereType<NasLibraryTag>()
          .where((tag) => tag.level == 2)
          .map((tag) => NasTagDirectoryChild(
                tag: tag,
                movieCount: counts[tag.id] ?? 0,
              ))
          .toList(growable: false);
      if (normalized.isNotEmpty &&
          !root.name.toLowerCase().contains(normalized) &&
          !children.any((item) => item.tag.name.toLowerCase().contains(normalized))) {
        return null;
      }
      final visibleChildren = normalized.isNotEmpty &&
              !root.name.toLowerCase().contains(normalized)
          ? children
              .where((item) => item.tag.name.toLowerCase().contains(normalized))
              .toList(growable: false)
          : children;
      return NasTagDirectoryRoot(
        tag: root,
        movieCount: counts[root.id] ?? 0,
        children: visibleChildren,
      );
    }).whereType<NasTagDirectoryRoot>().toList(growable: false);
  }

  NasTagDetails? tagDetails({
    required String tagId,
    String? contextParentId,
    String? contextRootId,
  }) {
    final tag = findTag(tagId);
    if (tag == null) return null;
    final allTags = listTags(includeArchived: true);
    final byId = {for (final item in allTags) item.id: item};
    final parentsByChild = _tagParentsByChild();
    final parentIds = parentsByChild[tagId] ?? const <String>[];
    final parents = parentIds.map((id) => byId[id]).whereType<NasLibraryTag>().toList(growable: false);
    final directChildCount = _db.select(
      'SELECT COUNT(*) AS count FROM tag_parent_links WHERE parent_tag_id = ?',
      [tagId],
    ).single['count'] as int;
    final path = _tagPathForContext(
      tag: tag,
      byId: byId,
      parentsByChild: parentsByChild,
      contextParentId: contextParentId,
      contextRootId: contextRootId,
    );
    return NasTagDetails(
      tag: tag,
      parents: parents,
      directChildCount: directChildCount,
      movieCount: _tagMovieCounts()[tagId] ?? 0,
      path: path,
    );
  }

  NasTagChildPage tagChildren({
    required String parentTagId,
    String query = '',
    bool? associated,
    String sort = 'movieCount',
    String order = 'desc',
    int page = 1,
    int pageSize = 10,
  }) {
    if (page < 1 || pageSize != 10 ||
        !const {'movieCount', 'name', 'createdAt'}.contains(sort) ||
        !const {'asc', 'desc'}.contains(order)) {
      throw ArgumentError('子标签分页参数无效');
    }
    final tags = listTags();
    final byId = {for (final tag in tags) tag.id: tag};
    final counts = _tagMovieCounts();
    final normalized = query.trim().toLowerCase();
    final items = ( _tagChildrenByParent()[parentTagId] ?? const <String>[])
        .map((id) => byId[id])
        .whereType<NasLibraryTag>()
        .where((tag) => normalized.isEmpty || tag.name.toLowerCase().contains(normalized))
        .where((tag) =>
            associated == null || ((counts[tag.id] ?? 0) > 0) == associated)
        .map((tag) => NasTagChildSummary(tag: tag, movieCount: counts[tag.id] ?? 0))
        .toList(growable: false);
    items.sort((left, right) {
      final comparison = switch (sort) {
        'movieCount' => left.movieCount.compareTo(right.movieCount),
        'name' => left.tag.name.compareTo(right.tag.name),
        _ => left.tag.createdAt.compareTo(right.tag.createdAt),
      };
      return order == 'asc' ? comparison : -comparison;
    });
    final offset = (page - 1) * pageSize;
    final paged = offset >= items.length
        ? const <NasTagChildSummary>[]
        : items.skip(offset).take(pageSize).toList(growable: false);
    return NasTagChildPage(
      items: paged,
      number: page,
      size: pageSize,
      total: items.length,
      hasMore: offset + paged.length < items.length,
    );
  }

  NasTagMoviePage tagMovies({
    required String tagId,
    String query = '',
    String? categoryId,
    String? resolution,
    String sort = 'lastPlayedAt',
    String order = 'desc',
    int page = 1,
    int pageSize = 15,
  }) {
    if (page < 1 || pageSize != 15 ||
        !const {'lastPlayedAt', 'createdAt', 'title', 'durationMs'}.contains(sort) ||
        !const {'asc', 'desc'}.contains(order)) {
      throw ArgumentError('关联影片分页参数无效');
    }
    final clauses = <String>[
      'm.id IN (SELECT movie_id FROM movie_tag_links WHERE tag_id IN (SELECT tag_id FROM tag_scope))',
    ];
    final parameters = <Object?>[tagId];
    final trimmed = query.trim();
    if (trimmed.isNotEmpty) {
      final like = '%$trimmed%';
      final catalog = '%${_normalizeCatalogNumber(trimmed)}%';
      clauses.add('''(
        lower(m.title) LIKE lower(?) OR
        lower(COALESCE(m.original_title, '')) LIKE lower(?) OR
        lower(REPLACE(REPLACE(REPLACE(COALESCE(m.catalog_number, ''), '-', ''), '_', ''), ' ', '')) LIKE lower(?)
      )''');
      parameters.addAll([like, like, catalog]);
    }
    if (categoryId != null) {
      clauses.add('m.category_id = ?');
      parameters.add(categoryId);
    }
    if (resolution != null) {
      clauses.add('EXISTS (SELECT 1 FROM episodes re WHERE re.movie_id = m.id AND re.resolution_label = ?)');
      parameters.add(resolution);
    }
    final where = clauses.join(' AND ');
    final cte = '''WITH RECURSIVE tag_scope(tag_id) AS (
      SELECT ?
      UNION
      SELECT l.child_tag_id FROM tag_parent_links l
      JOIN tag_scope scope ON scope.tag_id = l.parent_tag_id
    )''';
    final count = _db.select('$cte SELECT COUNT(*) AS count FROM movies m WHERE $where', parameters)
        .single['count'] as int;
    final expression = switch (sort) {
      'title' => 'm.title COLLATE NOCASE',
      'createdAt' => 'm.created_at',
      'durationMs' => 'SUM(COALESCE(e.duration_ms, 0))',
      _ => 'MAX(h.started_at)',
    };
    final offset = (page - 1) * pageSize;
    final rows = _db.select('''$cte
      SELECT m.id
      FROM movies m
      LEFT JOIN episodes e ON e.movie_id = m.id
      LEFT JOIN playback_history h ON h.movie_id = m.id
      WHERE $where
      GROUP BY m.id
      ORDER BY $expression ${order.toUpperCase()}, m.id ASC
      LIMIT ? OFFSET ?
    ''', [...parameters, pageSize, offset]);
    return NasTagMoviePage(
      movieIds: rows.map((row) => row['id'] as String).toList(growable: false),
      number: page,
      size: pageSize,
      total: count,
      hasMore: offset + rows.length < count,
    );
  }

  NasTagTaxonomyTransfer exportTagTaxonomy() {
    final tags = listTags();
    final byId = {for (final tag in tags) tag.id: tag};
    final parents = _tagParentsByChild();
    return NasTagTaxonomyTransfer(
      tags: tags.map((tag) => NasTaxonomyTagDefinition(
        name: tag.name,
        level: tag.level,
        description: tag.description,
        color: tag.color,
        parents: (parents[tag.id] ?? const <String>[])
            .map((id) => byId[id]?.name)
            .whereType<String>()
            .toList(growable: false),
      )).toList(growable: false),
    );
  }

  NasTaxonomyTransferResult importTagTaxonomy(NasTagTaxonomyTransfer transfer) {
    if (transfer.validationConflicts.isNotEmpty) {
      return NasTaxonomyTransferResult(
        added: const [], skipped: transfer.sourceSkipped, conflicts: transfer.validationConflicts,
      );
    }
    final violations = taxonomyViolations();
    if (violations.isNotEmpty) {
      return NasTaxonomyTransferResult(
        added: const [], skipped: transfer.sourceSkipped, conflicts: violations,
      );
    }
    final tagsByName = {
      for (final tag in listTags(includeArchived: true)) normalizeTaxonomyName(tag.name): tag,
    };
    final definitions = {
      for (final definition in transfer.tags) normalizeTaxonomyName(definition.name): definition,
    };
    final conflicts = <String>[];
    for (final definition in transfer.tags) {
      final existing = tagsByName[normalizeTaxonomyName(definition.name)];
      if (existing != null && existing.level != definition.level) {
        conflicts.add('标签层级冲突：${definition.name} 已是${_tagLevelName(existing.level)}标签');
      }
      for (final parentName in definition.parents) {
        final key = normalizeTaxonomyName(parentName);
        final parent = tagsByName[key];
        final pending = definitions[key];
        final parentLevel = parent?.level ?? pending?.level;
        if (parentLevel == null) {
          conflicts.add('标签父级不存在：$parentName → ${definition.name}');
        } else if (parentLevel != definition.level - 1) {
          conflicts.add('标签父级层级错误：$parentName → ${definition.name}');
        } else if (parent?.archivedAt != null) {
          conflicts.add('标签父级已归档：$parentName → ${definition.name}');
        }
      }
    }
    if (conflicts.isNotEmpty) {
      return NasTaxonomyTransferResult(
        added: const [], skipped: transfer.sourceSkipped, conflicts: conflicts,
      );
    }
    final links = _db.select('SELECT child_tag_id, parent_tag_id FROM tag_parent_links')
        .map((row) => '${row['child_tag_id']}:${row['parent_tag_id']}').toSet();
    final added = <String>[];
    final skipped = <String>[...transfer.sourceSkipped];
    _db.execute('BEGIN IMMEDIATE');
    try {
      for (var level = 1; level <= 3; level++) {
        for (final definition in transfer.tags.where((item) => item.level == level)) {
          final key = normalizeTaxonomyName(definition.name);
          if (tagsByName.containsKey(key)) {
            skipped.add('${_tagLevelName(level)}标签：${tagsByName[key]!.name}');
            continue;
          }
          final timestamp = _now();
          final tag = NasLibraryTag(
            id: newUuidV4(), name: definition.name, level: level,
            description: definition.description, color: definition.color,
            createdAt: timestamp, updatedAt: timestamp,
          );
          _insertTag(tag);
          tagsByName[key] = tag;
          added.add('${_tagLevelName(level)}标签：${tag.name}');
        }
      }
      for (final definition in transfer.tags.where((item) => item.level > 1)) {
        final child = tagsByName[normalizeTaxonomyName(definition.name)]!;
        for (final parentName in definition.parents) {
          final parent = tagsByName[normalizeTaxonomyName(parentName)]!;
          final key = '${child.id}:${parent.id}';
          if (!links.add(key)) {
            skipped.add('标签归属：${parent.name} → ${child.name}');
            continue;
          }
          _db.execute('''
            INSERT INTO tag_parent_links(child_tag_id, parent_tag_id, created_at)
            VALUES (?, ?, ?)
          ''', [child.id, parent.id, _now()]);
          added.add('标签归属：${parent.name} → ${child.name}');
        }
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return NasTaxonomyTransferResult(added: added, skipped: skipped, conflicts: const []);
  }

  List<String> taxonomyViolations() {
    final tags = listTags(includeArchived: true);
    final byId = {for (final tag in tags) tag.id: tag};
    final parents = _tagParentsByChild();
    final violations = <String>[];
    for (final tag in tags) {
      final parentIds = parents[tag.id] ?? const <String>[];
      if (tag.level == 1 && parentIds.isNotEmpty) {
        violations.add('一级标签不能拥有父级：${tag.name}');
      }
      if (tag.level > 1 && parentIds.isEmpty) {
        violations.add('${_tagLevelName(tag.level)}标签缺少父级：${tag.name}');
      }
      for (final parentId in parentIds) {
        final parent = byId[parentId];
        if (parent == null || parent.level != tag.level - 1) {
          violations.add('标签父级层级错误：${tag.name}');
        }
      }
    }
    return violations;
  }

  List<String> _categoryViolations() {
    final names = <String, String>{};
    final violations = <String>[];
    for (final category in listCategories()) {
      final key = normalizeTaxonomyName(category.name);
      final existing = names[key];
      if (existing != null) {
        violations.add('分类名称重复（不区分大小写）：$existing / ${category.name}');
      } else {
        names[key] = category.name;
      }
    }
    return violations;
  }

  List<String> categoryTaxonomyViolations() => _categoryViolations();

  void _requireWritableTaxonomy() {
    final violations = taxonomyViolations();
    if (violations.isNotEmpty) throw StateError(violations.join('\n'));
  }

  static void _requireTaxonomyName(String name, String label) {
    if (name.trim().isEmpty || name != name.trim()) {
      throw ArgumentError.value(name, 'name', '$label 名称不能为空或含首尾空白');
    }
  }

  void _requireTagInput({
    required String name,
    required int level,
    required String? color,
    required List<String> parentIds,
  }) {
    _requireTaxonomyName(name, '标签');
    if (level < 1 || level > 3 || !isValidTaxonomyColor(color)) {
      throw ArgumentError('标签层级或颜色无效');
    }
    if ((level == 1 && parentIds.isNotEmpty) ||
        (level > 1 && parentIds.isEmpty) ||
        parentIds.toSet().length != parentIds.length) {
      throw ArgumentError('标签父级不符合固定三级规则');
    }
    for (final parentId in parentIds) {
      final parent = findTag(parentId);
      if (parent == null || parent.archivedAt != null || parent.level != level - 1) {
        throw ArgumentError('标签父级不存在、已归档或层级不匹配');
      }
    }
  }

  void _insertTag(NasLibraryTag tag) {
    _db.execute('''
      INSERT INTO tags(
        id, name, normalized_name, level, description, color,
        created_at, updated_at, archived_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      tag.id,
      tag.name,
      normalizeTaxonomyName(tag.name),
      tag.level,
      tag.description,
      tag.color,
      tag.createdAt,
      tag.updatedAt,
      tag.archivedAt,
    ]);
  }

  void _replaceTagParents(
    String tagId,
    List<String> parentIds,
    String timestamp,
  ) {
    _db.execute('DELETE FROM tag_parent_links WHERE child_tag_id = ?', [tagId]);
    for (final parentId in parentIds) {
      _db.execute('''
        INSERT INTO tag_parent_links(child_tag_id, parent_tag_id, created_at)
        VALUES (?, ?, ?)
      ''', [tagId, parentId, timestamp]);
    }
  }

  Map<String, List<String>> _tagParentsByChild() {
    final values = <String, List<String>>{};
    for (final row in _db.select('''
      SELECT child_tag_id, parent_tag_id
      FROM tag_parent_links
      ORDER BY parent_tag_id, child_tag_id
    ''')) {
      values.putIfAbsent(row['child_tag_id'] as String, () => [])
          .add(row['parent_tag_id'] as String);
    }
    return values;
  }

  Map<String, List<String>> _tagChildrenByParent() {
    final values = <String, List<String>>{};
    for (final entry in _tagParentsByChild().entries) {
      for (final parentId in entry.value) {
        values.putIfAbsent(parentId, () => []).add(entry.key);
      }
    }
    return values;
  }

  Map<String, int> _tagMovieCounts() {
    final rows = _db.select('''
      WITH RECURSIVE descendants(ancestor_id, descendant_id) AS (
        SELECT id, id FROM tags
        UNION
        SELECT descendants.ancestor_id, links.child_tag_id
        FROM descendants
        JOIN tag_parent_links links ON links.parent_tag_id = descendants.descendant_id
      )
      SELECT descendants.ancestor_id AS tag_id,
             COUNT(DISTINCT movie_tag_links.movie_id) AS movie_count
      FROM descendants
      LEFT JOIN movie_tag_links ON movie_tag_links.tag_id = descendants.descendant_id
      GROUP BY descendants.ancestor_id
    ''');
    return {
      for (final row in rows) row['tag_id'] as String: row['movie_count'] as int,
    };
  }

  List<NasLibraryTag> _tagPathForContext({
    required NasLibraryTag tag,
    required Map<String, NasLibraryTag> byId,
    required Map<String, List<String>> parentsByChild,
    required String? contextParentId,
    required String? contextRootId,
  }) {
    if (tag.level == 1) return [tag];
    final parentIds = parentsByChild[tag.id] ?? const <String>[];
    final selectedParentId = contextParentId != null && parentIds.contains(contextParentId)
        ? contextParentId
        : parentIds.isEmpty
            ? null
            : parentIds.first;
    final parent = selectedParentId == null ? null : byId[selectedParentId];
    if (parent == null) return [tag];
    if (tag.level == 2) return [parent, tag];
    final grandparentIds = parentsByChild[parent.id] ?? const <String>[];
    final grandparentId = contextRootId != null && grandparentIds.contains(contextRootId)
        ? contextRootId
        : grandparentIds.isEmpty
            ? null
            : grandparentIds.first;
    final grandparent = grandparentId == null ? null : byId[grandparentId];
    return [if (grandparent != null) grandparent, parent, tag];
  }

  List<NasTagPath> _tagPathsForIds(Iterable<String> tagIds) {
    final tags = listTags(includeArchived: true);
    final byId = {for (final tag in tags) tag.id: tag};
    final parentsByChild = _tagParentsByChild();
    List<List<NasLibraryTag>> pathsFor(String tagId, Set<String> visiting) {
      final tag = byId[tagId];
      if (tag == null || !visiting.add(tagId)) return const [];
      try {
        if (tag.level == 1) return [[tag]];
        final parentIds = parentsByChild[tagId] ?? const <String>[];
        final paths = <List<NasLibraryTag>>[];
        for (final parentId in parentIds) {
          for (final path in pathsFor(parentId, visiting)) {
            paths.add([...path, tag]);
          }
        }
        return paths;
      } finally {
        visiting.remove(tagId);
      }
    }

    final result = <NasTagPath>[];
    final seen = <String>{};
    for (final tagId in tagIds) {
      final tag = byId[tagId];
      if (tag == null) continue;
      for (final path in pathsFor(tagId, <String>{})) {
        final names = path.map((item) => item.name).toList(growable: false);
        final key = '${tag.id}:${names.join('\u0000')}';
        if (!seen.add(key)) continue;
        result.add(NasTagPath(
          placementId: tag.id,
          tagId: tag.id,
          tagName: tag.name,
          names: names,
        ));
      }
    }
    return result;
  }

  NasLibraryCategory? categoryForMovie(String movieId) {
    final rows = _db.select('''
      SELECT c.id, c.name, c.media_relative_path, c.created_at, c.updated_at
      FROM movies m JOIN library_categories c ON c.id = m.category_id
      WHERE m.id = ?
    ''', [movieId]);
    return rows.isEmpty ? null : _mapCategory(rows.single);
  }

  List<NasTagPath> tagPathsForMovie(String movieId) {
    final linkedIds = _db.select('''
      SELECT tag_id FROM movie_tag_links WHERE movie_id = ? ORDER BY tag_id
    ''', [movieId]).map((row) => row['tag_id'] as String);
    return _tagPathsForIds(linkedIds);
  }

  List<NasTagPath> allTagPaths() =>
      _tagPathsForIds(listTags(includeArchived: true).map((tag) => tag.id));

  List<NasLibraryTag> tagsForMovie(String movieId) {
    return _db.select('''
      SELECT t.id, t.name, t.level, t.description, t.color,
             t.created_at, t.updated_at, t.archived_at
      FROM tags t JOIN movie_tag_links links ON links.tag_id = t.id
      WHERE links.movie_id = ?
      ORDER BY t.level, t.name COLLATE NOCASE, t.id
    ''', [movieId]).map(_mapTag).toList(growable: false);
  }

  List<NasLibraryTag> _tagsForRelation(
    String condition,
    List<Object?> parameters,
  ) =>
      _db.select('''
        SELECT DISTINCT t.id, t.name, t.level, t.description, t.color,
               t.created_at, t.updated_at, t.archived_at
        FROM movies m
        JOIN movie_tag_links links ON links.movie_id = m.id
        JOIN tags t ON t.id = links.tag_id
        WHERE $condition
        ORDER BY t.name COLLATE NOCASE, t.id
      ''', parameters).map(_mapTag).toList(growable: false);

  List<NasRelatedActor> _relatedActorsForMovies(
    String condition,
    List<Object?> parameters,
  ) {
    final rows = _db.select('''
      SELECT l.actor_id, COUNT(DISTINCT l.movie_id) AS movie_count
      FROM movie_actor_links l
      JOIN movies m ON m.id = l.movie_id
      WHERE $condition
      GROUP BY l.actor_id
      ORDER BY movie_count DESC, l.actor_id ASC
    ''', parameters);
    return rows
        .map((row) {
          final actor = findActor(row['actor_id'] as String);
          return actor == null
              ? null
              : NasRelatedActor(
                  actor: actor,
                  movieCount: row['movie_count'] as int,
                );
        })
        .whereType<NasRelatedActor>()
        .toList(growable: false);
  }

  bool setMovieTaxonomy({
    required String movieId,
    required bool updateCategory,
    required String? categoryId,
    required bool updateTagIds,
    required List<String> tagIds,
  }) {
    if (findMovieForAdmin(movieId) == null) return false;
    if (updateCategory) {
      _db.execute(
        'UPDATE movies SET category_id = ?, updated_at = ? WHERE id = ?',
        [categoryId, _now(), movieId],
      );
    }
    if (updateTagIds) {
      _db.execute('DELETE FROM movie_tag_links WHERE movie_id = ?', [movieId]);
      for (final tagId in tagIds) {
        _db.execute(
          'INSERT INTO movie_tag_links(movie_id, tag_id) VALUES (?, ?)',
          [movieId, tagId],
        );
      }
    }
    return true;
  }

  NasLibraryMovie? updateMoviePosterFileName({
    required String movieId,
    required String posterFileName,
  }) {
    if (findMovieForAdmin(movieId) == null) return null;
    _db.execute(
      'UPDATE movies SET poster_file_name = ?, updated_at = ? WHERE id = ?',
      [posterFileName, _now(), movieId],
    );
    return findMovieForAdmin(movieId);
  }

  NasLibraryEpisode? updateEpisodeSourceAfterRename({
    required String episodeId,
    required String relativePath,
    required String title,
    required int fileSize,
    required int mediaModifiedAt,
  }) {
    final episode = findEpisode(episodeId);
    if (episode == null) return null;
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute(
        '''UPDATE episodes
           SET relative_path = ?, title = ?, file_size = ?, media_modified_at = ?,
               is_available = 1, updated_at = ?
           WHERE id = ?''',
        [
          relativePath,
          title,
          fileSize,
          mediaModifiedAt,
          _now(),
          episodeId,
        ],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return findEpisode(episodeId);
  }

  int resumePositionMsForEpisode({
    required String movieId,
    required String episodeId,
  }) {
    final rows = _db.select('''
      SELECT position_ms FROM episode_playback_progress
      WHERE movie_id = ? AND episode_id = ?
    ''', [movieId, episodeId]);
    return rows.isEmpty ? 0 : rows.single['position_ms'] as int;
  }

  String recordPlaybackStarted({
    required String movieId,
    required String episodeId,
  }) {
    final historyId = newUuidV4();
    final timestamp = _now();
    _db.execute(
      'UPDATE movies SET play_count = play_count + 1, updated_at = ? WHERE id = ?',
      [timestamp, movieId],
    );
    _db.execute(
      '''INSERT INTO playback_history(id, movie_id, episode_id, started_at)
         VALUES (?, ?, ?, ?)''',
      [historyId, movieId, episodeId, timestamp],
    );
    return historyId;
  }

  void finishPlaybackHistory({
    required String historyId,
    required int? endPositionMs,
    required int? durationMs,
  }) {
    _db.execute(
      '''UPDATE playback_history
         SET ended_at = ?, end_position_ms = ?, duration_ms = ?
         WHERE id = ?''',
      [_now(), endPositionMs, durationMs, historyId],
    );
  }

  List<NasPlaybackHistoryItem> listPlaybackHistory({String titleQuery = ''}) {
    final query = titleQuery.trim();
    final like = '%$query%';
    final normalizedCatalogQuery = _normalizeCatalogNumber(query);
    final catalogLike = '%$normalizedCatalogQuery%';
    final rows = _db.select('''
      SELECT h.id, h.movie_id, h.episode_id, m.title, m.original_title,
             m.catalog_number, m.poster_file_name,
             h.started_at, h.ended_at, h.end_position_ms, h.duration_ms
        FROM playback_history h
        JOIN movies m ON m.id = h.movie_id
       WHERE (
         ? = ''
         OR lower(m.title) LIKE lower(?)
         OR lower(COALESCE(m.original_title, '')) LIKE lower(?)
         OR (? != '' AND lower(REPLACE(REPLACE(REPLACE(
           COALESCE(m.catalog_number, ''), '-', ''), '_', ''), ' ', '')) LIKE ?)
       )
       ORDER BY h.started_at DESC, h.id DESC
    ''', [query, like, like, normalizedCatalogQuery, catalogLike]);
    return rows
        .map(
          (row) => NasPlaybackHistoryItem(
            id: row['id'] as String,
            movieId: row['movie_id'] as String,
            episodeId: row['episode_id'] as String,
            title: row['title'] as String,
            originalTitle: row['original_title'] as String?,
            catalogNumber: row['catalog_number'] as String?,
            posterFileName: row['poster_file_name'] as String?,
            startedAt: row['started_at'] as String,
            endedAt: row['ended_at'] as String?,
            endPositionMs: row['end_position_ms'] as int?,
            durationMs: row['duration_ms'] as int?,
          ),
        )
        .toList(growable: false);
  }

  void savePlaybackProgress({
    required String movieId,
    required String episodeId,
    required int positionMs,
    required int durationMs,
  }) {
    final boundedPosition = positionMs > durationMs ? durationMs : positionMs;
    _db.execute('''
      INSERT INTO episode_playback_progress(
        movie_id, episode_id, position_ms, duration_ms, updated_at
      ) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(movie_id, episode_id) DO UPDATE SET
        position_ms = excluded.position_ms,
        duration_ms = excluded.duration_ms,
        updated_at = excluded.updated_at
    ''', [movieId, episodeId, boundedPosition, durationMs, _now()]);
  }

  List<NasCarouselImage> carouselImagesForMovie(String movieId) =>
      _db.select('''
        SELECT id, movie_id, file_name, created_at
        FROM movie_carousel_images WHERE movie_id = ? ORDER BY created_at, id
      ''', [movieId]).map(_mapCarouselImage).toList(growable: false);

  String? lastPlaybackStartedAtForMovie(String movieId) {
    final rows = _db.select('''
      SELECT started_at FROM playback_history
      WHERE movie_id = ?
      ORDER BY started_at DESC, id DESC
      LIMIT 1
    ''', [movieId]);
    return rows.isEmpty ? null : rows.single['started_at'] as String?;
  }

  NasCarouselImage? addCarouselImage({
    required String movieId,
    required String fileName,
  }) {
    if (findMovieForAdmin(movieId) == null) return null;
    final image = NasCarouselImage(
      id: newUuidV4(),
      movieId: movieId,
      fileName: fileName,
      createdAt: _now(),
    );
    _db.execute(
      'INSERT INTO movie_carousel_images(id, movie_id, file_name, created_at) VALUES (?, ?, ?, ?)',
      [image.id, image.movieId, image.fileName, image.createdAt],
    );
    return image;
  }

  NasCarouselImage? removeCarouselImage({
    required String movieId,
    required String imageId,
  }) {
    final rows = _db.select('''
      SELECT id, movie_id, file_name, created_at FROM movie_carousel_images
      WHERE id = ? AND movie_id = ?
    ''', [imageId, movieId]);
    if (rows.isEmpty) return null;
    final image = _mapCarouselImage(rows.single);
    _db.execute('DELETE FROM movie_carousel_images WHERE id = ?', [imageId]);
    return image;
  }

  NasCarouselImage? findCarouselImage(String imageId) {
    final rows = _db.select('''
      SELECT id, movie_id, file_name, created_at FROM movie_carousel_images
      WHERE id = ?
    ''', [imageId]);
    return rows.isEmpty ? null : _mapCarouselImage(rows.single);
  }

  NasPublisher _mapPublisher(Row row) => NasPublisher(
        id: row['id'] as String,
        displayName: row['display_name'] as String,
        originalName: row['original_name'] as String?,
        countryRegion: row['country_region'] as String?,
        foundedDate: row['founded_date'] as String?,
        logoAssetId: row['logo_asset_id'] as String?,
        movieCount: row['movie_count'] as int,
        seriesCount: row['series_count'] as int,
        durationMs: (row['duration_ms'] as int?) == 0
            ? null
            : row['duration_ms'] as int?,
        createdAt: row['created_at'] as String,
        updatedAt: row['updated_at'] as String,
        archivedAt: row['archived_at'] as String?,
      );

  NasSeries _mapSeries(Row row) => NasSeries(
        id: row['id'] as String,
        displayName: row['display_name'] as String,
        originalName: row['original_name'] as String?,
        translatedName: row['translated_name'] as String?,
        publisherId: row['publisher_id'] as String?,
        releaseDate: row['release_date'] as String?,
        posterAssetId: row['poster_asset_id'] as String?,
        movieCount: row['movie_count'] as int,
        episodeCount: row['episode_count'] as int,
        durationMs: (row['duration_ms'] as int?) == 0
            ? null
            : row['duration_ms'] as int?,
        createdAt: row['created_at'] as String,
        updatedAt: row['updated_at'] as String,
        archivedAt: row['archived_at'] as String?,
      );

  NasActor _mapActor(Row row) => NasActor(
        id: row['id'] as String,
        stageName: row['stage_name'] as String?,
        originalName: row['original_name'] as String?,
        translatedName: row['translated_name'] as String?,
        aliases: _decodeTextList(row['aliases_json'] as String?),
        gender: row['gender'] as String?,
        birthMonth: row['birth_month'] as String?,
        heightCm: row['height_cm'] as int?,
        weightKg: row['weight_kg'] as int?,
        measurements: row['measurements'] as String?,
        bodyType: row['body_type'] as String?,
        country: row['country'] as String?,
        debutMonth: row['debut_month'] as String?,
        debutDescription: row['debut_description'] as String?,
        photoAssetId: row['photo_asset_id'] as String?,
        publisherIds: publisherIdsForActor(row['id'] as String),
        movieCount: row['movie_count'] as int,
        createdAt: row['created_at'] as String,
        updatedAt: row['updated_at'] as String,
        archivedAt: row['archived_at'] as String?,
      );

  NasLibraryMovie _mapMovie(Row row) => NasLibraryMovie(
        id: row['id'] as String,
        title: row['title'] as String,
        originalTitle: row['original_title'] as String?,
        catalogNumber: row['catalog_number'] as String?,
        publisherId: row['publisher_id'] as String?,
        publisherName: row['publisher_name'] as String?,
        seriesId: row['series_id'] as String?,
        seriesName: row['series_name'] as String?,
        summary: row['summary'] as String,
        actors: _movieActors(row['id'] as String),
        posterFileName: row['poster_file_name'] as String?,
        playCount: row['play_count'] as int,
        episodeCount: row['episode_count'] as int,
        durationMs: (row['duration_ms'] as int?) == 0
            ? null
            : row['duration_ms'] as int?,
        updatedAt: row['updated_at'] as String,
      );

  NasLibraryMovie _withResolution(NasLibraryMovie movie) {
    final rows = _db.select(
      'SELECT DISTINCT video_width, video_height, resolution_label FROM episodes WHERE movie_id = ? AND is_available = 1 AND video_width IS NOT NULL AND video_height IS NOT NULL',
      [movie.id],
    );
    final label = rows.length > 1
        ? '多种分辨率'
        : rows.isEmpty
            ? null
            : rows.single['resolution_label'] as String?;
    final row = rows.length == 1 ? rows.single : null;
    return NasLibraryMovie(
      id: movie.id,
      title: movie.title,
      originalTitle: movie.originalTitle,
      catalogNumber: movie.catalogNumber,
      publisherId: movie.publisherId,
      publisherName: movie.publisherName,
      seriesId: movie.seriesId,
      seriesName: movie.seriesName,
      summary: movie.summary,
      actors: movie.actors,
      posterFileName: movie.posterFileName,
      episodeCount: movie.episodeCount,
      durationMs: movie.durationMs,
      playCount: movie.playCount,
      updatedAt: movie.updatedAt,
      videoWidth: row?['video_width'] as int?,
      videoHeight: row?['video_height'] as int?,
      resolutionLabel: label,
    );
  }

  List<NasMovieActor> _movieActors(String movieId) => actorsForMovie(movieId)
      .map(
        (actor) => NasMovieActor(
          id: actor.id,
          name: actor.translatedName ??
              actor.stageName ??
              actor.originalName ??
              '未命名演员',
          gender:
              NasActorGender.tryParse(actor.gender) ?? NasActorGender.unknown,
        ),
      )
      .toList(growable: false);

  NasMediaRoot? _mediaRootForContainerPath(String containerPath) {
    final rows = _db.select('''
      SELECT id, name, container_path, read_only, enabled, created_at,
             updated_at, last_scanned_at
      FROM media_roots WHERE container_path = ?
    ''', [containerPath]);
    return rows.isEmpty ? null : _mapMediaRoot(rows.single);
  }

  NasMediaRoot _mapMediaRoot(Row row) => NasMediaRoot(
        id: row['id'] as String,
        name: row['name'] as String,
        containerPath: row['container_path'] as String,
        readOnly: (row['read_only'] as int) == 1,
        enabled: (row['enabled'] as int) == 1,
        createdAt: row['created_at'] as String,
        updatedAt: row['updated_at'] as String,
        lastScannedAt: row['last_scanned_at'] as String?,
      );

  NasLibraryCategory _mapCategory(Row row) => NasLibraryCategory(
        id: row['id'] as String,
        name: row['name'] as String,
        color: row['color'] as String?,
        mediaRelativePath: row['media_relative_path'] as String?,
        createdAt: row['created_at'] as String,
        updatedAt: row['updated_at'] as String,
      );

  NasCarouselImage _mapCarouselImage(Row row) => NasCarouselImage(
        id: row['id'] as String,
        movieId: row['movie_id'] as String,
        fileName: row['file_name'] as String,
        createdAt: row['created_at'] as String,
      );

  NasLibraryTag _mapTag(Row row) => NasLibraryTag(
        id: row['id'] as String,
        name: row['name'] as String,
        level: row['level'] as int,
        description: row['description'] as String? ?? '',
        color: row['color'] as String?,
        createdAt: row['created_at'] as String,
        updatedAt: row['updated_at'] as String,
        archivedAt: row['archived_at'] as String?,
      );

  void _markRootScanned(String rootId) {
    _db.execute(
      'UPDATE media_roots SET last_scanned_at = ?, updated_at = ? WHERE id = ?',
      [_now(), _now(), rootId],
    );
  }

  static bool _isVideo(String path) =>
      RegExp(r'\.(mp4|m4v|mkv|mov|webm)$', caseSensitive: false).hasMatch(path);
  static String _titleFromPath(String relativePath) {
    final name = relativePath.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  static String _now() => DateTime.now().toUtc().toIso8601String();
}

List<String> _decodeTextList(String? value) {
  if (value == null || value.isEmpty) return const [];
  try {
    final decoded = jsonDecode(value);
    if (decoded is! List) return const [];
    return _cleanTextList(decoded.whereType<String>());
  } on FormatException {
    return const [];
  }
}

List<String> _cleanTextList(Iterable<String> values) => values
    .map((value) => value.trim())
    .where((value) => value.isNotEmpty)
    .toSet()
    .toList(growable: false);

String _normalizeActorSearch(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[\s\-_.·•]+'), '');

String _actorSearchText(NasActor actor) => _normalizeActorSearch([
      actor.stageName,
      actor.originalName,
      actor.translatedName,
      actor.bodyType,
      ...actor.aliases,
    ].whereType<String>().join(' '));
