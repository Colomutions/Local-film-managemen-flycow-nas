import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';
import '../library_models.dart';
import '../media_service.dart';
import '../metadata_probe.dart';
import 'library_values.dart';

/// Owns source enumeration and scan writes, preserving their existing order.
class NasScanRepository {
  NasScanRepository(
    this._connection, {
    required this.carouselImagesForMovie,
    required this.findCategory,
    required this.findMovieForAdmin,
    required this.mediaSourcesForCategory,
    required this.transaction,
  });

  final Database Function() _connection;
  Database get _db => _connection();
  final List<NasCarouselImage> Function(String movieId) carouselImagesForMovie;
  final NasLibraryCategory? Function(String categoryId) findCategory;
  final NasLibraryMovie? Function(String movieId) findMovieForAdmin;
  final List<NasCategoryMediaSource> Function(String categoryId)
      mediaSourcesForCategory;
  final T Function<T>(T Function() action) transaction;

  NasMediaRoot ensureConfiguredMediaRoot({
    required String rootName,
    required String containerPath,
  }) {
    final existing = _db.select(
      'SELECT id FROM media_roots WHERE container_path = ?',
      [containerPath],
    );
    final timestamp = now();
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
    final root = _mediaRootForContainerPath(containerPath)!;
    _backfillLegacyCategorySources(root.id);
    return root;
  }

  List<NasMediaRoot> listMediaRoots() {
    final rows = _db.select('''
      SELECT id, name, container_path, read_only, enabled, created_at,
             updated_at, last_scanned_at, is_online
      FROM media_roots ORDER BY created_at
    ''');
    return rows.map(_mapMediaRoot).toList(growable: false);
  }

  NasMediaRoot? findMediaRoot(String mediaRootId) {
    final rows = _db.select('''
      SELECT id, name, container_path, read_only, enabled, created_at,
             updated_at, last_scanned_at, is_online
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
    final root = directoryRelativePath == null
        ? Directory(configuredRoot.containerPath)
        : (await mediaService.directoryForRelativePath(directoryRelativePath))
            ?.directory;
    if (root == null) {
      _markRootOffline(rootId);
      return const NasScanResult(scannedFiles: 0, availableEpisodes: 0);
    }
    if (!await root.exists()) {
      _markRootOffline(rootId);
      return const NasScanResult(scannedFiles: 0, availableEpisodes: 0);
    }
    if (categoryId == null) {
      _db.execute(
        'UPDATE episodes SET is_available = 0, updated_at = ? WHERE media_root_id = ?',
        [now(), rootId],
      );
    } else {
      _db.execute('''
        UPDATE episodes SET is_available = 0, updated_at = ?
        WHERE movie_id IN (SELECT id FROM movies WHERE category_id = ?)
      ''', [now(), categoryId]);
    }
    // `followLinks: false` guarantees that a listed [File] is not a symbolic
    // link. Deriving the relative path from this already-enumerated directory
    // avoids resolving the media root and every file again, which is very
    // expensive on a mounted NAS volume.
    final listedRoot = root.absolute.path;
    final prefix = listedRoot.endsWith(Platform.pathSeparator)
        ? listedRoot
        : '$listedRoot${Platform.pathSeparator}';
    var scannedFiles = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File || !isVideo(entity.path)) continue;
      final listedFile = entity.absolute.path;
      if (!listedFile.startsWith(prefix)) continue;
      final scannedRelativePath = listedFile
          .substring(prefix.length)
          .replaceAll(Platform.pathSeparator, '/');
      final relativePath = directoryRelativePath == null
          ? scannedRelativePath
          : '$directoryRelativePath/$scannedRelativePath';
      final checkedFile = NasMediaFile(File(listedFile), relativePath);
      final stat = await checkedFile.file.stat();
      final mediaModifiedAt = stat.modified.microsecondsSinceEpoch;
      final existing = _db.select(
        'SELECT file_size, media_modified_at, duration_ms, video_width, video_height, resolution_label, metadata_probed_at FROM episodes WHERE media_root_id = ? AND relative_path = ?',
        [rootId, relativePath],
      );
      final fileSize = stat.size;
      final unchanged = existing.isNotEmpty &&
          existing.first['file_size'] == fileSize &&
          existing.first['media_modified_at'] == mediaModifiedAt &&
          existing.first['metadata_probed_at'] != null;
      NasMediaMetadata? metadata;
      if (!unchanged) {
        metadata = await metadataProbe.probe(checkedFile);
      }
      final movieId =
          'movie-${sha256Hex('$rootId:$relativePath').substring(0, 24)}';
      final episodeId =
          'episode-${sha256Hex('$rootId:$relativePath').substring(0, 24)}';
      final title = titleFromPath(relativePath);
      final timestamp = now();
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
        INSERT INTO episodes(id, movie_id, media_root_id, title, relative_path, duration_ms, video_width, video_height, resolution_label, metadata_probed_at, media_modified_at, file_size, is_available, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
        ON CONFLICT(media_root_id, relative_path) DO UPDATE SET
          duration_ms = excluded.duration_ms,
          video_width = excluded.video_width,
          video_height = excluded.video_height,
          resolution_label = excluded.resolution_label,
          metadata_probed_at = excluded.metadata_probed_at,
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
        unchanged ? existing.first['metadata_probed_at'] : timestamp,
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
    Future<void> Function()? beforeFile,
    required String mediaRootId,
    required NasMediaService mediaService,
    NasMediaMetadataProbe metadataProbe = const NasMediaMetadataProbe(),
  }) async {
    final category = findCategory(categoryId);
    if (category == null) {
      throw ArgumentError.value(
          categoryId, 'categoryId', 'has no media directory');
    }
    final sources = mediaSourcesForCategory(categoryId);
    if (sources.isEmpty) {
      final directoryRelativePath = category.mediaRelativePath;
      if (directoryRelativePath == null || directoryRelativePath.isEmpty) {
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
    var scannedFiles = 0;
    var availableEpisodes = 0;
    final conflicts = <String>[];
    for (final source in sources) {
      final result = await _scanCategorySource(
        categoryId: categoryId,
        beforeFile: beforeFile,
        source: source,
        mediaService: mediaService,
        metadataProbe: metadataProbe,
      );
      scannedFiles += result.scannedFiles;
      availableEpisodes += result.availableEpisodes;
      conflicts.addAll(result.conflicts);
    }
    // 扫描期间绑定被直接修改时不执行清理，防止旧扫描误删新范围的索引。
    final currentSources = mediaSourcesForCategory(categoryId);
    final scannedScope = sources
        .map((source) => '${source.mediaRootId}:${source.relativePath}')
        .toSet();
    final currentScope = currentSources
        .map((source) => '${source.mediaRootId}:${source.relativePath}')
        .toSet();
    if (scannedScope.length != currentScope.length ||
        !scannedScope.containsAll(currentScope)) {
      throw StateError('分类目录在扫描期间已变更，请重新扫描');
    }
    final removed = _removeUnboundCategoryIndexes(categoryId);
    return NasScanResult(
      scannedFiles: scannedFiles,
      availableEpisodes: availableEpisodes,
      conflicts: conflicts,
      removedEpisodes: removed.episodes,
      removedMovieIndexes: removed.movies,
    );
  }

  /// 主动取消绑定才移除索引；不检查硬盘是否在线，也不删除任何源文件。
  ({
    int episodes,
    List<NasRemovedMovieIndex> movies
  }) _removeUnboundCategoryIndexes(String categoryId) => transaction(() {
        final stale = _db.select('''
      SELECT e.id, e.movie_id FROM episodes e JOIN movies m ON m.id=e.movie_id
      WHERE m.category_id=? AND m.lifecycle_state='active'
        AND NOT EXISTS (
          SELECT 1 FROM category_media_sources s
          WHERE s.category_id=m.category_id AND s.media_root_id=e.media_root_id
            AND (e.relative_path=s.relative_path OR
              substr(e.relative_path,1,length(s.relative_path)+1)=s.relative_path || '/')
        )
    ''', [categoryId]);
        final affectedMovies =
            stale.map((row) => row['movie_id'] as String).toSet();
        final removedMovies = <NasRemovedMovieIndex>[];
        for (final row in stale) {
          // NFO 审计对分集使用限制删除；保留影片字段值，解除已退出来源的审计引用。
          _db.execute('DELETE FROM mdcng_import_records WHERE episode_id=?',
              [row['id']]);
          _db.execute('DELETE FROM episodes WHERE id=?', [row['id']]);
        }
        for (final movieId in affectedMovies) {
          if (_db.select('SELECT 1 FROM episodes WHERE movie_id=? LIMIT 1',
              [movieId]).isNotEmpty) {
            _db.execute(
                'UPDATE movies SET updated_at=? WHERE id=?', [now(), movieId]);
            continue;
          }
          final movie = findMovieForAdmin(movieId)!;
          removedMovies.add(NasRemovedMovieIndex(
            posterFileName: movie.posterFileName,
            carouselFileNames: carouselImagesForMovie(movieId)
                .map((image) => image.fileName)
                .toList(),
          ));
          // 旧归并条目仍保持隐藏，只解除指向已移除目标的外键引用。
          _db.execute(
              'UPDATE movies SET merged_into_movie_id=NULL WHERE merged_into_movie_id=?',
              [movieId]);
          _db.execute('DELETE FROM movies WHERE id=?', [movieId]);
          _db.execute(
              "DELETE FROM scrape_fields WHERE kind='movie' AND entity_id=?",
              [movieId]);
        }
        return (episodes: stale.length, movies: removedMovies);
      });

  /// 分类扫描在单一物理来源盘内完成；盘不可读时绝不改写既有分集可用性。
  Future<NasScanResult> _scanCategorySource({
    required String categoryId,
    Future<void> Function()? beforeFile,
    required NasCategoryMediaSource source,
    required NasMediaService mediaService,
    required NasMediaMetadataProbe metadataProbe,
  }) async {
    final mediaRoot = findMediaRoot(source.mediaRootId);
    if (mediaRoot == null || !mediaRoot.enabled) {
      return const NasScanResult(scannedFiles: 0, availableEpisodes: 0);
    }
    try {
      if (!await Directory(mediaRoot.containerPath).exists()) {
        _markRootOffline(mediaRoot.id);
        return const NasScanResult(scannedFiles: 0, availableEpisodes: 0);
      }
    } on FileSystemException {
      _markRootOffline(mediaRoot.id);
      return const NasScanResult(scannedFiles: 0, availableEpisodes: 0);
    }
    final directory = mediaRoot.containerPath == mediaService.mediaDir
        ? await mediaService.directoryForRelativePath(source.relativePath)
        : await mediaService.directoryForRootRelativePath(
            rootPath: mediaRoot.containerPath,
            relativePath: source.relativePath,
          );
    if (directory == null) {
      // 来源盘在线而已绑定目录缺失，才可以确认该来源下的文件已不存在。
      _markUnavailableEpisodesForSource(categoryId, source);
      _markRootScanned(mediaRoot.id);
      return const NasScanResult(scannedFiles: 0, availableEpisodes: 0);
    }
    final files = <File>[];
    try {
      await for (final entity in directory.directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File && isVideo(entity.path)) files.add(entity);
      }
    } on FileSystemException {
      _markRootOffline(mediaRoot.id);
      return const NasScanResult(scannedFiles: 0, availableEpisodes: 0);
    }
    final listedDirectory = directory.directory.absolute.path;
    final prefix = listedDirectory.endsWith(Platform.pathSeparator)
        ? listedDirectory
        : '$listedDirectory${Platform.pathSeparator}';
    // 成功穷举后才标记不可用，避免挂载中断导致“离线即删除”。
    final seenPaths = <String>{};
    final changes = <void Function()>[];
    void flushChanges() {
      if (changes.isEmpty) return;
      transaction(() {
        for (final change in changes) {
          change();
        }
      });
      changes.clear();
    }

    var scannedFiles = 0;
    final conflicts = <String>[];
    for (final entity in files) {
      await beforeFile?.call();
      final listedFile = entity.absolute.path;
      if (!listedFile.startsWith(prefix)) continue;
      final inCategoryPath = listedFile
          .substring(prefix.length)
          .replaceAll(Platform.pathSeparator, '/');
      final grouping = episodeGrouping(inCategoryPath);
      if (grouping.isConflict) {
        conflicts.add(
            '${source.sourceName}/${source.relativePath}/${grouping.conflictPath}');
        continue;
      }
      final relativePath = '${source.relativePath}/$inCategoryPath';
      seenPaths.add(relativePath);
      final checked = NasMediaFile(File(listedFile), relativePath);
      final stat = await checked.file.stat();
      final existing = _db.select('''
        SELECT e.id, e.movie_id, e.file_size, e.media_modified_at,
               e.duration_ms, e.video_width, e.video_height, e.resolution_label,
               e.metadata_probed_at, e.is_available,
               m.collection_key
        FROM episodes e JOIN movies m ON m.id = e.movie_id
        WHERE e.media_root_id = ? AND e.relative_path = ?
      ''', [mediaRoot.id, relativePath]);
      final collectionKey =
          grouping.rootPath == null ? null : '$categoryId:${grouping.rootPath}';
      final existingCollectionKey = existing.isEmpty
          ? null
          : existing.single['collection_key'] as String?;
      if (collectionKey != null &&
          existing.isNotEmpty &&
          existingCollectionKey != collectionKey) {
        // 旧逐文件数据和管理员手工归组只能在预览确认后迁移。
        _markExistingEpisodeAvailable(existing.single['id'] as String);
        conflicts.add(
            '${source.sourceName}/${source.relativePath}/${grouping.rootPath}');
        continue;
      }
      final fileSize = stat.size;
      final modifiedAt = stat.modified.microsecondsSinceEpoch;
      final unchanged = existing.isNotEmpty &&
          existing.single['file_size'] == fileSize &&
          existing.single['media_modified_at'] == modifiedAt &&
          existing.single['metadata_probed_at'] != null;
      if (unchanged) {
        if (existing.single['is_available'] != 1) {
          final id = existing.single['id'] as String;
          changes.add(() => _markExistingEpisodeAvailable(id));
        }
        scannedFiles++;
        if (changes.length >= 100) flushChanges();
        continue;
      }
      final metadata = await metadataProbe.probe(checked);
      final movieId = existing.isNotEmpty
          ? existing.single['movie_id'] as String
          : movieIdForScannedEpisode(
              categoryId: categoryId,
              collectionKey: collectionKey,
              title: grouping.displayTitle ?? titleFromPath(inCategoryPath),
            );
      final timestamp = now();
      changes.add(() => _db.execute('''
        INSERT INTO episodes(
          id, movie_id, media_root_id, title, relative_path, duration_ms,
          video_width, video_height, resolution_label, metadata_probed_at,
          media_modified_at, file_size, is_available, natural_sort_key, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
        ON CONFLICT(media_root_id, relative_path) DO UPDATE SET
          duration_ms = excluded.duration_ms,
          video_width = excluded.video_width,
          video_height = excluded.video_height,
          resolution_label = excluded.resolution_label,
          metadata_probed_at = excluded.metadata_probed_at,
          media_modified_at = excluded.media_modified_at,
          file_size = excluded.file_size,
          is_available = 1,
          natural_sort_key = excluded.natural_sort_key,
          updated_at = excluded.updated_at
      ''', [
            newUuidV4(),
            movieId,
            mediaRoot.id,
            titleFromPath(inCategoryPath),
            relativePath,
            unchanged ? existing.single['duration_ms'] : metadata?.durationMs,
            unchanged ? existing.single['video_width'] : metadata?.width,
            unchanged ? existing.single['video_height'] : metadata?.height,
            unchanged
                ? existing.single['resolution_label']
                : metadata?.resolutionLabel,
            unchanged ? existing.single['metadata_probed_at'] : timestamp,
            modifiedAt,
            fileSize,
            naturalSortKey(inCategoryPath),
            timestamp,
          ]));
      if (changes.length >= 100) flushChanges();
      scannedFiles++;
    }
    flushChanges();
    _markUnavailableEpisodesForSource(categoryId, source, seenPaths: seenPaths);
    _markRootScanned(mediaRoot.id);
    return NasScanResult(
      scannedFiles: scannedFiles,
      availableEpisodes: scannedFiles,
      conflicts: conflicts.toSet().toList(growable: false),
    );
  }

  void _markUnavailableEpisodesForSource(
    String categoryId,
    NasCategoryMediaSource source, {
    Set<String> seenPaths = const {},
  }) {
    final rows = _db.select('''
      SELECT e.id, e.relative_path FROM episodes e
      JOIN movies m ON m.id = e.movie_id
      WHERE m.category_id = ? AND e.media_root_id = ?
    ''', [categoryId, source.mediaRootId]);
    final prefix = '${source.relativePath}/';
    final ids = rows
        .where((row) {
          final path = row['relative_path'] as String;
          return !seenPaths.contains(path) &&
              (path == source.relativePath || path.startsWith(prefix));
        })
        .map((row) => row['id'] as String)
        .toList(growable: false);
    for (var offset = 0; offset < ids.length; offset += 100) {
      transaction(() {
        for (final id in ids.skip(offset).take(100)) {
          _db.execute(
              'UPDATE episodes SET is_available = 0, updated_at = ? WHERE id = ? AND is_available != 0',
              [now(), id]);
        }
      });
    }
  }

  void _markExistingEpisodeAvailable(String episodeId) {
    _db.execute(
        'UPDATE episodes SET is_available = 1, updated_at = ? WHERE id = ? AND is_available != 1',
        [now(), episodeId]);
  }

  String movieIdForScannedEpisode({
    required String categoryId,
    required String? collectionKey,
    required String title,
  }) {
    if (collectionKey != null) {
      final existing = _db.select(
        'SELECT id FROM movies WHERE collection_key = ?',
        [collectionKey],
      );
      if (existing.isNotEmpty) return existing.single['id'] as String;
    }
    final id = newUuidV4();
    final timestamp = now();
    _db.execute('''
      INSERT INTO movies(
        id, title, category_id, entry_type, collection_key, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
    ''', [
      id,
      title,
      categoryId,
      collectionKey == null ? 'single' : 'series',
      collectionKey,
      timestamp,
      timestamp,
    ]);
    return id;
  }

  EpisodeGrouping episodeGrouping(String path) {
    final segments = path.split('/');
    if (segments.length < 2) return const EpisodeGrouping();
    final roots = <({int index, String title})>[];
    for (var index = 0; index < segments.length - 1; index++) {
      final title = collectionTitleFromDirectory(segments[index]);
      if (title != null) roots.add((index: index, title: title));
    }
    if (roots.length > 1) {
      return EpisodeGrouping(
        conflictPath: segments.take(roots.last.index + 1).join('/'),
      );
    }
    if (roots.isEmpty) return const EpisodeGrouping();
    final root = roots.single;
    return EpisodeGrouping(
      rootPath: segments.take(root.index + 1).join('/'),
      displayTitle: root.title,
    );
  }

  NasMediaRoot? _mediaRootForContainerPath(String containerPath) {
    final rows = _db.select('''
      SELECT id, name, container_path, read_only, enabled, created_at,
             updated_at, last_scanned_at, is_online
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
        isOnline: (row['is_online'] as int? ?? 0) == 1,
      );

  void _backfillLegacyCategorySources(String rootId) {
    final categories = _db.select('''
      SELECT id, media_relative_path FROM library_categories
      WHERE media_relative_path IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM category_media_sources source
          WHERE source.category_id = library_categories.id
        )
    ''');
    final timestamp = now();
    for (final category in categories) {
      final path = normalizeRelativePath(
        category['media_relative_path'] as String?,
      );
      if (path == null) continue;
      _db.execute('''
        INSERT INTO category_media_sources(
          id, category_id, media_root_id, relative_path, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?)
      ''', [newUuidV4(), category['id'], rootId, path, timestamp, timestamp]);
    }
  }

  void _markRootScanned(String rootId) {
    _db.execute(
      'UPDATE media_roots SET last_scanned_at = ?, is_online = 1, updated_at = ? WHERE id = ?',
      [now(), now(), rootId],
    );
  }

  void _markRootOffline(String rootId) {
    _db.execute(
      'UPDATE media_roots SET is_online = 0, updated_at = ? WHERE id = ?',
      [now(), rootId],
    );
  }
}
