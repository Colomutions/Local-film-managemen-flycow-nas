import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';
import '../library_models.dart';
import 'library_values.dart';

/// Owns AI task records, metadata provenance and confirmed MDCNG writes.
class NasMetadataRepository {
  NasMetadataRepository(
    this._connection, {
    required this.findActor,
    required this.findEpisode,
    required this.findMovieForAdmin,
    required this.findTag,
    required this.recordGalleryOrigin,
  });

  final Database Function() _connection;
  Database get _db => _connection();
  final NasActor? Function(String actorId) findActor;
  final NasLibraryEpisode? Function(String episodeId) findEpisode;
  final NasLibraryMovie? Function(String movieId) findMovieForAdmin;
  final NasLibraryTag? Function(String tagId) findTag;
  final void Function(String imageId, String kind) recordGalleryOrigin;

  NasAiTask? createAiTask({
    required String movieId,
    required String instructions,
  }) {
    if (findMovieForAdmin(movieId) == null) return null;
    final task = NasAiTask(
      id: newUuidV4(),
      movieId: movieId,
      instructions: instructions,
      status: 'queued',
      createdAt: now(),
    );
    _db.execute('''
      INSERT INTO ai_metadata_tasks(
        id, movie_id, instructions, status, created_at
      ) VALUES (?, ?, ?, ?, ?)
    ''', [
      task.id,
      task.movieId,
      task.instructions,
      task.status,
      task.createdAt
    ]);
    return task;
  }

  NasAiTask? findAiTask(String taskId) {
    final rows = _db.select('''
      SELECT id, movie_id, instructions, status, result_json, error_code,
             created_at, finished_at
      FROM ai_metadata_tasks WHERE id = ?
    ''', [taskId]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    return NasAiTask(
      id: row['id'] as String,
      movieId: row['movie_id'] as String,
      instructions: row['instructions'] as String,
      status: row['status'] as String,
      resultJson: row['result_json'] as String?,
      errorCode: row['error_code'] as String?,
      createdAt: row['created_at'] as String,
      finishedAt: row['finished_at'] as String?,
    );
  }

  NasAiTask? markAiTaskRunning(String taskId) {
    final existing = findAiTask(taskId);
    if (existing == null || existing.status != 'queued') return null;
    _db.execute('''
      UPDATE ai_metadata_tasks
      SET status = 'running', error_code = NULL, result_json = NULL,
          finished_at = NULL
      WHERE id = ? AND status = 'queued'
    ''', [taskId]);
    return findAiTask(taskId);
  }

  NasAiTask? completeAiTask(String taskId, Map<String, Object?> result) {
    final existing = findAiTask(taskId);
    if (existing == null || existing.status != 'running') return null;
    _db.execute('''
      UPDATE ai_metadata_tasks
      SET status = 'succeeded', result_json = ?, error_code = NULL,
          finished_at = ?
      WHERE id = ? AND status = 'running'
    ''', [jsonEncode(result), now(), taskId]);
    return findAiTask(taskId);
  }

  NasAiTask? failAiTask(String taskId, String errorCode) {
    final existing = findAiTask(taskId);
    if (existing == null || existing.status != 'running') return null;
    _db.execute('''
      UPDATE ai_metadata_tasks
      SET status = 'failed', result_json = NULL, error_code = ?, finished_at = ?
      WHERE id = ? AND status = 'running'
    ''', [errorCode, now(), taskId]);
    return findAiTask(taskId);
  }

  Map<String, NasMovieMetadataFieldSource> metadataFieldSourcesForMovie(
    String movieId,
  ) {
    final rows = _db.select('''
      SELECT field_key, source_kind, import_record_id, source_content_hash,
             updated_at
      FROM movie_metadata_field_sources
      WHERE movie_id = ?
    ''', [movieId]);
    return {
      for (final row in rows)
        row['field_key'] as String: NasMovieMetadataFieldSource(
          fieldKey: row['field_key'] as String,
          sourceKind: row['source_kind'] as String,
          importRecordId: row['import_record_id'] as String?,
          sourceContentHash: row['source_content_hash'] as String?,
          updatedAt: row['updated_at'] as String,
        ),
    };
  }

  /// 由常规管理接口调用，以便后续 MDCNG 预览识别人工已确认的字段。
  bool markMovieMetadataFieldsManual({
    required String movieId,
    required Iterable<String> fieldKeys,
  }) {
    if (findMovieForAdmin(movieId) == null) return false;
    final normalized = fieldKeys.toSet();
    if (normalized.isEmpty) return true;
    if (normalized.any((field) => !metadataFieldKeys.contains(field))) {
      throw ArgumentError('Unsupported metadata field source.');
    }
    final timestamp = now();
    _db.execute('BEGIN IMMEDIATE');
    try {
      for (final fieldKey in normalized) {
        _db.execute('''
          INSERT INTO movie_metadata_field_sources(
            movie_id, field_key, source_kind, import_record_id,
            source_content_hash, updated_at
          ) VALUES (?, ?, 'manual', NULL, NULL, ?)
          ON CONFLICT(movie_id, field_key) DO UPDATE SET
            source_kind = 'manual',
            import_record_id = NULL,
            source_content_hash = NULL,
            updated_at = excluded.updated_at
        ''', [movieId, fieldKey, timestamp]);
      }
      _db.execute('COMMIT');
      return true;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 原子写入已经由管理员确认的 MDCNG 字段，并保存可追溯的来源摘要。
  NasMdcngImportRecord applyMdcngMetadata(NasMdcngMetadataApply input) {
    final movie = findMovieForAdmin(input.movieId);
    final episode = findEpisode(input.episodeId);
    final fields = input.fieldKeys.toSet();
    if (movie == null ||
        episode == null ||
        episode.movieId != input.movieId ||
        fields.isEmpty ||
        fields.length != input.fieldKeys.length ||
        fields.any((field) => !metadataFieldKeys.contains(field))) {
      throw ArgumentError('Invalid MDCNG metadata import.');
    }
    if ((fields.contains('title') && input.title == null) ||
        (fields.contains('originalTitle') && input.originalTitle == null) ||
        (fields.contains('catalogNumber') && input.catalogNumber == null) ||
        (fields.contains('summary') && input.summary == null) ||
        (fields.contains('actors') && input.actorIds == null) ||
        (fields.contains('tags') && input.tagIds == null) ||
        (fields.contains('poster') && input.posterFileName == null) ||
        (fields.contains('fanart') && input.fanartFileName == null)) {
      throw ArgumentError('Missing selected MDCNG metadata field.');
    }
    final actorIds = input.actorIds;
    if (actorIds != null &&
        (actorIds.toSet().length != actorIds.length ||
            actorIds.any((id) {
              final actor = findActor(id);
              return actor == null || actor.archivedAt != null;
            }))) {
      throw ArgumentError('Invalid MDCNG actors.');
    }
    final tagIds = input.tagIds;
    if (tagIds != null &&
        (tagIds.toSet().length != tagIds.length ||
            tagIds.any((id) {
              final tag = findTag(id);
              return tag == null || tag.archivedAt != null;
            }))) {
      throw ArgumentError('Invalid MDCNG tags.');
    }

    final timestamp = now();
    final record = NasMdcngImportRecord(
      id: newUuidV4(),
      movieId: input.movieId,
      episodeId: input.episodeId,
      nfoFileName: input.nfoFileName,
      nfoContentHash: input.nfoContentHash,
      appliedFieldKeys: input.fieldKeys,
      createdAt: timestamp,
    );
    _db.execute('BEGIN IMMEDIATE');
    try {
      final assignments = <String>[];
      final values = <Object?>[];
      if (fields.contains('title')) {
        assignments.add('title = ?');
        values.add(input.title);
      }
      if (fields.contains('originalTitle')) {
        assignments.add('original_title = ?');
        values.add(input.originalTitle);
      }
      if (fields.contains('catalogNumber')) {
        assignments.add('catalog_number = ?');
        values.add(input.catalogNumber);
      }
      if (fields.contains('summary')) {
        assignments.add('summary = ?');
        values.add(input.summary);
      }
      if (fields.contains('poster')) {
        assignments.add('poster_file_name = ?');
        values.add(input.posterFileName);
      }
      assignments.add('updated_at = ?');
      values.add(timestamp);
      values.add(input.movieId);
      _db.execute(
        'UPDATE movies SET ${assignments.join(', ')} WHERE id = ?',
        values,
      );

      if (actorIds != null) {
        _db.execute('DELETE FROM movie_actor_links WHERE movie_id = ?',
            [input.movieId]);
        for (final actorId in actorIds) {
          _db.execute(
            'INSERT INTO movie_actor_links(movie_id, actor_id) VALUES (?, ?)',
            [input.movieId, actorId],
          );
        }
      }
      if (tagIds != null) {
        _db.execute(
            'DELETE FROM movie_tag_links WHERE movie_id = ?', [input.movieId]);
        for (final tagId in tagIds) {
          _db.execute(
            'INSERT INTO movie_tag_links(movie_id, tag_id) VALUES (?, ?)',
            [input.movieId, tagId],
          );
        }
      }

      _db.execute('''
        INSERT INTO mdcng_import_records(
          id, movie_id, episode_id, nfo_file_name, nfo_content_hash,
          applied_fields_json, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ''', [
        record.id,
        record.movieId,
        record.episodeId,
        record.nfoFileName,
        record.nfoContentHash,
        jsonEncode(record.appliedFieldKeys),
        record.createdAt,
      ]);
      if (input.fanartFileName != null) {
        final imageId = newUuidV4();
        _db.execute('''
          INSERT INTO movie_carousel_images(id, movie_id, file_name, created_at)
          VALUES (?, ?, ?, ?)
        ''', [imageId, input.movieId, input.fanartFileName, timestamp]);
        recordGalleryOrigin(imageId, 'mdcng_cover');
      }
      for (final fieldKey in fields) {
        _db.execute('''
          INSERT INTO movie_metadata_field_sources(
            movie_id, field_key, source_kind, import_record_id,
            source_content_hash, updated_at
          ) VALUES (?, ?, 'mdcng', ?, ?, ?)
          ON CONFLICT(movie_id, field_key) DO UPDATE SET
            source_kind = 'mdcng',
            import_record_id = excluded.import_record_id,
            source_content_hash = excluded.source_content_hash,
            updated_at = excluded.updated_at
        ''', [
          input.movieId,
          fieldKey,
          record.id,
          input.nfoContentHash,
          timestamp,
        ]);
      }
      _db.execute('COMMIT');
      return record;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }
}
