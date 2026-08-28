import 'dart:convert';
import 'dart:io';

import '../lib/src/backup_recovery_harness.dart';
import '../lib/src/backup_service.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == '--help') {
    stdout.writeln(_usage);
    return;
  }
  final options = _parse(arguments);
  if (options == null) {
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }

  try {
    final record = await NasBackupRecoveryHarness(
      NasBackupService(options.dataDir),
    ).restore(
      backupId: options.backupId,
      target: Directory(options.target),
    );
    // Keep operational output useful but non-sensitive: never print paths,
    // manifest contents, token hashes, or the complete backup ID.
    stdout.writeln(jsonEncode({
      'status': 'restored_to_isolated_directory',
      'backupIdShort': record.id.substring(0, 8),
      'createdAt': record.createdAt.toUtc().toIso8601String(),
      'sizeBytes': record.sizeBytes,
    }));
  } catch (_) {
    stderr.writeln('backup_recovery_harness: isolated restore failed');
    exitCode = 1;
  }
}

const _usage = '用法: dart run tool/backup_recovery_harness.dart '
    '--data-dir <data-dir> --backup-id <id> --target <new-isolated-dir>';

_Options? _parse(List<String> arguments) {
  final values = <String, String>{};
  for (var index = 0; index < arguments.length; index += 2) {
    if (index + 1 >= arguments.length) return null;
    final key = arguments[index];
    if (key != '--data-dir' && key != '--backup-id' && key != '--target') {
      return null;
    }
    if (values.containsKey(key)) return null;
    final value = arguments[index + 1];
    if (value.isEmpty) return null;
    values[key] = value;
  }
  final dataDir = values['--data-dir'];
  final backupId = values['--backup-id'];
  final target = values['--target'];
  if (dataDir == null || backupId == null || target == null) return null;
  return _Options(dataDir: dataDir, backupId: backupId, target: target);
}

class _Options {
  const _Options({
    required this.dataDir,
    required this.backupId,
    required this.target,
  });

  final String dataDir;
  final String backupId;
  final String target;
}
