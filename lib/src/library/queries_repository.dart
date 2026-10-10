import 'package:sqlite3/sqlite3.dart';

import '../library_models.dart';
import '../movie_actor.dart';
import 'library_values.dart';

/// Reads movie and episode views without enumerating media files.
class NasQueriesRepository {
  NasQueriesRepository(
    this._connection, {
    required this.actorsForMovie,
    required this.findCategory,
  });

  final Database Function() _connection;
  Database get _db => _connection();
  final List<NasActor> Function(String movieId) actorsForMovie;
  final NasLibraryCategory? Function(String categoryId) findCategory;

  List<NasLibraryMovie> listMovies({String query = ''}) {
    final queryLike = '%${query.trim()}%';
    final normalizedCatalogQuery = normalizeCatalogNumber(query);
    final catalogQueryLike = '%$normalizedCatalogQuery%';
    final rows = _db.select('''
      SELECT m.id, m.title, m.original_title, m.catalog_number,
             m.publisher_id, p.display_name AS publisher_name,
             m.series_id, s.display_name AS series_name,
             m.summary, m.actors_json, m.poster_file_name, m.play_count,
             m.is_favorite,
             m.category_id, c.name AS category_name,
             m.updated_at, m.entry_type, COUNT(e.id) AS episode_count,
             SUM(CASE WHEN e.duration_ms IS NULL THEN 0 ELSE e.duration_ms END) AS duration_ms
      FROM movies m
      LEFT JOIN publishers p ON p.id = m.publisher_id
      LEFT JOIN series s ON s.id = m.series_id
      LEFT JOIN library_categories c ON c.id = m.category_id
      LEFT JOIN episodes e ON e.movie_id = m.id
       WHERE m.lifecycle_state = 'active'
         AND (m.entry_type = 'series' OR e.id IS NOT NULL) AND (
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
              isFavorite: (row['is_favorite'] as int) == 1,
              episodeCount: row['episode_count'] as int,
              durationMs: (row['duration_ms'] as int?) == 0
                  ? null
                  : row['duration_ms'] as int?,
              entryType: row['entry_type'] as String,
              updatedAt: row['updated_at'] as String,
              categoryId: row['category_id'] as String?,
              categoryName: row['category_name'] as String?,
            )))
        .toList(growable: false);
  }

  /// 影集目标选择专用的服务端分页查询，绝不借用客户端当前影片墙。
  NasMovieSearchPage searchSeries({
    String query = '',
    required String categoryId,
    int page = 1,
    int pageSize = 20,
  }) {
    if (page < 1 ||
        pageSize < 1 ||
        pageSize > 100 ||
        query.length > 120 ||
        findCategory(categoryId) == null) {
      throw ArgumentError('影集查询参数无效');
    }
    final like = '%${query.trim()}%';
    final total = _db.select('''
      SELECT COUNT(*) AS count FROM movies m
      WHERE m.lifecycle_state = 'active' AND m.entry_type = 'series'
        AND m.category_id = ?
        AND (? = '%%' OR lower(m.title) LIKE lower(?)
          OR lower(COALESCE(m.original_title, '')) LIKE lower(?))
    ''', [categoryId, like, like, like]).single['count'] as int;
    final offset = (page - 1) * pageSize;
    final rows = _db.select('''
      SELECT m.id, m.title, m.original_title, m.catalog_number,
             m.publisher_id, publisher.display_name AS publisher_name,
             m.series_id, series.display_name AS series_name,
             m.summary, m.poster_file_name, m.play_count, m.is_favorite,
             m.updated_at,
             m.entry_type, m.category_id, category.name AS category_name,
             COUNT(e.id) AS episode_count, SUM(COALESCE(e.duration_ms, 0)) AS duration_ms,
             MAX(e.video_width) AS video_width, MAX(e.video_height) AS video_height,
             CASE WHEN COUNT(DISTINCT NULLIF(e.resolution_label, '')) > 1
                  THEN '多种分辨率' ELSE MAX(e.resolution_label) END AS resolution_label
      FROM movies m
      LEFT JOIN episodes e ON e.movie_id = m.id
      LEFT JOIN publishers publisher ON publisher.id = m.publisher_id
      LEFT JOIN series ON series.id = m.series_id
      LEFT JOIN library_categories category ON category.id = m.category_id
      WHERE m.lifecycle_state = 'active' AND m.entry_type = 'series'
        AND m.category_id = ?
        AND (? = '%%' OR lower(m.title) LIKE lower(?)
          OR lower(COALESCE(m.original_title, '')) LIKE lower(?))
      GROUP BY m.id
      ORDER BY m.title COLLATE NOCASE, m.id
      LIMIT ? OFFSET ?
    ''', [categoryId, like, like, like, pageSize, offset]);
    final items = rows.map(_mapSearchMovie).toList(growable: false);
    return NasMovieSearchPage(
      items: items,
      number: page,
      size: pageSize,
      total: total,
      hasMore: offset + items.length < total,
    );
  }

  /// 在 SQLite 中完成搜索、三组标签条件、排序和分页，绝不回传全量影片。
  NasMovieSearchPage searchMovies(NasMovieSearchFilter filter) {
    if (filter.page < 1 ||
        filter.pageSize < 1 ||
        filter.pageSize > 100 ||
        !const {
          'relevance',
          'createdAt',
          'title',
          'updatedAt',
          'durationMs',
          'recent'
        }.contains(filter.sort) ||
        !filter.watchStates.every(
          const {'unwatched', 'continue'}.contains,
        ) ||
        !const {'asc', 'desc'}.contains(filter.order)) {
      throw ArgumentError('影片搜索参数无效');
    }
    final conditions = filter.tagConditions;
    final requestedValues = <Object?>[];
    final requestedSql = conditions.isEmpty
        ? '''SELECT CAST(NULL AS TEXT), CAST(NULL AS TEXT), CAST(NULL AS INTEGER)
            WHERE 0'''
        : 'VALUES ${conditions.map((condition) {
            requestedValues.addAll([
              condition.group,
              condition.tagId,
              condition.includeDescendants ? 1 : 0,
            ]);
            return '(?, ?, ?)';
          }).join(', ')}';
    final query = filter.query.trim();
    final queryLike = '%$query%';
    final queryPrefix = '$query%';
    final normalizedCatalog = normalizeCatalogNumber(query);
    final catalogLike = '%$normalizedCatalog%';
    final catalogPrefix = '$normalizedCatalog%';
    // 权重只影响搜索结果的服务端排序；任意筛选条件仍在同一条 SQL 内完成。
    final relevanceSql = '''CASE WHEN terms.query = '' THEN 0 ELSE
      CASE
        WHEN lower(m.title) = lower(terms.query) THEN 1000
        WHEN lower(m.title) LIKE lower(terms.query_prefix) THEN 900
        WHEN lower(m.title) LIKE lower(terms.query_like) THEN 800
        ELSE 0
      END +
      CASE
        WHEN lower(COALESCE(m.original_title, '')) = lower(terms.query) THEN 700
        WHEN lower(COALESCE(m.original_title, '')) LIKE lower(terms.query_prefix) THEN 650
        WHEN lower(COALESCE(m.original_title, '')) LIKE lower(terms.query_like) THEN 600
        ELSE 0
      END +
      CASE
        WHEN terms.catalog != '' AND lower(REPLACE(REPLACE(REPLACE(
          COALESCE(m.catalog_number, ''), '-', ''), '_', ''), ' ', '')) = lower(terms.catalog) THEN 550
        WHEN terms.catalog != '' AND lower(REPLACE(REPLACE(REPLACE(
          COALESCE(m.catalog_number, ''), '-', ''), '_', ''), ' ', '')) LIKE lower(terms.catalog_prefix) THEN 520
        WHEN terms.catalog != '' AND lower(REPLACE(REPLACE(REPLACE(
          COALESCE(m.catalog_number, ''), '-', ''), '_', ''), ' ', '')) LIKE lower(terms.catalog_like) THEN 480
        ELSE 0
      END +
      CASE
        WHEN EXISTS (
          SELECT 1 FROM movie_actor_links mal JOIN actors a ON a.id = mal.actor_id
          WHERE mal.movie_id = m.id AND (
            lower(COALESCE(a.stage_name, '')) = lower(terms.query)
            OR lower(COALESCE(a.original_name, '')) = lower(terms.query)
            OR lower(COALESCE(a.translated_name, '')) = lower(terms.query)
          )
        ) THEN 400
        WHEN EXISTS (
          SELECT 1 FROM movie_actor_links mal JOIN actors a ON a.id = mal.actor_id
          WHERE mal.movie_id = m.id AND (
            lower(COALESCE(a.stage_name, '')) LIKE lower(terms.query_prefix)
            OR lower(COALESCE(a.original_name, '')) LIKE lower(terms.query_prefix)
            OR lower(COALESCE(a.translated_name, '')) LIKE lower(terms.query_prefix)
          )
        ) THEN 360
        WHEN EXISTS (
          SELECT 1 FROM movie_actor_links mal JOIN actors a ON a.id = mal.actor_id
          WHERE mal.movie_id = m.id AND (
            lower(COALESCE(a.stage_name, '')) LIKE lower(terms.query_like)
            OR lower(COALESCE(a.original_name, '')) LIKE lower(terms.query_like)
            OR lower(COALESCE(a.translated_name, '')) LIKE lower(terms.query_like)
          )
        ) THEN 320
        ELSE 0
      END +
      CASE
        WHEN lower(COALESCE(series.display_name, '')) = lower(terms.query)
          OR lower(COALESCE(series.original_name, '')) = lower(terms.query)
          OR lower(COALESCE(series.translated_name, '')) = lower(terms.query)
          OR lower(COALESCE(publisher.display_name, '')) = lower(terms.query)
          OR lower(COALESCE(publisher.original_name, '')) = lower(terms.query) THEN 300
        WHEN lower(COALESCE(series.display_name, '')) LIKE lower(terms.query_prefix)
          OR lower(COALESCE(series.original_name, '')) LIKE lower(terms.query_prefix)
          OR lower(COALESCE(series.translated_name, '')) LIKE lower(terms.query_prefix)
          OR lower(COALESCE(publisher.display_name, '')) LIKE lower(terms.query_prefix)
          OR lower(COALESCE(publisher.original_name, '')) LIKE lower(terms.query_prefix) THEN 280
        WHEN lower(COALESCE(series.display_name, '')) LIKE lower(terms.query_like)
          OR lower(COALESCE(series.original_name, '')) LIKE lower(terms.query_like)
          OR lower(COALESCE(series.translated_name, '')) LIKE lower(terms.query_like)
          OR lower(COALESCE(publisher.display_name, '')) LIKE lower(terms.query_like)
          OR lower(COALESCE(publisher.original_name, '')) LIKE lower(terms.query_like) THEN 260
        ELSE 0
      END +
      CASE
        WHEN lower(COALESCE(category.name, '')) = lower(terms.query) THEN 240
        WHEN lower(COALESCE(category.name, '')) LIKE lower(terms.query_prefix) THEN 220
        WHEN lower(COALESCE(category.name, '')) LIKE lower(terms.query_like) THEN 200
        ELSE 0
      END +
      CASE
        WHEN EXISTS (
          SELECT 1 FROM movie_tag_links mtl JOIN tags t ON t.id = mtl.tag_id
          WHERE mtl.movie_id = m.id AND t.archived_at IS NULL
            AND lower(t.name) = lower(terms.query)
        ) THEN 280
        WHEN EXISTS (
          SELECT 1 FROM movie_tag_links mtl JOIN tags t ON t.id = mtl.tag_id
          WHERE mtl.movie_id = m.id AND t.archived_at IS NULL
            AND lower(t.name) LIKE lower(terms.query_prefix)
        ) THEN 260
        WHEN EXISTS (
          SELECT 1 FROM movie_tag_links mtl JOIN tags t ON t.id = mtl.tag_id
          WHERE mtl.movie_id = m.id AND t.archived_at IS NULL
            AND lower(t.name) LIKE lower(terms.query_like)
        ) THEN 240
        ELSE 0
      END +
      CASE
        WHEN lower(COALESCE(m.summary, '')) LIKE lower(terms.query_like) THEN 100
        ELSE 0
      END
    END AS relevance_score''';
    final clauses = <String>[
      "m.lifecycle_state = 'active'",
      // 已离线来源上的影视条目仍必须可见；可播放性由分集接口单独返回。
      "(m.entry_type = 'series' OR EXISTS (SELECT 1 FROM episodes visible_episode WHERE visible_episode.movie_id = m.id))",
      '''(
        terms.query = '' OR lower(m.title) LIKE lower(terms.query_like)
        OR lower(COALESCE(m.original_title, '')) LIKE lower(terms.query_like)
        OR lower(COALESCE(m.summary, '')) LIKE lower(terms.query_like)
        OR lower(COALESCE(series.display_name, '')) LIKE lower(terms.query_like)
        OR lower(COALESCE(series.original_name, '')) LIKE lower(terms.query_like)
        OR lower(COALESCE(series.translated_name, '')) LIKE lower(terms.query_like)
        OR lower(COALESCE(publisher.display_name, '')) LIKE lower(terms.query_like)
        OR lower(COALESCE(publisher.original_name, '')) LIKE lower(terms.query_like)
        OR lower(COALESCE(category.name, '')) LIKE lower(terms.query_like)
        OR (terms.catalog != '' AND lower(REPLACE(REPLACE(REPLACE(
          COALESCE(m.catalog_number, ''), '-', ''), '_', ''), ' ', '')) LIKE lower(terms.catalog_like))
        OR EXISTS (
          SELECT 1 FROM movie_actor_links mal JOIN actors a ON a.id = mal.actor_id
          WHERE mal.movie_id = m.id AND (
            lower(COALESCE(a.stage_name, '')) LIKE lower(terms.query_like)
            OR lower(COALESCE(a.original_name, '')) LIKE lower(terms.query_like)
            OR lower(COALESCE(a.translated_name, '')) LIKE lower(terms.query_like)
          )
        )
        OR EXISTS (
          SELECT 1 FROM movie_tag_links mtl JOIN tags t ON t.id = mtl.tag_id
          WHERE mtl.movie_id = m.id AND t.archived_at IS NULL
            AND lower(t.name) LIKE lower(terms.query_like)
        )
        OR EXISTS (
          SELECT 1 FROM episodes named_episode
          WHERE named_episode.movie_id = m.id
            AND lower(named_episode.title) LIKE lower(terms.query_like)
        )
      )''',
      '''(
        NOT EXISTS (SELECT 1 FROM requested WHERE group_name = 'all')
        OR NOT EXISTS (
          SELECT 1 FROM requested r
          WHERE r.group_name = 'all' AND NOT EXISTS (
            SELECT 1 FROM tag_scope scope
            JOIN movie_tag_links links ON links.tag_id = scope.tag_id
            WHERE scope.group_name = r.group_name
              AND scope.requested_tag_id = r.requested_tag_id
              AND links.movie_id = m.id
          )
        )
      )''',
      '''(
        NOT EXISTS (SELECT 1 FROM requested WHERE group_name = 'any')
        OR EXISTS (
          SELECT 1 FROM tag_scope scope
          JOIN movie_tag_links links ON links.tag_id = scope.tag_id
          WHERE scope.group_name = 'any' AND links.movie_id = m.id
        )
      )''',
      '''NOT EXISTS (
        SELECT 1 FROM tag_scope scope
        JOIN movie_tag_links links ON links.tag_id = scope.tag_id
        WHERE scope.group_name = 'exclude' AND links.movie_id = m.id
      )''',
    ];
    final whereValues = <Object?>[];
    void addIdSetClause(String column, Set<String> ids) {
      if (ids.isEmpty) return;
      final sorted = ids.toList()..sort();
      clauses.add('$column IN (${List.filled(sorted.length, '?').join(', ')})');
      whereValues.addAll(sorted);
    }

    addIdSetClause('m.category_id', filter.effectiveCategoryIds);
    addIdSetClause('m.series_id', filter.seriesIds);
    if (filter.publisherIds.isNotEmpty) {
      final ids = filter.publisherIds.toList()..sort();
      final placeholders = List.filled(ids.length, '?').join(',');
      clauses.add(
          '(m.publisher_id IN ($placeholders) OR EXISTS(SELECT 1 FROM movie_company_links cl WHERE cl.movie_id=m.id AND cl.company_id IN ($placeholders)))');
      whereValues.addAll([...ids, ...ids]);
    }
    if (filter.actorIds.isNotEmpty) {
      final actorIds = filter.actorIds.toList()..sort();
      clauses.add('''EXISTS (
        SELECT 1 FROM movie_actor_links selected_actor
        WHERE selected_actor.movie_id = m.id
          AND selected_actor.actor_id IN (${List.filled(actorIds.length, '?').join(', ')})
      )''');
      whereValues.addAll(actorIds);
    }
    if (filter.isFavorite != null) {
      clauses.add('m.is_favorite = ?');
      whereValues.add(filter.isFavorite! ? 1 : 0);
    }
    if (filter.resolutions.isNotEmpty) {
      clauses.add('''EXISTS (
        SELECT 1 FROM episodes resolution_episode
        WHERE resolution_episode.movie_id = m.id
          AND resolution_episode.is_available = 1
          AND resolution_episode.resolution_label IN (${List.filled(filter.resolutions.length, '?').join(', ')})
      )''');
      whereValues.addAll(filter.resolutions.toList()..sort());
    }
    if (filter.watchStates.isNotEmpty) {
      final watchStateClauses = <String>[];
      if (filter.watchStates.contains('unwatched')) {
        watchStateClauses.add('''NOT EXISTS (
          SELECT 1 FROM playback_history watched
          WHERE watched.movie_id = m.id
        )''');
      }
      if (filter.watchStates.contains('continue')) {
        watchStateClauses.add('''EXISTS (
          SELECT 1 FROM episode_playback_progress progress
          WHERE progress.movie_id = m.id
            AND progress.position_ms > 0
            AND progress.duration_ms > 0
            AND progress.position_ms < progress.duration_ms
        )''');
      }
      clauses.add('(${watchStateClauses.join(' OR ')})');
    }
    final cte = '''WITH RECURSIVE
      requested(group_name, requested_tag_id, include_descendants) AS (
        $requestedSql
      ),
      search_terms(query, query_like, query_prefix, catalog, catalog_like, catalog_prefix) AS (
        VALUES (?, ?, ?, ?, ?, ?)
      ),
      tag_scope(group_name, requested_tag_id, tag_id) AS (
        SELECT group_name, requested_tag_id, requested_tag_id FROM requested
        UNION
        SELECT scope.group_name, scope.requested_tag_id, links.child_tag_id
        FROM tag_scope scope
        JOIN requested request ON request.group_name = scope.group_name
          AND request.requested_tag_id = scope.requested_tag_id
        JOIN tag_parent_links links ON links.parent_tag_id = scope.tag_id
        JOIN tags child ON child.id = links.child_tag_id
        WHERE request.include_descendants = 1 AND child.archived_at IS NULL
      ),
      matching_movies AS (
        SELECT m.id, m.title, m.original_title, m.catalog_number,
               m.publisher_id, publisher.display_name AS publisher_name,
               m.series_id, series.display_name AS series_name,
               m.summary, m.poster_file_name, m.play_count, m.is_favorite,
               m.created_at, m.updated_at,
               m.entry_type,
               $relevanceSql,
               m.category_id, category.name AS category_name,
               COUNT(e.id) AS episode_count,
               SUM(COALESCE(e.duration_ms, 0)) AS duration_ms,
               MAX(e.video_width) AS video_width,
               MAX(e.video_height) AS video_height,
               CASE WHEN COUNT(DISTINCT NULLIF(e.resolution_label, '')) > 1
                    THEN '多种分辨率' ELSE MAX(e.resolution_label) END AS resolution_label
        FROM movies m
        CROSS JOIN search_terms terms
        LEFT JOIN episodes e ON e.movie_id = m.id
        LEFT JOIN publishers publisher ON publisher.id = m.publisher_id
        LEFT JOIN series ON series.id = m.series_id
        LEFT JOIN library_categories category ON category.id = m.category_id
        WHERE ${clauses.join(' AND ')}
        GROUP BY m.id
      )''';
    final parameters = [
      ...requestedValues,
      query,
      queryLike,
      queryPrefix,
      normalizedCatalog,
      catalogLike,
      catalogPrefix,
      ...whereValues,
    ];
    final total = _db
        .select(
            '$cte SELECT COUNT(*) AS count FROM matching_movies', parameters)
        .single['count'] as int;
    final upperOrder = filter.order.toUpperCase();
    final orderBy = switch (filter.sort) {
      'relevance' => 'relevance_score $upperOrder, created_at DESC, id ASC',
      'createdAt' => 'created_at $upperOrder, id ASC',
      'title' => 'title COLLATE NOCASE $upperOrder, id ASC',
      'durationMs' => 'duration_ms $upperOrder, id ASC',
      'recent' => 'play_count $upperOrder, id ASC',
      _ => 'updated_at $upperOrder, id ASC',
    };
    final offset = (filter.page - 1) * filter.pageSize;
    final rows = _db.select('''$cte
      SELECT * FROM matching_movies
      ORDER BY $orderBy
      LIMIT ? OFFSET ?
    ''', [...parameters, filter.pageSize, offset]);
    final items = rows.map(_mapSearchMovie).toList(growable: false);
    return NasMovieSearchPage(
      items: items,
      number: filter.page,
      size: filter.pageSize,
      total: total,
      hasMore: offset + items.length < total,
    );
  }

  bool get hasMediaRoots =>
      _db.select('SELECT 1 FROM media_roots LIMIT 1').isNotEmpty;

  bool get hasScannedMediaRoots => _db
      .select(
          'SELECT 1 FROM media_roots WHERE last_scanned_at IS NOT NULL LIMIT 1')
      .isNotEmpty;

  NasLibraryMovie? findMovie(String movieId) {
    final movie = findMovieForAdmin(movieId);
    if (movie == null ||
        _db.select(
          "SELECT 1 FROM movies WHERE id = ? AND lifecycle_state = 'active'",
          [movieId],
        ).isEmpty ||
        (movie.entryType != 'series' && movie.episodeCount == 0)) {
      return null;
    }
    return movie;
  }

  NasLibraryMovie? findMovieForAdmin(String movieId) {
    final rows = _db.select('''
      SELECT m.id, m.title, m.original_title, m.catalog_number,
             m.publisher_id, p.display_name AS publisher_name,
             m.series_id, s.display_name AS series_name,
             m.summary, m.actors_json, m.poster_file_name, m.play_count,
             m.is_favorite,
             m.category_id, c.name AS category_name,
             m.updated_at, m.entry_type, COUNT(e.id) AS episode_count,
             SUM(CASE WHEN e.duration_ms IS NULL THEN 0 ELSE e.duration_ms END) AS duration_ms
      FROM movies m
      LEFT JOIN publishers p ON p.id = m.publisher_id
      LEFT JOIN series s ON s.id = m.series_id
      LEFT JOIN library_categories c ON c.id = m.category_id
      LEFT JOIN episodes e ON e.movie_id = m.id
      WHERE m.id = ?
      GROUP BY m.id
    ''', [movieId]);
    return rows.isEmpty ? null : _withResolution(_mapMovie(rows.single));
  }

  List<String> activeMovieIdsForCategory(String categoryId) => _db
      .select('''
        SELECT id FROM movies
        WHERE category_id = ? AND lifecycle_state = 'active'
          AND EXISTS (SELECT 1 FROM episodes WHERE movie_id = movies.id)
        ORDER BY id
      ''', [categoryId])
      .map((row) => row['id'] as String)
      .toList(growable: false);

  String? preferredMdcngEpisodeIdForMovie(String movieId) {
    final linked = _db.select('''
      SELECT record.episode_id FROM movie_metadata_field_sources source
      JOIN mdcng_import_records record ON record.id = source.import_record_id
      WHERE source.movie_id = ?
      ORDER BY record.created_at DESC, record.id DESC LIMIT 1
    ''', [movieId]);
    if (linked.isNotEmpty) return linked.single['episode_id'] as String;
    final rows = _db.select('''
      SELECT episode_id FROM mdcng_import_records
      WHERE movie_id = ? ORDER BY created_at DESC, id DESC LIMIT 1
    ''', [movieId]);
    return rows.isEmpty ? null : rows.single['episode_id'] as String;
  }

  bool hasDefaultScannedTitle(String movieId) {
    final rows = _db.select('''
      SELECT m.title, m.entry_type, m.collection_key,
             (SELECT e.relative_path FROM episodes e
              WHERE e.movie_id = m.id ORDER BY e.id LIMIT 1) AS relative_path
      FROM movies m WHERE m.id = ?
    ''', [movieId]);
    if (rows.isEmpty) return false;
    final row = rows.single;
    final collectionKey = row['collection_key'] as String?;
    if (collectionKey != null) {
      final folder = collectionKey
          .substring(collectionKey.indexOf(':') + 1)
          .split('/')
          .last;
      return row['title'] == collectionTitleFromDirectory(folder);
    }
    if (row['entry_type'] != 'single') return false;
    final path = row['relative_path'] as String?;
    return path != null && row['title'] == titleFromPath(path);
  }

  List<NasLibraryEpisode> episodesForMovie(String movieId) {
    final rows = _db.select('''
      SELECT e.id, e.movie_id, e.media_root_id, e.title, e.relative_path, e.file_size, e.is_available,
             e.duration_ms, e.video_width, e.video_height, e.resolution_label,
             e.media_modified_at, e.updated_at, e.natural_sort_key, e.manual_order,
             root.name AS source_name, root.is_online AS source_online
      FROM episodes e JOIN media_roots root ON root.id = e.media_root_id
      WHERE e.movie_id = ?
      ORDER BY e.manual_order IS NOT NULL DESC, e.manual_order,
               e.natural_sort_key COLLATE NOCASE, e.relative_path COLLATE NOCASE, e.id
    ''', [movieId]);
    return rows.map(_mapEpisode).toList(growable: false);
  }

  NasEpisodePage episodePageForMovie({
    required String movieId,
    String query = '',
    required int page,
    required int pageSize,
    String? anchorEpisodeId,
  }) {
    if (page < 1 || pageSize < 1 || pageSize > 100 || query.length > 120) {
      throw ArgumentError('分集分页参数无效');
    }
    final like = '%${query.trim()}%';
    final total = _db.select('''
      SELECT COUNT(*) AS count FROM episodes
      WHERE movie_id = ? AND (? = '%%' OR lower(title) LIKE lower(?))
    ''', [movieId, like, like]).single['count'] as int;
    var effectivePage = page;
    if (anchorEpisodeId != null) {
      final ordered = _db.select('''
        SELECT id FROM episodes
        WHERE movie_id = ? AND (? = '%%' OR lower(title) LIKE lower(?))
        ORDER BY manual_order IS NOT NULL DESC, manual_order,
                 natural_sort_key COLLATE NOCASE, relative_path COLLATE NOCASE, id
      ''', [movieId, like, like]);
      final index = ordered.indexWhere((row) => row['id'] == anchorEpisodeId);
      if (index < 0) throw ArgumentError('分集不属于影视条目');
      effectivePage = index ~/ pageSize + 1;
    }
    final offset = (effectivePage - 1) * pageSize;
    final rows = _db.select('''
      SELECT e.id, e.movie_id, e.media_root_id, e.title, e.relative_path, e.file_size, e.is_available,
             e.duration_ms, e.video_width, e.video_height, e.resolution_label,
             e.media_modified_at, e.updated_at, e.natural_sort_key, e.manual_order,
             root.name AS source_name, root.is_online AS source_online
      FROM episodes e JOIN media_roots root ON root.id = e.media_root_id
      WHERE e.movie_id = ? AND (? = '%%' OR lower(e.title) LIKE lower(?))
      ORDER BY e.manual_order IS NOT NULL DESC, e.manual_order,
               e.natural_sort_key COLLATE NOCASE, e.relative_path COLLATE NOCASE, e.id
      LIMIT ? OFFSET ?
    ''', [movieId, like, like, pageSize, offset]);
    final items = rows.map(_mapEpisode).toList(growable: false);
    return NasEpisodePage(
      items: items,
      number: effectivePage,
      size: pageSize,
      total: total,
      hasMore: offset + items.length < total,
    );
  }

  NasScannedMediaFilePage scannedMediaFiles({
    required int page,
    required int pageSize,
    String query = '',
  }) {
    if (page < 1 || pageSize < 1 || pageSize > 100 || query.length > 120) {
      throw ArgumentError('媒体文件分页参数无效');
    }
    final like = '%${query.trim()}%';
    final total = _db.select('''
      SELECT COUNT(*) AS count FROM episodes e JOIN movies m ON m.id = e.movie_id
      WHERE ? = '%%' OR lower(e.title) LIKE lower(?) OR lower(m.title) LIKE lower(?)
    ''', [like, like, like]).single['count'] as int;
    final offset = (page - 1) * pageSize;
    final rows = _db.select('''
      SELECT e.id, e.movie_id, e.media_root_id, e.title, e.relative_path,
             e.file_size, e.is_available, e.duration_ms, e.video_width,
             e.video_height, e.resolution_label, e.media_modified_at, e.updated_at,
             e.natural_sort_key, e.manual_order, root.name AS source_name,
              root.is_online AS source_online, m.title AS movie_title,
              m.entry_type, m.category_id
      FROM episodes e
      JOIN movies m ON m.id = e.movie_id
      JOIN media_roots root ON root.id = e.media_root_id
      WHERE ? = '%%' OR lower(e.title) LIKE lower(?) OR lower(m.title) LIKE lower(?)
      ORDER BY e.updated_at DESC, e.id
      LIMIT ? OFFSET ?
    ''', [like, like, like, pageSize, offset]);
    final items = rows
        .map(
          (row) => NasScannedMediaFile(
            episode: _mapEpisode(row),
            movieId: row['movie_id'] as String,
            movieTitle: row['movie_title'] as String,
            entryType: row['entry_type'] as String,
            categoryId: row['category_id'] as String?,
          ),
        )
        .toList(growable: false);
    return NasScannedMediaFilePage(
      items: items,
      number: page,
      size: pageSize,
      total: total,
      hasMore: offset + items.length < total,
    );
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
        isFavorite: (row['is_favorite'] as int) == 1,
        episodeCount: row['episode_count'] as int,
        durationMs: (row['duration_ms'] as int?) == 0
            ? null
            : row['duration_ms'] as int?,
        entryType: row['entry_type'] as String,
        updatedAt: row['updated_at'] as String,
        categoryId: row['category_id'] as String?,
        categoryName: row['category_name'] as String?,
      );

  /// 搜索列表已经由 SQL 聚合，不能再为每部影片读取标签或路径。
  NasLibraryMovie _mapSearchMovie(Row row) => NasLibraryMovie(
        id: row['id'] as String,
        title: row['title'] as String,
        originalTitle: row['original_title'] as String?,
        catalogNumber: row['catalog_number'] as String?,
        publisherId: row['publisher_id'] as String?,
        publisherName: row['publisher_name'] as String?,
        seriesId: row['series_id'] as String?,
        seriesName: row['series_name'] as String?,
        summary: row['summary'] as String,
        // 海报墙不展示演员；关键词中的演员匹配也已在同一个 SQL 查询内完成。
        actors: const [],
        posterFileName: row['poster_file_name'] as String?,
        playCount: row['play_count'] as int,
        isFavorite: (row['is_favorite'] as int) == 1,
        episodeCount: row['episode_count'] as int,
        durationMs: (row['duration_ms'] as int?) == 0
            ? null
            : row['duration_ms'] as int?,
        entryType: row['entry_type'] as String,
        updatedAt: row['updated_at'] as String,
        categoryId: row['category_id'] as String?,
        categoryName: row['category_name'] as String?,
        videoWidth: row['video_width'] as int?,
        videoHeight: row['video_height'] as int?,
        resolutionLabel: row['resolution_label'] as String?,
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
      entryType: movie.entryType,
      playCount: movie.playCount,
      isFavorite: movie.isFavorite,
      updatedAt: movie.updatedAt,
      categoryId: movie.categoryId,
      categoryName: movie.categoryName,
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

  NasLibraryEpisode _mapEpisode(Row row) => NasLibraryEpisode(
        id: row['id'] as String,
        movieId: row['movie_id'] as String,
        mediaRootId: row['media_root_id'] as String,
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
        sourceName: row['source_name'] as String? ?? '未知来源盘',
        sourceOnline: (row['source_online'] as int? ?? 0) == 1,
      );
}
