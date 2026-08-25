import 'dart:convert';
import 'dart:io';

import 'auth.dart';

class NasBackupRecord {
  const NasBackupRecord({
    required this.id,
    required this.createdAt,
    required this.sizeBytes,
  });

  final String id;
  final DateTime createdAt;
  final int sizeBytes;

  Map<String, Object> toJson() => {
        'id': id,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'sizeBytes': sizeBytes,
      };

  static NasBackupRecord? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final createdAt = DateTime.tryParse(value['createdAt'] as String? ?? '');
    final sizeBytes = value['sizeBytes'];
    if (id is! String ||
        !RegExp(r'^[a-f0-9-]{36}$').hasMatch(id) ||
        createdAt == null ||
        sizeBytes is! int ||
        sizeBytes < 0) {
      return null;
    }
    return NasBackupRecord(
      id: id,
      createdAt: createdAt.toUtc(),
      sizeBytes: sizeBytes,
    );
  }
}

class NasBackupService {
  NasBackupService(this.dataDir);

  final String dataDir;

  Directory get _backupDirectory =>
      Directory('$dataDir${Platform.pathSeparator}backups');

  Future<NasBackupRecord> create({
    required Future<void> Function(File target) databaseSnapshot,
  }) async {
    final id = newUuidV4();
    final createdAt = DateTime.now().toUtc();
    final backupRoot = _backupDirectory;
    await backupRoot.create(recursive: true);
    final temporary = Directory(
      '${backupRoot.path}${Platform.pathSeparator}.tmp-$id',
    );
    final destination =
        Directory('${backupRoot.path}${Platform.pathSeparator}$id');
    await temporary.create();
    try {
      await databaseSnapshot(
        File(
            '${temporary.path}${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite'),
      );
      await _copyFileIfExists(
        File(
            '$dataDir${Platform.pathSeparator}state${Platform.pathSeparator}server.json'),
        File(
            '${temporary.path}${Platform.pathSeparator}state${Platform.pathSeparator}server.json'),
      );
      await _copyFileIfExists(
        File(
            '$dataDir${Platform.pathSeparator}config${Platform.pathSeparator}config.json'),
        File(
            '${temporary.path}${Platform.pathSeparator}config${Platform.pathSeparator}config.json'),
      );
      await _copyDirectoryIfExists(
        Directory(
            '$dataDir${Platform.pathSeparator}artwork${Platform.pathSeparator}posters'),
        Directory(
            '${temporary.path}${Platform.pathSeparator}artwork${Platform.pathSeparator}posters'),
      );
      final record = NasBackupRecord(
        id: id,
        createdAt: createdAt,
        sizeBytes: await _payloadSize(temporary),
      );
      await File('${temporary.path}${Platform.pathSeparator}manifest.json')
          .writeAsString(
        jsonEncode(record.toJson()),
        flush: true,
      );
      await temporary.rename(destination.path);
      return record;
    } catch (_) {
      if (await temporary.exists()) {
        await temporary.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<List<NasBackupRecord>> list() async {
    final root = _backupDirectory;
    if (!await root.exists()) return const [];
    final records = <NasBackupRecord>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory ||
          entity.path.split(Platform.pathSeparator).last.startsWith('.tmp-')) {
        continue;
      }
      final manifest =
          File('${entity.path}${Platform.pathSeparator}manifest.json');
      if (!await manifest.exists()) continue;
      try {
        final record =
            NasBackupRecord.fromJson(jsonDecode(await manifest.readAsString()));
        if (record != null) records.add(record);
      } on FormatException {
        // Ignore incomplete or invalid backup directories.
      }
    }
    records.sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return records;
  }

  Future<NasBackupRecord?> find(String id) async {
    for (final record in await list()) {
      if (record.id == id) return record;
    }
    return null;
  }

  Future<void> _copyFileIfExists(File source, File target) async {
    if (!await source.exists()) return;
    await target.parent.create(recursive: true);
    await source.copy(target.path);
  }

  Future<void> _copyDirectoryIfExists(
      Directory source, Directory target) async {
    if (!await source.exists()) return;
    await target.create(recursive: true);
    await for (final entity
        in source.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relativePath = entity.path.substring(source.path.length + 1);
      final copy = File('${target.path}${Platform.pathSeparator}$relativePath');
      await copy.parent.create(recursive: true);
      await entity.copy(copy.path);
    }
  }

  Future<int> _payloadSize(Directory directory) async {
    var size = 0;
    await for (final entity
        in directory.list(recursive: true, followLinks: false)) {
      if (entity is File) size += await entity.length();
    }
    return size;
  }
}
