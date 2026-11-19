import 'package:sqlite3/sqlite3.dart';

import 'library_values.dart';

/// Metadata-only bulk operations. No media files or artwork are read or moved.
class NasTagBatchRepository {
  NasTagBatchRepository(this._connection, {required this.transaction});

  final Database Function() _connection;
  final T Function<T>(T Function() action) transaction;
  Database get _db => _connection();

  Map<String, Object?> clearMovieLinks() => transaction(() {
        final counts = _db.select('''
          SELECT COUNT(*) AS total, SUM(EXISTS(
            SELECT 1 FROM movie_tag_links l WHERE l.movie_id = m.id
          )) AS linked FROM movies m WHERE lifecycle_state = 'active'
        ''').single;
        final total = counts['total'] as int;
        final completed = (counts['linked'] as int?) ?? 0;
        if (completed > 0) {
          // Preserve manual-field protection before removing the relationships.
          _db.execute('''
            INSERT INTO movie_metadata_field_sources(
              movie_id, field_key, source_kind, import_record_id,
              source_content_hash, updated_at
            ) SELECT DISTINCT l.movie_id, 'tags', 'manual', NULL, NULL, ?
              FROM movie_tag_links l JOIN movies m ON m.id = l.movie_id
              WHERE m.lifecycle_state = 'active'
            ON CONFLICT(movie_id, field_key) DO UPDATE SET
              source_kind = 'manual', import_record_id = NULL,
              source_content_hash = NULL, updated_at = excluded.updated_at
            WHERE source_kind != 'manual'
          ''', [now()]);
          _db.execute('''DELETE FROM movie_tag_links WHERE movie_id IN (
            SELECT id FROM movies WHERE lifecycle_state = 'active'
          )''');
        }
        return {
          'total': total,
          'completed': completed,
          'skipped': total - completed,
          'failed': 0,
          'issues': <Object?>[],
        };
      });

  Map<String, Object?> deleteActiveTags() => transaction(() {
        final total = _db
            .select(
              'SELECT COUNT(*) AS n FROM tags WHERE archived_at IS NULL',
            )
            .single['n'] as int;
        // A memory-only candidate set lets each level be deleted with set SQL.
        _db.execute('CREATE TEMP TABLE IF NOT EXISTS tag_batch_candidates '
            '(id TEXT PRIMARY KEY)');
        for (final level in [3, 2, 1]) {
          _db.execute('DELETE FROM tag_batch_candidates');
          _db.execute('''INSERT INTO tag_batch_candidates
            SELECT t.id FROM tags t WHERE t.level = ? AND t.archived_at IS NULL
              AND NOT EXISTS(SELECT 1 FROM tag_parent_links
                WHERE parent_tag_id = t.id)
              AND NOT EXISTS(SELECT 1 FROM movie_tag_links l
                JOIN movies m ON m.id = l.movie_id
                WHERE l.tag_id = t.id AND m.lifecycle_state = 'active')
          ''', [level]);
          _db.execute('''DELETE FROM movie_tag_links
            WHERE tag_id IN (SELECT id FROM tag_batch_candidates)''');
          _db.execute('''DELETE FROM tag_parent_links
            WHERE child_tag_id IN (SELECT id FROM tag_batch_candidates)''');
          _db.execute('''DELETE FROM tags
            WHERE id IN (SELECT id FROM tag_batch_candidates)''');
        }
        _db.execute('DELETE FROM tag_batch_candidates');
        final issues = _db
            .select('''SELECT name FROM tags
          WHERE archived_at IS NULL ORDER BY level DESC, name, id''')
            .map((row) => {
                  'name': row['name'],
                  'message': '标签仍有关联影片或子级，只能归档',
                })
            .toList(growable: false);
        return {
          'total': total,
          'completed': total - issues.length,
          'skipped': 0,
          'failed': issues.length,
          'issues': issues,
        };
      });

  /// At most 500 films per transaction; retries add only missing links.
  Map<String, Object?> associateMovies(List<NasMovieTagAssociation> films) {
    if (films.isEmpty || films.length > 500) {
      throw const FormatException('每批影片数量须为 1 至 500。');
    }
    final seen = <String>{};
    for (final film in films) {
      if (!seen.add(normalizeCatalogNumber(film.code))) {
        throw const FormatException('影片番号重复。');
      }
    }
    return transaction(() {
      final moviesByCode = <String, List<String>>{};
      for (final row in _db.select('''SELECT id, catalog_number FROM movies
        WHERE lifecycle_state = 'active' AND catalog_number IS NOT NULL''')) {
        final key = normalizeCatalogNumber(row['catalog_number'] as String);
        moviesByCode.putIfAbsent(key, () => []).add(row['id'] as String);
      }
      final tagsByName = <String, String>{};
      for (final row in _db
          .select('SELECT id, name FROM tags WHERE archived_at IS NULL')) {
        final key = (row['name'] as String).trim().toLowerCase();
        if (tagsByName.containsKey(key)) {
          throw const FormatException('NAS 存在重复标签名称。');
        }
        tagsByName[key] = row['id'] as String;
      }
      var updated = 0;
      var unchanged = 0;
      var unmatched = 0;
      var ambiguous = 0;
      var failed = 0;
      final issues = <Map<String, Object?>>[];
      final insert =
          _db.prepare('''INSERT INTO movie_tag_links(movie_id, tag_id)
        VALUES (?, ?) ON CONFLICT(movie_id, tag_id) DO NOTHING''');
      final manual = _db.prepare('''
        INSERT INTO movie_metadata_field_sources(
          movie_id, field_key, source_kind, import_record_id,
          source_content_hash, updated_at
        ) VALUES (?, 'tags', 'manual', NULL, NULL, ?)
        ON CONFLICT(movie_id, field_key) DO UPDATE SET
          source_kind = 'manual', import_record_id = NULL,
          source_content_hash = NULL, updated_at = excluded.updated_at
        WHERE source_kind != 'manual'
      ''');
      try {
        final timestamp = now();
        for (final film in films) {
          final candidates =
              moviesByCode[normalizeCatalogNumber(film.code)] ?? [];
          if (candidates.length != 1) {
            final status = candidates.isEmpty ? 'unmatched' : 'ambiguous';
            if (candidates.isEmpty) {
              unmatched++;
            } else {
              ambiguous++;
            }
            issues.add({
              'code': film.code,
              'status': status,
              'message': candidates.isEmpty
                  ? 'NAS 中找不到此番号。'
                  : 'NAS 中存在 ${candidates.length} 部同番号影片，未自动写入。'
            });
            continue;
          }
          final missing = film.tagNames
              .where(
                  (name) => !tagsByName.containsKey(name.trim().toLowerCase()))
              .toList();
          if (missing.isNotEmpty) {
            failed++;
            issues.add({
              'code': film.code,
              'status': 'failed',
              'message': 'NAS 中不存在标签：${missing.join('、')}。'
            });
            continue;
          }
          final id = candidates.single;
          var changed = false;
          for (final name in film.tagNames) {
            insert.execute([id, tagsByName[name.trim().toLowerCase()]]);
            changed |= _db.updatedRows > 0;
          }
          // An empty mapping must not create a manual lock on an untouched film.
          if (film.tagNames.isNotEmpty) manual.execute([id, timestamp]);
          if (changed) {
            updated++;
          } else {
            unchanged++;
          }
        }
      } finally {
        insert.dispose();
        manual.dispose();
      }
      return {
        'total': films.length,
        'updated': updated,
        'unchanged': unchanged,
        'unmatched': unmatched,
        'ambiguous': ambiguous,
        'failed': failed,
        'issues': issues
      };
    });
  }
}

class NasMovieTagAssociation {
  const NasMovieTagAssociation({required this.code, required this.tagNames});
  final String code;
  final List<String> tagNames;

  static List<NasMovieTagAssociation> decode(Object? raw) {
    if (raw is! List || raw.isEmpty || raw.length > 500) {
      throw const FormatException('无效影片关联批次。');
    }
    return raw.map((item) {
      if (item is! Map ||
          item['code'] is! String ||
          (item['code'] as String).trim().isEmpty ||
          (item['code'] as String).length > 120 ||
          normalizeCatalogNumber(item['code'] as String).isEmpty ||
          item['previewTags'] is! List) {
        throw const FormatException('无效影片关联项目。');
      }
      final names = item['previewTags'] as List;
      if (names.length > 500 ||
          names.any((name) =>
              name is! String || name.trim().isEmpty || name.length > 200)) {
        throw const FormatException('无效标签名称。');
      }
      return NasMovieTagAssociation(
          code: (item['code'] as String).trim(),
          tagNames:
              names.cast<String>().map((name) => name.trim()).toSet().toList());
    }).toList(growable: false);
  }
}
