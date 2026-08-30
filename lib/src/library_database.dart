import 'dart:convert';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'auth.dart';
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
    required this.containerPath,
    required this.readOnly,
    required this.enabled,
    required this.createdAt,
    required this.updatedAt,
    required this.lastScannedAt,
  });

  final String id;
  final String name;
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
    this.mediaRelativePath,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String? mediaRelativePath;
  final String createdAt;
  final String updatedAt;
}

class NasLibraryTag {
  const NasLibraryTag({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
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

class NasLibraryDatabase {
  static const currentSchemaVersion = 9;

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
          'SELECT id, name, media_relative_path, created_at, updated_at FROM library_categories ORDER BY name COLLATE NOCASE')
      .map(_mapCategory)
      .toList(growable: false);

  NasLibraryCategory? findCategory(String categoryId) {
    final rows = _db.select(
      'SELECT id, name, media_relative_path, created_at, updated_at FROM library_categories WHERE id = ?',
      [categoryId],
    );
    return rows.isEmpty ? null : _mapCategory(rows.single);
  }

  bool hasCategoryName(String name, {String? excludingId}) {
    final rows = _db.select(
      'SELECT id FROM library_categories WHERE name = ?',
      [name],
    );
    return rows.any((row) => row['id'] != excludingId);
  }

  NasLibraryCategory createCategory(String name, {String? mediaRelativePath}) {
    final timestamp = _now();
    final category = NasLibraryCategory(
      id: newUuidV4(),
      name: name,
      mediaRelativePath: mediaRelativePath,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    _db.execute(
      'INSERT INTO library_categories(id, name, media_relative_path, created_at, updated_at) VALUES (?, ?, ?, ?, ?)',
      [category.id, category.name, category.mediaRelativePath, category.createdAt, category.updatedAt],
    );
    return category;
  }

  NasLibraryCategory? updateCategory(
    String categoryId, {
    required String name,
    String? mediaRelativePath,
    required bool updateMediaRelativePath,
  }) {
    if (findCategory(categoryId) == null) return null;
    if (updateMediaRelativePath) {
      _db.execute('DELETE FROM movies WHERE category_id = ?', [categoryId]);
    }
    _db.execute(
      updateMediaRelativePath
          ? 'UPDATE library_categories SET name = ?, media_relative_path = ?, updated_at = ? WHERE id = ?'
          : 'UPDATE library_categories SET name = ?, updated_at = ? WHERE id = ?',
      updateMediaRelativePath
          ? [name, mediaRelativePath, _now(), categoryId]
          : [name, _now(), categoryId],
    );
    return findCategory(categoryId);
  }

  bool deleteCategory(String categoryId) {
    if (findCategory(categoryId) == null) return false;
    _db.execute('DELETE FROM library_categories WHERE id = ?', [categoryId]);
    return true;
  }

  List<NasLibraryTag> listTags() => _db
      .select(
          'SELECT id, name, created_at, updated_at FROM tags ORDER BY name COLLATE NOCASE')
      .map(_mapTag)
      .toList(growable: false);

  NasLibraryTag? findTag(String tagId) {
    final rows = _db.select(
      'SELECT id, name, created_at, updated_at FROM tags WHERE id = ?',
      [tagId],
    );
    return rows.isEmpty ? null : _mapTag(rows.single);
  }

  bool hasTagName(String name, {String? excludingId}) {
    final rows = _db.select('SELECT id FROM tags WHERE name = ?', [name]);
    return rows.any((row) => row['id'] != excludingId);
  }

  NasLibraryTag createTag(String name) {
    final timestamp = _now();
    final tag = NasLibraryTag(
      id: newUuidV4(),
      name: name,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    _db.execute(
      'INSERT INTO tags(id, name, created_at, updated_at) VALUES (?, ?, ?, ?)',
      [tag.id, tag.name, tag.createdAt, tag.updatedAt],
    );
    return tag;
  }

  NasLibraryTag? updateTagName(String tagId, String name) {
    if (findTag(tagId) == null) return null;
    _db.execute(
      'UPDATE tags SET name = ?, updated_at = ? WHERE id = ?',
      [name, _now(), tagId],
    );
    return findTag(tagId);
  }

  bool deleteTag(String tagId) {
    if (findTag(tagId) == null) return false;
    _db.execute('DELETE FROM tags WHERE id = ?', [tagId]);
    return true;
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
    final timestamp = _now();
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

  NasTagPlacement? updateTagPlacementParent({
    required String placementId,
    required String? parentPlacementId,
  }) {
    if (findTagPlacement(placementId) == null) return null;
    _db.execute(
      'UPDATE tag_placements SET parent_placement_id = ?, updated_at = ? WHERE id = ?',
      [parentPlacementId, _now(), placementId],
    );
    return findTagPlacement(placementId);
  }

  bool deleteTagPlacement(String placementId) {
    if (findTagPlacement(placementId) == null) return false;
    _db.execute('DELETE FROM tag_placements WHERE id = ?', [placementId]);
    return true;
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

  void recordPlaybackStarted(String movieId) {
    _db.execute(
      'UPDATE movies SET play_count = play_count + 1, updated_at = ? WHERE id = ?',
      [_now(), movieId],
    );
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
