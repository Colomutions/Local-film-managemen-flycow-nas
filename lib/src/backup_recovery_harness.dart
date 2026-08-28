import 'dart:io';

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
    return _backupService.restoreToIsolatedDirectory(
      backupId: backupId,
      target: target,
    );
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
