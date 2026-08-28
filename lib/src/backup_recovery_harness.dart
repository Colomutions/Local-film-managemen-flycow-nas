import 'dart:io';

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
      } finally {
        database.dispose();
      }
    } on StateError {
      rethrow;
    } catch (_) {
      throw StateError('Restored SQLite snapshot integrity check failed.');
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
