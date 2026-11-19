import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';
import 'library_values.dart';

class NasCollectionCompositionConflict implements Exception {
  const NasCollectionCompositionConflict(this.code);
  final String code;
}

/// Whole-movie composition. Videos never move; image bytes are read only for
/// deduplication, outside the write transaction. Source metadata remains intact.
class NasCollectionCompositionRepository {
  NasCollectionCompositionRepository(this.connection,
      {required this.transaction});
  final Database Function() connection;
  final T Function<T>(T Function() action) transaction;
  Database get _db => connection();
  final Map<String, (int, DateTime, String)> _imageDigests = {};

  Never _conflict(String code) => throw NasCollectionCompositionConflict(code);

  Map<String, Object?> _snapshot(List<String> movieIds, String sourceId) {
    if (movieIds.length < 2 ||
        movieIds.length > 100 ||
        movieIds.toSet().length != movieIds.length ||
        !movieIds.contains(sourceId)) {
      throw const FormatException('请选择 2 至 100 部不同影片和主资料来源。');
    }
    final marks = List.filled(movieIds.length, '?').join(',');
    List<Map<String, Object?>> rows(String sql) => _db
        .select(sql, movieIds)
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    final movies =
        rows('SELECT * FROM movies WHERE id IN ($marks) ORDER BY id');
    if (movies.length != movieIds.length ||
        movies.any((m) => m['lifecycle_state'] != 'active')) {
      _conflict('collection_selection_changed');
    }
    final category = movies.first['category_id'];
    if (category == null || movies.any((m) => m['category_id'] != category)) {
      _conflict('collection_category_mismatch');
    }
    if (_db.select('''SELECT 1 FROM scrape_tasks
        WHERE status IN ('pending','running','retry')
          AND json_extract(payload,'\$.movieId') IN ($marks) LIMIT 1''',
            movieIds).isNotEmpty ||
        _db.select('''SELECT 1 FROM ai_metadata_tasks
          WHERE status IN ('queued','running') AND movie_id IN ($marks) LIMIT 1''',
            movieIds).isNotEmpty) {
      _conflict('collection_task_active');
    }
    final episodes = rows('''SELECT e.*, r.name AS source_name,
      r.is_online AS source_online FROM episodes e
      JOIN media_roots r ON r.id=e.media_root_id
      WHERE e.movie_id IN ($marks)
      ORDER BY e.manual_order IS NOT NULL DESC, e.manual_order,
        e.natural_sort_key COLLATE NOCASE, e.relative_path COLLATE NOCASE, e.id''');
    if (episodes.length > 500 ||
        movieIds.any((id) => !episodes.any((e) => e['movie_id'] == id))) {
      _conflict('collection_episode_limit');
    }
    return {
      'movieIds': movieIds,
      'sourceId': sourceId,
      'movies': movies,
      'episodes': episodes,
      'actors': rows('''SELECT l.movie_id, l.actor_id,
        COALESCE(a.translated_name,a.stage_name,a.original_name,'未命名演员') AS name
        FROM movie_actor_links l JOIN actors a ON a.id=l.actor_id
        WHERE l.movie_id IN ($marks) ORDER BY l.movie_id, l.actor_id'''),
      'tags': rows('''SELECT l.movie_id, l.tag_id, t.name
        FROM movie_tag_links l JOIN tags t ON t.id=l.tag_id
        WHERE l.movie_id IN ($marks) ORDER BY l.movie_id, l.tag_id'''),
      'images': rows('''SELECT * FROM movie_carousel_images
        WHERE movie_id IN ($marks) ORDER BY created_at, id'''),
      'fieldSources': rows('''SELECT * FROM movie_metadata_field_sources
        WHERE movie_id IN ($marks) ORDER BY movie_id, field_key'''),
      'scrapeFields': rows('''SELECT * FROM scrape_fields
        WHERE kind='movie' AND entity_id IN ($marks) ORDER BY entity_id, field'''),
      'supplementCast': rows('''SELECT * FROM supplement_cast
        WHERE movie_id IN ($marks) ORDER BY movie_id, source_key'''),
      'actorAppendPolicies':
          rows('''SELECT * FROM composition_actor_append_policies
        WHERE movie_id IN ($marks) ORDER BY movie_id'''),
      'companies': rows('''SELECT * FROM movie_company_links
        WHERE movie_id IN ($marks) ORDER BY movie_id,company_id,role'''),
      'sourceProfiles': rows('''SELECT * FROM scrape_movie_profiles
        WHERE movie_id IN ($marks) ORDER BY movie_id'''),
    };
  }

  String _token(Map<String, Object?> snapshot) =>
      sha256.convert(utf8.encode(jsonEncode(snapshot))).toString();

  List<Map<String, Object?>> sourcesForMovie(String movieId) => _db.select('''
    WITH RECURSIVE source_ids(id) AS (
      SELECT id FROM movies WHERE merged_into_movie_id=? AND lifecycle_state='merged'
      UNION
      SELECT m.id FROM movies m JOIN source_ids s ON m.merged_into_movie_id=s.id
        WHERE m.lifecycle_state='merged'
    ) SELECT m.id,m.title,m.original_title AS originalTitle,
        m.catalog_number AS catalogNumber
      FROM movies m JOIN source_ids s ON s.id=m.id ORDER BY m.title,m.id LIMIT 500
  ''', [movieId]).map((row) => Map<String, Object?>.from(row)).toList();

  Future<Map<String, Object?>> preview(
      {required List<String> movieIds,
      required String metadataSourceMovieId,
      required String dataDir}) async {
    final snapshot = _snapshot(movieIds, metadataSourceMovieId);
    final token = _token(snapshot);
    final movies = snapshot['movies'] as List<Map<String, Object?>>;
    final byId = {for (final movie in movies) movie['id']: movie};
    final source = byId[metadataSourceMovieId]!;
    final images = snapshot['images'] as List<Map<String, Object?>>;
    final keptImages = <String>[];
    final seen = <String>{};
    final stats = <String, FileStat>{};
    final sizeCounts = <int, int>{};
    for (final image in images) {
      final path = '$dataDir/artwork/carousel/${image['file_name']}';
      try {
        final stat = await File(path).stat();
        if (stat.type == FileSystemEntityType.file) {
          stats[path] = stat;
          sizeCounts[stat.size] = (sizeCounts[stat.size] ?? 0) + 1;
        }
      } on FileSystemException {
        // A missing screenshot remains a separate record.
      }
    }
    // Managed images are immutable. A bounded cache avoids hashing them again
    // when the user changes the main metadata or confirms the same preview.
    for (final image in images) {
      final file = File('$dataDir/artwork/carousel/${image['file_name']}');
      var key = 'missing:${image['id']}';
      try {
        final stat = stats[file.path];
        // Different lengths cannot be identical; avoid reading those images.
        if (stat != null && sizeCounts[stat.size]! > 1) {
          final cached = _imageDigests[file.path];
          if (cached != null &&
              cached.$1 == stat.size &&
              cached.$2 == stat.modified) {
            key = cached.$3;
          } else {
            key = (await sha256.bind(file.openRead()).first).toString();
            if (_imageDigests.length >= 2048)
              _imageDigests.remove(_imageDigests.keys.first);
            _imageDigests[file.path] = (stat.size, stat.modified, key);
          }
        }
      } on FileSystemException {
        // Preserve unavailable artwork records rather than silently discard them.
      }
      if (seen.add(key)) keptImages.add(image['id'] as String);
    }
    if (_token(_snapshot(movieIds, metadataSourceMovieId)) != token) {
      _conflict('collection_selection_changed');
    }
    // A new composition defaults to automatic ordering even when a source has
    // a saved manual order. Use SQLite's exact collations and final tie breaks.
    final marks = List.filled(movieIds.length, '?').join(',');
    final order = _db.select('''SELECT id FROM episodes
      WHERE movie_id IN ($marks)
      ORDER BY natural_sort_key COLLATE NOCASE, relative_path COLLATE NOCASE, id''',
        movieIds);
    final positions = {
      for (var i = 0; i < order.length; i++) order[i]['id']: i,
    };
    final episodes = [...snapshot['episodes'] as List<Map<String, Object?>>]
      ..sort((a, b) => positions[a['id']]!.compareTo(positions[b['id']]!));
    List<Map<String, Object?>> union(String kind, String key) {
      final unique = <Object?, Map<String, Object?>>{};
      for (final row in snapshot[kind] as List<Map<String, Object?>>) {
        unique[row[key]] = {'id': row[key], 'name': row['name']};
      }
      return unique.values.toList()
        ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    }

    return {
      'previewToken': token,
      'categoryId': source['category_id'],
      'metadataSourceMovieId': metadataSourceMovieId,
      'title': source['title'],
      'originalTitle': source['original_title'],
      'catalogNumber': source['catalog_number'],
      'summary': source['summary'],
      'posterUrl': source['poster_file_name'] == null
          ? null
          : '/api/v1/assets/posters/$metadataSourceMovieId',
      'isFavorite': movies.any((m) => m['is_favorite'] == 1),
      'actors': union('actors', 'actor_id'),
      'tags': union('tags', 'tag_id'),
      'imageCount': keptImages.length,
      'keptImageIds': keptImages,
      'movies': [
        for (final id in movieIds)
          {
            'id': id,
            'title': byId[id]!['title'],
            'catalogNumber': byId[id]!['catalog_number'],
            'episodeCount': episodes.where((e) => e['movie_id'] == id).length,
          }
      ],
      'episodes': [
        for (final e in episodes)
          {
            'id': e['id'],
            'movieId': e['movie_id'],
            'movieTitle': byId[e['movie_id']]!['title'],
            'title': e['title'],
            'sourceName': e['source_name'],
            'relativePath': e['relative_path'],
            'available': e['is_available'] == 1 && e['source_online'] == 1,
          }
      ],
    };
  }

  Future<String> compose(
      {required List<String> movieIds,
      required String metadataSourceMovieId,
      required String previewToken,
      required List<String> episodeOrder,
      String sortMode = 'automatic',
      bool automaticGrouping = false,
      String? scannedTitle,
      required String dataDir,
      required bool Function(Set<String>) hasActivePlayback}) async {
    if (!{'automatic', 'manual'}.contains(sortMode)) {
      throw const FormatException('分集排序模式无效。');
    }
    final plan = await preview(
        movieIds: movieIds,
        metadataSourceMovieId: metadataSourceMovieId,
        dataDir: dataDir);
    if (plan['previewToken'] != previewToken)
      _conflict('collection_selection_changed');
    final expected = (plan['episodes'] as List<Map<String, Object?>>)
        .map((e) => e['id'] as String)
        .toSet();
    if (episodeOrder.length != expected.length ||
        episodeOrder.toSet().length != expected.length ||
        !expected.containsAll(episodeOrder)) {
      throw const FormatException('分集顺序与合并预览不一致。');
    }
    return transaction(() {
      if (_token(_snapshot(movieIds, metadataSourceMovieId)) != previewToken) {
        _conflict('collection_selection_changed');
      }
      if (hasActivePlayback(movieIds.toSet()))
        _conflict('collection_playback_active');
      final targetId = newUuidV4();
      final timestamp = now();
      final marks = List.filled(movieIds.length, '?').join(',');
      _db.execute(
          '''INSERT INTO movies(id, title, original_title, catalog_number,
        publisher_id, series_id, summary, category_id, poster_file_name,
        entry_type, is_favorite, play_count, created_at, updated_at)
        SELECT ?, title, original_title, catalog_number, publisher_id, series_id,
          summary, category_id, poster_file_name, 'series', ?,
          (SELECT COALESCE(SUM(play_count),0) FROM movies WHERE id IN ($marks)), ?, ?
        FROM movies WHERE id=?''',
          [
            targetId,
            plan['isFavorite'] == true ? 1 : 0,
            ...movieIds,
            timestamp,
            timestamp,
            metadataSourceMovieId
          ]);
      for (final relation in [
        ('movie_actor_links', 'actor_id'),
        ('movie_tag_links', 'tag_id')
      ]) {
        _db.execute('''INSERT INTO ${relation.$1}(movie_id, ${relation.$2})
          SELECT DISTINCT ?, ${relation.$2} FROM ${relation.$1}
          WHERE movie_id IN ($marks)''', [targetId, ...movieIds]);
      }
      if (automaticGrouping) {
        // 自动扫描保留主资料原有来源及人工清空标记，让缺失资料和新版导入仍可补充。
        _db.execute('''INSERT INTO movie_metadata_field_sources
          (movie_id,field_key,source_kind,import_record_id,source_content_hash,updated_at)
          SELECT ?,field_key,source_kind,import_record_id,source_content_hash,updated_at
          FROM movie_metadata_field_sources WHERE movie_id=?''',
            [targetId, metadataSourceMovieId]);
        _db.execute('''INSERT INTO scrape_fields
          (kind,entity_id,field,value,manual,updated_at)
          SELECT kind,?,field,value,manual,updated_at FROM scrape_fields
          WHERE kind='movie' AND entity_id=?''',
            [targetId, metadataSourceMovieId]);
        // 多来源的非空并集需要保护，避免后续只导入某一分集的资料而丢失关联。
        for (final field in ['actors', 'tags', 'fanart']) {
          final hasCombinedValues = switch (field) {
            'actors' => (plan['actors'] as List).isNotEmpty,
            'tags' => (plan['tags'] as List).isNotEmpty,
            _ => (plan['keptImageIds'] as List).isNotEmpty,
          };
          if (!hasCombinedValues) continue;
          _db.execute('''INSERT INTO movie_metadata_field_sources
            (movie_id,field_key,source_kind,updated_at) VALUES (?,?,'manual',?)
            ON CONFLICT(movie_id,field_key) DO UPDATE SET
              source_kind='manual',import_record_id=NULL,source_content_hash=NULL,
              updated_at=excluded.updated_at''', [targetId, field, timestamp]);
        }
        _db.execute('''INSERT INTO composition_actor_append_policies
          (movie_id,allow_append,source_kind,updated_at)
          VALUES (?,1,'composition',?)
          ON CONFLICT(movie_id) DO UPDATE SET
            allow_append=1,source_kind='composition',updated_at=excluded.updated_at''',
            [targetId, timestamp]);
      } else {
        // 手工组成影集时，保护用户已确认的全部资料。
        for (final field in metadataFieldKeys) {
          _db.execute('''INSERT INTO movie_metadata_field_sources
          (movie_id, field_key, source_kind, updated_at) VALUES (?, ?, 'manual', ?)''',
              [targetId, field, timestamp]);
        }
        for (final field in [
          'title',
          'original_title',
          'catalog_number',
          'summary',
          'poster_file_name',
          'publisher_id',
          'series_id'
        ]) {
          _db.execute(
              '''INSERT INTO scrape_fields(kind,entity_id,field,manual,updated_at)
          VALUES ('movie',?,?,1,?)''', [targetId, field, timestamp]);
        }
        _db.execute('''INSERT INTO composition_actor_append_policies
          (movie_id,allow_append,source_kind,updated_at)
          VALUES (?,1,'composition',?)
          ON CONFLICT(movie_id) DO UPDATE SET
            allow_append=1,source_kind='composition',updated_at=excluded.updated_at''',
            [targetId, timestamp]);
      }
      // Keep a per-source decision so a hidden movie whose cast was explicitly
      // frozen is not resurrected when its collection is reconciled later.
      for (final sourceMovieId in movieIds) {
        final existing = _db.select('''SELECT allow_append,source_kind
          FROM composition_actor_append_policies WHERE movie_id=?''',
            [sourceMovieId]);
        final sourceManual = _db.select('''SELECT 1
          FROM movie_metadata_field_sources
          WHERE movie_id=? AND field_key='actors' AND source_kind='manual'
          LIMIT 1''', [sourceMovieId]).isNotEmpty;
        final existingComposition = existing.isNotEmpty &&
            existing.single['source_kind'] == 'composition' &&
            existing.single['allow_append'] == 1;
        final allow =
            automaticGrouping && (existingComposition || !sourceManual) ? 1 : 0;
        final kind = allow == 1 ? 'composition' : 'user';
        if (existing.isNotEmpty && existing.single['source_kind'] == 'user') {
          continue;
        }
        _db.execute('''INSERT INTO composition_actor_append_policies
          (movie_id,allow_append,source_kind,updated_at) VALUES (?,?,?,?)
          ON CONFLICT(movie_id) DO UPDATE SET
            allow_append=excluded.allow_append,source_kind=excluded.source_kind,
            updated_at=excluded.updated_at''',
            [sourceMovieId, allow, kind, timestamp]);
      }
      if (scannedTitle != null) {
        // 自动扫描标题使用作品目录名，并允许后续 NFO 或采集资料补充正式标题。
        _db.execute('UPDATE movies SET title=?,scanned_title=? WHERE id=?',
            [scannedTitle, scannedTitle, targetId]);
        _db.execute('''DELETE FROM movie_metadata_field_sources
          WHERE movie_id=? AND field_key='title' ''', [targetId]);
        _db.execute('''DELETE FROM scrape_fields
          WHERE kind='movie' AND entity_id=? AND field='title' ''', [targetId]);
      }
      _db.execute('''INSERT INTO movie_company_links(movie_id,company_id,role)
        SELECT ?,company_id,role FROM movie_company_links WHERE movie_id=?''',
          [targetId, metadataSourceMovieId]);
      // 保留主资料的来源详情。自动扫描保留出演名单用于后续补关联；
      // 手工组成只保存来源信息，移除演员字段，避免重放旧名单覆盖用户选择。
      final sourceProfiles = _db.select(
          'SELECT metadata FROM scrape_movie_profiles WHERE movie_id=?',
          [metadataSourceMovieId]);
      for (final profile in sourceProfiles) {
        final metadata =
            jsonDecode(profile['metadata'] as String) as Map<String, dynamic>;
        if (!automaticGrouping) {
          metadata.remove('actors');
          metadata.remove('actorSources');
        }
        _db.execute(
            '''INSERT INTO scrape_movie_profiles(movie_id,metadata,updated_at)
          VALUES (?,?,?) ON CONFLICT(movie_id) DO UPDATE SET
            metadata=excluded.metadata,updated_at=excluded.updated_at''',
            [targetId, jsonEncode(metadata), timestamp]);
      }
      // 待补关联名单保留在原影片上，由归并链解析最终影集。这样连续合并
      // 不会丢失来源，影集改分类后也不会把旧来源误当成本地资料。
      for (var index = 0; index < episodeOrder.length; index++) {
        _db.execute(
            '''UPDATE episodes SET movie_id=?, manual_order=?, updated_at=?
          WHERE id=?''',
            [
              targetId,
              sortMode == 'manual' ? index : null,
              timestamp,
              episodeOrder[index]
            ]);
      }
      _db.execute('UPDATE movies SET episode_sort_mode=? WHERE id=?',
          [sortMode, targetId]);
      for (final table in ['episode_playback_progress', 'playback_history']) {
        _db.execute('UPDATE $table SET movie_id=? WHERE movie_id IN ($marks)',
            [targetId, ...movieIds]);
      }
      for (final imageId in plan['keptImageIds'] as List<String>) {
        _db.execute('UPDATE movie_carousel_images SET movie_id=? WHERE id=?',
            [targetId, imageId]);
      }
      _db.execute('''UPDATE movies SET lifecycle_state='merged',
        merged_into_movie_id=?, merged_at=?, updated_at=?, play_count=0
        WHERE id IN ($marks)''', [targetId, timestamp, timestamp, ...movieIds]);
      return targetId;
    });
  }
}
