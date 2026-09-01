import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'auth.dart';
import 'library/taxonomy_transfer.dart';
import 'media_service.dart';
import 'metadata_probe.dart';

class NasLibraryMovie {
  const NasLibraryMovie({
    required this.id,
    required this.title,
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
  final String summary;
  final List<String> actors;
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
    this.color,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String? color;
  final String createdAt;
  final String updatedAt;
}

class NasTagPlacement {
  const NasTagPlacement({
    required this.id,
    required this.tagId,
    required this.parentPlacementId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String tagId;
  final String? parentPlacementId;
  final String createdAt;
  final String updatedAt;
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

/// NAS 自身持久化的播放历史；不包含任何 Windows 本地路径或客户端令牌。
class NasPlaybackHistoryItem {
  const NasPlaybackHistoryItem({
    required this.id,
    required this.movieId,
    required this.episodeId,
    required this.title,
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
  final String? posterFileName;
  final String startedAt;
  final String? endedAt;
  final int? endPositionMs;
  final int? durationMs;
}

class NasLibraryDatabase {
  static const currentSchemaVersion = 11;

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
      throw ArgumentError('Category scan requires both category and directory.');
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
        unchanged ? existing.first['resolution_label'] : metadata?.resolutionLabel,
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
      throw ArgumentError.value(categoryId, 'categoryId', 'has no media directory');
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
    final rows = _db.select('''
      SELECT m.id, m.title, m.summary, m.actors_json, m.poster_file_name, m.play_count, m.updated_at, COUNT(e.id) AS episode_count,
             SUM(CASE WHEN e.duration_ms IS NULL THEN 0 ELSE e.duration_ms END) AS duration_ms
      FROM movies m JOIN episodes e ON e.movie_id = m.id
      WHERE e.is_available = 1 AND (? = '%%' OR lower(m.title) LIKE lower(?))
      GROUP BY m.id ORDER BY m.title COLLATE NOCASE
    ''', [queryLike, queryLike]);
    return rows
        .map((row) => _withResolution(NasLibraryMovie(
              id: row['id'] as String,
              title: row['title'] as String,
              summary: row['summary'] as String,
              actors: _decodeActors(row['actors_json'] as String?),
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
      SELECT m.id, m.title, m.summary, m.actors_json, m.poster_file_name, m.play_count, m.updated_at, COUNT(e.id) AS episode_count,
             SUM(CASE WHEN e.duration_ms IS NULL THEN 0 ELSE e.duration_ms END) AS duration_ms
      FROM movies m LEFT JOIN episodes e ON e.movie_id = m.id
      WHERE m.id = ?
      GROUP BY m.id
    ''', [movieId]);
    return rows.isEmpty ? null : _withResolution(_mapMovie(rows.single));
  }

  NasLibraryMovie? updateMovieMetadata({
    required String movieId,
    String? title,
    String? summary,
    List<String>? actors,
  }) {
    if (findMovieForAdmin(movieId) == null) return null;
    if (title == null && summary == null && actors == null) {
      return findMovieForAdmin(movieId);
    }
    final assignments = <String>[];
    final values = <Object?>[];
    if (title != null) {
      assignments.add('title = ?');
      values.add(title);
    }
    if (summary != null) {
      assignments.add('summary = ?');
      values.add(summary);
    }
    if (actors != null) {
      assignments.add('actors_json = ?');
      values.add(jsonEncode(actors));
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

  NasLibraryCategory createCategory(String name, {String? mediaRelativePath, String? color}) {
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
      [category.id, category.name, category.color, category.mediaRelativePath, category.createdAt, category.updatedAt],
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
          ? [name, updateColor ? color : findCategory(categoryId)!.color, mediaRelativePath, _now(), categoryId]
          : [name, updateColor ? color : findCategory(categoryId)!.color, _now(), categoryId],
    );
    return findCategory(categoryId);
  }

  bool deleteCategory(String categoryId) {
    if (findCategory(categoryId) == null) return false;
    _db.execute('DELETE FROM library_categories WHERE id = ?', [categoryId]);
    return true;
  }

  NasCategoryTaxonomyTransfer exportCategoryTaxonomy() {
    final conflicts = categoryTaxonomyViolations();
    if (conflicts.isNotEmpty) throw StateError(conflicts.join('\n'));
    return NasCategoryTaxonomyTransfer(
      categories: [
        for (final category in listCategories())
          NasTaxonomyCategoryDefinition(name: category.name, color: category.color),
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

  List<NasLibraryTag> listTags() => _db
      .select(
           'SELECT id, name, color, created_at, updated_at FROM tags ORDER BY name COLLATE NOCASE')
      .map(_mapTag)
      .toList(growable: false);

  NasLibraryTag? findTag(String tagId) {
    final rows = _db.select(
      'SELECT id, name, color, created_at, updated_at FROM tags WHERE id = ?',
      [tagId],
    );
    return rows.isEmpty ? null : _mapTag(rows.single);
  }

  bool hasTagName(String name, {String? excludingId}) {
    final normalized = normalizeTaxonomyName(name);
    return listTags().any(
      (tag) =>
          tag.id != excludingId && normalizeTaxonomyName(tag.name) == normalized,
    );
  }

  NasLibraryTag createTag(String name, {String? color}) {
    return createRootTag(name, color: color).$1;
  }

  (NasLibraryTag, NasTagPlacement) createRootTag(String name, {String? color}) {
    _requireWritableTaxonomy();
    _requireTaxonomyName(name, '标签');
    if (hasTagName(name)) {
      throw ArgumentError.value(name, 'name', 'already exists');
    }
    final timestamp = _now();
    final tag = NasLibraryTag(
      id: newUuidV4(),
      name: name,
      color: color,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    _db.execute(
      'INSERT INTO tags(id, name, color, created_at, updated_at) VALUES (?, ?, ?, ?, ?)',
      [tag.id, tag.name, tag.color, tag.createdAt, tag.updatedAt],
    );
    final placement = _insertTagPlacement(tag.id, null, timestamp);
    return (tag, placement);
  }

  (NasLibraryTag, NasTagPlacement) createChildTag({
    required String name,
    required String parentTagId,
    String? color,
  }) {
    _requireWritableTaxonomy();
    _requireTaxonomyName(name, '标签');
    if (hasTagName(name)) {
      throw ArgumentError.value(name, 'name', 'already exists');
    }
    final parentPlacement = _rootPlacementForTag(parentTagId);
    if (parentPlacement == null) {
      throw ArgumentError.value(parentTagId, 'parentTagId', 'must be a root tag');
    }
    final timestamp = _now();
    final tag = NasLibraryTag(
      id: newUuidV4(),
      name: name,
      color: color,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    _db.execute(
      'INSERT INTO tags(id, name, color, created_at, updated_at) VALUES (?, ?, ?, ?, ?)',
      [tag.id, tag.name, tag.color, tag.createdAt, tag.updatedAt],
    );
    return (tag, _insertTagPlacement(tag.id, parentPlacement.id, timestamp));
  }

  NasLibraryTag? updateTagName(String tagId, String name, {String? color, bool updateColor = false}) {
    if (findTag(tagId) == null) return null;
    _requireWritableTaxonomy();
    _requireTaxonomyName(name, '标签');
    if (hasTagName(name, excludingId: tagId)) {
      throw ArgumentError.value(name, 'name', 'already exists');
    }
    _db.execute(
      'UPDATE tags SET name = ?, color = ?, updated_at = ? WHERE id = ?',
      [name, updateColor ? color : findTag(tagId)!.color, _now(), tagId],
    );
    return findTag(tagId);
  }

  bool deleteTag(String tagId) {
    return deleteTagWithTaxonomyRules(tagId);
  }

  List<NasTagPlacement> listTagPlacements() => _db.select('''
        SELECT id, tag_id, parent_placement_id, created_at, updated_at
        FROM tag_placements ORDER BY created_at
      ''').map(_mapTagPlacement).toList(growable: false);

  NasTagPlacement? findTagPlacement(String placementId) {
    final rows = _db.select('''
      SELECT id, tag_id, parent_placement_id, created_at, updated_at
      FROM tag_placements WHERE id = ?
    ''', [placementId]);
    return rows.isEmpty ? null : _mapTagPlacement(rows.single);
  }

  NasTagPlacement createTagPlacement({
    required String tagId,
    required String? parentPlacementId,
  }) {
    _requireWritableTaxonomy();
    if (parentPlacementId == null) {
      throw ArgumentError('一级标签只能通过新建一级标签创建');
    }
    final parent = findTagPlacement(parentPlacementId);
    if (parent == null || parent.parentPlacementId != null) {
      throw ArgumentError('二级标签只能归属一级标签');
    }
    if (_rootPlacementForTag(tagId) != null) {
      throw ArgumentError('一级标签不能作为二级标签归属');
    }
    if (findTag(tagId) == null) {
      throw ArgumentError.value(tagId, 'tagId', 'does not exist');
    }
    if (listTagPlacements().any(
      (placement) =>
          placement.tagId == tagId &&
          placement.parentPlacementId == parentPlacementId,
    )) {
      throw ArgumentError('该一级归属已存在');
    }
    return _insertTagPlacement(tagId, parentPlacementId, _now());
  }

  NasTagPlacement? updateTagPlacementParent({
    required String placementId,
    required String? parentPlacementId,
  }) {
    _requireWritableTaxonomy();
    final placement = findTagPlacement(placementId);
    if (placement == null) return null;
    if (placement.parentPlacementId == null || parentPlacementId == null) {
      throw ArgumentError('一级标签不能移动，二级标签必须保留一级归属');
    }
    final parent = findTagPlacement(parentPlacementId);
    if (parent == null || parent.parentPlacementId != null) {
      throw ArgumentError('二级标签只能归属一级标签');
    }
    if (parent.tagId == placement.tagId ||
        listTagPlacements().any(
          (item) =>
              item.id != placementId &&
              item.tagId == placement.tagId &&
              item.parentPlacementId == parentPlacementId,
        )) {
      throw ArgumentError('该一级归属已存在');
    }
    _db.execute(
      'UPDATE tag_placements SET parent_placement_id = ?, updated_at = ? WHERE id = ?',
      [parentPlacementId, _now(), placementId],
    );
    return findTagPlacement(placementId);
  }

  bool deleteTagPlacement(String placementId) {
    _requireWritableTaxonomy();
    final placement = findTagPlacement(placementId);
    if (placement == null || placement.parentPlacementId == null) return false;
    final siblingPlacements = listTagPlacements()
        .where((item) => item.tagId == placement.tagId)
        .toList(growable: false);
    _db.execute('DELETE FROM tag_placements WHERE id = ?', [placementId]);
    if (siblingPlacements.length == 1) {
      _db.execute('DELETE FROM tags WHERE id = ?', [placement.tagId]);
    }
    return true;
  }

  NasTagTaxonomyTransfer exportTagTaxonomy() {
    final conflicts = taxonomyViolations();
    if (conflicts.isNotEmpty) throw StateError(conflicts.join('\n'));
    final tagsById = {for (final tag in listTags()) tag.id: tag};
    final placements = listTagPlacements();
    final roots = <NasTaxonomyTagDefinition>[];
    final children = <NasTaxonomyTagDefinition>[];
    for (final placement in placements.where((item) => item.parentPlacementId == null)) {
      final tag = tagsById[placement.tagId]!;
      roots.add(NasTaxonomyTagDefinition(name: tag.name, color: tag.color));
    }
    for (final tag in tagsById.values) {
      final parents = placements
          .where((item) => item.tagId == tag.id && item.parentPlacementId != null)
          .map((item) => tagsById[findTagPlacement(item.parentPlacementId!)!.tagId]!.name)
          .toList(growable: false);
      if (parents.isNotEmpty) {
        children.add(NasTaxonomyTagDefinition(name: tag.name, color: tag.color, parents: parents));
      }
    }
    return NasTagTaxonomyTransfer(roots: roots, children: children);
  }

  NasTaxonomyTransferResult importTagTaxonomy(NasTagTaxonomyTransfer transfer) {
    final conflicts = taxonomyViolations();
    if (conflicts.isNotEmpty) {
      return NasTaxonomyTransferResult(
        added: const [],
        skipped: const [],
        conflicts: conflicts,
      );
    }
    final tags = {for (final tag in listTags()) normalizeTaxonomyName(tag.name): tag};
    final rootIds = {
      for (final placement in listTagPlacements().where((item) => item.parentPlacementId == null))
        placement.tagId,
    };
    final childIds = {
      for (final placement in listTagPlacements().where((item) => item.parentPlacementId != null))
        placement.tagId,
    };
    final preflight = <String>[];
    for (final root in transfer.roots) {
      final existing = tags[normalizeTaxonomyName(root.name)];
      if (existing != null && !rootIds.contains(existing.id)) {
        preflight.add('标签角色冲突：${existing.name} 已是二级标签');
      }
    }
    for (final child in transfer.children) {
      final existing = tags[normalizeTaxonomyName(child.name)];
      if (existing != null && !childIds.contains(existing.id)) {
        preflight.add('标签角色冲突：${existing.name} 已是一级标签');
      }
    }
    if (preflight.isNotEmpty) {
      return NasTaxonomyTransferResult(
        added: const [],
        skipped: const [],
        conflicts: preflight,
      );
    }
    final added = <String>[];
    final skipped = <String>[];
    _db.execute('BEGIN IMMEDIATE');
    try {
      for (final root in transfer.roots) {
        final key = normalizeTaxonomyName(root.name);
        if (tags.containsKey(key)) {
          skipped.add('一级标签：${tags[key]!.name}');
        } else {
          final created = createRootTag(root.name, color: root.color).$1;
          tags[key] = created;
          rootIds.add(created.id);
          added.add('一级标签：${created.name}');
        }
      }
      for (final child in transfer.children) {
        final key = normalizeTaxonomyName(child.name);
        final existing = tags[key];
        final createdChild = existing == null;
        final tag = existing ?? createChildTag(
          name: child.name,
          parentTagId: tags[normalizeTaxonomyName(child.parents.first)]!.id,
          color: child.color,
        ).$1;
        if (existing == null) {
          tags[key] = tag;
          childIds.add(tag.id);
          added.add('二级标签：${tag.name}');
        } else {
          skipped.add('二级标签：${tag.name}');
        }
        final currentParents = listTagPlacements()
            .where((item) => item.tagId == tag.id && item.parentPlacementId != null)
            .map((item) => findTagPlacement(item.parentPlacementId!)!.tagId)
            .toSet();
        for (final parentName in child.parents) {
          final parent = tags[normalizeTaxonomyName(parentName)]!;
          if (currentParents.contains(parent.id)) {
            // createChildTag 会原子创建第一个一级归属；它属于本次导入的新增数据。
            if (createdChild &&
                normalizeTaxonomyName(parentName) ==
                    normalizeTaxonomyName(child.parents.first)) {
              added.add('标签归属：${parent.name} → ${tag.name}');
            } else {
              skipped.add('标签归属：${parent.name} → ${tag.name}');
            }
          } else {
            createTagPlacement(
              tagId: tag.id,
              parentPlacementId: _rootPlacementForTag(parent.id)!.id,
            );
            currentParents.add(parent.id);
            added.add('标签归属：${parent.name} → ${tag.name}');
          }
        }
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

  bool deleteTagWithTaxonomyRules(String tagId) {
    _requireWritableTaxonomy();
    final root = _rootPlacementForTag(tagId);
    if (root == null) return false;
    _db.execute('BEGIN IMMEDIATE');
    try {
      final children = listTagPlacements()
          .where((item) => item.parentPlacementId == root.id)
          .toList(growable: false);
      _db.execute('DELETE FROM tags WHERE id = ?', [tagId]);
      for (final childPlacement in children) {
        final remaining = listTagPlacements()
            .where((item) => item.tagId == childPlacement.tagId)
            .toList(growable: false);
        if (remaining.isEmpty) {
          _db.execute('DELETE FROM tags WHERE id = ?', [childPlacement.tagId]);
        }
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return true;
  }

  List<String> taxonomyViolations() {
    final violations = <String>[];
    final tags = listTags();
    final placements = listTagPlacements();
    final tagsById = {for (final tag in tags) tag.id: tag};
    final names = <String, String>{};
    for (final tag in tags) {
      final key = normalizeTaxonomyName(tag.name);
      final existing = names[key];
      if (existing != null) {
        violations.add('标签名称重复（不区分大小写）：$existing / ${tag.name}');
      } else {
        names[key] = tag.name;
      }
    }
    final rootCount = <String, int>{};
    final childCount = <String, int>{};
    final childParents = <String>{};
    for (final placement in placements) {
      final tag = tagsById[placement.tagId];
      if (tag == null) {
        violations.add('标签位置引用了不存在的标签：${placement.id}');
        continue;
      }
      if (placement.parentPlacementId == null) {
        rootCount.update(tag.id, (count) => count + 1, ifAbsent: () => 1);
        continue;
      }
      final parents = placements
          .where((item) => item.id == placement.parentPlacementId)
          .toList(growable: false);
      final parent = parents.isEmpty ? null : parents.single;
      if (parent == null || parent.parentPlacementId != null) {
        violations.add('标签层级超过两级：${tag.name}');
        continue;
      }
      final key = '${tag.id}:${parent.id}';
      if (!childParents.add(key)) {
        violations.add('标签归属重复：${tag.name}');
      }
      childCount.update(tag.id, (count) => count + 1, ifAbsent: () => 1);
    }
    for (final tag in tags) {
      final roots = rootCount[tag.id] ?? 0;
      final children = childCount[tag.id] ?? 0;
      if (roots == 0 && children == 0) {
        violations.add('标签未归属：${tag.name}');
      } else if (roots > 1) {
        violations.add('一级标签位置重复：${tag.name}');
      } else if (roots > 0 && children > 0) {
        violations.add('标签角色混用：${tag.name} 同时是一级和二级');
      }
    }
    return violations;
  }

  bool isTagPlacementDescendant({
    required String candidateParentId,
    required String placementId,
  }) {
    var current = findTagPlacement(candidateParentId);
    final visited = <String>{};
    while (current != null && visited.add(current.id)) {
      if (current.id == placementId) return true;
      current = current.parentPlacementId == null
          ? null
          : findTagPlacement(current.parentPlacementId!);
    }
    return false;
  }

  NasTagPlacement _insertTagPlacement(
    String tagId,
    String? parentPlacementId,
    String timestamp,
  ) {
    final placement = NasTagPlacement(
      id: newUuidV4(),
      tagId: tagId,
      parentPlacementId: parentPlacementId,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    _db.execute('''
      INSERT INTO tag_placements(id, tag_id, parent_placement_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?)
    ''', [
      placement.id,
      placement.tagId,
      placement.parentPlacementId,
      placement.createdAt,
      placement.updatedAt,
    ]);
    return placement;
  }

  NasTagPlacement? _rootPlacementForTag(String tagId) {
    final roots = listTagPlacements()
        .where((placement) =>
            placement.tagId == tagId && placement.parentPlacementId == null)
        .toList(growable: false);
    return roots.length == 1 ? roots.single : null;
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

  NasLibraryCategory? categoryForMovie(String movieId) {
    final rows = _db.select('''
      SELECT c.id, c.name, c.media_relative_path, c.created_at, c.updated_at
      FROM movies m JOIN library_categories c ON c.id = m.category_id
      WHERE m.id = ?
    ''', [movieId]);
    return rows.isEmpty ? null : _mapCategory(rows.single);
  }

  List<NasTagPath> tagPathsForMovie(String movieId) {
    final rows = _db.select('''
      SELECT tag_placement_id FROM movie_tag_placements
      WHERE movie_id = ? ORDER BY tag_placement_id
    ''', [movieId]);
    return rows
        .map((row) => _tagPathForPlacement(row['tag_placement_id'] as String))
        .whereType<NasTagPath>()
        .toList(growable: false);
  }

  List<NasTagPath> allTagPaths() => listTagPlacements()
      .map((placement) => _tagPathForPlacement(placement.id))
      .whereType<NasTagPath>()
      .toList(growable: false);

  List<NasLibraryTag> tagsForMovie(String movieId) {
    final tags = <String, NasLibraryTag>{};
    for (final path in tagPathsForMovie(movieId)) {
      final tag = findTag(path.tagId);
      if (tag != null) tags[tag.id] = tag;
    }
    return tags.values.toList(growable: false);
  }

  bool setMovieTaxonomy({
    required String movieId,
    required bool updateCategory,
    required String? categoryId,
    required bool updateTagPlacements,
    required List<String> tagPlacementIds,
  }) {
    if (findMovieForAdmin(movieId) == null) return false;
    if (updateCategory) {
      _db.execute(
        'UPDATE movies SET category_id = ?, updated_at = ? WHERE id = ?',
        [categoryId, _now(), movieId],
      );
    }
    if (updateTagPlacements) {
      _db.execute(
          'DELETE FROM movie_tag_placements WHERE movie_id = ?', [movieId]);
      for (final placementId in tagPlacementIds) {
        _db.execute(
          'INSERT INTO movie_tag_placements(movie_id, tag_placement_id) VALUES (?, ?)',
          [movieId, placementId],
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
    final rows = _db.select('''
      SELECT h.id, h.movie_id, h.episode_id, m.title, m.poster_file_name,
             h.started_at, h.ended_at, h.end_position_ms, h.duration_ms
        FROM playback_history h
        JOIN movies m ON m.id = h.movie_id
       WHERE (? = '' OR lower(m.title) LIKE lower(?))
       ORDER BY h.started_at DESC, h.id DESC
    ''', [query, like]);
    return rows
        .map(
          (row) => NasPlaybackHistoryItem(
            id: row['id'] as String,
            movieId: row['movie_id'] as String,
            episodeId: row['episode_id'] as String,
            title: row['title'] as String,
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

  List<NasCarouselImage> carouselImagesForMovie(String movieId) => _db
      .select('''
        SELECT id, movie_id, file_name, created_at
        FROM movie_carousel_images WHERE movie_id = ? ORDER BY created_at, id
      ''', [movieId])
      .map(_mapCarouselImage)
      .toList(growable: false);

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

  NasLibraryMovie _mapMovie(Row row) => NasLibraryMovie(
        id: row['id'] as String,
        title: row['title'] as String,
        summary: row['summary'] as String,
        actors: _decodeActors(row['actors_json'] as String?),
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

  List<String> _decodeActors(String? value) {
    if (value == null || value.isEmpty) return const [];
    try {
      final decoded = jsonDecode(value);
      return decoded is List
          ? decoded.whereType<String>().toList(growable: false)
          : const [];
    } on FormatException {
      return const [];
    }
  }

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
        color: row['color'] as String?,
        createdAt: row['created_at'] as String,
        updatedAt: row['updated_at'] as String,
      );

  NasTagPlacement _mapTagPlacement(Row row) => NasTagPlacement(
        id: row['id'] as String,
        tagId: row['tag_id'] as String,
        parentPlacementId: row['parent_placement_id'] as String?,
        createdAt: row['created_at'] as String,
        updatedAt: row['updated_at'] as String,
      );

  NasTagPath? _tagPathForPlacement(String placementId) {
    final reversedNames = <String>[];
    final visited = <String>{};
    var current = findTagPlacement(placementId);
    while (current != null && visited.add(current.id)) {
      final tag = findTag(current.tagId);
      if (tag == null) return null;
      reversedNames.add(tag.name);
      current = current.parentPlacementId == null
          ? null
          : findTagPlacement(current.parentPlacementId!);
    }
    if (reversedNames.isEmpty || current != null) return null;
    final placement = findTagPlacement(placementId);
    final tag = placement == null ? null : findTag(placement.tagId);
    if (tag == null) return null;
    return NasTagPath(
      placementId: placementId,
      tagId: tag.id,
      tagName: tag.name,
      names: reversedNames.reversed.toList(growable: false),
    );
  }

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
