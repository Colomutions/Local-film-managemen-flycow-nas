import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';
import 'novel_models.dart';

void migrateNovelSchema(Database database) {
  database.execute('''
    CREATE TABLE novel_content_objects (
      content_sha256 TEXT PRIMARY KEY,
      size_bytes INTEGER NOT NULL CHECK(size_bytes >= 0),
      ref_count INTEGER NOT NULL CHECK(ref_count >= 0),
      created_at TEXT NOT NULL
    );
    CREATE TABLE novels (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      author TEXT,
      format TEXT NOT NULL CHECK(format = 'txt'),
      content_state TEXT NOT NULL CHECK(content_state = 'complete_file'),
      relative_path TEXT NOT NULL DEFAULT '',
      file_name TEXT NOT NULL,
      size_bytes INTEGER NOT NULL CHECK(size_bytes >= 0),
      content_sha256 TEXT NOT NULL REFERENCES novel_content_objects(content_sha256)
        ON DELETE RESTRICT,
      revision INTEGER NOT NULL CHECK(revision >= 1),
      storage_state TEXT NOT NULL DEFAULT 'healthy'
        CHECK(storage_state IN ('healthy', 'missing', 'corrupt')),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE INDEX novels_content_sha256_idx ON novels(content_sha256, id);
    CREATE INDEX novels_conflict_key_idx ON novels(title, author, format, id);
    CREATE INDEX novels_updated_id_idx ON novels(updated_at DESC, id);
    CREATE INDEX novels_created_id_idx ON novels(created_at DESC, id);
    CREATE INDEX novels_title_id_idx ON novels(title, id);

    CREATE TABLE novel_quota_state (
      singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1),
      logical_bytes INTEGER NOT NULL CHECK(logical_bytes >= 0),
      updated_at TEXT NOT NULL
    );

    CREATE TABLE novel_idempotency (
      device_id TEXT NOT NULL,
      http_method TEXT NOT NULL,
      canonical_path TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      semantic_digest TEXT NOT NULL,
      state TEXT NOT NULL CHECK(state IN ('in_progress', 'succeeded', 'gone')),
      owner_nonce TEXT,
      lease_expires_at TEXT,
      http_status INTEGER,
      response_json TEXT,
      novel_id TEXT,
      expires_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY(device_id, http_method, canonical_path, idempotency_key),
      CHECK(
        (state = 'in_progress' AND owner_nonce IS NOT NULL AND lease_expires_at IS NOT NULL) OR
        (state != 'in_progress' AND owner_nonce IS NULL AND lease_expires_at IS NULL)
      )
    );
    CREATE INDEX novel_idempotency_novel_idx
      ON novel_idempotency(novel_id, state, expires_at);
    CREATE INDEX novel_idempotency_expiry_idx
      ON novel_idempotency(state, expires_at, lease_expires_at);

    CREATE TABLE novel_deletion_audit (
      id TEXT PRIMARY KEY,
      actor_device_id TEXT NOT NULL,
      novel_id TEXT NOT NULL,
      deleted_revision INTEGER NOT NULL,
      content_sha256 TEXT NOT NULL,
      deleted_at TEXT NOT NULL
    );
    CREATE INDEX novel_deletion_audit_novel_idx
      ON novel_deletion_audit(novel_id, deleted_at DESC);

    CREATE TABLE novel_backup_jobs (
      id TEXT PRIMARY KEY,
      status TEXT NOT NULL CHECK(status IN ('running', 'completed', 'abandoned')),
      created_at TEXT NOT NULL,
      completed_at TEXT
    );
    CREATE TABLE novel_backup_pins (
      job_id TEXT NOT NULL REFERENCES novel_backup_jobs(id) ON DELETE CASCADE,
      content_sha256 TEXT NOT NULL REFERENCES novel_content_objects(content_sha256)
        ON DELETE RESTRICT,
      PRIMARY KEY(job_id, content_sha256)
    );
    CREATE INDEX novel_backup_pins_content_idx
      ON novel_backup_pins(content_sha256, job_id);
  ''');
  final now = DateTime.now().toUtc().toIso8601String();
  database.execute(
    'INSERT INTO novel_quota_state(singleton_id, logical_bytes, updated_at) '
    'VALUES (1, 0, ?)',
    [now],
  );
}

class NasNovelRepositoryException implements Exception {
  const NasNovelRepositoryException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

enum NasNovelIdempotencyDecision {
  acquired,
  replay,
  inProgress,
  conflict,
  gone,
}

class NasNovelIdempotencyAcquisition {
  const NasNovelIdempotencyAcquisition({
    required this.decision,
    required this.record,
    this.ownerNonce,
  });

  final NasNovelIdempotencyDecision decision;
  final NasNovelIdempotencyRecord record;
  final String? ownerNonce;
}

class NasNovelPostCommit {
  const NasNovelPostCommit({
    required this.novel,
    required this.deduplicated,
    required this.statusCode,
  });

  final NasNovel novel;
  final bool deduplicated;
  final int statusCode;

  Map<String, Object?> toResponseJson() => {
        'data': {
          'novel': novel.toJson(),
          'deduplicated': deduplicated,
        },
      };
}

class NasNovelPutCommit {
  const NasNovelPutCommit({
    required this.novel,
    required this.changed,
    required this.unreferencedContentSha256,
  });

  final NasNovel novel;
  final bool changed;
  final String? unreferencedContentSha256;

  Map<String, Object?> toResponseJson() => {
        'data': {
          'novel': novel.toJson(),
          'changed': changed,
        },
      };
}

class NasNovelDeleteCommit {
  const NasNovelDeleteCommit({required this.unreferencedContentSha256});

  final String? unreferencedContentSha256;
}

class NasNovelRepository {
  NasNovelRepository(this.database);

  final Database database;

  NasNovelPage list({
    String? query,
    int page = 1,
    int pageSize = 30,
    String sort = 'updatedAt',
    String order = 'desc',
  }) {
    if (page < 1 || pageSize < 1 || pageSize > 100) {
      throw const NasNovelRepositoryException(
        'invalid_request',
        'invalid pagination parameters',
      );
    }
    final sortColumn = switch (sort) {
      'title' => 'title',
      'updatedAt' => 'updated_at',
      'createdAt' => 'created_at',
      _ => throw const NasNovelRepositoryException(
          'invalid_request',
          'invalid novel sort field',
        ),
    };
    final direction = switch (order) {
      'asc' => 'ASC',
      'desc' => 'DESC',
      _ => throw const NasNovelRepositoryException(
          'invalid_request',
          'invalid novel sort order',
        ),
    };
    final trimmedQuery = query?.trim();
    if (trimmedQuery != null && trimmedQuery.runes.length > 120) {
      throw const NasNovelRepositoryException(
        'invalid_request',
        'novel query is too long',
      );
    }
    final hasQuery = trimmedQuery != null && trimmedQuery.isNotEmpty;
    final where = hasQuery
        ? '''storage_state = 'healthy' AND
             (title LIKE ? ESCAPE '\\' OR author LIKE ? ESCAPE '\\'
              OR relative_path LIKE ? ESCAPE '\\')'''
        : "storage_state = 'healthy'";
    final escaped = hasQuery ? '%${_escapeLike(trimmedQuery)}%' : null;
    final parameters = <Object?>[
      if (hasQuery) escaped,
      if (hasQuery) escaped,
      if (hasQuery) escaped,
    ];
    final total = database
        .select(
          'SELECT COUNT(*) AS count FROM novels WHERE $where',
          parameters,
        )
        .first['count'] as int;
    final rows = database.select(
      '''SELECT * FROM novels WHERE $where
         ORDER BY $sortColumn $direction, id $direction
         LIMIT ? OFFSET ?''',
      [...parameters, pageSize, (page - 1) * pageSize],
    );
    return NasNovelPage(
      items: rows.map(_novelFromRow).toList(growable: false),
      number: page,
      size: pageSize,
      total: total,
    );
  }

  NasNovel? find(String id, {bool includeUnhealthy = false}) {
    final rows = database.select(
      'SELECT * FROM novels WHERE id = ? '
      "${includeUnhealthy ? '' : "AND storage_state = 'healthy'"}",
      [id],
    );
    return rows.isEmpty ? null : _novelFromRow(rows.first);
  }

  NasNovel? findHealthyByDigest(String digest) {
    final rows = database.select(
      "SELECT * FROM novels WHERE content_sha256 = ? AND storage_state = 'healthy' "
      'ORDER BY created_at, id LIMIT 1',
      [digest],
    );
    return rows.isEmpty ? null : _novelFromRow(rows.first);
  }

  List<NasNovel> allIncludingUnhealthy() => database
      .select('SELECT * FROM novels ORDER BY id')
      .map(_novelFromRow)
      .toList(growable: false);

  Set<String> referencedContentDigests() => database
      .select('SELECT content_sha256 FROM novel_content_objects')
      .map((row) => row['content_sha256'] as String)
      .toSet();

  void setStorageState(String novelId, NasNovelStorageState state) {
    final value = switch (state) {
      NasNovelStorageState.healthy => 'healthy',
      NasNovelStorageState.missing => 'missing',
      NasNovelStorageState.corrupt => 'corrupt',
    };
    database.execute(
      'UPDATE novels SET storage_state = ? WHERE id = ?',
      [value, novelId],
    );
  }

  int get logicalUsageBytes => database
      .select(
        'SELECT logical_bytes FROM novel_quota_state WHERE singleton_id = 1',
      )
      .first['logical_bytes'] as int;

  bool get hasNovels =>
      database.select('SELECT 1 FROM novels LIMIT 1').isNotEmpty;

  NasNovelIdempotencyAcquisition acquireIdempotency({
    required NasNovelIdempotencyScope scope,
    required String semanticDigest,
    DateTime? now,
    Duration leaseDuration = const Duration(minutes: 5),
  }) {
    final timestamp = (now ?? DateTime.now().toUtc()).toUtc();
    database.execute('BEGIN IMMEDIATE');
    try {
      var existing = _findIdempotency(scope);
      final expiresAt = existing?.expiresAt;
      if (existing != null &&
          existing.state != NasNovelIdempotencyState.inProgress &&
          expiresAt != null &&
          !expiresAt.isAfter(timestamp)) {
        database.execute(
          '''DELETE FROM novel_idempotency
             WHERE device_id = ? AND http_method = ? AND canonical_path = ?
               AND idempotency_key = ? AND state != 'in_progress'
               AND expires_at <= ?''',
          [
            scope.deviceId,
            scope.method,
            scope.canonicalPath,
            scope.key,
            _time(timestamp),
          ],
        );
        existing = _findIdempotency(scope);
      }
      if (existing == null) {
        final ownerNonce = newUuidV4();
        final leaseExpiresAt = timestamp.add(leaseDuration);
        database.execute(
          '''INSERT INTO novel_idempotency(
            device_id, http_method, canonical_path, idempotency_key,
            semantic_digest, state, owner_nonce, lease_expires_at,
            created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, 'in_progress', ?, ?, ?, ?)''',
          [
            scope.deviceId,
            scope.method,
            scope.canonicalPath,
            scope.key,
            semanticDigest,
            ownerNonce,
            _time(leaseExpiresAt),
            _time(timestamp),
            _time(timestamp),
          ],
        );
        database.execute('COMMIT');
        return NasNovelIdempotencyAcquisition(
          decision: NasNovelIdempotencyDecision.acquired,
          ownerNonce: ownerNonce,
          record: _findIdempotency(scope)!,
        );
      }
      if (existing.semanticDigest != semanticDigest) {
        database.execute('COMMIT');
        return NasNovelIdempotencyAcquisition(
          decision: NasNovelIdempotencyDecision.conflict,
          record: existing,
        );
      }
      if (existing.state == NasNovelIdempotencyState.succeeded) {
        database.execute('COMMIT');
        return NasNovelIdempotencyAcquisition(
          decision: NasNovelIdempotencyDecision.replay,
          record: existing,
        );
      }
      if (existing.state == NasNovelIdempotencyState.gone) {
        database.execute('COMMIT');
        return NasNovelIdempotencyAcquisition(
          decision: NasNovelIdempotencyDecision.gone,
          record: existing,
        );
      }
      final leaseExpiresAt = existing.leaseExpiresAt;
      if (leaseExpiresAt != null && leaseExpiresAt.isAfter(timestamp)) {
        database.execute('COMMIT');
        return NasNovelIdempotencyAcquisition(
          decision: NasNovelIdempotencyDecision.inProgress,
          record: existing,
        );
      }
      final ownerNonce = newUuidV4();
      database.execute(
        '''UPDATE novel_idempotency
           SET owner_nonce = ?, lease_expires_at = ?, updated_at = ?
           WHERE device_id = ? AND http_method = ? AND canonical_path = ?
             AND idempotency_key = ? AND state = 'in_progress'
             AND owner_nonce = ?''',
        [
          ownerNonce,
          _time(timestamp.add(leaseDuration)),
          _time(timestamp),
          scope.deviceId,
          scope.method,
          scope.canonicalPath,
          scope.key,
          existing.ownerNonce,
        ],
      );
      final acquired = _findIdempotency(scope)!;
      database.execute('COMMIT');
      return NasNovelIdempotencyAcquisition(
        decision: acquired.ownerNonce == ownerNonce
            ? NasNovelIdempotencyDecision.acquired
            : NasNovelIdempotencyDecision.inProgress,
        ownerNonce: acquired.ownerNonce == ownerNonce ? ownerNonce : null,
        record: acquired,
      );
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  bool renewIdempotencyLease({
    required NasNovelIdempotencyScope scope,
    required String ownerNonce,
    DateTime? now,
    Duration leaseDuration = const Duration(minutes: 5),
  }) {
    final timestamp = (now ?? DateTime.now().toUtc()).toUtc();
    database.execute(
      '''UPDATE novel_idempotency
         SET lease_expires_at = ?, updated_at = ?
         WHERE device_id = ? AND http_method = ? AND canonical_path = ?
           AND idempotency_key = ? AND state = 'in_progress'
           AND owner_nonce = ?''',
      [
        _time(timestamp.add(leaseDuration)),
        _time(timestamp),
        scope.deviceId,
        scope.method,
        scope.canonicalPath,
        scope.key,
        ownerNonce,
      ],
    );
    return _findIdempotency(scope)?.ownerNonce == ownerNonce;
  }

  NasNovelPostCommit commitPost({
    required NasNovelIdempotencyScope scope,
    required String ownerNonce,
    required NasNovelMetadata metadata,
    required int? quotaBytes,
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now().toUtc()).toUtc();
    database.execute('BEGIN IMMEDIATE');
    try {
      _requireCurrentOwner(scope, ownerNonce);
      final duplicate = findHealthyByDigest(metadata.contentSha256);
      if (duplicate != null) {
        final result = NasNovelPostCommit(
          novel: duplicate,
          deduplicated: true,
          statusCode: 200,
        );
        _completeIdempotency(
          scope: scope,
          ownerNonce: ownerNonce,
          statusCode: result.statusCode,
          response: result.toResponseJson(),
          novelId: duplicate.id,
          now: timestamp,
        );
        database.execute('COMMIT');
        return result;
      }
      final conflict = _findNameConflict(metadata, excludingId: null);
      if (conflict != null &&
          metadata.conflictPolicy == NasNovelConflictPolicy.reject) {
        _releaseIdempotency(scope, ownerNonce);
        database.execute('COMMIT');
        throw const NasNovelRepositoryException(
          'novel_name_conflict',
          'a novel with the same normalized name already exists',
        );
      }
      final usage = logicalUsageBytes;
      if (quotaBytes != null && usage + metadata.sizeBytes > quotaBytes) {
        _releaseIdempotency(scope, ownerNonce);
        database.execute('COMMIT');
        throw const NasNovelRepositoryException(
          'quota_exceeded',
          'global novel quota would be exceeded',
        );
      }

      database.execute(
        '''INSERT INTO novel_content_objects(
             content_sha256, size_bytes, ref_count, created_at
           ) VALUES (?, ?, 1, ?)
           ON CONFLICT(content_sha256) DO UPDATE SET
             ref_count = ref_count + 1
           WHERE size_bytes = excluded.size_bytes''',
        [metadata.contentSha256, metadata.sizeBytes, _time(timestamp)],
      );
      final object = database.select(
        'SELECT size_bytes FROM novel_content_objects WHERE content_sha256 = ?',
        [metadata.contentSha256],
      );
      if (object.isEmpty || object.first['size_bytes'] != metadata.sizeBytes) {
        throw const NasNovelRepositoryException(
          'novel_content_unavailable',
          'content object metadata is inconsistent',
        );
      }

      final novelId = newUuidV4();
      final fileName = _novelFileName(metadata.title, novelId);
      database.execute(
        '''INSERT INTO novels(
          id, title, author, format, content_state, relative_path, file_name,
          size_bytes, content_sha256, revision, storage_state, created_at, updated_at
        ) VALUES (?, ?, ?, 'txt', 'complete_file', ?, ?, ?, ?, 1, 'healthy', ?, ?)''',
        [
          novelId,
          metadata.title,
          metadata.author,
          metadata.relativePath,
          fileName,
          metadata.sizeBytes,
          metadata.contentSha256,
          _time(timestamp),
          _time(timestamp),
        ],
      );
      database.execute(
        '''UPDATE novel_quota_state
           SET logical_bytes = logical_bytes + ?, updated_at = ?
           WHERE singleton_id = 1''',
        [metadata.sizeBytes, _time(timestamp)],
      );
      final novel = find(novelId)!;
      final result = NasNovelPostCommit(
        novel: novel,
        deduplicated: false,
        statusCode: 201,
      );
      _completeIdempotency(
        scope: scope,
        ownerNonce: ownerNonce,
        statusCode: result.statusCode,
        response: result.toResponseJson(),
        novelId: novelId,
        now: timestamp,
      );
      database.execute('COMMIT');
      return result;
    } on NasNovelRepositoryException {
      if (database.autocommit) rethrow;
      database.execute('ROLLBACK');
      rethrow;
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  NasNovelPutCommit commitPut({
    required NasNovelIdempotencyScope scope,
    required String ownerNonce,
    required String novelId,
    required int expectedRevision,
    required NasNovelMetadata metadata,
    required int? quotaBytes,
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now().toUtc()).toUtc();
    database.execute('BEGIN IMMEDIATE');
    try {
      _requireCurrentOwner(scope, ownerNonce);
      final current = find(novelId);
      if (current == null) {
        _releaseIdempotency(scope, ownerNonce);
        database.execute('COMMIT');
        throw const NasNovelRepositoryException(
          'resource_not_found',
          'novel does not exist',
        );
      }
      if (current.revision != expectedRevision) {
        _releaseIdempotency(scope, ownerNonce);
        database.execute('COMMIT');
        throw const NasNovelRepositoryException(
          'novel_revision_conflict',
          'novel revision has changed',
        );
      }

      final conflictKeyChanged =
          current.title != metadata.title || current.author != metadata.author;
      if (conflictKeyChanged &&
          _findNameConflict(metadata, excludingId: novelId) != null) {
        _releaseIdempotency(scope, ownerNonce);
        database.execute('COMMIT');
        throw const NasNovelRepositoryException(
          'novel_name_conflict',
          'a novel with the same normalized name already exists',
        );
      }
      final projectedUsage =
          logicalUsageBytes + metadata.sizeBytes - current.sizeBytes;
      if (quotaBytes != null && projectedUsage > quotaBytes) {
        _releaseIdempotency(scope, ownerNonce);
        database.execute('COMMIT');
        throw const NasNovelRepositoryException(
          'quota_exceeded',
          'global novel quota would be exceeded',
        );
      }

      final changed = current.title != metadata.title ||
          current.author != metadata.author ||
          current.relativePath != metadata.relativePath ||
          current.sizeBytes != metadata.sizeBytes ||
          current.contentSha256 != metadata.contentSha256;
      if (!changed) {
        final result = NasNovelPutCommit(
          novel: current,
          changed: false,
          unreferencedContentSha256: null,
        );
        _completeIdempotency(
          scope: scope,
          ownerNonce: ownerNonce,
          statusCode: 200,
          response: result.toResponseJson(),
          novelId: novelId,
          now: timestamp,
        );
        database.execute('COMMIT');
        return result;
      }

      final previousContentSha256 = current.contentSha256;
      if (current.contentSha256 != metadata.contentSha256) {
        database.execute(
          '''INSERT INTO novel_content_objects(
               content_sha256, size_bytes, ref_count, created_at
             ) VALUES (?, ?, 1, ?)
             ON CONFLICT(content_sha256) DO UPDATE SET
               ref_count = ref_count + 1
             WHERE size_bytes = excluded.size_bytes''',
          [metadata.contentSha256, metadata.sizeBytes, _time(timestamp)],
        );
        final object = database.select(
          'SELECT size_bytes FROM novel_content_objects WHERE content_sha256 = ?',
          [metadata.contentSha256],
        );
        if (object.isEmpty ||
            object.first['size_bytes'] != metadata.sizeBytes) {
          throw const NasNovelRepositoryException(
            'novel_content_unavailable',
            'content object metadata is inconsistent',
          );
        }
      }

      database.execute(
        '''UPDATE novels
           SET title = ?, author = ?, relative_path = ?, file_name = ?,
               size_bytes = ?, content_sha256 = ?, revision = revision + 1,
               updated_at = ?
           WHERE id = ?''',
        [
          metadata.title,
          metadata.author,
          metadata.relativePath,
          _novelFileName(metadata.title, novelId),
          metadata.sizeBytes,
          metadata.contentSha256,
          _time(timestamp),
          novelId,
        ],
      );
      final unreferenced = previousContentSha256 != metadata.contentSha256
          ? _releaseContentReference(previousContentSha256)
          : null;
      database.execute(
        '''UPDATE novel_quota_state
           SET logical_bytes = ?, updated_at = ? WHERE singleton_id = 1''',
        [projectedUsage, _time(timestamp)],
      );
      final updated = find(novelId)!;
      final result = NasNovelPutCommit(
        novel: updated,
        changed: true,
        unreferencedContentSha256: unreferenced,
      );
      _completeIdempotency(
        scope: scope,
        ownerNonce: ownerNonce,
        statusCode: 200,
        response: result.toResponseJson(),
        novelId: novelId,
        now: timestamp,
      );
      database.execute('COMMIT');
      return result;
    } on NasNovelRepositoryException {
      if (database.autocommit) rethrow;
      database.execute('ROLLBACK');
      rethrow;
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  NasNovelDeleteCommit delete({
    required String novelId,
    required int expectedRevision,
    required String actorDeviceId,
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now().toUtc()).toUtc();
    database.execute('BEGIN IMMEDIATE');
    try {
      final current = find(novelId, includeUnhealthy: true);
      if (current == null) {
        throw const NasNovelRepositoryException(
          'resource_not_found',
          'novel does not exist',
        );
      }
      if (current.revision != expectedRevision) {
        throw const NasNovelRepositoryException(
          'novel_revision_conflict',
          'novel revision has changed',
        );
      }
      database.execute('DELETE FROM novels WHERE id = ?', [novelId]);
      final unreferenced = _releaseContentReference(current.contentSha256);
      database.execute(
        '''UPDATE novel_quota_state
           SET logical_bytes = logical_bytes - ?, updated_at = ?
           WHERE singleton_id = 1''',
        [current.sizeBytes, _time(timestamp)],
      );
      database.execute(
        '''UPDATE novel_idempotency
           SET state = 'gone', owner_nonce = NULL, lease_expires_at = NULL,
               http_status = 410, response_json = NULL, updated_at = ?
           WHERE novel_id = ? AND state = 'succeeded'
             AND expires_at > ?''',
        [_time(timestamp), novelId, _time(timestamp)],
      );
      database.execute(
        '''INSERT INTO novel_deletion_audit(
             id, actor_device_id, novel_id, deleted_revision,
             content_sha256, deleted_at
           ) VALUES (?, ?, ?, ?, ?, ?)''',
        [
          newUuidV4(),
          actorDeviceId,
          novelId,
          current.revision,
          current.contentSha256,
          _time(timestamp),
        ],
      );
      database.execute('COMMIT');
      return NasNovelDeleteCommit(unreferencedContentSha256: unreferenced);
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  void releaseIdempotency({
    required NasNovelIdempotencyScope scope,
    required String ownerNonce,
  }) {
    _releaseIdempotency(scope, ownerNonce);
  }

  void cleanupRuntimeState({DateTime? now}) {
    final timestamp = (now ?? DateTime.now().toUtc()).toUtc();
    database.execute('BEGIN IMMEDIATE');
    try {
      database
          .execute("DELETE FROM novel_idempotency WHERE state = 'in_progress'");
      database.execute(
        "DELETE FROM novel_idempotency WHERE state != 'in_progress' AND expires_at <= ?",
        [_time(timestamp)],
      );
      database.execute(
        "UPDATE novel_backup_jobs SET status = 'abandoned' WHERE status = 'running'",
      );
      database.execute(
        '''DELETE FROM novel_backup_pins
           WHERE job_id IN (
             SELECT id FROM novel_backup_jobs WHERE status = 'abandoned'
           )''',
      );
      _removeUnpinnedZeroReferenceObjects();
      recomputeLogicalUsage(now: timestamp);
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  List<NasNovelBackupEntry> beginBackupJob(
    String jobId, {
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now().toUtc()).toUtc();
    database.execute('BEGIN IMMEDIATE');
    try {
      final unhealthy = database.select(
        "SELECT 1 FROM novels WHERE storage_state != 'healthy' LIMIT 1",
      );
      if (unhealthy.isNotEmpty) {
        throw const NasNovelRepositoryException(
          'novel_content_unavailable',
          'backup cannot include missing or corrupt novel content',
        );
      }
      database.execute(
        '''INSERT INTO novel_backup_jobs(id, status, created_at)
           VALUES (?, 'running', ?)''',
        [jobId, _time(timestamp)],
      );
      database.execute(
        '''INSERT INTO novel_backup_pins(job_id, content_sha256)
           SELECT ?, content_sha256 FROM novel_content_objects
           WHERE ref_count > 0''',
        [jobId],
      );
      final rows = database.select(
        '''SELECT id, revision, content_sha256, size_bytes FROM novels
           ORDER BY id''',
      );
      final entries = rows
          .map(
            (row) => NasNovelBackupEntry(
              novelId: row['id'] as String,
              revision: row['revision'] as int,
              contentSha256: row['content_sha256'] as String,
              sizeBytes: row['size_bytes'] as int,
            ),
          )
          .toList(growable: false);
      database.execute('COMMIT');
      return entries;
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  List<String> completeBackupJob(String jobId, {DateTime? now}) {
    final timestamp = (now ?? DateTime.now().toUtc()).toUtc();
    database.execute('BEGIN IMMEDIATE');
    try {
      database
          .execute('DELETE FROM novel_backup_pins WHERE job_id = ?', [jobId]);
      database.execute(
        '''UPDATE novel_backup_jobs
           SET status = 'completed', completed_at = ?
           WHERE id = ? AND status = 'running' ''',
        [_time(timestamp), jobId],
      );
      final unreferenced = _removeUnpinnedZeroReferenceObjects();
      database.execute('COMMIT');
      return unreferenced;
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  List<String> abandonBackupJob(String jobId) {
    database.execute('BEGIN IMMEDIATE');
    try {
      database
          .execute('DELETE FROM novel_backup_pins WHERE job_id = ?', [jobId]);
      database.execute(
        "UPDATE novel_backup_jobs SET status = 'abandoned' "
        "WHERE id = ? AND status = 'running'",
        [jobId],
      );
      final unreferenced = _removeUnpinnedZeroReferenceObjects();
      database.execute('COMMIT');
      return unreferenced;
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  void recomputeLogicalUsage({DateTime? now}) {
    final timestamp = (now ?? DateTime.now().toUtc()).toUtc();
    final usage = database
        .select(
          'SELECT COALESCE(SUM(size_bytes), 0) AS total FROM novels',
        )
        .first['total'] as int;
    database.execute(
      '''UPDATE novel_quota_state SET logical_bytes = ?, updated_at = ?
         WHERE singleton_id = 1''',
      [usage, _time(timestamp)],
    );
  }

  NasNovelIdempotencyRecord? _findIdempotency(
    NasNovelIdempotencyScope scope,
  ) {
    final rows = database.select(
      '''SELECT * FROM novel_idempotency
         WHERE device_id = ? AND http_method = ? AND canonical_path = ?
           AND idempotency_key = ?''',
      [scope.deviceId, scope.method, scope.canonicalPath, scope.key],
    );
    return rows.isEmpty ? null : _idempotencyFromRow(rows.first);
  }

  NasNovel? _findNameConflict(
    NasNovelMetadata metadata, {
    required String? excludingId,
  }) {
    final rows = database.select(
      '''SELECT * FROM novels
         WHERE title = ? AND author IS ? AND format = 'txt'
           AND storage_state = 'healthy'
           ${excludingId == null ? '' : 'AND id != ?'}
         ORDER BY created_at, id LIMIT 1''',
      [metadata.title, metadata.author, if (excludingId != null) excludingId],
    );
    return rows.isEmpty ? null : _novelFromRow(rows.first);
  }

  void _requireCurrentOwner(
    NasNovelIdempotencyScope scope,
    String ownerNonce,
  ) {
    final current = _findIdempotency(scope);
    if (current?.state != NasNovelIdempotencyState.inProgress ||
        current?.ownerNonce != ownerNonce) {
      throw const NasNovelRepositoryException(
        'upload_in_progress',
        'idempotency lease is no longer owned by this request',
      );
    }
  }

  void _completeIdempotency({
    required NasNovelIdempotencyScope scope,
    required String ownerNonce,
    required int statusCode,
    required Map<String, Object?> response,
    required String novelId,
    required DateTime now,
  }) {
    database.execute(
      '''UPDATE novel_idempotency
         SET state = 'succeeded', owner_nonce = NULL, lease_expires_at = NULL,
             http_status = ?, response_json = ?, novel_id = ?, expires_at = ?,
             updated_at = ?
         WHERE device_id = ? AND http_method = ? AND canonical_path = ?
           AND idempotency_key = ? AND state = 'in_progress'
           AND owner_nonce = ?''',
      [
        statusCode,
        jsonEncode(response),
        novelId,
        _time(now.add(const Duration(days: 7))),
        _time(now),
        scope.deviceId,
        scope.method,
        scope.canonicalPath,
        scope.key,
        ownerNonce,
      ],
    );
    final current = _findIdempotency(scope);
    if (current?.state != NasNovelIdempotencyState.succeeded) {
      throw const NasNovelRepositoryException(
        'upload_in_progress',
        'idempotency lease changed before the request committed',
      );
    }
  }

  void _releaseIdempotency(
    NasNovelIdempotencyScope scope,
    String ownerNonce,
  ) {
    database.execute(
      '''DELETE FROM novel_idempotency
         WHERE device_id = ? AND http_method = ? AND canonical_path = ?
           AND idempotency_key = ? AND state = 'in_progress'
           AND owner_nonce = ?''',
      [
        scope.deviceId,
        scope.method,
        scope.canonicalPath,
        scope.key,
        ownerNonce,
      ],
    );
  }

  String? _releaseContentReference(String digest) {
    database.execute(
      '''UPDATE novel_content_objects SET ref_count = ref_count - 1
         WHERE content_sha256 = ? AND ref_count > 0''',
      [digest],
    );
    final rows = database.select(
      'SELECT ref_count FROM novel_content_objects WHERE content_sha256 = ?',
      [digest],
    );
    if (rows.isEmpty || rows.first['ref_count'] != 0) return null;
    final pinned = database.select(
      'SELECT 1 FROM novel_backup_pins WHERE content_sha256 = ? LIMIT 1',
      [digest],
    );
    if (pinned.isNotEmpty) return null;
    database.execute(
      'DELETE FROM novel_content_objects WHERE content_sha256 = ? AND ref_count = 0',
      [digest],
    );
    return digest;
  }

  List<String> _removeUnpinnedZeroReferenceObjects() {
    final rows = database.select(
      '''SELECT content_sha256 FROM novel_content_objects objects
         WHERE ref_count = 0 AND NOT EXISTS(
           SELECT 1 FROM novel_backup_pins pins
           WHERE pins.content_sha256 = objects.content_sha256
         )''',
    );
    final digests = rows
        .map((row) => row['content_sha256'] as String)
        .toList(growable: false);
    for (final digest in digests) {
      database.execute(
        'DELETE FROM novel_content_objects WHERE content_sha256 = ?',
        [digest],
      );
    }
    return digests;
  }
}

NasNovel _novelFromRow(Row row) => NasNovel(
      id: row['id'] as String,
      title: row['title'] as String,
      author: row['author'] as String?,
      relativePath: row['relative_path'] as String,
      fileName: row['file_name'] as String,
      sizeBytes: row['size_bytes'] as int,
      contentSha256: row['content_sha256'] as String,
      revision: row['revision'] as int,
      storageState: switch (row['storage_state'] as String) {
        'healthy' => NasNovelStorageState.healthy,
        'missing' => NasNovelStorageState.missing,
        'corrupt' => NasNovelStorageState.corrupt,
        _ => throw StateError('Unknown novel storage state'),
      },
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
    );

NasNovelIdempotencyRecord _idempotencyFromRow(Row row) =>
    NasNovelIdempotencyRecord(
      scope: NasNovelIdempotencyScope(
        deviceId: row['device_id'] as String,
        method: row['http_method'] as String,
        canonicalPath: row['canonical_path'] as String,
        key: row['idempotency_key'] as String,
      ),
      semanticDigest: row['semantic_digest'] as String,
      state: switch (row['state'] as String) {
        'in_progress' => NasNovelIdempotencyState.inProgress,
        'succeeded' => NasNovelIdempotencyState.succeeded,
        'gone' => NasNovelIdempotencyState.gone,
        _ => throw StateError('Unknown novel idempotency state'),
      },
      ownerNonce: row['owner_nonce'] as String?,
      leaseExpiresAt: _optionalTime(row['lease_expires_at'] as String?),
      httpStatus: row['http_status'] as int?,
      responseJson: row['response_json'] as String?,
      novelId: row['novel_id'] as String?,
      expiresAt: _optionalTime(row['expires_at'] as String?),
    );

String _escapeLike(String value) => value
    .replaceAll('\\', '\\\\')
    .replaceAll('%', '\\%')
    .replaceAll('_', '\\_');

String _novelFileName(String title, String id) {
  final sanitized = title
      .replaceAll(RegExp(r'[\x00-\x1F\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '')
      .trim();
  final base = sanitized.isEmpty ? 'novel-$id' : sanitized;
  final runes = base.runes.take(180).toList(growable: false);
  return '${String.fromCharCodes(runes)}.txt';
}

String _time(DateTime value) => value.toUtc().toIso8601String();

DateTime? _optionalTime(String? value) =>
    value == null ? null : DateTime.parse(value).toUtc();
