import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-nas-startup-integrity-');
  try {
    await _corruptStateFailsBeforeDatabaseOpen(directory);
    await _corruptDatabaseFailsWithoutRewritingIt(directory);
    await _futureSchemaFailsWithoutPartialMigration(directory);
    await _staleBackupTemporaryDirectoryIsRecovered(directory);
  } finally {
    await directory.delete(recursive: true);
  }
  stdout.writeln('startup_integrity_test: PASS');
}

Future<void> _corruptStateFailsBeforeDatabaseOpen(Directory root) async {
  final data = Directory('${root.path}${Platform.pathSeparator}bad-state');
  final state = File(
    '${data.path}${Platform.pathSeparator}state${Platform.pathSeparator}server.json',
  );
  await state.parent.create(recursive: true);
  await state.writeAsString('{not-json');
  final server = _server(data, root);
  await _expectStartFailure(server, 'corrupt persistent state fails startup');
  _expect(await state.readAsString() == '{not-json',
      'corrupt state is not rewritten');
  _expect(
    !await File(
            '${data.path}${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite')
        .exists(),
    'database is not created after state validation failure',
  );
}

Future<void> _corruptDatabaseFailsWithoutRewritingIt(Directory root) async {
  final data = Directory('${root.path}${Platform.pathSeparator}bad-database');
  final database = File(
    '${data.path}${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite',
  );
  const bytes = <int>[110, 111, 116, 45, 115, 113, 108, 105, 116, 101];
  await database.parent.create(recursive: true);
  await database.writeAsBytes(bytes);
  final server = _server(data, root);
  await _expectStartFailure(server, 'corrupt SQLite file fails startup');
  _expect(
    _sameBytes(await database.readAsBytes(), bytes),
    'corrupt SQLite file is not rewritten on failed startup',
  );
}

Future<void> _futureSchemaFailsWithoutPartialMigration(Directory root) async {
  final data = Directory('${root.path}${Platform.pathSeparator}future-schema');
  final databaseFile = File(
    '${data.path}${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite',
  );
  await databaseFile.parent.create(recursive: true);
  final database = sqlite3.open(databaseFile.path);
  try {
    database.execute('''
      CREATE TABLE schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      );
      INSERT INTO schema_migrations(version, applied_at) VALUES (99, 'fixture');
    ''');
  } finally {
    database.dispose();
  }
  final server = _server(data, root);
  await _expectStartFailure(server, 'future schema fails startup');
  final verify = sqlite3.open(databaseFile.path);
  try {
    _expect(
      verify
          .select(
              "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'media_roots'")
          .isEmpty,
      'future schema failure does not partially migrate the database',
    );
  } finally {
    verify.dispose();
  }
}

Future<void> _staleBackupTemporaryDirectoryIsRecovered(Directory root) async {
  final data = Directory('${root.path}${Platform.pathSeparator}stale-backup');
  final partial = File(
    '${data.path}${Platform.pathSeparator}backups${Platform.pathSeparator}.tmp-123e4567-e89b-42d3-a456-426614174000${Platform.pathSeparator}partial',
  );
  final unrelated = File(
    '${data.path}${Platform.pathSeparator}backups${Platform.pathSeparator}.tmp-interrupted${Platform.pathSeparator}keep',
  );
  await partial.parent.create(recursive: true);
  await partial.writeAsString('unfinished backup');
  await unrelated.parent.create(recursive: true);
  await unrelated.writeAsString('not a managed temporary backup');
  final server = _server(data, root);
  await server.start();
  try {
    _expect(
        server.isRunning, 'service starts with an interrupted backup present');
  } finally {
    await server.stop();
  }
  _expect(!await partial.exists(),
      'startup deletes a managed interrupted backup directory');
  _expect(await unrelated.exists(),
      'startup preserves directories outside the managed pattern');
}

NasHealthServer _server(Directory data, Directory root) => NasHealthServer(
      NasConfig(
        bindHost: '127.0.0.1',
        port: 0,
        serverName: 'Test NAS',
        advertiseUrl: null,
        pairingCode: 'test-pairing-code',
        fixtureMediaRelativePath: null,
        mediaRootName: '测试媒体根',
        scanOnStart: false,
        dataDir: data.path,
        mediaDir: '${root.path}${Platform.pathSeparator}media',
        timezone: 'Asia/Shanghai',
      ),
    );

Future<void> _expectStartFailure(NasHealthServer server, String message) async {
  var failed = false;
  try {
    await server.start();
  } catch (_) {
    failed = true;
  } finally {
    if (server.isRunning) await server.stop();
  }
  _expect(failed && !server.isRunning, message);
}

bool _sameBytes(List<int> actual, List<int> expected) =>
    actual.length == expected.length &&
    actual.asMap().entries.every((entry) => entry.value == expected[entry.key]);

void _expect(bool condition, String message) {
  if (!condition) throw StateError('Assertion failed: $message');
}
