part of '../library_database.dart';

/// 采集队列与正式资料同库快照，下载缓存可以重建。
extension NasScrapeDatabase on NasLibraryDatabase {
  void initializeScraping() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS scrape_jobs (
        id TEXT PRIMARY KEY, title TEXT NOT NULL, paused INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS scrape_tasks (
        id TEXT PRIMARY KEY, task_key TEXT NOT NULL, kind TEXT NOT NULL,
        payload TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
        attempts INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL DEFAULT 0,
        error TEXT, result TEXT, conflicts TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL
      );
      CREATE UNIQUE INDEX IF NOT EXISTS scrape_active_task ON scrape_tasks(task_key)
        WHERE status IN ('pending','running','retry');
      CREATE INDEX IF NOT EXISTS scrape_task_queue ON scrape_tasks(status,next_at,created_at);
      CREATE TABLE IF NOT EXISTS scrape_job_tasks (
        job_id TEXT NOT NULL REFERENCES scrape_jobs(id) ON DELETE CASCADE,
        task_id TEXT NOT NULL REFERENCES scrape_tasks(id) ON DELETE CASCADE,
        PRIMARY KEY(job_id,task_id)
      );
      CREATE TABLE IF NOT EXISTS scrape_sources (
        source_key TEXT PRIMARY KEY, kind TEXT NOT NULL, entity_id TEXT NOT NULL,
        source_url TEXT NOT NULL, profile TEXT, updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS scrape_task_children (
        parent_id TEXT NOT NULL REFERENCES scrape_tasks(id) ON DELETE CASCADE,
        child_id TEXT NOT NULL REFERENCES scrape_tasks(id) ON DELETE CASCADE,
        PRIMARY KEY(parent_id,child_id),CHECK(parent_id!=child_id)
      );
      CREATE INDEX IF NOT EXISTS scrape_sources_entity ON scrape_sources(kind,entity_id);
      CREATE TABLE IF NOT EXISTS scrape_fields (
        kind TEXT NOT NULL, entity_id TEXT NOT NULL, field TEXT NOT NULL,
        value TEXT, manual INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL,
        PRIMARY KEY(kind,entity_id,field)
      );
      CREATE TABLE IF NOT EXISTS movie_company_links (
        movie_id TEXT NOT NULL REFERENCES movies(id) ON DELETE CASCADE,
        company_id TEXT NOT NULL REFERENCES publishers(id) ON DELETE CASCADE,
        role TEXT NOT NULL CHECK(role IN ('maker','label','distributor')),
        PRIMARY KEY(movie_id,company_id,role)
      );
      CREATE TABLE IF NOT EXISTS scrape_settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS scrape_movie_profiles (
        movie_id TEXT PRIMARY KEY REFERENCES movies(id) ON DELETE CASCADE,
        metadata TEXT NOT NULL, updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS scrape_actor_works (
        actor_id TEXT NOT NULL REFERENCES actors(id) ON DELETE CASCADE,
        source_id TEXT NOT NULL, code TEXT, title TEXT, url TEXT NOT NULL,
        PRIMARY KEY(actor_id,source_id)
      );
      CREATE INDEX IF NOT EXISTS scrape_actor_works_code ON scrape_actor_works(code);
    ''');
    initializeSupplementation();
    _db.execute(
        "UPDATE scrape_tasks SET status='pending',error='服务重启后继续',attempts=MAX(0,attempts-1) WHERE status='running'");
    if (scrapeSettings['actorAssociationVersion'] != 1) {
      transaction(() {
        reconcileScrapeActorMovies();
        setScrapeSetting('actorAssociationVersion', 1);
      });
    }
  }

  Map<String, dynamic> get scrapeSettings {
    final result = <String, dynamic>{
      'minIntervalSeconds': 15,
      'maxIntervalSeconds': 25
    };
    for (final row in _db.select('SELECT key,value FROM scrape_settings')) {
      result[row['key'] as String] = jsonDecode(row['value'] as String);
    }
    return result;
  }

  void setScrapeSetting(String key, Object? value) => _db.execute(
      'INSERT INTO scrape_settings VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
      [key, jsonEncode(value)]);

  String createScrapeJob(String title) {
    final id = newUuidV4();
    _db.execute('INSERT INTO scrape_jobs(id,title,created_at) VALUES (?,?,?)',
        [id, title, NasLibraryDatabase._now()]);
    return id;
  }

  String enqueueScrapeTask(
      List<String> jobs, String kind, String key, Map<String, dynamic> payload,
      {bool refresh = false}) {
    final active = _db.select(
        "SELECT id FROM scrape_tasks WHERE task_key=? AND status IN ('pending','running','retry')",
        [key]);
    String? id = active.isEmpty ? null : active.first['id'] as String;
    if (id == null && !refresh) {
      final complete = _db.select(
          "SELECT id FROM scrape_tasks WHERE task_key=? AND status='done' ORDER BY created_at DESC LIMIT 1",
          [key]);
      if (complete.isNotEmpty) id = complete.first['id'] as String;
    }
    if (id == null) {
      id = newUuidV4();
      _db.execute(
          'INSERT INTO scrape_tasks(id,task_key,kind,payload,created_at,updated_at) VALUES (?,?,?,?,?,?)',
          [
            id,
            key,
            kind,
            jsonEncode({...payload, 'refresh': refresh, 'generation': id}),
            NasLibraryDatabase._now(),
            NasLibraryDatabase._now()
          ]);
    }
    for (final job in jobs) {
      _db.execute(
          'INSERT OR IGNORE INTO scrape_job_tasks VALUES (?,?)', [job, id]);
      final descendants = _db.select('''WITH RECURSIVE children(id) AS (
        SELECT child_id FROM scrape_task_children WHERE parent_id=?
        UNION SELECT c.child_id FROM scrape_task_children c JOIN children ON c.parent_id=children.id
      ) SELECT id FROM children''', [id]);
      for (final child in descendants) {
        _db.execute('INSERT OR IGNORE INTO scrape_job_tasks VALUES (?,?)',
            [job, child['id']]);
      }
    }
    return id;
  }

  void linkScrapeChild(String parent, String child) {
    if (parent == child) throw ArgumentError('采集分页形成循环');
    _db.execute('INSERT OR IGNORE INTO scrape_task_children VALUES (?,?)',
        [parent, child]);
  }

  List<String> scrapeTaskJobs(String id) => _db
      .select('SELECT job_id FROM scrape_job_tasks WHERE task_id=?', [id])
      .map((r) => r['job_id'] as String)
      .toList();

  Map<String, dynamic> _scrapeTask(Row row) => {
        ...row,
        'payload': jsonDecode(row['payload'] as String),
        'result':
            row['result'] == null ? null : jsonDecode(row['result'] as String),
        'conflicts': jsonDecode(row['conflicts'] as String),
      };

  Map<String, dynamic>? scrapeTask(String id) {
    final rows = _db.select('SELECT * FROM scrape_tasks WHERE id=?', [id]);
    return rows.isEmpty ? null : _scrapeTask(rows.single);
  }

  Map<String, dynamic>? claimScrapeTask() {
    final rows = _db.select('''SELECT t.* FROM scrape_tasks t
      WHERE t.status IN ('pending','retry') AND t.next_at<=?
        AND EXISTS(SELECT 1 FROM scrape_job_tasks jt JOIN scrape_jobs j ON j.id=jt.job_id
          WHERE jt.task_id=t.id AND j.paused=0)
      ORDER BY t.created_at,t.rowid LIMIT 1''',
        [DateTime.now().millisecondsSinceEpoch]);
    if (rows.isEmpty) return null;
    final id = rows.single['id'] as String;
    _db.execute(
        "UPDATE scrape_tasks SET status='running',attempts=attempts+1,updated_at=? WHERE id=?",
        [NasLibraryDatabase._now(), id]);
    return scrapeTask(id);
  }

  void finishScrapeTask(String id, String status,
      {String? error,
      int nextAt = 0,
      Map<String, dynamic>? result,
      List<Object?>? conflicts}) {
    if(status=='pending'){
      _db.execute("UPDATE scrape_tasks SET attempts=MAX(0,attempts-1) WHERE id=? AND status='running'",[id]);
    }
    _db.execute(
        '''UPDATE scrape_tasks SET status=?,error=?,next_at=?,
      result=COALESCE(?,result),conflicts=COALESCE(?,conflicts),updated_at=? WHERE id=?''',
        [
          status,
          error,
          nextAt,
          result == null ? null : jsonEncode(result),
          conflicts == null ? null : jsonEncode(conflicts),
          NasLibraryDatabase._now(),
          id
        ]);
  }

  void pauseScrapeJob(String id, bool paused) => _db.execute(
      'UPDATE scrape_jobs SET paused=? WHERE id=?', [paused ? 1 : 0, id]);

  void retryScrapeJob(String id) {
    _db.execute(
        '''UPDATE scrape_tasks SET status='pending',attempts=0,error=NULL,next_at=0
      WHERE id IN (SELECT task_id FROM scrape_job_tasks WHERE job_id=?)
        AND status IN ('failed','partial','review','retry')
        AND NOT EXISTS(SELECT 1 FROM scrape_tasks active WHERE active.task_key=scrape_tasks.task_key
          AND active.id!=scrape_tasks.id AND active.status IN ('pending','running','retry'))''',
        [id]);
    pauseScrapeJob(id, false);
  }

  List<Map<String, dynamic>> scrapeJobs({int offset = 0}) => _db
      .select('''
    SELECT j.*,count(t.id) AS total,
      SUM(CASE WHEN t.status='done' THEN 1 ELSE 0 END) AS completed,
      SUM(CASE WHEN t.status IN ('failed','partial','review') THEN 1 ELSE 0 END) AS attention,
      SUM(CASE WHEN t.status IN ('pending','running','retry') THEN 1 ELSE 0 END) AS remaining
    FROM scrape_jobs j LEFT JOIN scrape_job_tasks jt ON jt.job_id=j.id
    LEFT JOIN scrape_tasks t ON t.id=jt.task_id
    GROUP BY j.id ORDER BY j.created_at DESC,j.rowid DESC LIMIT 30 OFFSET ?''',
          [offset])
      .map((r) => Map<String, dynamic>.from(r))
      .toList();

  Map<String, dynamic>? scrapeJob(String id, {int offset = 0}) {
    final rows = _db.select('SELECT * FROM scrape_jobs WHERE id=?', [id]);
    if (rows.isEmpty) return null;
    final tasks = _db.select(
        '''SELECT t.* FROM scrape_tasks t JOIN scrape_job_tasks jt ON jt.task_id=t.id
      WHERE jt.job_id=? ORDER BY CASE t.status WHEN 'running' THEN 0 WHEN 'review' THEN 1
      WHEN 'failed' THEN 2 WHEN 'partial' THEN 3 ELSE 4 END,t.created_at,t.rowid LIMIT 50 OFFSET ?''',
        [id, offset]);
    final counts = {
      for (final r in _db.select(
          '''SELECT status,count(*) AS n FROM scrape_tasks t
      JOIN scrape_job_tasks jt ON jt.task_id=t.id WHERE jt.job_id=? GROUP BY status''',
          [id]))
        r['status'] as String: r['n']
    };
    return {
      ...rows.single,
      'counts': counts,
      'items': tasks.map((row) {
        final payload = jsonDecode(row['payload'] as String) as Map;
        return {
          'id': row['id'],
          'kind': row['kind'],
          'status': row['status'],
          'attempts': row['attempts'],
          'nextAt': row['next_at'],
          'error': row['error'],
          'payload': {
            for (final key in ['name', 'movieId', 'url'])
              if (payload.containsKey(key)) key: payload[key]
          },
          'conflicts': jsonDecode(row['conflicts'] as String),
          'updatedAt': row['updated_at']
        };
      }).toList(),
      'offset': offset,
      'total': counts.values.fold<int>(0, (sum, n) => sum + (n as int))
    };
  }

  List<String> scrapeMovieTargets(
      {String? categoryId, List<String>? movieIds}) {
    if (movieIds != null) {
      final ids = movieIds.toSet().toList();
      if (ids.isEmpty || ids.length > 3000)
        throw ArgumentError('请选择 1～3000 部影片');
      for (final id in ids) {
        if (_db.select(
            "SELECT id FROM movies WHERE id=? AND lifecycle_state='active'",
            [id]).isEmpty) throw ArgumentError('影片不存在或已移除');
      }
      return ids;
    }
    if (categoryId != null &&
        _db.select('SELECT id FROM library_categories WHERE id=?',
            [categoryId]).isEmpty) throw ArgumentError('分类不存在');
    return _db
        .select(
            "SELECT id FROM movies WHERE lifecycle_state='active' ${categoryId == null ? '' : 'AND category_id=?'} ORDER BY id",
            [if (categoryId != null) categoryId])
        .map((r) => r['id'] as String)
        .toList();
  }

  String scrapeMovieCode(String movieId) {
    final movie = findMovieForAdmin(movieId);
    if (movie == null) throw ArgumentError('影片已移除');
    if ((movie.catalogNumber ?? '').trim().isNotEmpty) {
      final code = _scrapeCodes(movie.catalogNumber!).toList();
      if (code.length == 1) return code.single;
      throw ArgumentError('影片番号无效，请编辑番号后重试');
    }
    final candidates = <String>{};
    for (final row in _db.select(
        'SELECT relative_path FROM episodes WHERE movie_id=?', [movieId])) {
      final pieces =
          (row['relative_path'] as String).replaceAll('\\', '/').split('/');
      candidates.addAll(_scrapeCodes(pieces.last));
      if (pieces.length > 1)
        candidates.addAll(_scrapeCodes(pieces[pieces.length - 2]));
    }
    if (candidates.isEmpty) candidates.addAll(_scrapeCodes(movie.title));
    if (candidates.length != 1)
      throw ArgumentError(
          candidates.isEmpty ? '未识别到番号，请编辑影片番号后重试' : '文件或分集包含多个番号，请指定影片番号后重试');
    return candidates.single;
  }

  void markScrapeManual(String kind, String id, Iterable<String> fields) {
    for (final field in fields) {
      _db.execute(
          '''INSERT INTO scrape_fields(kind,entity_id,field,manual,updated_at) VALUES (?,?,?,1,?)
        ON CONFLICT(kind,entity_id,field) DO UPDATE SET manual=1,updated_at=excluded.updated_at''',
          [kind, id, field, NasLibraryDatabase._now()]);
    }
  }

  bool scrapeFieldAllowed(
      String kind, String id, String field, Object? current, Object? proposed,
      {bool overwrite = false, bool scannedTitle = false}) {
    if (proposed == null || proposed == '' || proposed == '[]') return false;
    if (overwrite) return true;
    if (kind == 'actor' && actorHasMdcngSource(id) &&
        current != null && current != '' && current != '[]') return false;
    final source = _db.select(
        'SELECT value,manual FROM scrape_fields WHERE kind=? AND entity_id=? AND field=?',
        [kind, id, field]);
    if (source.isNotEmpty && source.single['manual'] == 1) return false;
    if (kind == 'movie') {
      final names = {
        'original_title': 'originalTitle',
        'catalog_number': 'catalogNumber',
        'poster_file_name': 'poster',
        'publisher_id': 'publisher'
      };
      if (_db.select(
          "SELECT 1 FROM movie_metadata_field_sources WHERE movie_id=? AND field_key=? AND source_kind='manual'",
          [id, names[field] ?? field]).isNotEmpty) return false;
    }
    return current == null ||
        current == '' ||
        current == '[]' ||
        scannedTitle ||
        (source.isNotEmpty && source.single['value'] == jsonEncode(current));
  }

  void recordScrapeField(String kind, String id, String field, Object? value) =>
      _db.execute('''
    INSERT INTO scrape_fields(kind,entity_id,field,value,manual,updated_at) VALUES (?,?,?,?,0,?)
    ON CONFLICT(kind,entity_id,field) DO UPDATE SET value=excluded.value,manual=0,updated_at=excluded.updated_at''',
          [kind, id, field, jsonEncode(value), NasLibraryDatabase._now()]);

  String scrapeEntity(Map<String, dynamic> entity) {
    final kind = entity['kind'] as String;
    if (!['actor', 'company'].contains(kind) || entity['provisional'] == true)
      throw ArgumentError('来源身份需要核对');
    final key = entity['id'] as String;
    final rows = _db.select(
        'SELECT entity_id FROM scrape_sources WHERE source_key=?', [key]);
    if (rows.isNotEmpty) {
      final id = rows.single['entity_id'] as String;
      if (kind == 'actor' ? findActor(id) != null : findPublisher(id) != null) {
        if ((kind == 'actor'
                ? findActor(id)!.archivedAt
                : findPublisher(id)!.archivedAt) !=
            null) throw ArgumentError('来源对应的档案已归档，请先在资料管理中恢复');
        return id;
      }
      _db.execute('DELETE FROM scrape_sources WHERE source_key=?', [key]);
    }
    final name = entity['name'] as String;
    final matches = kind == 'actor'
        ? findActorsByExactNames([name, ...List<String>.from(entity['aliases'] as List? ?? const [])],
            includeArchived: true)
        : const <NasActor>[];
    if (matches.length > 1 || matches.any((actor) => actor.archivedAt != null) ||
        (matches.length == 1 && _db.select(
          "SELECT 1 FROM scrape_sources WHERE kind='actor' AND entity_id=? AND source_key!=? LIMIT 1",
          [matches.single.id, key]).isNotEmpty)) {
      throw ArgumentError('演员“$name”存在重名或已归档档案，请核对并选择正确演员；已归档的档案需先恢复');
    }
    final id = kind == 'actor'
        ? (matches.isEmpty ? createActor(stageName: name).id : matches.single.id)
        : createPublisher(displayName: name).id;
    _db.execute(
        'INSERT INTO scrape_sources(source_key,kind,entity_id,source_url,updated_at) VALUES (?,?,?,?,?)',
        [key, kind, id, entity['url'], NasLibraryDatabase._now()]);
    if (matches.isEmpty) {
      recordScrapeField(
          kind, id, kind == 'actor' ? 'stage_name' : 'display_name', name);
    }
    return id;
  }

  /// MDCNG 负责已有资料；内置来源仍可补充空白，不能自动接管姓名或头像。
  bool actorHasMdcngSource(String id) => _db.select(
      'SELECT 1 FROM mdcng_actor_source_links WHERE actor_id=? LIMIT 1', [id]).isNotEmpty;

  /// 只根据影片保存的出演名单补关联，绝不将演员名字当作影片搜索条件。
  int reconcileScrapeActorMovies([String? actorId]) {
    final actors = {for (final actor in listActors(includeArchived: true)) actor.id: actor};
    if (actors.isEmpty || (actorId != null &&
        (actors[actorId] == null || actors[actorId]!.archivedAt != null))) return 0;
    final names = <String, Set<String>>{};
    void addName(String id, String? value) {
      final name = value?.trim().toLowerCase();
      if (name != null && name.isNotEmpty) names.putIfAbsent(name, () => {}).add(id);
    }
    for (final actor in actors.values) {
      for (final name in [actor.stageName, actor.originalName, actor.translatedName, ...actor.aliases]) {
        addName(actor.id, name);
      }
    }
    for (final row in _db.select('SELECT actor_id,source_name FROM mdcng_actor_source_links')) {
      if (actors.containsKey(row['actor_id'])) addName(row['actor_id'] as String, row['source_name'] as String);
    }
    final sourceKeys = <String, Set<String>>{}, sourceUrls = <String, Set<String>>{};
    final sourceActors = <String>{};
    for (final row in _db.select("SELECT source_key,source_url,entity_id FROM scrape_sources WHERE kind='actor'")) {
      final id = row['entity_id'] as String;
      if (!actors.containsKey(id)) continue;
      sourceActors.add(id);
      sourceKeys.putIfAbsent(row['source_key'] as String, () => {}).add(id);
      sourceUrls.putIfAbsent(row['source_url'] as String, () => {}).add(id);
    }
    var count = 0;
    for (final row in _db.select('''SELECT p.movie_id,p.metadata FROM scrape_movie_profiles p
      JOIN movies m ON m.id=p.movie_id WHERE m.lifecycle_state='active'
      AND NOT EXISTS(SELECT 1 FROM movie_metadata_field_sources f
        WHERE f.movie_id=m.id AND f.field_key='actors' AND f.source_kind='manual')''')) {
      final movieId = row['movie_id'] as String;
      final linked = _db.select('SELECT actor_id FROM movie_actor_links WHERE movie_id=?', [movieId])
          .map((row) => row['actor_id'] as String).toSet();
      if (actorId != null && linked.contains(actorId)) continue;
      final metadata = jsonDecode(row['metadata'] as String) as Map;
      final cast = (metadata['actorSources'] ?? metadata['actors']) as List? ?? const [];
      for (final entry in cast.whereType<Map>()) {
        final url = entry['url'] as String?;
        var key = entry['provisional'] == true ? null : entry['id'] as String?;
        // 旧版影片只保存演员 URL，按相同规则恢复 WhatsAV 稳定身份。
        final uri = url == null ? null : Uri.tryParse(url);
        if (key == null && uri != null && uri.host == 'whatsav.net' &&
            uri.pathSegments.length == 3 && uri.pathSegments[1] == 'actor') {
          key = 'actor_${sha256Hex(jsonEncode(['whatsav', 'actor', 'actor', uri.pathSegments.last])).substring(0, 32)}';
        }
        final mapped = <String>{...?sourceKeys[key], ...?sourceUrls[url]};
        final matches = mapped.isNotEmpty ? mapped
            : names[(entry['name'] as String? ?? '').trim().toLowerCase()] ?? <String>{};
        if (matches.length != 1) continue;
        final resolved = matches.single;
        if (actors[resolved]!.archivedAt != null || linked.contains(resolved) ||
            (actorId != null && actorId != resolved)) continue;
        if (mapped.isEmpty && key != null && url != null) {
          if (sourceActors.contains(resolved)) continue;
          _db.execute('''INSERT INTO scrape_sources(source_key,kind,entity_id,source_url,updated_at)
            VALUES (?,'actor',?,?,?) ON CONFLICT(source_key) DO UPDATE SET
            kind='actor',entity_id=excluded.entity_id,source_url=excluded.source_url,
            profile=NULL,updated_at=excluded.updated_at''',
            [key, resolved, url, NasLibraryDatabase._now()]);
          sourceKeys[key] = {resolved};
          sourceUrls.putIfAbsent(url, () => {}).add(resolved);
          sourceActors.add(resolved);
        }
        linkScrapeActors(movieId, [resolved]);
        linked.add(resolved);
        count++;
      }
    }
    return count + reconcileSupplementCast(actorId: actorId);
  }

  void saveScrapeProfile(String key, Map<String, dynamic> result) =>
      _db.execute(
          'UPDATE scrape_sources SET profile=?,updated_at=? WHERE source_key=?',
          [jsonEncode(result), NasLibraryDatabase._now(), key]);

  List<Map<String, dynamic>> scrapeProfiles(String kind, String id) =>
      _db.select(
          'SELECT source_key,source_url,profile,updated_at FROM scrape_sources WHERE kind=? AND entity_id=?',
          [kind, id]).map((r) {
        final result = r['profile'] == null
            ? null
            : jsonDecode(r['profile'] as String) as Map;
        return {
          'source': 'whatsav',
          'url': r['source_url'],
          'updatedAt': r['updated_at'],
          'profile': result?['profile'],
          'collectedWorks': kind == 'actor'
              ? _db.select(
                  'SELECT count(*) AS n FROM scrape_actor_works WHERE actor_id=?',
                  [id]).single['n']
              : null
        };
      }).toList();

  void saveScrapeMovieProfile(String id, Map<String, dynamic> metadata) =>
      _db.execute('''
    INSERT INTO scrape_movie_profiles VALUES (?,?,?) ON CONFLICT(movie_id) DO UPDATE
    SET metadata=excluded.metadata,updated_at=excluded.updated_at''',
          [id, jsonEncode(metadata), NasLibraryDatabase._now()]);

  Map<String, dynamic>? scrapeMovieProfile(String id) {
    final rows = _db.select(
        'SELECT metadata FROM scrape_movie_profiles WHERE movie_id=?', [id]);
    return rows.isEmpty
        ? null
        : jsonDecode(rows.single['metadata'] as String) as Map<String, dynamic>;
  }

  List<Map<String, dynamic>> movieCompanies(String movieId) => _db
      .select('''
    SELECT p.id,p.display_name AS name,l.role FROM movie_company_links l
    JOIN publishers p ON p.id=l.company_id WHERE l.movie_id=? ORDER BY l.role,p.display_name''',
          [movieId])
      .map((r) => Map<String, dynamic>.from(r))
      .toList();

  List<String> companyRoles(String id) => _db
      .select(
          'SELECT DISTINCT role FROM movie_company_links WHERE company_id=? ORDER BY role',
          [id])
      .map((r) => r['role'] as String)
      .toList();

  List<Map<String, dynamic>> applyScrapeFields(
      String kind, String id, Map<String, Object?> values,
      {Set<String> overwrite = const {}}) {
    final table =
        {'movie': 'movies', 'actor': 'actors', 'company': 'publishers'}[kind]!;
    final current = _db.select('SELECT * FROM $table WHERE id=?', [id]);
    if (current.isEmpty) throw ArgumentError('目标资料已移除');
    final conflicts = <Map<String, dynamic>>[];
    for (final entry in values.entries) {
      final field = entry.key, value = entry.value;
      if (value == null || value == '' || value == '[]') continue;
      final previous = current.single[field];
      if (previous == value) continue;
      if (kind == 'actor' && actorHasMdcngSource(id) && !overwrite.contains(field)) {
        final date = current.single['birth_date'], month = current.single['birth_month'];
        if (field == 'birth_date' && month is String && month.isNotEmpty &&
            value is String && !value.startsWith(month)) continue;
        if (field == 'birth_month' && date is String && date.isNotEmpty &&
            value is String && !date.startsWith(value)) continue;
      }
      if (kind == 'actor' && actorHasMdcngSource(id) &&
          previous != null && previous != '' && previous != '[]' &&
          !overwrite.contains(field)) continue;
      if (scrapeFieldAllowed(kind, id, field, previous, value,
          overwrite: overwrite.contains(field),
          scannedTitle: kind == 'movie' &&
              field == 'title' &&
              hasDefaultScannedTitle(id))) {
        _db.execute('UPDATE $table SET $field=?,updated_at=? WHERE id=?',
            [value, NasLibraryDatabase._now(), id]);
        recordScrapeField(kind, id, field, value);
      } else {
        conflicts.add({
          'kind': kind,
          'entityId': id,
          'field': field,
          'current': previous,
          'proposed': value
        });
      }
    }
    return conflicts;
  }

  void linkScrapeCompanies(
      String movieId, List<Map<String, dynamic>> entities) {
    for (final entity in entities) {
      if (entity['kind'] != 'company' || entity['provisional'] == true)
        continue;
      final id = scrapeEntity(entity), role = entity['role'];
      if (!['maker', 'label', 'distributor'].contains(role)) continue;
      _db.execute('INSERT OR IGNORE INTO movie_company_links VALUES (?,?,?)',
          [movieId, id, role]);
    }
  }

  void linkScrapeActors(String movieId, Iterable<String> actorIds) {
    if (_db.select(
        "SELECT 1 FROM movie_metadata_field_sources WHERE movie_id=? AND field_key='actors' AND source_kind='manual'",
        [movieId]).isNotEmpty) return;
    for (final actorId in actorIds) {
      _db.execute('INSERT OR IGNORE INTO movie_actor_links VALUES (?,?)',
          [movieId, actorId]);
    }
  }

  void saveScrapeWorks(String actorId, List<dynamic> works) {
    for (final value in works) {
      final work = Map<String, dynamic>.from(value as Map);
      _db.execute(
          '''INSERT INTO scrape_actor_works VALUES (?,?,?,?,?) ON CONFLICT(actor_id,source_id)
        DO UPDATE SET code=excluded.code,title=excluded.title,url=excluded.url''',
          [
            actorId,
            work['sourceId'],
            work['code'],
            work['title'],
            work['url']
          ]);
      final code = work['code'];
      if (code is! String) continue;
      final rows = _db.select(
          "SELECT id FROM movies WHERE catalog_number IS NOT NULL AND lifecycle_state='active' AND lower(replace(replace(replace(catalog_number,'-',''),'_',''),' ',''))=?",
          [_normalizeCatalogNumber(code)]);
      for (final row in rows) linkScrapeActors(row['id'] as String, [actorId]);
    }
  }

  void addScrapeGallery(String movieId, String fileName) {
    if (_db.select(
        'SELECT id FROM movie_carousel_images WHERE movie_id=? AND file_name=?',
        [movieId, fileName]).isEmpty) {
      _db.execute(
          'INSERT INTO movie_carousel_images(id,movie_id,file_name,created_at) VALUES (?,?,?,?)',
          [newUuidV4(), movieId, fileName, NasLibraryDatabase._now()]);
    }
  }

  void resolveScrapeConflicts(String taskId, List<String> fields,
      {Map<String, String> actorMappings = const {}}) {
    final task = scrapeTask(taskId);
    if (task == null || task['status'] != 'review')
      throw ArgumentError('任务没有可审核结果');
    if ((task['payload'] as Map)['supplementOnly'] == true) {
      resolveSupplementTask(task, fields, actorMappings);
      return;
    }
    final conflicts = (task['conflicts'] as List).whereType<Map>().toList();
    final allowed = conflicts
        .where((c) => c['field'] != 'identity')
        .map((c) => c['field'])
        .toSet();
    if (fields.any((field) => !allowed.contains(field)))
      throw ArgumentError('审核字段无效');
    transaction(() {
      for (final mapping in actorMappings.entries) {
        final choices = conflicts.where((conflict) => conflict['field'] == 'identity' &&
            conflict['sourceKey'] == mapping.key).toList();
        final actor = findActor(mapping.value);
        if (choices.isEmpty || actor == null || actor.archivedAt != null ||
            !choices.every((choice) => (choice['candidates'] as List? ?? const [])
                .whereType<Map>().any((candidate) => candidate['id'] == actor.id))) {
          throw ArgumentError('演员选择已失效，请重新刮削核对');
        }
        final existing = _db.select('SELECT entity_id FROM scrape_sources WHERE source_key=?', [mapping.key]);
        if (existing.isNotEmpty && existing.single['entity_id'] != actor.id) {
          throw ArgumentError('来源已绑定其他演员，请重新刮削核对');
        }
        _db.execute('''INSERT OR IGNORE INTO scrape_sources
          (source_key,kind,entity_id,source_url,updated_at) VALUES (?,'actor',?,?,?)''',
          [mapping.key, actor.id, choices.first['sourceUrl'], NasLibraryDatabase._now()]);
        reconcileScrapeActorMovies(actor.id);
      }
      for (final conflict
          in conflicts.where((c) => fields.contains(c['field']))) {
        final kind = conflict['kind'] as String,
            id = conflict['entityId'] as String,
            field = conflict['field'] as String;
        final table = {
          'movie': 'movies',
          'actor': 'actors',
          'company': 'publishers'
        }[kind]!;
        final rows = _db.select('SELECT $field FROM $table WHERE id=?', [id]);
        if (rows.isEmpty || rows.single[field] != conflict['current'])
          throw ArgumentError('资料已变更，请重新刮削并核对后再覆盖');
        applyScrapeFields(kind, id, {field: conflict['proposed']},
            overwrite: {field});
      }
      final warnings = (task['result'] as Map?)?['warnings'] as List? ?? [];
      final identities = conflicts.where((conflict) => conflict['field'] == 'identity' &&
          !actorMappings.containsKey(conflict['sourceKey'])).toList();
      if (actorMappings.isNotEmpty && _db.select('''SELECT 1 FROM scrape_tasks
          WHERE task_key=? AND id!=? AND status IN ('pending','running','retry')''',
          [task['task_key'], taskId]).isNotEmpty) {
        throw ArgumentError('同一来源正在另一个任务中采集，请完成后重新核对');
      }
      finishScrapeTask(taskId, actorMappings.isNotEmpty ? 'pending'
          : identities.isNotEmpty ? 'review' : warnings.isEmpty ? 'done' : 'partial',
          conflicts: identities, error: identities.isNotEmpty
              ? '演员身份仍需核对，请选择正确演员；无候选时可导入 MDCNG 资料后重试'
              : warnings.isEmpty ? null : warnings.join('；'));
    });
  }
}

Set<String> _scrapeCodes(String value) {
  var text = value.toUpperCase();
  final result = <String>{};
  final fc2 = RegExp(r'(?<![A-Z0-9])FC2[\s_-]*(?:PPV[\s_-]*)?(\d{5,10})(?!\d)');
  for (final match in fc2.allMatches(text)) {
    result.add('FC2-PPV-${match[1]}');
  }
  text = text.replaceAll(fc2, ' ');
  for (final match
      in RegExp(r'(?<![A-Z0-9])([A-Z]{2,12})[\s_-]?(\d{2,7})(?!\d)')
          .allMatches(text)) {
    if (!{'HEVC', 'AVC', 'FHD', 'UHD', 'MP', 'CD', 'DISC', 'PART'}
        .contains(match[1])) result.add('${match[1]}-${match[2]}');
  }
  return result;
}
