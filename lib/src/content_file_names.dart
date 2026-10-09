import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Stored beside the catalog, so reads resolve a digest without scanning files.
/// Reserve before publishing: an interrupted upload may leave a reservation,
/// but must never leave a committed record pointing at another book's bytes.
class ContentFileNames {
  ContentFileNames(this.database);

  final Database database;

  static void createSchema(Database database) => database.execute('''
    CREATE TABLE IF NOT EXISTS reading_content_file_names (
      digest TEXT PRIMARY KEY,
      file_name TEXT NOT NULL,
      name_key TEXT NOT NULL UNIQUE
    );
  ''');

  String resolve(String digest) {
    final rows = database.select(
      'SELECT file_name FROM reading_content_file_names WHERE digest = ?',
      [digest],
    );
    if (rows.isEmpty) return digest; // Existing uploads need no migration.
    final name = rows.single['file_name'] as String;
    if (name != safeContentFileName(name)) {
      throw StateError('Invalid stored content file name');
    }
    return name;
  }

  Future<String> reserve(
    String digest,
    String requestedName,
    Directory objects, {
    Future<bool> Function(File file)? reuseExisting,
  }) async {
    final existing = resolve(digest);
    if (existing != digest) return existing;
    // Keep old digest objects readable without renaming or copying them.
    if (reuseExisting == null &&
        await FileSystemEntity.type('${objects.path}/$digest',
                followLinks: false) !=
            FileSystemEntityType.notFound) {
      return digest;
    }
    for (var suffix = 0;; suffix++) {
      final name = safeContentFileName(requestedName, suffix: suffix);
      final key = name.toLowerCase();
      if (database.select(
        'SELECT 1 FROM reading_content_file_names WHERE name_key = ?',
        [key],
      ).isNotEmpty) continue;
      final file = File('${objects.path}${Platform.pathSeparator}$name');
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          !(type == FileSystemEntityType.file &&
              reuseExisting != null &&
              await reuseExisting(file))) continue;
      database.execute(
        'INSERT INTO reading_content_file_names(digest, file_name, name_key) '
        'VALUES (?, ?, ?)',
        [digest, name, key],
      );
      return name;
    }
  }
}

/// Keep normal names intact, but fit common NAS/SMB filename limits in bytes.
String safeContentFileName(String requestedName, {int suffix = 0}) {
  var name = unorm
      .nfc(requestedName)
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f\x7f]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  final dot = name.lastIndexOf('.');
  final extension =
      dot > 0 && name.length - dot <= 10 ? name.substring(dot) : '';
  var base = dot > 0 && extension.isNotEmpty ? name.substring(0, dot) : name;
  base = base.replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  if (base.isEmpty) base = 'book';
  if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
          caseSensitive: false)
      .hasMatch(base)) base = '_$base';
  final tail = '${suffix == 0 ? '' : '-$suffix'}$extension';
  final budget = 240 - utf8.encode(tail).length;
  final runes = <int>[];
  var bytes = 0;
  for (final rune in base.runes) {
    final length = utf8.encode(String.fromCharCode(rune)).length;
    if (bytes + length > budget) break;
    runes.add(rune);
    bytes += length;
  }
  base = String.fromCharCodes(runes).replaceAll(RegExp(r'[. ]+$'), '');
  return '$base$tail';
}
