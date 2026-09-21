import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'backup_service.dart';

/// A deliberately local-only wrapper around isolated backup recovery.
///
/// This class does not expose an HTTP route and never targets the live data
/// directory. It is intended for a separately approved operational harness.
class NasBackupRecoveryHarness {
  NasBackupRecoveryHarness(this._backupService);

  final NasBackupService _backupService;

  Future<NasBackupRecord> restore({
    required String backupId,
    required Directory target,
  }) async {
    await _rejectSymlinkTarget(target);
    NasBackupRecord? restored;
    try {
      restored = await _backupService.restoreToIsolatedDirectory(
        backupId: backupId,
        target: target,
      );
      await _verifyRestoredSnapshot(target);
      return restored;
    } catch (_) {
      // The service already cleans its own temporary directory. If it had
      // completed the rename but validation failed, remove only this newly
      // created isolated target; an existing target was rejected up front.
      if (restored != null && await target.exists()) {
        await target.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<void> _verifyRestoredSnapshot(Directory target) async {
    final snapshot = File(
      '${target.path}${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite',
    );
    if (await FileSystemEntity.type(snapshot.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Restored backup does not contain a SQLite snapshot.');
    }
    try {
      final database = sqlite3.open(snapshot.path);
      try {
        final check = database.select('PRAGMA integrity_check');
        if (check.length != 1 || check.single['integrity_check'] != 'ok') {
          throw StateError('Restored SQLite snapshot integrity check failed.');
        }
        await _verifyNovelPayload(target, database);
        _resetNovelRuntimeState(database);
      } finally {
        database.dispose();
      }
    } on StateError {
      rethrow;
    } catch (_) {
      throw StateError('Restored SQLite snapshot integrity check failed.');
    }
  }

  void _resetNovelRuntimeState(Database database) {
    final hasNovelTables = database
        .select(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'novel_idempotency'",
        )
        .isNotEmpty;
    if (!hasNovelTables) return;
    final now = DateTime.now().toUtc().toIso8601String();
    database.execute('BEGIN IMMEDIATE');
    try {
      database
          .execute("DELETE FROM novel_idempotency WHERE state = 'in_progress'");
      database.execute(
        "DELETE FROM novel_idempotency WHERE state != 'in_progress' AND expires_at <= ?",
        [now],
      );
      database.execute(
        '''UPDATE novel_idempotency
           SET state = 'gone', owner_nonce = NULL, lease_expires_at = NULL,
               http_status = 410, response_json = NULL, updated_at = ?
           WHERE state = 'succeeded' AND expires_at > ?
             AND (novel_id IS NULL OR NOT EXISTS(
               SELECT 1 FROM novels WHERE novels.id = novel_idempotency.novel_id
             ))''',
        [now, now],
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
      final usage = database
          .select(
            'SELECT COALESCE(SUM(size_bytes), 0) AS total FROM novels',
          )
          .first['total'] as int;
      database.execute(
        '''UPDATE novel_quota_state
           SET logical_bytes = ?, updated_at = ? WHERE singleton_id = 1''',
        [usage, now],
      );
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> _verifyNovelPayload(
    Directory target,
    Database database,
  ) async {
    final manifestFile =
        File('${target.path}${Platform.pathSeparator}manifest.json');
    final decoded = jsonDecode(await manifestFile.readAsString());
    if (decoded is! Map) throw StateError('Backup manifest is invalid.');
    final novelManifest = decoded['novels'];
    final hasNovelTable = database
        .select(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'novels'",
        )
        .isNotEmpty;
    final databaseNovelCount = hasNovelTable
        ? database.select('SELECT COUNT(*) AS count FROM novels').first['count']
            as int
        : 0;
    if (novelManifest == null) {
      if (databaseNovelCount != 0) {
        throw StateError('Backup omits novel content referenced by SQLite.');
      }
      return;
    }
    if (novelManifest is! Map ||
        novelManifest['version'] != 1 ||
        novelManifest['items'] is! List) {
      throw StateError('Novel backup manifest is invalid.');
    }
    final items = novelManifest['items'] as List;
    if (items.length != databaseNovelCount) {
      throw StateError('Novel backup manifest does not match SQLite.');
    }
    final expectedObjects = <String>{};
    for (final raw in items) {
      if (raw is! Map) throw StateError('Novel backup entry is invalid.');
      final novelId = raw['novelId'];
      final revision = raw['revision'];
      final relativePath = raw['relativePath'];
      final sizeBytes = raw['sizeBytes'];
      final digest = raw['sha256'];
      if (novelId is! String ||
          revision is! int ||
          revision < 1 ||
          sizeBytes is! int ||
          sizeBytes < 0 ||
          digest is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
          relativePath != 'novels/objects/$digest') {
        throw StateError('Novel backup entry is invalid.');
      }
      final rows = database.select(
        '''SELECT revision, size_bytes, content_sha256 FROM novels
           WHERE id = ?''',
        [novelId],
      );
      if (rows.length != 1 ||
          rows.single['revision'] != revision ||
          rows.single['size_bytes'] != sizeBytes ||
          rows.single['content_sha256'] != digest) {
        throw StateError('Novel backup entry does not match SQLite.');
      }
      if (!expectedObjects.add(digest)) continue;
      final object = File(
        '${target.path}${Platform.pathSeparator}novels'
        '${Platform.pathSeparator}objects${Platform.pathSeparator}$digest',
      );
      if (await FileSystemEntity.type(object.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await object.length() != sizeBytes) {
        throw StateError(
            'Novel backup object is missing or has an invalid size.');
      }
      final actual = await sha256.bind(object.openRead()).first;
      if (actual.toString() != digest) {
        throw StateError('Novel backup object has an invalid digest.');
      }
    }
    final objectDirectory = Directory(
      '${target.path}${Platform.pathSeparator}novels'
      '${Platform.pathSeparator}objects',
    );
    if (await objectDirectory.exists()) {
      await for (final entity in objectDirectory.list(followLinks: false)) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (entity is! File || !expectedObjects.contains(name)) {
          throw StateError('Novel backup contains an unmanifested object.');
        }
      }
    }
  }

  Future<void> _rejectSymlinkTarget(Directory target) async {
    final targetType =
        await FileSystemEntity.type(target.path, followLinks: false);
    if (targetType != FileSystemEntityType.notFound) {
      throw StateError('Restore target must be a new, non-link path.');
    }

    // A missing target can still be reached through a symlinked parent. Walk
    // to the first existing ancestor without following links so the harness
    // cannot redirect its temporary copy into an unintended tree.
    var ancestor = target.absolute.parent;
    while (true) {
      final type =
          await FileSystemEntity.type(ancestor.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw StateError('Restore target has a symlinked parent.');
      }
      if (type != FileSystemEntityType.notFound) return;
      final parent = ancestor.parent;
      if (parent.path == ancestor.path) return;
      ancestor = parent;
    }
  }
}
