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
      await _copySanitizedJsonFile(
        File(
            '$dataDir${Platform.pathSeparator}state${Platform.pathSeparator}server.json'),
        File(
            '${temporary.path}${Platform.pathSeparator}state${Platform.pathSeparator}server.json'),
      );
      await _copySanitizedJsonFile(
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

  /// Copies a persisted JSON file while removing credential-bearing fields.
  ///
  /// The live state file stores token hashes under `tokens`; those hashes are
  /// deliberately omitted from backups. Optional config files are sanitized
  /// recursively so a future config key cannot accidentally place a pairing
  /// code or token in a backup artifact.
  Future<void> _copySanitizedJsonFile(File source, File target) async {
    if (!await source.exists()) return;
    final decoded = jsonDecode(await source.readAsString());
    final sanitized = _sanitizeJson(decoded, parentKey: '');
    await target.parent.create(recursive: true);
    await target.writeAsString(jsonEncode(sanitized), flush: true);
  }

  Object? _sanitizeJson(Object? value, {required String parentKey}) {
    if (value is Map) {
      final result = <String, Object?>{};
      value.forEach((key, child) {
        final name = key.toString();
        final normalized = name.toLowerCase();
        // `tokens` is a map keyed by token hash in server.json. Remove the
        // entire field rather than attempting to retain device metadata.
        if (normalized == 'tokens' || _sensitiveKey(normalized)) return;
        result[name] = _sanitizeJson(child, parentKey: normalized);
      });
      return result;
    }
    if (value is List) {
      return value
          .map((child) => _sanitizeJson(child, parentKey: parentKey))
          .toList(growable: false);
    }
    return value;
  }

  bool _sensitiveKey(String normalized) =>
      normalized.contains('token') ||
      normalized.contains('pairing') ||
      normalized.contains('password') ||
      normalized.contains('secret');

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
