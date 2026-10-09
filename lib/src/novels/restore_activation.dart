import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../content_file_names.dart';

class NasRestoreActivationService {
  NasRestoreActivationService({
    required this.dataDir,
    this.novelDir,
  });

  final String dataDir;
  final String? novelDir;

  Directory get _databaseDirectory =>
      Directory('$dataDir${Platform.pathSeparator}db');
  File get _activeDatabase =>
      File('${_databaseDirectory.path}${Platform.pathSeparator}mujing.sqlite');
  File get _stagingDatabase => File(
        '${_databaseDirectory.path}${Platform.pathSeparator}mujing.restore-staging.sqlite',
      );
  File get _rollbackDatabase => File(
        '${_databaseDirectory.path}${Platform.pathSeparator}mujing.restore-rollback.sqlite',
      );
  File get _journal => File(
        '${_databaseDirectory.path}${Platform.pathSeparator}restore-activation.json',
      );

  Future<void> recoverIncompleteActivation() async {
    if (!await _journal.exists()) return;
    final journal = await _readJournal();
    final phase = journal['phase'];
    if (phase == 'completed') {
      await _deleteIfExists(_rollbackDatabase);
      await _deleteIfExists(_stagingDatabase);
      await _deleteIfExists(_journal);
      return;
    }
    if (await _rollbackDatabase.exists()) {
      await _deleteDatabaseWithSidecars(_activeDatabase);
      await _rollbackDatabase.rename(_activeDatabase.path);
    }
    await _deleteIfExists(_stagingDatabase);
    await _deleteSidecars(_activeDatabase);
    await _deleteIfExists(_journal);
  }

  Future<void> activate({
    required Directory restoredDirectory,
    required Future<void> Function() enterMaintenance,
    required Future<void> Function() leaveMaintenance,
    required Future<void> Function() closeDatabase,
    required Future<void> Function() openAndValidateDatabase,
  }) async {
    await recoverIncompleteActivation();
    final restoredDatabase = File(
      '${restoredDirectory.path}${Platform.pathSeparator}db'
      '${Platform.pathSeparator}mujing.sqlite',
    );
    if (!await restoredDatabase.exists()) {
      throw StateError('Restored SQLite database is missing.');
    }
    await _databaseDirectory.create(recursive: true);
    await _copyFileDurably(restoredDatabase, _stagingDatabase);

    var maintenanceEntered = false;
    var databaseClosed = false;
    try {
      await enterMaintenance();
      maintenanceEntered = true;
      // Uploads must be drained before reserving human-readable names against
      // the live directory; their catalog is independent of the staged one.
      await _publishNovelObjects(restoredDirectory);
      await _writeJournal('prepared');
      await closeDatabase();
      databaseClosed = true;
      await _deleteIfExists(_rollbackDatabase);
      if (await _activeDatabase.exists()) {
        await _activeDatabase.rename(_rollbackDatabase.path);
      }
      await _writeJournal('old_moved');
      await _stagingDatabase.rename(_activeDatabase.path);
      await _deleteSidecars(_activeDatabase);
      await _writeJournal('new_active');
      await openAndValidateDatabase();
      databaseClosed = false;
      await _writeJournal('completed');
      await leaveMaintenance();
      maintenanceEntered = false;
    } catch (_) {
      if (!databaseClosed) {
        try {
          await closeDatabase();
        } catch (_) {}
      }
      if (await _rollbackDatabase.exists()) {
        await _deleteDatabaseWithSidecars(_activeDatabase);
        await _rollbackDatabase.rename(_activeDatabase.path);
      }
      await _deleteIfExists(_stagingDatabase);
      await _deleteSidecars(_activeDatabase);
      try {
        await openAndValidateDatabase();
        databaseClosed = false;
        await _deleteIfExists(_journal);
        if (maintenanceEntered) {
          await leaveMaintenance();
          maintenanceEntered = false;
        }
      } catch (_) {
        // Keep maintenance active when neither database can be validated.
      }
      rethrow;
    }
  }

  Future<void> _publishNovelObjects(Directory restoredDirectory) async {
    final manifestFile = File(
      '${restoredDirectory.path}${Platform.pathSeparator}manifest.json',
    );
    final decoded = jsonDecode(await manifestFile.readAsString());
    if (decoded is! Map) throw StateError('Backup manifest is invalid.');
    final novels = decoded['novels'];
    if (novels == null) return;
    if (novelDir == null)
      throw StateError('Novel storage is unavailable for restore.');
    if (novels is! Map || novels['items'] is! List) {
      throw StateError('Novel backup manifest is invalid.');
    }
    final objectDirectory =
        Directory('$novelDir${Platform.pathSeparator}objects');
    final temporaryDirectory =
        Directory('$novelDir${Platform.pathSeparator}.tmp');
    await objectDirectory.create(recursive: true);
    await temporaryDirectory.create(recursive: true);
    final database = sqlite3.open(_stagingDatabase.path);
    try {
      // Reallocate in the staged catalog: live files from a later upload may
      // already use a backed-up name. Never overwrite those rollback files.
      database.execute('PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;');
      ContentFileNames.createSchema(database);
      database.execute('DELETE FROM reading_content_file_names');
      final names = ContentFileNames(database);
      final handled = <String>{};
      for (final raw in novels['items'] as List) {
        if (raw is! Map ||
            raw['sha256'] is! String ||
            raw['sizeBytes'] is! int) {
          throw StateError('Novel backup entry is invalid.');
        }
        final digest = raw['sha256'] as String;
        final sizeBytes = raw['sizeBytes'] as int;
        if (!handled.add(digest)) continue;
        final source = File(
          '${restoredDirectory.path}${Platform.pathSeparator}novels'
          '${Platform.pathSeparator}objects${Platform.pathSeparator}$digest',
        );
        final rows = database.select(
          'SELECT file_name FROM novels WHERE content_sha256 = ? ORDER BY id LIMIT 1',
          [digest],
        );
        if (rows.isEmpty)
          throw StateError('Restored novel catalog is incomplete');
        final name = await names.reserve(
          digest,
          rows.single['file_name'] as String,
          objectDirectory,
          reuseExisting: (file) async =>
              await file.length() == sizeBytes &&
              (await sha256.bind(file.openRead()).first).toString() == digest,
        );
        final destination =
            File('${objectDirectory.path}${Platform.pathSeparator}$name');
        if (await destination.exists()) {
          continue;
        }
        final temporary = File(
          '${temporaryDirectory.path}${Platform.pathSeparator}restore-$digest',
        );
        await _copyFileDurably(source, temporary);
        await _verifyObject(temporary, digest, sizeBytes);
        try {
          await temporary.rename(destination.path);
        } on FileSystemException {
          if (!await destination.exists()) rethrow;
          await _verifyObject(destination, digest, sizeBytes);
          await _deleteIfExists(temporary);
        }
      }
    } finally {
      database.dispose();
    }
  }

  Future<void> _verifyObject(File file, String digest, int sizeBytes) async {
    if (!await file.exists() || await file.length() != sizeBytes) {
      throw StateError('Restored novel object has an invalid size.');
    }
    final actual = await sha256.bind(file.openRead()).first;
    if (actual.toString() != digest) {
      throw StateError('Restored novel object has an invalid digest.');
    }
  }

  Future<void> _copyFileDurably(File source, File target) async {
    await target.parent.create(recursive: true);
    await _deleteIfExists(target);
    final sink = target.openWrite(mode: FileMode.writeOnly);
    try {
      await sink.addStream(source.openRead());
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  Future<Map<String, dynamic>> _readJournal() async {
    final decoded = jsonDecode(await _journal.readAsString());
    if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
      throw StateError('Restore activation journal is invalid.');
    }
    return decoded;
  }

  Future<void> _writeJournal(String phase) => _journal.writeAsString(
        jsonEncode({
          'version': 1,
          'phase': phase,
          'activeDatabase': 'mujing.sqlite',
          'stagingDatabase': 'mujing.restore-staging.sqlite',
          'rollbackDatabase': 'mujing.restore-rollback.sqlite',
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );

  Future<void> _deleteDatabaseWithSidecars(File database) async {
    await _deleteIfExists(database);
    await _deleteSidecars(database);
  }

  Future<void> _deleteSidecars(File database) async {
    await _deleteIfExists(File('${database.path}-wal'));
    await _deleteIfExists(File('${database.path}-shm'));
    await _deleteIfExists(File('${database.path}-journal'));
  }

  Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) await file.delete();
  }
}
