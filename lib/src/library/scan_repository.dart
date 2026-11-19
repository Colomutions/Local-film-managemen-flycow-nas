import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';
import '../library_models.dart';
import '../media_service.dart';
import '../metadata_probe.dart';
import 'collection_composition_repository.dart';
import 'library_values.dart';
import 'scan_directory_index.dart';

/// Owns source enumeration and scan writes, preserving their existing order.
class NasScanRepository {
  NasScanRepository(
    this._connection, {
    required this.carouselImagesForMovie,
    required this.findCategory,
    required this.findMovieForAdmin,
    required this.mediaSourcesForCategory,
    required this.composeScannedMovies,
    required this.transaction,
  });

  final Database Function() _connection;
  Database get _db => _connection();
  final List<NasCarouselImage> Function(String movieId) carouselImagesForMovie;
  final NasLibraryCategory? Function(String categoryId) findCategory;
  final NasLibraryMovie? Function(String movieId) findMovieForAdmin;
  final List<NasCategoryMediaSource> Function(String categoryId)
      mediaSourcesForCategory;
  final Future<String> Function({
    required List<String> movieIds,
    required String metadataSourceMovieId,
    String? scannedTitle,
  }) composeScannedMovies;
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
    final paths = <String, File>{};
    final directoryCounts = <String, int>{};
    final pathsByWork = <String, List<String>>{};
    final directorySpellings = <String, Set<String>>{};
    for (final file in files) {
      final absolute = file.absolute.path;
      if (!absolute.startsWith(prefix)) continue;
      final path = absolute
          .substring(prefix.length)
          .replaceAll(Platform.pathSeparator, '/');
      paths[path] = file;
      final work = NasScanDirectoryIndex.workDirectory(path);
      if (work != null) {
        directoryCounts.update(work, (count) => count + 1, ifAbsent: () => 1);
        pathsByWork.putIfAbsent(work, () => []).add(path);
        directorySpellings
            .putIfAbsent(work, () => {})
            .add(path.substring(0, path.lastIndexOf('/')));
      }
    }
    final categorySources = mediaSourcesForCategory(categoryId);
    var index =
        NasScanDirectoryIndex(_db, categoryId, categorySources, mediaRoot.id);
    final currentPaths =
        paths.keys.map((path) => '${source.relativePath}/$path').toSet();
    final initialRenames = index.suffixRenameCandidates(currentPaths);
    final fileStats = <String, FileStat>{};
    final conflicts = <String>[];
    final failedAutomaticGroups = <String>{};
    var composedAny = false;
    for (final work in directoryCounts.keys.toList()..sort()) {
      if ((directorySpellings[work]?.length ?? 0) > 1 ||
          episodeGrouping('$work/segment.mp4').isConflict) continue;
      final movieIds = index.automaticSingleMovieIds(work);
      if (movieIds.isEmpty) continue;
      // Do not change ownership before an old suffix rename is known to be
      // unambiguous. Reuse these stats below instead of touching the file twice.
      var renameConflict = false;
      for (final path in pathsByWork[work]!) {
        final fullPath = '${source.relativePath}/$path';
        final candidates = initialRenames[fullPath] ?? const [];
        if (index.episodesByPath.containsKey(fullPath)) {
          // 新路径已有分集时，不能把旧后缀记录当作同一文件一起归并。
          if (candidates.isNotEmpty) {
            renameConflict = true;
            break;
          }
          continue;
        }
        if (candidates.isEmpty) continue;
        if (candidates.length != 1) {
          renameConflict = true;
          break;
        }
        final stat = await paths[path]!.stat();
        fileStats[path] = stat;
        if (candidates.single['file_size'] != stat.size ||
            candidates.single['media_modified_at'] !=
                stat.modified.microsecondsSinceEpoch) {
          renameConflict = true;
          break;
        }
      }
      if (renameConflict) {
        failedAutomaticGroups.add(work);
        continue;
      }
      await beforeFile?.call();
      try {
        await composeScannedMovies(
          movieIds: movieIds,
          metadataSourceMovieId: movieIds.first,
          scannedTitle: episodeGrouping('$work/segment.mp4').displayTitle,
        );
        composedAny = true;
      } on NasCollectionCompositionConflict catch (error) {
        final reason = switch (error.code) {
          'collection_playback_active' => '影片正在播放，暂不自动合并',
          'collection_task_active' => '影片资料任务尚未完成，暂不自动合并',
          'collection_episode_limit' => '分集数量超过自动合并限制',
          _ => '影片资料或分集已变化，暂不自动合并',
        };
        conflicts
            .add('${source.sourceName}/${source.relativePath}/$work（$reason）');
        failedAutomaticGroups.add(work);
      } on FormatException {
        conflicts.add(
            '${source.sourceName}/${source.relativePath}/$work（影片或分集数量不符合自动合并条件）');
        failedAutomaticGroups.add(work);
      }
    }
    if (composedAny) {
      // Composition moves existing episode IDs and metadata as one transaction.
      // Refresh all owner rows before scanning so their former singles can never
      // be recreated, including when another source disk supplied a segment.
      index =
          NasScanDirectoryIndex(_db, categoryId, categorySources, mediaRoot.id);
    }
    final renames = index.suffixRenameCandidates(currentPaths);
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
    final sortedPaths = paths.keys.toList()
      ..sort((a, b) {
        final byName = naturalSortKey(a).compareTo(naturalSortKey(b));
        return byName != 0 ? byName : a.compareTo(b);
      });
    final directoryMovieIds = <String, String>{};
    for (final inCategoryPath in sortedPaths) {
      await beforeFile?.call();
      final grouping = episodeGrouping(inCategoryPath);
      if (grouping.isConflict) {
        conflicts.add(
            '${source.sourceName}/${source.relativePath}/${grouping.conflictPath}');
        continue;
      }
      final relativePath = '${source.relativePath}/$inCategoryPath';
      seenPaths.add(relativePath);
      final checked = NasMediaFile(paths[inCategoryPath]!, relativePath);
      final stat = fileStats[inCategoryPath] ?? await checked.file.stat();
      var existing = index.episodesByPath[relativePath];
      final work = grouping.rootPath;
      final spellingConflict = (directorySpellings[work]?.length ?? 0) > 1;
      final renameCandidates = renames[relativePath] ?? const [];
      if (existing != null && renameCandidates.isNotEmpty) {
        conflicts
            .add('${source.sourceName}/$relativePath（去后缀目标已对应其他分集，保留原有索引）');
        if (work != null) failedAutomaticGroups.add(work);
      }
      if (existing == null && renameCandidates.isNotEmpty) {
        if (spellingConflict ||
            renameCandidates.length != 1 ||
            renameCandidates.single['file_size'] != stat.size ||
            renameCandidates.single['media_modified_at'] !=
                stat.modified.microsecondsSinceEpoch) {
          conflicts.add('${source.sourceName}/$relativePath（去后缀路径匹配不唯一或文件已变更）');
          continue;
        }
        existing = renameCandidates.single;
        final episodeId = existing['id'] as String;
        changes.add(() => _db.execute('''UPDATE episodes
          SET relative_path=?, natural_sort_key=?, updated_at=? WHERE id=?''',
            [relativePath, naturalSortKey(inCategoryPath), now(), episodeId]));
      }
      final owners =
          work == null ? <String>{} : (index.owners[work] ?? <String>{});
      final ambiguous = work != null && (spellingConflict || owners.length > 1);
      if (ambiguous) {
        if (!failedAutomaticGroups.contains(work)) {
          conflicts.add(
              '${source.sourceName}/${source.relativePath}/$work（目录对应多个条目或新旧目录同时存在）');
        }
        // Existing manual splits are respected. Only an unassigned new segment
        // needs an explicit ownership decision before it can enter the index.
        if (existing == null) continue;
      }
      String movieId;
      if (existing != null) {
        movieId = existing['movie_id'] as String;
      } else if (owners.length == 1) {
        movieId = owners.single;
      } else if (work != null && directoryMovieIds.containsKey(work)) {
        movieId = directoryMovieIds[work]!;
      } else {
        movieId = newUuidV4();
        final timestamp = now();
        final isSeries = work != null &&
            ((directoryCounts[work] ?? 0) > 1 ||
                collectionTitleFromDirectory(
                        inCategoryPath.split('/').reversed.skip(1).first) !=
                    null);
        // Reserve a directory owner immediately; the writes remain batched.
        if (work != null) {
          directoryMovieIds[work] = movieId;
          index.owners.putIfAbsent(work, () => {}).add(movieId);
        }
        final initialTitle = isSeries
            ? grouping.displayTitle ?? titleFromPath(inCategoryPath)
            : titleFromPath(inCategoryPath);
        changes.add(() => _db.execute('''INSERT INTO movies
          (id,title,scanned_title,category_id,entry_type,created_at,updated_at)
          VALUES (?,?,?,?,?,?,?)''', [
              movieId,
              initialTitle,
              initialTitle,
              categoryId,
              isSeries ? 'series' : 'single',
              timestamp,
              timestamp
            ]));
      }
      final fileSize = stat.size;
      final modifiedAt = stat.modified.microsecondsSinceEpoch;
      final unchanged = existing != null &&
          existing['file_size'] == fileSize &&
          existing['media_modified_at'] == modifiedAt &&
          existing['metadata_probed_at'] != null;
      if (unchanged) {
        if (existing['natural_sort_key'] != naturalSortKey(inCategoryPath)) {
          final id = existing['id'] as String;
          changes.add(() => _db.execute(
              'UPDATE episodes SET natural_sort_key=? WHERE id=?',
              [naturalSortKey(inCategoryPath), id]));
        }
        if (existing['is_available'] != 1) {
          final id = existing['id'] as String;
          changes.add(() => _markExistingEpisodeAvailable(id));
        }
        scannedFiles++;
        if (changes.length >= 100) flushChanges();
        continue;
      }
      final metadata = await metadataProbe.probe(checked);
      final timestamp = now();
      changes.add(() => _db.execute('''
        INSERT INTO episodes(
          id, movie_id, media_root_id, title, relative_path, duration_ms,
          video_width, video_height, resolution_label, metadata_probed_at,
          media_modified_at, file_size, is_available, natural_sort_key, manual_order, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?,
          CASE WHEN (SELECT episode_sort_mode FROM movies WHERE id=?)='manual'
            THEN (SELECT COALESCE(MAX(manual_order),-1)+1 FROM episodes WHERE movie_id=?)
            ELSE NULL END, ?)
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
            metadata?.durationMs,
            metadata?.width,
            metadata?.height,
            metadata?.resolutionLabel,
            timestamp,
            modifiedAt,
            fileSize,
            naturalSortKey(inCategoryPath),
            movieId,
            movieId,
            timestamp,
          ]));
      if (changes.length >= 100) flushChanges();
      scannedFiles++;
    }
    flushChanges();
    // Upgrade in place, including when a second disk supplies the new segment.
    _db.execute('''UPDATE movies SET entry_type='series',updated_at=?
      WHERE category_id=? AND lifecycle_state='active' AND entry_type='single'
        AND (SELECT COUNT(*) FROM episodes WHERE movie_id=movies.id)>1''',
        [now(), categoryId]);
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
    String? storedCollectionKey = collectionKey;
    if (collectionKey != null) {
      final existing = _db.select(
        'SELECT id,lifecycle_state FROM movies WHERE collection_key = ?',
        [collectionKey],
      );
      if (existing.isNotEmpty) {
        if (existing.single['lifecycle_state'] == 'active') {
          return existing.single['id'] as String;
        }
        // Keep audit aliases on hidden sources without reviving them or
        // violating the legacy unique key when the directory is regrouped.
        storedCollectionKey = null;
      }
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
      storedCollectionKey,
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
    final directory = segments.take(segments.length - 1).join('/');
    return EpisodeGrouping(
      rootPath: canonicalWorkDirectory(directory),
      displayTitle:
          collectionTitleFromDirectory(segments[segments.length - 2]) ??
              segments[segments.length - 2],
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
