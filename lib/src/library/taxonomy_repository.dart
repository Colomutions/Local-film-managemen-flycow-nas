import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';
import '../library_models.dart';
import 'library_values.dart';
import 'taxonomy_transfer.dart';

/// Owns category bindings, tag hierarchy and taxonomy transfers.
class NasTaxonomyRepository {
  NasTaxonomyRepository(
    this._connection, {
    required this.removeMovieIndex,
    required this.findMediaRoot,
    required this.findMovieForAdmin,
    required this.listMediaRoots,
    required this.transaction,
  });

  final Database Function() _connection;
  Database get _db => _connection();
  final NasRemovedMovieIndex Function(NasLibraryMovie movie) removeMovieIndex;
  final NasMediaRoot? Function(String mediaRootId) findMediaRoot;
  final NasLibraryMovie? Function(String movieId) findMovieForAdmin;
  final List<NasMediaRoot> Function() listMediaRoots;
  final T Function<T>(T Function() action) transaction;
  static const _categoryMovieCountSql = '''SELECT COUNT(*) FROM movies m
    WHERE m.category_id=c.id AND m.lifecycle_state='active'
      AND (m.entry_type='series' OR EXISTS(SELECT 1 FROM episodes e WHERE e.movie_id=m.id))''';

  List<NasLibraryCategory> listCategories() => _db
      .select('''SELECT c.*, ($_categoryMovieCountSql) AS movie_count
             FROM library_categories c ORDER BY c.name COLLATE NOCASE, c.id''')
      .map(_mapCategoryWithSources)
      .toList(growable: false);

  NasLibraryCategory? findCategory(String categoryId) {
    final rows = _db.select(
      '''SELECT c.*, ($_categoryMovieCountSql) AS movie_count
         FROM library_categories c WHERE c.id = ?''',
      [categoryId],
    );
    return rows.isEmpty ? null : _mapCategoryWithSources(rows.single);
  }

  List<NasCategoryMediaSource> mediaSourcesForCategory(String categoryId) {
    final rows = _db.select('''
      SELECT source.id, source.category_id, source.media_root_id,
             root.name AS source_name, source.relative_path,
             root.is_online, root.last_scanned_at
      FROM category_media_sources source
      JOIN media_roots root ON root.id = source.media_root_id
      WHERE source.category_id = ?
      ORDER BY root.name COLLATE NOCASE, source.relative_path COLLATE NOCASE, source.id
    ''', [categoryId]);
    return rows
        .map(
          (row) => NasCategoryMediaSource(
            id: row['id'] as String,
            categoryId: row['category_id'] as String,
            mediaRootId: row['media_root_id'] as String,
            sourceName: row['source_name'] as String,
            relativePath: row['relative_path'] as String,
            isOnline: (row['is_online'] as int) == 1,
            lastScannedAt: row['last_scanned_at'] as String?,
          ),
        )
        .toList(growable: false);
  }

  bool replaceCategoryMediaSources({
    required String categoryId,
    required List<NasCategoryMediaSourceInput> sources,
  }) {
    if (findCategory(categoryId) == null || sources.length > 32) return false;
    final normalized = <NasCategoryMediaSourceInput>[];
    for (final source in sources) {
      final relativePath = normalizeRelativePath(source.relativePath);
      if (relativePath == null || findMediaRoot(source.mediaRootId) == null) {
        return false;
      }
      normalized.add(NasCategoryMediaSourceInput(
        mediaRootId: source.mediaRootId,
        relativePath: relativePath,
      ));
    }
    if (normalized
            .map((source) => '${source.mediaRootId}:${source.relativePath}')
            .toSet()
            .length !=
        normalized.length) {
      return false;
    }
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute('DELETE FROM category_media_sources WHERE category_id = ?',
          [categoryId]);
      final timestamp = now();
      for (final source in normalized) {
        _db.execute('''
          INSERT INTO category_media_sources(
            id, category_id, media_root_id, relative_path, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?)
        ''', [
          newUuidV4(),
          categoryId,
          source.mediaRootId,
          source.relativePath,
          timestamp,
          timestamp,
        ]);
      }
      _db.execute(
        'UPDATE library_categories SET media_relative_path = ?, updated_at = ? WHERE id = ?',
        [
          normalized.isEmpty ? null : normalized.first.relativePath,
          timestamp,
          categoryId
        ],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return true;
  }

  bool hasCategoryName(String name, {String? excludingId}) {
    final normalized = normalizeTaxonomyName(name);
    return listCategories().any(
      (category) =>
          category.id != excludingId &&
          normalizeTaxonomyName(category.name) == normalized,
    );
  }

  NasLibraryCategory createCategory(String name,
      {String? mediaRelativePath, String? color}) {
    _requireTaxonomyName(name, '分类');
    if (hasCategoryName(name)) {
      throw ArgumentError.value(name, 'name', 'already exists');
    }
    final timestamp = now();
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
      [
        category.id,
        category.name,
        category.color,
        category.mediaRelativePath,
        category.createdAt,
        category.updatedAt
      ],
    );
    if (mediaRelativePath != null && listMediaRoots().isNotEmpty) {
      replaceCategoryMediaSources(
        categoryId: category.id,
        sources: [
          NasCategoryMediaSourceInput(
            mediaRootId: listMediaRoots().first.id,
            relativePath: mediaRelativePath,
          ),
        ],
      );
    }
    return findCategory(category.id)!;
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
    // 保存绑定不立即清理；分类扫描完成后统一移除退出扫描范围的旧索引。
    _db.execute(
      updateMediaRelativePath
          ? 'UPDATE library_categories SET name = ?, color = ?, media_relative_path = ?, updated_at = ? WHERE id = ?'
          : 'UPDATE library_categories SET name = ?, color = ?, updated_at = ? WHERE id = ?',
      updateMediaRelativePath
          ? [
              name,
              updateColor ? color : findCategory(categoryId)!.color,
              mediaRelativePath,
              now(),
              categoryId
            ]
          : [
              name,
              updateColor ? color : findCategory(categoryId)!.color,
              now(),
              categoryId
            ],
    );
    if (updateMediaRelativePath &&
        mediaRelativePath != null &&
        listMediaRoots().isNotEmpty) {
      replaceCategoryMediaSources(
        categoryId: categoryId,
        sources: [
          NasCategoryMediaSourceInput(
            mediaRootId: listMediaRoots().first.id,
            relativePath: mediaRelativePath,
          ),
        ],
      );
    }
    return findCategory(categoryId);
  }

  bool deleteCategory(String categoryId, {bool deleteMovies = false}) =>
      deleteCategoryWithIndexes(categoryId, deleteMovies: deleteMovies) != null;

  /// 原子删除分类和索引，返回仅供清理 NAS 内部图片副本的信息。
  List<NasRemovedMovieIndex>? deleteCategoryWithIndexes(String categoryId,
          {bool deleteMovies = false}) =>
      transaction(() {
        if (findCategory(categoryId) == null) return null;
        final removed = <NasRemovedMovieIndex>[];
        if (deleteMovies) {
          // 隐藏的归并来源也属于本分类，不能留下无分类的旧记录。
          final ids = _db.select(
              'SELECT id FROM movies WHERE category_id=?', [categoryId]);
          for (final row in ids) {
            removed
                .add(removeMovieIndex(findMovieForAdmin(row['id'] as String)!));
          }
        }
        _db.execute(
            'DELETE FROM library_categories WHERE id = ?', [categoryId]);
        return removed;
      });

  NasCategoryTaxonomyTransfer exportCategoryTaxonomy() {
    final conflicts = categoryTaxonomyViolations();
    if (conflicts.isNotEmpty) throw StateError(conflicts.join('\n'));
    return NasCategoryTaxonomyTransfer(
      categories: [
        for (final category in listCategories())
          NasTaxonomyCategoryDefinition(
              name: category.name, color: category.color),
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
        createCategory(
          definition.name,
          color:
              definition.color ?? randomImportColor(importCategoryColorOptions),
        );
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

  List<NasLibraryTag> listTags({int? level, bool includeArchived = false}) {
    final conditions = <String>[if (!includeArchived) 'archived_at IS NULL'];
    final parameters = <Object?>[];
    if (level != null) {
      conditions.add('level = ?');
      parameters.add(level);
    }
    return _db.select('''
      SELECT id, name, level, description, color, created_at, updated_at, archived_at
      FROM tags
      ${conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}'}
      ORDER BY level, name COLLATE NOCASE, id
    ''', parameters).map(_mapTag).toList(growable: false);
  }

  NasLibraryTag? findTag(String tagId) {
    final rows = _db.select('''
      SELECT id, name, level, description, color, created_at, updated_at, archived_at
      FROM tags WHERE id = ?
    ''', [tagId]);
    return rows.isEmpty ? null : _mapTag(rows.single);
  }

  NasLibraryTag? findActiveTagByName(String name) {
    final normalized = normalizeTaxonomyName(name);
    if (normalized.isEmpty) return null;
    final rows = _db.select('''
      SELECT id, name, level, description, color, created_at, updated_at, archived_at
      FROM tags WHERE normalized_name = ? AND archived_at IS NULL
    ''', [normalized]);
    return rows.length == 1 ? _mapTag(rows.single) : null;
  }

  bool hasTagName(String name, {String? excludingId}) {
    final rows = _db.select(
      'SELECT id FROM tags WHERE normalized_name = ?',
      [normalizeTaxonomyName(name)],
    );
    return rows.any((row) => row['id'] != excludingId);
  }

  NasLibraryTag createTag({
    required String name,
    required int level,
    String description = '',
    String? color,
    List<String> parentIds = const [],
  }) {
    _requireWritableTaxonomy();
    _requireTagInput(
      name: name,
      level: level,
      color: color,
      parentIds: parentIds,
    );
    if (hasTagName(name)) {
      throw ArgumentError.value(name, 'name', '标签名称已存在');
    }
    final timestamp = now();
    final tag = NasLibraryTag(
      id: newUuidV4(),
      name: name,
      level: level,
      description: description.trim(),
      color: color,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    _insertTag(tag);
    _replaceTagParents(tag.id, parentIds, timestamp);
    return tag;
  }

  NasLibraryTag? updateTag({
    required String tagId,
    required String name,
    required String description,
    String? color,
    required List<String> parentIds,
  }) {
    final current = findTag(tagId);
    if (current == null) return null;
    _requireWritableTaxonomy();
    _requireTagInput(
      name: name,
      level: current.level,
      color: color,
      parentIds: parentIds,
    );
    if (hasTagName(name, excludingId: tagId)) {
      throw ArgumentError.value(name, 'name', '标签名称已存在');
    }
    final timestamp = now();
    _db.execute('''
      UPDATE tags
      SET name = ?, normalized_name = ?, description = ?, color = ?, updated_at = ?
      WHERE id = ?
    ''', [
      name,
      normalizeTaxonomyName(name),
      description.trim(),
      color,
      timestamp,
      tagId,
    ]);
    _replaceTagParents(tagId, parentIds, timestamp);
    return findTag(tagId);
  }

  bool archiveTag(String tagId) {
    if (findTag(tagId) == null) return false;
    _requireWritableTaxonomy();
    _db.execute(
      'UPDATE tags SET archived_at = ?, updated_at = ? WHERE id = ?',
      [now(), now(), tagId],
    );
    return true;
  }

  bool deleteTag(String tagId) {
    final tag = findTag(tagId);
    if (tag == null) return false;
    _requireWritableTaxonomy();
    final movieLinks = _db.select(
      '''SELECT COUNT(*) AS count FROM movie_tag_links links
         JOIN movies m ON m.id = links.movie_id
         WHERE links.tag_id = ? AND m.lifecycle_state = 'active' ''',
      [tagId],
    ).single['count'] as int;
    final childLinks = _db.select(
      'SELECT COUNT(*) AS count FROM tag_parent_links WHERE parent_tag_id = ?',
      [tagId],
    ).single['count'] as int;
    if (movieLinks > 0 || childLinks > 0) {
      throw StateError('标签仍有关联影片或子级，只能归档');
    }
    _db.execute('''
      DELETE FROM movie_tag_links
      WHERE tag_id = ? AND movie_id IN (
        SELECT id FROM movies WHERE lifecycle_state = 'merged'
      )
    ''', [tagId]);
    _db.execute('DELETE FROM tag_parent_links WHERE child_tag_id = ?', [tagId]);
    _db.execute('DELETE FROM tags WHERE id = ?', [tagId]);
    return true;
  }

  NasTagOverview tagOverview() {
    final row = _db.select('''
      SELECT COUNT(*) AS total,
             SUM(CASE WHEN level = 1 THEN 1 ELSE 0 END) AS level_one,
             SUM(CASE WHEN level = 2 THEN 1 ELSE 0 END) AS level_two,
             SUM(CASE WHEN level = 3 THEN 1 ELSE 0 END) AS level_three
      FROM tags
    ''').single;
    final links =
        _db.select('''SELECT COUNT(*) AS count FROM movie_tag_links links
          JOIN movies m ON m.id = links.movie_id
          WHERE m.lifecycle_state = 'active' ''').single['count'] as int;
    return NasTagOverview(
      total: row['total'] as int,
      levelOne: (row['level_one'] as int?) ?? 0,
      levelTwo: (row['level_two'] as int?) ?? 0,
      levelThree: (row['level_three'] as int?) ?? 0,
      movieLinks: links,
    );
  }

  List<NasTagDirectoryRoot> tagDirectory({String query = ''}) {
    final tags = listTags();
    final byId = {for (final tag in tags) tag.id: tag};
    final childrenByParent = _tagChildrenByParent();
    final counts = _tagMovieCounts();
    final normalized = query.trim().toLowerCase();
    final roots = tags.where((tag) => tag.level == 1).toList(growable: false);
    return roots
        .map((root) {
          final children = (childrenByParent[root.id] ?? const <String>[])
              .map((id) => byId[id])
              .whereType<NasLibraryTag>()
              .where((tag) => tag.level == 2)
              .map((tag) => NasTagDirectoryChild(
                    tag: tag,
                    movieCount: counts[tag.id] ?? 0,
                  ))
              .toList(growable: false);
          if (normalized.isNotEmpty &&
              !root.name.toLowerCase().contains(normalized) &&
              !children.any(
                  (item) => item.tag.name.toLowerCase().contains(normalized))) {
            return null;
          }
          final visibleChildren = normalized.isNotEmpty &&
                  !root.name.toLowerCase().contains(normalized)
              ? children
                  .where((item) =>
                      item.tag.name.toLowerCase().contains(normalized))
                  .toList(growable: false)
              : children;
          return NasTagDirectoryRoot(
            tag: root,
            movieCount: counts[root.id] ?? 0,
            children: visibleChildren,
          );
        })
        .whereType<NasTagDirectoryRoot>()
        .toList(growable: false);
  }

  /// 仅返回活跃的一、二级标签及进入二级时需要的一级路径上下文。
  List<NasMovieSearchTagDirectoryRoot> movieSearchTagDirectory({
    String query = '',
  }) {
    final queryLike = '%${query.trim()}%';
    final rows = _db.select('''
      WITH RECURSIVE descendants(ancestor_id, descendant_id) AS (
        SELECT id, id FROM tags WHERE archived_at IS NULL
        UNION
        SELECT descendants.ancestor_id, links.child_tag_id
        FROM descendants
        JOIN tag_parent_links links ON links.parent_tag_id = descendants.descendant_id
        JOIN tags child ON child.id = links.child_tag_id
        WHERE child.archived_at IS NULL
      ),
      tag_counts AS (
        SELECT descendants.ancestor_id AS tag_id,
                COUNT(DISTINCT CASE WHEN movie.lifecycle_state = 'active'
                  THEN movie_tag_links.movie_id END) AS movie_count
        FROM descendants
        LEFT JOIN movie_tag_links ON movie_tag_links.tag_id = descendants.descendant_id
        LEFT JOIN movies movie ON movie.id = movie_tag_links.movie_id
        GROUP BY descendants.ancestor_id
      )
      SELECT root.id AS root_id, root.name AS root_name,
             COALESCE(root_count.movie_count, 0) AS root_movie_count,
             child.id AS child_id, child.name AS child_name,
             COALESCE(child_count.movie_count, 0) AS child_movie_count,
             (
               SELECT COUNT(*) FROM tag_parent_links third_link
               JOIN tags third ON third.id = third_link.child_tag_id
               WHERE third_link.parent_tag_id = child.id
                 AND third.level = 3 AND third.archived_at IS NULL
             ) AS third_level_count
      FROM tags root
      LEFT JOIN tag_parent_links child_link ON child_link.parent_tag_id = root.id
      LEFT JOIN tags child ON child.id = child_link.child_tag_id
        AND child.level = 2 AND child.archived_at IS NULL
      LEFT JOIN tag_counts root_count ON root_count.tag_id = root.id
      LEFT JOIN tag_counts child_count ON child_count.tag_id = child.id
      WHERE root.level = 1 AND root.archived_at IS NULL
        AND (? = '%%' OR lower(root.name) LIKE lower(?)
             OR lower(COALESCE(child.name, '')) LIKE lower(?))
      ORDER BY root.name COLLATE NOCASE, root.id, child.name COLLATE NOCASE, child.id
    ''', [queryLike, queryLike, queryLike]);
    final rootOrder = <String>[];
    final roots = <String, NasLibraryTag>{};
    final rootCounts = <String, int>{};
    final children = <String, List<NasMovieSearchTagDirectoryChild>>{};
    for (final row in rows) {
      final rootId = row['root_id'] as String;
      if (!roots.containsKey(rootId)) {
        rootOrder.add(rootId);
        roots[rootId] = NasLibraryTag(
          id: rootId,
          name: row['root_name'] as String,
          level: 1,
          createdAt: '',
          updatedAt: '',
        );
        rootCounts[rootId] = row['root_movie_count'] as int;
      }
      final childId = row['child_id'] as String?;
      if (childId == null) continue;
      children.putIfAbsent(rootId, () => []).add(
            NasMovieSearchTagDirectoryChild(
              tag: NasLibraryTag(
                id: childId,
                name: row['child_name'] as String,
                level: 2,
                createdAt: '',
                updatedAt: '',
              ),
              movieCount: row['child_movie_count'] as int,
              thirdLevelCount: row['third_level_count'] as int,
            ),
          );
    }
    return rootOrder
        .map(
          (id) => NasMovieSearchTagDirectoryRoot(
            tag: roots[id]!,
            movieCount: rootCounts[id]!,
            children: children[id] ?? const [],
          ),
        )
        .toList(growable: false);
  }

  /// 固定 30 条读取某个二级标签的直属三级标签，不展开其余目录。
  NasMovieSearchThirdLevelTagPage movieSearchThirdLevelTags({
    required String parentTagId,
    String query = '',
    int page = 1,
    int pageSize = 30,
  }) {
    final parent = findTag(parentTagId);
    if (parent == null || parent.archivedAt != null || parent.level != 2) {
      throw ArgumentError('二级标签不存在或不可用');
    }
    if (page < 1 || pageSize != 30) {
      throw ArgumentError('三级标签分页参数无效');
    }
    final queryLike = '%${query.trim()}%';
    const from = '''
      FROM tag_parent_links link
      JOIN tags child ON child.id = link.child_tag_id
      LEFT JOIN movie_tag_links ON movie_tag_links.tag_id = child.id
      LEFT JOIN movies linked_movie ON linked_movie.id = movie_tag_links.movie_id
      WHERE link.parent_tag_id = ? AND child.level = 3
        AND child.archived_at IS NULL
        AND (? = '%%' OR lower(child.name) LIKE lower(?))
    ''';
    final parameters = <Object?>[parentTagId, queryLike, queryLike];
    final total = _db
        .select('SELECT COUNT(DISTINCT child.id) AS count $from', parameters)
        .single['count'] as int;
    final offset = (page - 1) * pageSize;
    final rows = _db.select('''
      SELECT child.id, child.name,
             COUNT(DISTINCT CASE WHEN linked_movie.lifecycle_state = 'active'
               THEN movie_tag_links.movie_id END) AS movie_count
      $from
      GROUP BY child.id
      ORDER BY child.name COLLATE NOCASE, child.id
      LIMIT ? OFFSET ?
    ''', [...parameters, pageSize, offset]);
    return NasMovieSearchThirdLevelTagPage(
      items: rows
          .map(
            (row) => NasTagChildSummary(
              tag: NasLibraryTag(
                id: row['id'] as String,
                name: row['name'] as String,
                level: 3,
                createdAt: '',
                updatedAt: '',
              ),
              movieCount: row['movie_count'] as int,
            ),
          )
          .toList(growable: false),
      number: page,
      size: pageSize,
      total: total,
      hasMore: offset + rows.length < total,
    );
  }

  NasTagDetails? tagDetails({
    required String tagId,
    String? contextParentId,
    String? contextRootId,
  }) {
    final tag = findTag(tagId);
    if (tag == null) return null;
    final allTags = listTags(includeArchived: true);
    final byId = {for (final item in allTags) item.id: item};
    final parentsByChild = _tagParentsByChild();
    final parentIds = parentsByChild[tagId] ?? const <String>[];
    final parents = parentIds
        .map((id) => byId[id])
        .whereType<NasLibraryTag>()
        .toList(growable: false);
    final directChildCount = _db.select(
      'SELECT COUNT(*) AS count FROM tag_parent_links WHERE parent_tag_id = ?',
      [tagId],
    ).single['count'] as int;
    final path = _tagPathForContext(
      tag: tag,
      byId: byId,
      parentsByChild: parentsByChild,
      contextParentId: contextParentId,
      contextRootId: contextRootId,
    );
    return NasTagDetails(
      tag: tag,
      parents: parents,
      directChildCount: directChildCount,
      movieCount: _tagMovieCounts()[tagId] ?? 0,
      path: path,
    );
  }

  NasTagChildPage tagChildren({
    required String parentTagId,
    String query = '',
    bool? associated,
    String sort = 'movieCount',
    String order = 'desc',
    int page = 1,
    int pageSize = 10,
  }) {
    if (page < 1 ||
        pageSize != 10 ||
        !const {'movieCount', 'name', 'createdAt'}.contains(sort) ||
        !const {'asc', 'desc'}.contains(order)) {
      throw ArgumentError('子标签分页参数无效');
    }
    final tags = listTags();
    final byId = {for (final tag in tags) tag.id: tag};
    final counts = _tagMovieCounts();
    final normalized = query.trim().toLowerCase();
    final items = (_tagChildrenByParent()[parentTagId] ?? const <String>[])
        .map((id) => byId[id])
        .whereType<NasLibraryTag>()
        .where((tag) =>
            normalized.isEmpty || tag.name.toLowerCase().contains(normalized))
        .where((tag) =>
            associated == null || ((counts[tag.id] ?? 0) > 0) == associated)
        .map((tag) =>
            NasTagChildSummary(tag: tag, movieCount: counts[tag.id] ?? 0))
        .toList(growable: false);
    items.sort((left, right) {
      final comparison = switch (sort) {
        'movieCount' => left.movieCount.compareTo(right.movieCount),
        'name' => left.tag.name.compareTo(right.tag.name),
        _ => left.tag.createdAt.compareTo(right.tag.createdAt),
      };
      return order == 'asc' ? comparison : -comparison;
    });
    final offset = (page - 1) * pageSize;
    final paged = offset >= items.length
        ? const <NasTagChildSummary>[]
        : items.skip(offset).take(pageSize).toList(growable: false);
    return NasTagChildPage(
      items: paged,
      number: page,
      size: pageSize,
      total: items.length,
      hasMore: offset + paged.length < items.length,
    );
  }

  NasTagMoviePage tagMovies({
    required String tagId,
    String query = '',
    String? categoryId,
    String? resolution,
    String sort = 'lastPlayedAt',
    String order = 'desc',
    int page = 1,
    int pageSize = 15,
  }) {
    if (page < 1 ||
        pageSize != 15 ||
        !const {'lastPlayedAt', 'createdAt', 'title', 'durationMs'}
            .contains(sort) ||
        !const {'asc', 'desc'}.contains(order)) {
      throw ArgumentError('关联影片分页参数无效');
    }
    final clauses = <String>[
      "m.lifecycle_state = 'active'",
      'm.id IN (SELECT movie_id FROM movie_tag_links WHERE tag_id IN (SELECT tag_id FROM tag_scope))',
    ];
    final parameters = <Object?>[tagId];
    final trimmed = query.trim();
    if (trimmed.isNotEmpty) {
      final like = '%$trimmed%';
      final catalog = '%${normalizeCatalogNumber(trimmed)}%';
      clauses.add('''(
        lower(m.title) LIKE lower(?) OR
        lower(COALESCE(m.original_title, '')) LIKE lower(?) OR
        lower(REPLACE(REPLACE(REPLACE(COALESCE(m.catalog_number, ''), '-', ''), '_', ''), ' ', '')) LIKE lower(?)
      )''');
      parameters.addAll([like, like, catalog]);
    }
    if (categoryId != null) {
      clauses.add('m.category_id = ?');
      parameters.add(categoryId);
    }
    if (resolution != null) {
      clauses.add(
          'EXISTS (SELECT 1 FROM episodes re WHERE re.movie_id = m.id AND re.resolution_label = ?)');
      parameters.add(resolution);
    }
    final where = clauses.join(' AND ');
    final cte = '''WITH RECURSIVE tag_scope(tag_id) AS (
      SELECT ?
      UNION
      SELECT l.child_tag_id FROM tag_parent_links l
      JOIN tag_scope scope ON scope.tag_id = l.parent_tag_id
    )''';
    final count = _db
        .select('$cte SELECT COUNT(*) AS count FROM movies m WHERE $where',
            parameters)
        .single['count'] as int;
    final expression = switch (sort) {
      'title' => 'm.title COLLATE NOCASE',
      'createdAt' => 'm.created_at',
      'durationMs' => 'SUM(COALESCE(e.duration_ms, 0))',
      _ => 'MAX(h.started_at)',
    };
    final offset = (page - 1) * pageSize;
    final rows = _db.select('''$cte
      SELECT m.id
      FROM movies m
      LEFT JOIN episodes e ON e.movie_id = m.id
      LEFT JOIN playback_history h ON h.movie_id = m.id
      WHERE $where
      GROUP BY m.id
      ORDER BY $expression ${order.toUpperCase()}, m.id ASC
      LIMIT ? OFFSET ?
    ''', [...parameters, pageSize, offset]);
    return NasTagMoviePage(
      movieIds: rows.map((row) => row['id'] as String).toList(growable: false),
      number: page,
      size: pageSize,
      total: count,
      hasMore: offset + rows.length < count,
    );
  }

  NasTagTaxonomyTransfer exportTagTaxonomy() {
    final tags = listTags();
    final byId = {for (final tag in tags) tag.id: tag};
    final parents = _tagParentsByChild();
    return NasTagTaxonomyTransfer(
      tags: tags
          .map((tag) => NasTaxonomyTagDefinition(
                name: tag.name,
                level: tag.level,
                description: tag.description,
                color: tag.color,
                parents: (parents[tag.id] ?? const <String>[])
                    .map((id) => byId[id]?.name)
                    .whereType<String>()
                    .toList(growable: false),
              ))
          .toList(growable: false),
    );
  }

  NasTaxonomyTransferResult importTagTaxonomy(NasTagTaxonomyTransfer transfer) {
    if (transfer.validationConflicts.isNotEmpty) {
      return NasTaxonomyTransferResult(
        added: const [],
        skipped: transfer.sourceSkipped,
        conflicts: transfer.validationConflicts,
      );
    }
    final violations = taxonomyViolations();
    if (violations.isNotEmpty) {
      return NasTaxonomyTransferResult(
        added: const [],
        skipped: transfer.sourceSkipped,
        conflicts: violations,
      );
    }
    final tagsByName = {
      for (final tag in listTags(includeArchived: true))
        normalizeTaxonomyName(tag.name): tag,
    };
    final definitions = {
      for (final definition in transfer.tags)
        normalizeTaxonomyName(definition.name): definition,
    };
    final conflicts = <String>[];
    for (final definition in transfer.tags) {
      final existing = tagsByName[normalizeTaxonomyName(definition.name)];
      if (existing != null && existing.level != definition.level) {
        conflicts.add(
            '标签层级冲突：${definition.name} 已是${tagLevelName(existing.level)}标签');
      }
      for (final parentName in definition.parents) {
        final key = normalizeTaxonomyName(parentName);
        final parent = tagsByName[key];
        final pending = definitions[key];
        final parentLevel = parent?.level ?? pending?.level;
        if (parentLevel == null) {
          conflicts.add('标签父级不存在：$parentName → ${definition.name}');
        } else if (parentLevel != definition.level - 1) {
          conflicts.add('标签父级层级错误：$parentName → ${definition.name}');
        } else if (parent?.archivedAt != null) {
          conflicts.add('标签父级已归档：$parentName → ${definition.name}');
        }
      }
    }
    if (conflicts.isNotEmpty) {
      return NasTaxonomyTransferResult(
        added: const [],
        skipped: transfer.sourceSkipped,
        conflicts: conflicts,
      );
    }
    final links = _db
        .select('SELECT child_tag_id, parent_tag_id FROM tag_parent_links')
        .map((row) => '${row['child_tag_id']}:${row['parent_tag_id']}')
        .toSet();
    final added = <String>[];
    final skipped = <String>[...transfer.sourceSkipped];
    _db.execute('BEGIN IMMEDIATE');
    try {
      for (var level = 1; level <= 3; level++) {
        for (final definition
            in transfer.tags.where((item) => item.level == level)) {
          final key = normalizeTaxonomyName(definition.name);
          if (tagsByName.containsKey(key)) {
            skipped.add('${tagLevelName(level)}标签：${tagsByName[key]!.name}');
            continue;
          }
          final timestamp = now();
          final tag = NasLibraryTag(
            id: newUuidV4(),
            name: definition.name,
            level: level,
            description: definition.description,
            color: definition.color ?? randomImportColor(importTagColorOptions),
            createdAt: timestamp,
            updatedAt: timestamp,
          );
          _insertTag(tag);
          tagsByName[key] = tag;
          added.add('${tagLevelName(level)}标签：${tag.name}');
        }
      }
      for (final definition in transfer.tags.where((item) => item.level > 1)) {
        final child = tagsByName[normalizeTaxonomyName(definition.name)]!;
        for (final parentName in definition.parents) {
          final parent = tagsByName[normalizeTaxonomyName(parentName)]!;
          final key = '${child.id}:${parent.id}';
          if (!links.add(key)) {
            skipped.add('标签归属：${parent.name} → ${child.name}');
            continue;
          }
          _db.execute('''
            INSERT INTO tag_parent_links(child_tag_id, parent_tag_id, created_at)
            VALUES (?, ?, ?)
          ''', [child.id, parent.id, now()]);
          added.add('标签归属：${parent.name} → ${child.name}');
        }
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return NasTaxonomyTransferResult(
        added: added, skipped: skipped, conflicts: const []);
  }

  List<String> taxonomyViolations() {
    final tags = listTags(includeArchived: true);
    final byId = {for (final tag in tags) tag.id: tag};
    final parents = _tagParentsByChild();
    final violations = <String>[];
    for (final tag in tags) {
      final parentIds = parents[tag.id] ?? const <String>[];
      if (tag.level == 1 && parentIds.isNotEmpty) {
        violations.add('一级标签不能拥有父级：${tag.name}');
      }
      if (tag.level > 1 && parentIds.isEmpty) {
        violations.add('${tagLevelName(tag.level)}标签缺少父级：${tag.name}');
      }
      for (final parentId in parentIds) {
        final parent = byId[parentId];
        if (parent == null || parent.level != tag.level - 1) {
          violations.add('标签父级层级错误：${tag.name}');
        }
      }
    }
    return violations;
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

  void _requireTagInput({
    required String name,
    required int level,
    required String? color,
    required List<String> parentIds,
  }) {
    _requireTaxonomyName(name, '标签');
    if (level < 1 || level > 3 || !isValidTaxonomyColor(color)) {
      throw ArgumentError('标签层级或颜色无效');
    }
    if ((level == 1 && parentIds.isNotEmpty) ||
        (level > 1 && parentIds.isEmpty) ||
        parentIds.toSet().length != parentIds.length) {
      throw ArgumentError('标签父级不符合固定三级规则');
    }
    for (final parentId in parentIds) {
      final parent = findTag(parentId);
      if (parent == null ||
          parent.archivedAt != null ||
          parent.level != level - 1) {
        throw ArgumentError('标签父级不存在、已归档或层级不匹配');
      }
    }
  }

  void _insertTag(NasLibraryTag tag) {
    _db.execute('''
      INSERT INTO tags(
        id, name, normalized_name, level, description, color,
        created_at, updated_at, archived_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      tag.id,
      tag.name,
      normalizeTaxonomyName(tag.name),
      tag.level,
      tag.description,
      tag.color,
      tag.createdAt,
      tag.updatedAt,
      tag.archivedAt,
    ]);
  }

  void _replaceTagParents(
    String tagId,
    List<String> parentIds,
    String timestamp,
  ) {
    _db.execute('DELETE FROM tag_parent_links WHERE child_tag_id = ?', [tagId]);
    for (final parentId in parentIds) {
      _db.execute('''
        INSERT INTO tag_parent_links(child_tag_id, parent_tag_id, created_at)
        VALUES (?, ?, ?)
      ''', [tagId, parentId, timestamp]);
    }
  }

  Map<String, List<String>> _tagParentsByChild() {
    final values = <String, List<String>>{};
    for (final row in _db.select('''
      SELECT child_tag_id, parent_tag_id
      FROM tag_parent_links
      ORDER BY parent_tag_id, child_tag_id
    ''')) {
      values
          .putIfAbsent(row['child_tag_id'] as String, () => [])
          .add(row['parent_tag_id'] as String);
    }
    return values;
  }

  Map<String, List<String>> _tagChildrenByParent() {
    final values = <String, List<String>>{};
    for (final entry in _tagParentsByChild().entries) {
      for (final parentId in entry.value) {
        values.putIfAbsent(parentId, () => []).add(entry.key);
      }
    }
    return values;
  }

  Map<String, int> _tagMovieCounts() {
    final rows = _db.select('''
      WITH RECURSIVE descendants(ancestor_id, descendant_id) AS (
        SELECT id, id FROM tags
        UNION
        SELECT descendants.ancestor_id, links.child_tag_id
        FROM descendants
        JOIN tag_parent_links links ON links.parent_tag_id = descendants.descendant_id
      )
      SELECT descendants.ancestor_id AS tag_id,
              COUNT(DISTINCT CASE WHEN movie.lifecycle_state = 'active'
                THEN movie_tag_links.movie_id END) AS movie_count
       FROM descendants
       LEFT JOIN movie_tag_links ON movie_tag_links.tag_id = descendants.descendant_id
       LEFT JOIN movies movie ON movie.id = movie_tag_links.movie_id
      GROUP BY descendants.ancestor_id
    ''');
    return {
      for (final row in rows)
        row['tag_id'] as String: row['movie_count'] as int,
    };
  }

  List<NasLibraryTag> _tagPathForContext({
    required NasLibraryTag tag,
    required Map<String, NasLibraryTag> byId,
    required Map<String, List<String>> parentsByChild,
    required String? contextParentId,
    required String? contextRootId,
  }) {
    if (tag.level == 1) return [tag];
    final parentIds = parentsByChild[tag.id] ?? const <String>[];
    final selectedParentId =
        contextParentId != null && parentIds.contains(contextParentId)
            ? contextParentId
            : parentIds.isEmpty
                ? null
                : parentIds.first;
    final parent = selectedParentId == null ? null : byId[selectedParentId];
    if (parent == null) return [tag];
    if (tag.level == 2) return [parent, tag];
    final grandparentIds = parentsByChild[parent.id] ?? const <String>[];
    final grandparentId =
        contextRootId != null && grandparentIds.contains(contextRootId)
            ? contextRootId
            : grandparentIds.isEmpty
                ? null
                : grandparentIds.first;
    final grandparent = grandparentId == null ? null : byId[grandparentId];
    return [if (grandparent != null) grandparent, parent, tag];
  }

  List<NasTagPath> _tagPathsForIds(Iterable<String> tagIds) {
    final tags = listTags(includeArchived: true);
    final byId = {for (final tag in tags) tag.id: tag};
    final parentsByChild = _tagParentsByChild();
    List<List<NasLibraryTag>> pathsFor(String tagId, Set<String> visiting) {
      final tag = byId[tagId];
      if (tag == null || !visiting.add(tagId)) return const [];
      try {
        if (tag.level == 1)
          return [
            [tag]
          ];
        final parentIds = parentsByChild[tagId] ?? const <String>[];
        final paths = <List<NasLibraryTag>>[];
        for (final parentId in parentIds) {
          for (final path in pathsFor(parentId, visiting)) {
            paths.add([...path, tag]);
          }
        }
        return paths;
      } finally {
        visiting.remove(tagId);
      }
    }

    final result = <NasTagPath>[];
    final seen = <String>{};
    for (final tagId in tagIds) {
      final tag = byId[tagId];
      if (tag == null) continue;
      for (final path in pathsFor(tagId, <String>{})) {
        final names = path.map((item) => item.name).toList(growable: false);
        final key = '${tag.id}:${names.join('\u0000')}';
        if (!seen.add(key)) continue;
        result.add(NasTagPath(
          placementId: tag.id,
          tagId: tag.id,
          tagName: tag.name,
          names: names,
        ));
      }
    }
    return result;
  }

  NasLibraryCategory? categoryForMovie(String movieId) {
    final rows = _db.select('''
      SELECT category_id FROM movies WHERE id = ?
    ''', [movieId]);
    final id = rows.isEmpty ? null : rows.single['category_id'] as String?;
    return id == null ? null : findCategory(id);
  }

  /// Batch the current page's associations; load tag ancestry only once.
  Map<String, Map<String, Object?>> browseAssociations(List<String> ids) {
    if (ids.isEmpty) return {};
    final placeholders = List.filled(ids.length, '?').join(',');
    final result = {
      for (final id in ids)
        id: <String, Object?>{
          'actors': <Map<String, Object?>>[],
          'tags': <Map<String, Object?>>[],
          'tagPaths': <List<String>>[],
        }
    };
    for (final row in _db.select('''SELECT links.movie_id, a.id, a.stage_name,
      a.original_name, a.translated_name, a.gender FROM movie_actor_links links
      JOIN actors a ON a.id=links.actor_id WHERE links.movie_id IN ($placeholders)
      ORDER BY a.id''', ids)) {
      (result[row['movie_id']]!['actors'] as List).add({
        'id': row['id'],
        'name': [
              row['stage_name'],
              row['original_name'],
              row['translated_name']
            ]
                .whereType<String>()
                .where((name) => name.trim().isNotEmpty)
                .firstOrNull ??
            '',
        'gender': row['gender'],
      });
    }
    final tags =
        _db.select('''SELECT links.movie_id, t.* FROM movie_tag_links links
      JOIN tags t ON t.id=links.tag_id WHERE links.movie_id IN ($placeholders)
      ORDER BY t.level, t.name COLLATE NOCASE, t.id''', ids);
    final paths =
        _tagPathsForIds(tags.map((row) => row['id'] as String).toSet());
    final pathsById = <String, List<List<String>>>{};
    for (final path in paths) {
      pathsById.putIfAbsent(path.tagId, () => []).add(path.names);
    }
    for (final row in tags) {
      final item = result[row['movie_id']]!;
      (item['tags'] as List).add({
        'id': row['id'],
        'name': row['name'],
        'level': row['level'],
        'description': row['description'],
        'color': row['color'],
        'createdAt': row['created_at'],
        'updatedAt': row['updated_at'],
        'archivedAt': row['archived_at']
      });
      (item['tagPaths'] as List).addAll(pathsById[row['id']] ?? const []);
    }
    return result;
  }

  List<NasTagPath> tagPathsForMovie(String movieId) {
    final linkedIds = _db.select('''
      SELECT tag_id FROM movie_tag_links WHERE movie_id = ? ORDER BY tag_id
    ''', [movieId]).map((row) => row['tag_id'] as String);
    return _tagPathsForIds(linkedIds);
  }

  List<NasTagPath> allTagPaths() =>
      _tagPathsForIds(listTags(includeArchived: true).map((tag) => tag.id));

  List<NasLibraryTag> tagsForMovie(String movieId) {
    return _db.select('''
      SELECT t.id, t.name, t.level, t.description, t.color,
             t.created_at, t.updated_at, t.archived_at
      FROM tags t JOIN movie_tag_links links ON links.tag_id = t.id
      WHERE links.movie_id = ?
      ORDER BY t.level, t.name COLLATE NOCASE, t.id
    ''', [movieId]).map(_mapTag).toList(growable: false);
  }

  List<NasLibraryTag> tagsForRelation(
    String condition,
    List<Object?> parameters,
  ) =>
      _db.select('''
        SELECT DISTINCT t.id, t.name, t.level, t.description, t.color,
               t.created_at, t.updated_at, t.archived_at
        FROM movies m
        JOIN movie_tag_links links ON links.movie_id = m.id
        JOIN tags t ON t.id = links.tag_id
        WHERE m.lifecycle_state = 'active' AND $condition
        ORDER BY t.name COLLATE NOCASE, t.id
      ''', parameters).map(_mapTag).toList(growable: false);

  bool setMovieTaxonomy({
    required String movieId,
    required bool updateCategory,
    required String? categoryId,
    required bool updateTagIds,
    required List<String> tagIds,
  }) {
    if (findMovieForAdmin(movieId) == null) return false;
    if (updateCategory) {
      _db.execute(
        'UPDATE movies SET category_id = ?, updated_at = ? WHERE id = ?',
        [categoryId, now(), movieId],
      );
    }
    if (updateTagIds) {
      _db.execute('DELETE FROM movie_tag_links WHERE movie_id = ?', [movieId]);
      for (final tagId in tagIds) {
        _db.execute(
          'INSERT INTO movie_tag_links(movie_id, tag_id) VALUES (?, ?)',
          [movieId, tagId],
        );
      }
    }
    return true;
  }

  NasLibraryCategory _mapCategory(Row row) => NasLibraryCategory(
        id: row['id'] as String,
        name: row['name'] as String,
        color: row['color'] as String?,
        mediaRelativePath: row['media_relative_path'] as String?,
        createdAt: row['created_at'] as String,
        updatedAt: row['updated_at'] as String,
      );

  NasLibraryCategory _mapCategoryWithSources(Row row) {
    final category = _mapCategory(row);
    return NasLibraryCategory(
      id: category.id,
      name: category.name,
      color: category.color,
      mediaRelativePath: category.mediaRelativePath,
      createdAt: category.createdAt,
      updatedAt: category.updatedAt,
      mediaSources: mediaSourcesForCategory(category.id),
      movieCount: row['movie_count'] as int,
    );
  }

  NasLibraryTag _mapTag(Row row) => NasLibraryTag(
        id: row['id'] as String,
        name: row['name'] as String,
        level: row['level'] as int,
        description: row['description'] as String? ?? '',
        color: row['color'] as String?,
        createdAt: row['created_at'] as String,
        updatedAt: row['updated_at'] as String,
        archivedAt: row['archived_at'] as String?,
      );
}
