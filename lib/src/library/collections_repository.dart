import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';
import '../library_models.dart';
import 'library_values.dart';

/// Owns series grouping, splitting and legacy collection migration.
class NasCollectionsRepository {
  NasCollectionsRepository(
    this._connection, {
    required this.episodeGrouping,
    required this.movieIdForScannedEpisode,
    required this.carouselImagesForMovie,
    required this.findCategory,
    required this.findMovieForAdmin,
    required this.listCategories,
    required this.dataDir,
  });

  final String dataDir;
  final Database Function() _connection;
  Database get _db => _connection();
  final EpisodeGrouping Function(String path) episodeGrouping;
  final String Function({
    required String categoryId,
    required String? collectionKey,
    required String title,
  }) movieIdForScannedEpisode;
  final List<NasCarouselImage> Function(String movieId) carouselImagesForMovie;
  final NasLibraryCategory? Function(String categoryId) findCategory;
  final NasLibraryMovie? Function(String movieId) findMovieForAdmin;
  final List<NasLibraryCategory> Function() listCategories;

  NasLibraryMovie createEmptySeries({
    required String title,
    required String categoryId,
  }) {
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty || findCategory(categoryId) == null) {
      throw ArgumentError('影集资料无效');
    }
    final timestamp = now();
    final id = newUuidV4();
    _db.execute('''
      INSERT INTO movies(id, title, category_id, entry_type, created_at, updated_at)
      VALUES (?, ?, ?, 'series', ?, ?)
    ''', [id, normalizedTitle, categoryId, timestamp, timestamp]);
    return findMovieForAdmin(id)!;
  }

  bool mergeEpisodesIntoSeries({
    required String targetMovieId,
    required List<String> episodeIds,
    required String metadataSourceMovieId,
  }) {
    if (episodeIds.isEmpty ||
        episodeIds.length > 500 ||
        episodeIds.toSet().length != episodeIds.length) {
      return false;
    }
    final target = findMovieForAdmin(targetMovieId);
    if (target == null ||
        target.entryType != 'series' ||
        _db.select(
          "SELECT 1 FROM movies WHERE id = ? AND lifecycle_state = 'active'",
          [targetMovieId],
        ).isEmpty) {
      return false;
    }
    final placeholders = List.filled(episodeIds.length, '?').join(', ');
    final rows = _db.select('''
      SELECT e.id, e.movie_id, m.category_id
      FROM episodes e JOIN movies m ON m.id = e.movie_id
      WHERE e.id IN ($placeholders)
    ''', episodeIds);
    if (rows.length != episodeIds.length) return false;
    final sourceMovieIds = rows.map((row) => row['movie_id'] as String).toSet();
    final sourceMoviePlaceholders =
        List.filled(sourceMovieIds.length, '?').join(', ');
    if (metadataSourceMovieId != targetMovieId &&
        !sourceMovieIds.contains(metadataSourceMovieId)) {
      return false;
    }
    final targetCategory = _db.select(
      'SELECT category_id FROM movies WHERE id = ?',
      [targetMovieId],
    ).single['category_id'] as String?;
    // 分类是影集的逻辑归属。任何跨分类归并都必须走未来单独设计的迁移流程。
    if (targetCategory == null ||
        rows.any((row) => row['category_id'] != targetCategory)) {
      return false;
    }
    _db.execute('BEGIN IMMEDIATE');
    try {
      if (metadataSourceMovieId != targetMovieId) {
        _copyMovieMetadataToSeries(
          fromMovieId: metadataSourceMovieId,
          targetMovieId: targetMovieId,
        );
      }
      final movedPlaybackCount = _db.select('''
        SELECT COUNT(*) AS count FROM playback_history
        WHERE movie_id != ? AND episode_id IN ($placeholders)
      ''', [targetMovieId, ...episodeIds]).single['count'] as int;
      _db.execute('''
        UPDATE movies
        SET play_count = MAX(0, play_count - (
          SELECT COUNT(*) FROM playback_history history
          WHERE history.movie_id = movies.id
            AND history.episode_id IN ($placeholders)
        ))
        WHERE id IN ($sourceMoviePlaceholders) AND id != ?
      ''', [
        ...episodeIds,
        ...sourceMovieIds,
        targetMovieId,
      ]);
      _db.execute('''
        UPDATE movies SET play_count = play_count + ? WHERE id = ?
      ''', [movedPlaybackCount, targetMovieId]);
      _db.execute('''
        UPDATE playback_history SET movie_id = ?
        WHERE episode_id IN ($placeholders) AND movie_id != ?
      ''', [targetMovieId, ...episodeIds, targetMovieId]);
      _db.execute('''
        UPDATE episodes SET movie_id = ? WHERE id IN ($placeholders)
      ''', [targetMovieId, ...episodeIds]);
      _db.execute('''
        UPDATE episode_playback_progress SET movie_id = ?
        WHERE episode_id IN ($placeholders)
      ''', [targetMovieId, ...episodeIds]);
      // 保留旧条目与全部关系以便审计，却从普通查询和统计中明确排除。
      _db.execute('''
        UPDATE movies
        SET lifecycle_state = 'merged', merged_into_movie_id = ?, merged_at = ?,
            updated_at = ?
        WHERE id IN ($sourceMoviePlaceholders) AND id != ?
          AND NOT EXISTS (SELECT 1 FROM episodes WHERE episodes.movie_id = movies.id)
      ''', [
        targetMovieId,
        now(),
        now(),
        ...sourceMovieIds,
        targetMovieId,
      ]);
      _db.execute(
        "UPDATE movies SET entry_type = 'series', updated_at = ? WHERE id = ?",
        [now(), targetMovieId],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return true;
  }

  List<NasLibraryMovie>? splitEpisodesIntoSingles({
    required String movieId,
    required List<String> episodeIds,
  }) {
    if (episodeIds.isEmpty ||
        episodeIds.length > 500 ||
        episodeIds.toSet().length != episodeIds.length) {
      return null;
    }
    final source = findMovieForAdmin(movieId);
    if (source == null || source.entryType != 'series') return null;
    final placeholders = List.filled(episodeIds.length, '?').join(', ');
    final episodes = _db.select('''
      SELECT id, title FROM episodes WHERE movie_id = ? AND id IN ($placeholders)
    ''', [movieId, ...episodeIds]);
    if (episodes.length != episodeIds.length) return null;
    final sourceEpisodeCount = _db.select(
      'SELECT COUNT(*) AS count FROM episodes WHERE movie_id = ?',
      [movieId],
    ).single['count'] as int;
    final isCompleteSplit = sourceEpisodeCount == episodeIds.length;
    final created = <NasLibraryMovie>[];
    final sourceImages = carouselImagesForMovie(movieId);
    _db.execute('BEGIN IMMEDIATE');
    try {
      // 必须在迁移历史关联前扣除原影集的计数，避免被已迁走的记录误算为零。
      _db.execute('''
        UPDATE movies
        SET play_count = MAX(0, play_count - (
          SELECT COUNT(*) FROM playback_history history
          WHERE history.movie_id = movies.id AND history.episode_id IN ($placeholders)
        ))
        WHERE id = ?
      ''', [...episodeIds, movieId]);
      for (final episode in episodes) {
        final id = newUuidV4();
        final timestamp = now();
        _db.execute('''
          INSERT INTO movies(
            id, title, original_title, catalog_number, publisher_id, series_id,
            summary, category_id, poster_file_name, entry_type, play_count,
            created_at, updated_at
          ) SELECT ?, ?, original_title, catalog_number, publisher_id, series_id,
                   summary, category_id, poster_file_name, 'single',
                   (SELECT COUNT(*) FROM playback_history WHERE movie_id = ? AND episode_id = ?),
                   ?, ?
          FROM movies WHERE id = ?
        ''', [
          id,
          episode['title'],
          movieId,
          episode['id'],
          timestamp,
          timestamp,
          movieId,
        ]);
        _db.execute('''
          INSERT INTO movie_actor_links(movie_id, actor_id)
          SELECT ?, actor_id FROM movie_actor_links WHERE movie_id = ?
        ''', [id, movieId]);
        _db.execute('''
          INSERT INTO movie_tag_links(movie_id, tag_id)
          SELECT ?, tag_id FROM movie_tag_links WHERE movie_id = ?
        ''', [id, movieId]);
        _db.execute('UPDATE episodes SET movie_id = ? WHERE id = ?',
            [id, episode['id']]);
        _db.execute(
          'UPDATE episode_playback_progress SET movie_id = ? WHERE episode_id = ?',
          [id, episode['id']],
        );
        _db.execute(
          'UPDATE playback_history SET movie_id = ? WHERE episode_id = ?',
          [id, episode['id']],
        );
        // 部分拆分时原影集仍可访问，完整拆分时首个新条目接管原记录；
        // 其余新条目都得到独立图片文件和记录，绝不共享或删除原资产。
        if (!isCompleteSplit || created.isNotEmpty) {
          _copyCarouselImages(sourceImages, id);
        }
        created.add(findMovieForAdmin(id)!);
      }
      if (isCompleteSplit && created.isNotEmpty) {
        _db.execute(
          'UPDATE movie_carousel_images SET movie_id = ? WHERE movie_id = ?',
          [created.first.id, movieId],
        );
      }
      // 完整拆分后，原影集已经被拆出的独立条目替代。保留原行供审计，
      // 但不能再让没有分集的来源条目参与任何普通列表或资料统计。
      _db.execute('''
        UPDATE movies
        SET entry_type = 'single', collection_key = NULL,
            lifecycle_state = CASE WHEN ? THEN 'merged' ELSE lifecycle_state END,
            merged_into_movie_id = CASE WHEN ? THEN NULL ELSE merged_into_movie_id END,
            merged_at = CASE WHEN ? THEN ? ELSE merged_at END,
            updated_at = ?
        WHERE id = ? AND NOT EXISTS (SELECT 1 FROM episodes WHERE movie_id = ?)
      ''', [
        isCompleteSplit ? 1 : 0,
        isCompleteSplit ? 1 : 0,
        isCompleteSplit ? 1 : 0,
        now(),
        now(),
        movieId,
        movieId,
      ]);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return created;
  }

  List<NasCollectionMigrationCandidate> collectionMigrationPreview() {
    final groups = <String, _LegacyCollectionGroup>{};
    for (final category in listCategories()) {
      for (final source in category.mediaSources) {
        final rows = _db.select('''
          SELECT e.id, e.movie_id, e.relative_path, m.entry_type, m.collection_key
          FROM episodes e JOIN movies m ON m.id = e.movie_id
          WHERE e.media_root_id = ? AND m.category_id = ?
            AND m.lifecycle_state = 'active'
        ''', [source.mediaRootId, category.id]);
        final prefix = '${source.relativePath}/';
        for (final row in rows) {
          final path = row['relative_path'] as String;
          if (!path.startsWith(prefix) ||
              row['entry_type'] != 'single' ||
              row['collection_key'] != null) {
            continue;
          }
          final grouping = episodeGrouping(path.substring(prefix.length));
          if (grouping.isConflict || grouping.rootPath == null) continue;
          final key = '${category.id}:${grouping.rootPath}';
          final group = groups.putIfAbsent(
            key,
            () => _LegacyCollectionGroup(
              categoryId: category.id,
              title: grouping.displayTitle!,
            ),
          );
          group.episodeIds.add(row['id'] as String);
          group.sourceMovieIds.add(row['movie_id'] as String);
        }
      }
    }
    return groups.entries
        .map(
          (entry) => NasCollectionMigrationCandidate(
            key: entry.key,
            categoryId: entry.value.categoryId,
            title: entry.value.title,
            episodeIds: entry.value.episodeIds.toList(growable: false),
            sourceMovieIds: entry.value.sourceMovieIds.toList(growable: false),
            requiresMetadataChoice: entry.value.sourceMovieIds.length > 1,
          ),
        )
        .toList(growable: false);
  }

  NasLibraryMovie? applyCollectionMigration({
    required String key,
    required String metadataSourceMovieId,
  }) {
    NasCollectionMigrationCandidate? candidate;
    for (final item in collectionMigrationPreview()) {
      if (item.key == key) {
        candidate = item;
        break;
      }
    }
    if (candidate == null ||
        !candidate.sourceMovieIds.contains(metadataSourceMovieId)) {
      return null;
    }
    final id = movieIdForScannedEpisode(
      categoryId: candidate.categoryId,
      collectionKey: candidate.key,
      title: candidate.title,
    );
    if (!mergeEpisodesIntoSeries(
      targetMovieId: id,
      episodeIds: candidate.episodeIds,
      metadataSourceMovieId: metadataSourceMovieId,
    )) {
      return null;
    }
    return findMovieForAdmin(id);
  }

  void _copyMovieMetadataToSeries({
    required String fromMovieId,
    required String targetMovieId,
  }) {
    _db.execute('''
      UPDATE movies SET
        title = (SELECT title FROM movies WHERE id = ?),
        original_title = (SELECT original_title FROM movies WHERE id = ?),
        catalog_number = (SELECT catalog_number FROM movies WHERE id = ?),
        publisher_id = (SELECT publisher_id FROM movies WHERE id = ?),
        series_id = (SELECT series_id FROM movies WHERE id = ?),
        summary = (SELECT summary FROM movies WHERE id = ?),
        poster_file_name = (SELECT poster_file_name FROM movies WHERE id = ?),
        updated_at = ?
      WHERE id = ?
    ''', [
      fromMovieId,
      fromMovieId,
      fromMovieId,
      fromMovieId,
      fromMovieId,
      fromMovieId,
      fromMovieId,
      now(),
      targetMovieId,
    ]);
    _db.execute(
        'DELETE FROM movie_actor_links WHERE movie_id = ?', [targetMovieId]);
    _db.execute('''
      INSERT INTO movie_actor_links(movie_id, actor_id)
      SELECT ?, actor_id FROM movie_actor_links WHERE movie_id = ?
    ''', [targetMovieId, fromMovieId]);
    _db.execute(
        'DELETE FROM movie_tag_links WHERE movie_id = ?', [targetMovieId]);
    _db.execute('''
      INSERT INTO movie_tag_links(movie_id, tag_id)
      SELECT ?, tag_id FROM movie_tag_links WHERE movie_id = ?
    ''', [targetMovieId, fromMovieId]);
    _db.execute('''
      UPDATE movie_carousel_images SET movie_id = ? WHERE movie_id = ?
    ''', [targetMovieId, fromMovieId]);
    _db.execute('DELETE FROM movie_metadata_field_sources WHERE movie_id = ?',
        [targetMovieId]);
    _db.execute('''
      INSERT INTO movie_metadata_field_sources(
        movie_id, field_key, source_kind, import_record_id,
        source_content_hash, updated_at
      ) SELECT ?, field_key, source_kind, import_record_id,
               source_content_hash, updated_at
        FROM movie_metadata_field_sources WHERE movie_id = ?
    ''', [targetMovieId, fromMovieId]);
  }

  /// 为拆出的影视条目复制截图文件和记录。
  ///
  /// 部分拆分保留源记录；完整拆分会由首个新条目接管源记录，其余条目各自复制。
  /// 复制失败会回滚数据库变更，源图片文件绝不删除。
  void _copyCarouselImages(
      List<NasCarouselImage> images, String targetMovieId) {
    for (final image in images) {
      final extensionIndex = image.fileName.lastIndexOf('.');
      if (extensionIndex <= 0) {
        throw StateError('截图文件名无效，无法安全拆分');
      }
      final extension = image.fileName.substring(extensionIndex);
      final copiedFileName = '$targetMovieId-${newUuidV4()}$extension';
      final sourceFile = File(
        '$dataDir${Platform.pathSeparator}artwork${Platform.pathSeparator}carousel${Platform.pathSeparator}${image.fileName}',
      );
      if (!sourceFile.existsSync()) {
        throw StateError('截图资产缺失，无法安全拆分');
      }
      final destinationFile = File(
        '$dataDir${Platform.pathSeparator}artwork${Platform.pathSeparator}carousel${Platform.pathSeparator}$copiedFileName',
      );
      sourceFile.copySync(destinationFile.path);
      _db.execute(
        'INSERT INTO movie_carousel_images(id, movie_id, file_name, created_at) VALUES (?, ?, ?, ?)',
        [newUuidV4(), targetMovieId, copiedFileName, now()],
      );
    }
  }
}

class _LegacyCollectionGroup {
  _LegacyCollectionGroup({required this.categoryId, required this.title});

  final String categoryId;
  final String title;
  final Set<String> episodeIds = <String>{};
  final Set<String> sourceMovieIds = <String>{};
}
