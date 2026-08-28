import 'dart:convert';
import 'dart:io';

import '../lib/src/backup_recovery_harness.dart';
import '../lib/src/backup_service.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-nas-recovery-harness-');
  final dataDir = Directory('${directory.path}${Platform.pathSeparator}data');
  const backupId = '00000000-0000-4000-8000-000000000001';
  final backupDir = Directory(
    '${dataDir.path}${Platform.pathSeparator}backups${Platform.pathSeparator}$backupId',
  );
  final createdAt = DateTime.utc(2026, 8, 28, 2, 0);
  try {
    await _writeFixture(backupDir, backupId, createdAt);
    final harness = NasBackupRecoveryHarness(NasBackupService(dataDir.path));
    final target = Directory(
      '${directory.path}${Platform.pathSeparator}isolated-copy',
    );
    final restored = await harness.restore(
      backupId: backupId,
      target: target,
    );
    _expect(restored.id == backupId, 'returns the validated backup record');
    _expect(
      await File(
        '${target.path}${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite',
      ).exists(),
      'copies the SQLite payload',
    );
    _expect(
      await File(
        '${target.path}${Platform.pathSeparator}artwork${Platform.pathSeparator}posters${Platform.pathSeparator}poster.png',
      ).exists(),
      'copies artwork payloads',
    );
    _expect(
      !await Directory('${target.path}${Platform.pathSeparator}media').exists(),
      'isolated target contains no media directory',
    );
    _expect(await backupDir.exists(), 'source backup remains intact');

    var existingRejected = false;
    try {
      await harness.restore(backupId: backupId, target: target);
    } on StateError {
      existingRejected = true;
    }
    _expect(existingRejected, 'existing target is rejected');

    var insideDataRejected = false;
    try {
      await harness.restore(
        backupId: backupId,
        target: Directory('${dataDir.path}${Platform.pathSeparator}restore'),
      );
    } on StateError {
      insideDataRejected = true;
    }
    _expect(insideDataRejected, 'target inside live data is rejected');
    _expect(
      !await Directory('${dataDir.path}${Platform.pathSeparator}restore')
          .exists(),
      'rejected target is not created',
    );
  } finally {
    await directory.delete(recursive: true);
  }

  stdout.writeln('backup_recovery_harness_test: PASS');
}

Future<void> _writeFixture(
  Directory backupDir,
  String backupId,
  DateTime createdAt,
) async {
  final db = File(
    '${backupDir.path}${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite',
  );
  final state = File(
    '${backupDir.path}${Platform.pathSeparator}state${Platform.pathSeparator}server.json',
  );
  final poster = File(
    '${backupDir.path}${Platform.pathSeparator}artwork${Platform.pathSeparator}posters${Platform.pathSeparator}poster.png',
  );
  await db.parent.create(recursive: true);
  await state.parent.create(recursive: true);
  await poster.parent.create(recursive: true);
  await db.writeAsString('sqlite snapshot');
  await state.writeAsString('{"serverId":"fixture"}');
  await poster.writeAsBytes(const [137, 80, 78, 71]);
  await File('${backupDir.path}${Platform.pathSeparator}manifest.json')
      .writeAsString(jsonEncode({
    'id': backupId,
    'createdAt': createdAt.toIso8601String(),
    'sizeBytes': 42,
  }));
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('Assertion failed: $message');
}
