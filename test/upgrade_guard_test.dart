import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/src/library_database.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-nas-upgrade-guard-');
  final dataDir = Directory('${directory.path}${Platform.pathSeparator}data');
  final databaseFile = File(
    '${dataDir.path}${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite',
  );
  try {
    final database = NasLibraryDatabase(dataDir.path);
    await database.open();
    await database.close();
    _expect(
        await databaseFile.exists(), 'migration creates a persistent database');
    _expect(
      _schemaVersions(databaseFile.path).join(',') == '1,2,3,4',
      'fresh database applies each schema version once',
    );

    await database.open();
    await database.close();
    _expect(
      _schemaVersions(databaseFile.path).join(',') == '1,2,3,4',
      'reopening does not repeat or duplicate migrations',
    );

    final futureDirectory =
        await Directory.systemTemp.createTemp('mujing-nas-future-schema-');
    try {
      final futureData =
          Directory('${futureDirectory.path}${Platform.pathSeparator}data');
      final futureFile = File(
        '${futureData.path}${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite',
      );
      await futureFile.parent.create(recursive: true);
      final futureDatabase = sqlite3.open(futureFile.path);
      try {
        futureDatabase.execute('''
          CREATE TABLE schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL
          );
          INSERT INTO schema_migrations(version, applied_at)
          VALUES (99, 'fixture');
        ''');
      } finally {
        futureDatabase.dispose();
      }

      final guarded = NasLibraryDatabase(futureData.path);
      var rejected = false;
      try {
        await guarded.open();
      } on StateError catch (error) {
        rejected =
            error.message.toString().contains('Unsupported database schema');
      } finally {
        await guarded.close();
      }
      _expect(rejected, 'older service rejects a future schema version');

      final verify = sqlite3.open(futureFile.path);
      try {
        _expect(
          verify
              .select(
                  "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'media_roots'")
              .isEmpty,
          'future schema rejection does not partially create current tables',
        );
      } finally {
        verify.dispose();
      }
    } finally {
      await futureDirectory.delete(recursive: true);
    }
  } finally {
    await directory.delete(recursive: true);
  }

  stdout.writeln('upgrade_guard_test: PASS');
}

List<int> _schemaVersions(String path) {
  final database = sqlite3.open(path);
  try {
    return database
        .select('SELECT version FROM schema_migrations ORDER BY version')
        .map((row) => row['version'] as int)
        .toList(growable: false);
  } finally {
    database.dispose();
  }
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('Assertion failed: $message');
}
