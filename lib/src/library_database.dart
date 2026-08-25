import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'auth.dart';
import 'media_service.dart';

class NasLibraryMovie {
  const NasLibraryMovie({
    required this.id,
    required this.title,
    required this.summary,
    required this.episodeCount,
    required this.durationMs,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String summary;
  final int episodeCount;
  final int? durationMs;
  final String updatedAt;
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
  });

  final String id;
  final String movieId;
  final String title;
  final String relativePath;
  final int fileSize;
  final bool isAvailable;
  final String updatedAt;
  final int? durationMs;
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

class NasScanResult {
  const NasScanResult(
      {required this.scannedFiles, required this.availableEpisodes});

  final int scannedFiles;
  final int availableEpisodes;
}

class NasLibraryDatabase {
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
    final database =
        sqlite3.open('${directory.path}${Platform.pathSeparator}mujing.sqlite');
    database.execute('PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;');
    _database = database;
    _migrate();
  }

  Future<void> close() async {
    _database?.dispose();
    _database = null;
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
  }) async {
    final root = ensureConfiguredMediaRoot(
      rootName: rootName,
      containerPath: containerPath,
    );
    return scanMediaRoot(mediaRootId: root.id, mediaService: mediaService);
  }

  Future<NasScanResult> scanMediaRoot({
    required String mediaRootId,
    required NasMediaService mediaService,
  }) async {
    final configuredRoot = findMediaRoot(mediaRootId);
    if (configuredRoot == null || !configuredRoot.enabled) {
      throw ArgumentError.value(mediaRootId, 'mediaRootId', 'is not enabled');
    }
    if (configuredRoot.containerPath != mediaService.mediaDir) {
      throw StateError(
          'Only the configured media service root can be scanned.');
    }
    final rootId = configuredRoot.id;
    _db.execute(
        'UPDATE episodes SET is_available = 0, updated_at = ? WHERE media_root_id = ?',
        [_now(), rootId]);
    final root = Directory(configuredRoot.containerPath);
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
      final relativePath = canonicalFile
          .substring(prefix.length)
          .replaceAll(Platform.pathSeparator, '/');
      final checkedFile = await mediaService.fileForRelativePath(relativePath);
      if (checkedFile == null) continue;
      final movieId =
          'movie-${sha256Hex('$rootId:$relativePath').substring(0, 24)}';
      final episodeId =
          'episode-${sha256Hex('$rootId:$relativePath').substring(0, 24)}';
      final title = _titleFromPath(relativePath);
      final timestamp = _now();
      _db.execute('''
        INSERT INTO movies(id, title, created_at, updated_at) VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO NOTHING
      ''', [movieId, title, timestamp, timestamp]);
      _db.execute('''
        INSERT INTO episodes(id, movie_id, media_root_id, title, relative_path, file_size, is_available, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, 1, ?)
        ON CONFLICT(media_root_id, relative_path) DO UPDATE SET
          file_size = excluded.file_size, is_available = 1, updated_at = excluded.updated_at
      ''', [
        episodeId,
        movieId,
        rootId,
        title,
        relativePath,
        await checkedFile.length(),
        timestamp
      ]);
      scannedFiles++;
    }
    _markRootScanned(rootId);
    return NasScanResult(
        scannedFiles: scannedFiles, availableEpisodes: scannedFiles);
  }

  List<NasLibraryMovie> listMovies({String query = ''}) {
    final queryLike = '%${query.trim()}%';
    final rows = _db.select('''
      SELECT m.id, m.title, m.summary, m.updated_at, COUNT(e.id) AS episode_count,
             SUM(CASE WHEN e.duration_ms IS NULL THEN 0 ELSE e.duration_ms END) AS duration_ms
      FROM movies m JOIN episodes e ON e.movie_id = m.id
      WHERE e.is_available = 1 AND (? = '%%' OR lower(m.title) LIKE lower(?))
      GROUP BY m.id ORDER BY m.title COLLATE NOCASE
    ''', [queryLike, queryLike]);
    return rows
        .map((row) => NasLibraryMovie(
              id: row['id'] as String,
              title: row['title'] as String,
              summary: row['summary'] as String,
              episodeCount: row['episode_count'] as int,
              durationMs: (row['duration_ms'] as int?) == 0
                  ? null
                  : row['duration_ms'] as int?,
              updatedAt: row['updated_at'] as String,
            ))
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
      SELECT m.id, m.title, m.summary, m.updated_at, COUNT(e.id) AS episode_count,
             SUM(CASE WHEN e.duration_ms IS NULL THEN 0 ELSE e.duration_ms END) AS duration_ms
      FROM movies m LEFT JOIN episodes e ON e.movie_id = m.id
      WHERE m.id = ?
      GROUP BY m.id
    ''', [movieId]);
    return rows.isEmpty ? null : _mapMovie(rows.single);
  }

  NasLibraryMovie? updateMovieMetadata({
    required String movieId,
    String? title,
    String? summary,
  }) {
    if (title == null && summary == null) {
      throw ArgumentError('At least one movie field is required.');
    }
    if (findMovieForAdmin(movieId) == null) return null;
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
      SELECT id, movie_id, title, relative_path, file_size, is_available, duration_ms, updated_at
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

  NasLibraryMovie _mapMovie(Row row) => NasLibraryMovie(
        id: row['id'] as String,
        title: row['title'] as String,
        summary: row['summary'] as String,
        episodeCount: row['episode_count'] as int,
        durationMs: (row['duration_ms'] as int?) == 0
            ? null
            : row['duration_ms'] as int?,
        updatedAt: row['updated_at'] as String,
      );

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
