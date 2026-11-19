part of '../library_database.dart';

/// 独立保存出演名单和身份映射，补关联时不改写演员档案。
extension NasSupplementDatabase on NasLibraryDatabase {
  /// Resolve a source movie to its final active owner. A category change at
  /// any point invalidates the alias so hidden records cannot cross groups.
  ({String id, String? categoryId})? _resolvedActorOwner(String movieId) {
    var current = movieId;
    String? category;
    final visited = <String>{};
    for (var depth = 0; depth < 100 && visited.add(current); depth++) {
      final rows = _db.select('''SELECT id,category_id,lifecycle_state,
          merged_into_movie_id FROM movies WHERE id=?''', [current]);
      if (rows.isEmpty) return null;
      final row = rows.single;
      final rowCategory = row['category_id'] as String?;
      category ??= rowCategory;
      if (category != rowCategory) return null;
      if (row['lifecycle_state'] == 'active') {
        return (id: current, categoryId: category);
      }
      if (row['lifecycle_state'] != 'merged' ||
          row['merged_into_movie_id'] == null) return null;
      current = row['merged_into_movie_id'] as String;
    }
    return null;
  }

  bool _movieActorAppendAllowed(String movieId) {
    final policy = _db.select('''SELECT allow_append,source_kind
      FROM composition_actor_append_policies WHERE movie_id=?''', [movieId]);
    if (policy.isNotEmpty) {
      final row = policy.single;
      if (row['source_kind'] == 'composition' && row['allow_append'] == 1) {
        return true;
      }
      return false;
    }
    return _db.select('''SELECT 1 FROM movie_metadata_field_sources
      WHERE movie_id=? AND field_key='actors' AND source_kind='manual' LIMIT 1''',
        [movieId]).isEmpty;
  }

  bool _movieActorSourceFrozen(String movieId) =>
      !_movieActorAppendAllowed(movieId);

  /// Returns the final owner only when background actor reconciliation is safe.
  String? _actorAppendOwner(String sourceMovieId,
      {required bool respectManualFreeze}) {
    final owner = _resolvedActorOwner(sourceMovieId);
    if (owner == null) return null;
    if (!respectManualFreeze) return owner.id;
    if (!_movieActorAppendAllowed(owner.id)) return null;
    // A user's freeze on a hidden source remains effective after composition;
    // an automatic composition policy explicitly permits additive union.
    final sourcePolicy = _db.select('''SELECT allow_append,source_kind
      FROM composition_actor_append_policies WHERE movie_id=?''',
        [sourceMovieId]);
    final sourceIsAutomaticComposition = sourcePolicy.isNotEmpty &&
        sourcePolicy.single['source_kind'] == 'composition' &&
        sourcePolicy.single['allow_append'] == 1;
    if (!sourceIsAutomaticComposition && _movieActorSourceFrozen(sourceMovieId))
      return null;
    return owner.id;
  }

  void initializeSupplementation() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS supplement_cast (
        movie_id TEXT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
        source_key TEXT NOT NULL, source_url TEXT, name TEXT NOT NULL,
        aliases_json TEXT NOT NULL, stable_identity INTEGER NOT NULL,
        PRIMARY KEY(movie_id,source_key)
      );
      CREATE TABLE IF NOT EXISTS supplement_actor_mappings (
        source_key TEXT NOT NULL,
        actor_id TEXT NOT NULL REFERENCES actors(id) ON DELETE CASCADE,
        PRIMARY KEY(source_key,actor_id)
      );
      CREATE TABLE IF NOT EXISTS movie_gallery_origins (
        image_id TEXT PRIMARY KEY REFERENCES movie_carousel_images(id) ON DELETE CASCADE,
        kind TEXT NOT NULL
      );
    ''');
    // 旧版 NFO 图与导入审计使用同一时间戳，只有有据可查的图才补记来源。
    _db.execute('''INSERT OR IGNORE INTO movie_gallery_origins(image_id,kind)
      SELECT i.id,'mdcng_cover' FROM movie_carousel_images i
      JOIN mdcng_import_records r ON r.movie_id=i.movie_id AND r.created_at=i.created_at
      WHERE EXISTS(SELECT 1 FROM json_each(r.applied_fields_json) WHERE value='fanart')''');
  }

  void recordGalleryOrigin(String imageId, String kind) => _db.execute(
      'INSERT OR IGNORE INTO movie_gallery_origins VALUES (?,?)',
      [imageId, kind]);

  String? galleryOrigin(String imageId) {
    final rows = _db.select(
        'SELECT kind FROM movie_gallery_origins WHERE image_id=?', [imageId]);
    return rows.isEmpty ? null : rows.single['kind'] as String;
  }

  void saveSupplementCast(String movieId, List<Map<String, dynamic>> cast) {
    for (final entity in cast) {
      final stable = entity['provisional'] != true && entity['id'] is String;
      final name = (entity['name'] as String? ?? '').trim();
      if (name.isEmpty) continue;
      final key =
          stable ? entity['id'] as String : 'name:$movieId:${sha256Hex(name)}';
      _db.execute('''INSERT INTO supplement_cast VALUES (?,?,?,?,?,?)
        ON CONFLICT(movie_id,source_key) DO UPDATE SET source_url=excluded.source_url,
        name=excluded.name,aliases_json=excluded.aliases_json''', [
        movieId,
        key,
        entity['url'],
        name,
        jsonEncode(entity['aliases'] ?? []),
        stable ? 1 : 0
      ]);
    }
  }

  List<NasActor> supplementActorMatches(Map<String, dynamic> entity,
      {String? actorId}) {
    final ids = <String>{};
    if (entity['id'] is String) {
      ids.addAll(_db.select(
          'SELECT actor_id FROM supplement_actor_mappings WHERE source_key=?',
          [entity['id']]).map((row) => row['actor_id'] as String));
    }
    if (entity['provisional'] != true && entity['id'] is String) {
      for (final row in _db.select(
          "SELECT entity_id FROM scrape_sources WHERE source_key=? AND kind='actor'",
          [entity['id']])) {
        ids.add(row['entity_id'] as String);
      }
    }
    final names = <String>[
      entity['name'] as String? ?? '',
      ...List<String>.from(entity['aliases'] as List? ?? const []),
    ]
        .map((name) => name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();
    // 在数据库内筛选姓名，避免每个出演名字都加载全量演员及影片计数。
    ids.addAll(_db.select(
        '''WITH names(value) AS (SELECT value FROM json_each(?))
      SELECT a.id FROM actors a WHERE a.archived_at IS NULL
        ${actorId == null ? '' : 'AND a.id=?'} AND (
        lower(trim(a.stage_name)) IN (SELECT value FROM names) OR
        lower(trim(a.original_name)) IN (SELECT value FROM names) OR
        lower(trim(a.translated_name)) IN (SELECT value FROM names) OR
        EXISTS(SELECT 1 FROM json_each(a.aliases_json) n WHERE lower(trim(n.value)) IN (SELECT value FROM names)) OR
        EXISTS(SELECT 1 FROM mdcng_actor_source_links s WHERE s.actor_id=a.id AND lower(trim(s.source_name)) IN (SELECT value FROM names)))''',
        [
          jsonEncode(names),
          if (actorId != null) actorId
        ]).map((row) => row['id'] as String));
    return ids
        .where((id) => actorId == null || id == actorId)
        .map(findActor)
        .whereType<NasActor>()
        .where((actor) => actor.archivedAt == null)
        .toList();
  }

  int reconcileSupplementCast({
    String? movieId,
    String? actorId,
    bool respectManualFreeze = true,
    bool allowDirectNonEmptyManual = false,
  }) {
    var added = 0;
    final rows = _db.select(
        'SELECT c.* FROM supplement_cast c JOIN movies m ON m.id=c.movie_id');
    for (final row in rows) {
      final sourceIsRequestedMovie =
          movieId != null && row['movie_id'] == movieId;
      final sourceIsActive = _db.select('''SELECT 1 FROM movies
          WHERE id=? AND lifecycle_state='active' LIMIT 1''',
          [row['movie_id']]).isNotEmpty;
      final hasExistingActors = sourceIsActive &&
          _db.select('SELECT 1 FROM movie_actor_links WHERE movie_id=? LIMIT 1',
              [row['movie_id']]).isNotEmpty;
      // A later MDCNG actor identity may be learned after a supplement task
      // completed. Keep additive behavior for an active standalone movie that
      // already has an actor list, while an empty manual list remains frozen.
      final allowDirectAppend = allowDirectNonEmptyManual && hasExistingActors;
      var owner = _actorAppendOwner(row['movie_id'] as String,
          respectManualFreeze: (respectManualFreeze && !allowDirectAppend) ||
              (!sourceIsRequestedMovie && !allowDirectAppend));
      if (owner == null) continue;
      if (movieId != null && owner != movieId && row['movie_id'] != movieId) {
        continue;
      }
      final matches = supplementActorMatches({
        'id': row['source_key'],
        'name': row['name'],
        'aliases': jsonDecode(row['aliases_json'] as String),
        'provisional': row['stable_identity'] == 0,
      }, actorId: actorId);
      for (final actor in matches) {
        // 用户明确要求追加所有候选；保留已有关系，包括人工关联。
        _db.execute('INSERT OR IGNORE INTO movie_actor_links VALUES (?,?)',
            [owner, actor.id]);
        added += _db.updatedRows;
        if (row['stable_identity'] == 1) {
          _db.execute(
              'INSERT OR IGNORE INTO supplement_actor_mappings VALUES (?,?)',
              [row['source_key'], actor.id]);
        }
      }
    }
    return added;
  }

  List<Map<String, dynamic>> supplementPending(String movieId) {
    final result = <Map<String, dynamic>>[];
    final seenKeys = <String>{};
    for (final row in _db.select('SELECT * FROM supplement_cast')) {
      // 归并来源继续保存原始名单；只有能安全解析到当前影集的来源才显示。
      final resolved = _resolvedActorOwner(row['movie_id'] as String);
      if (resolved == null || resolved.id != movieId) continue;
      // 活动影片本身即使人工维护过演员名单，也应保留待核对项；隐藏来源
      // 则仍需通过追加策略，避免用户冻结的旧资料重新出现。
      if (row['movie_id'] != movieId &&
          _actorAppendOwner(row['movie_id'] as String,
                  respectManualFreeze: true) !=
              movieId) continue;
      if (!seenKeys.add(row['source_key'] as String)) continue;
      if (supplementActorMatches({
        'id': row['source_key'],
        'name': row['name'],
        'aliases': jsonDecode(row['aliases_json'] as String),
        'provisional': row['stable_identity'] == 0
      }).isNotEmpty) continue;
      result.add({
        'field': 'identity',
        'supplement': true,
        'sourceKey': row['source_key'],
        'sourceUrl': row['source_url'],
        'proposed': row['name'],
        'aliases': jsonDecode(row['aliases_json'] as String),
        'candidates': <Object>[],
        'message': '未匹配 NAS 演员。可搜索已有演员确认异名，或先导入 MDCNG 演员后重试。'
      });
    }
    return result;
  }

  void supplementSummary(String movieId, String? summary) {
    if (summary == null || summary.trim().isEmpty) return;
    _db.execute(
        "UPDATE movies SET summary=?,updated_at=? WHERE id=? AND trim(summary)='' AND lifecycle_state='active'",
        [summary.trim(), NasLibraryDatabase._now(), movieId]);
    if (_db.updatedRows > 0)
      recordScrapeField('movie', movieId, 'summary', summary.trim());
  }

  void resolveSupplementTask(Map<String, dynamic> task, List<String> fields,
      Map<String, String> mappings) {
    if (fields.isNotEmpty) throw ArgumentError('补关联任务不能覆盖资料字段');
    final movieId = (task['payload'] as Map)['movieId'] as String;
    if (findMovie(movieId) == null) throw ArgumentError('影片已移除');
    transaction(() {
      final conflicts = (task['conflicts'] as List).whereType<Map>();
      for (final mapping in mappings.entries) {
        final rows = _db.select(
            'SELECT * FROM supplement_cast WHERE source_key=?',
            [mapping.key]).where((row) {
          final sourceMovieId = row['movie_id'] as String;
          final resolved = _resolvedActorOwner(sourceMovieId);
          if (resolved == null || resolved.id != movieId) return false;
          return sourceMovieId == movieId ||
              _actorAppendOwner(sourceMovieId, respectManualFreeze: true) ==
                  movieId;
        }).toList();
        final actor = findActor(mapping.value);
        if (!conflicts.any((c) => c['sourceKey'] == mapping.key) ||
            rows.isEmpty ||
            actor == null ||
            actor.archivedAt != null) {
          throw ArgumentError('演员选择已失效，请重新核对');
        }
        // 无稳定身份的 key 含影片 ID，只作用于本影片，且重试仍记住确认结果。
        _db.execute(
            'INSERT OR IGNORE INTO supplement_actor_mappings VALUES (?,?)',
            [mapping.key, actor.id]);
      }
      reconcileSupplementCast(respectManualFreeze: false);
      final pending = supplementPending(movieId);
      final warnings = (task['result'] as Map?)?['warnings'] as List? ?? [];
      finishScrapeTask(
          task['id'] as String,
          pending.isNotEmpty
              ? 'review'
              : warnings.isEmpty
                  ? 'done'
                  : 'partial',
          conflicts: pending,
          error: warnings.isEmpty ? null : warnings.join('；'));
    });
  }
}
