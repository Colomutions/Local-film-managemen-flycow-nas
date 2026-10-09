import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';
import '../content_file_names.dart';

class ComicFailure implements Exception {
  const ComicFailure(this.code, [this.details]);
  final String code;
  final Map<String, Object?>? details;
  @override
  String toString() => code;
}

class ComicRecord {
  const ComicRecord(
      {required this.id,
      required this.title,
      required this.author,
      required this.relativePath,
      required this.format,
      required this.fileName,
      required this.sizeBytes,
      required this.sha256,
      required this.revision,
      required this.createdAt,
      required this.updatedAt,
      required this.storageState});

  final String id,
      title,
      relativePath,
      format,
      fileName,
      sha256,
      createdAt,
      updatedAt,
      storageState;
  final String? author;
  final int sizeBytes, revision;

  Map<String, Object?> toJson({bool admin = false}) => {
        'id': id,
        'title': title,
        'author': author,
        'format': format,
        'contentState': 'complete_file',
        'relativePath': relativePath,
        'fileName': fileName,
        'sizeBytes': sizeBytes,
        'contentSha256': sha256,
        'canDownload': storageState == 'healthy',
        'coverUrl': null,
        'revision': revision,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        if (admin) 'storageState': storageState,
      };

  static ComicRecord fromRow(Row row) => ComicRecord(
        id: row['id'] as String,
        title: row['title'] as String,
        author: row['author'] as String?,
        relativePath: row['relative_path'] as String,
        format: row['format'] as String,
        fileName: row['file_name'] as String,
        sizeBytes: row['size_bytes'] as int,
        sha256: row['sha256'] as String,
        revision: row['revision'] as int,
        createdAt: row['created_at'] as String,
        updatedAt: row['updated_at'] as String,
        storageState: row['storage_state'] as String,
      );
}

class ComicCatalog {
  ComicCatalog(this.rootPath);
  final String rootPath;
  Database? _database;
  Database get db => _database ?? (throw StateError('Comic catalog is closed'));
  ContentFileNames get fileNames => ContentFileNames(db);
  File get file => File('$rootPath${Platform.pathSeparator}catalog.sqlite');

  Future<void> open() async {
    await Directory(rootPath).create(recursive: true);
    if (!await file.exists()) {
      final objects = Directory('$rootPath${Platform.pathSeparator}objects');
      if (await objects.exists() &&
          !await objects.list(followLinks: false).isEmpty) {
        throw StateError(
            'Comic catalog is missing while comic objects still exist');
      }
    }
    final database = sqlite3.open(file.path);
    try {
      database.execute(
          'PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;');
      database.execute('''
        CREATE TABLE IF NOT EXISTS comics (
          id TEXT PRIMARY KEY, title TEXT NOT NULL, author TEXT,
          relative_path TEXT NOT NULL, format TEXT NOT NULL,
          file_name TEXT NOT NULL, size_bytes INTEGER NOT NULL,
          sha256 TEXT NOT NULL, revision INTEGER NOT NULL,
          storage_state TEXT NOT NULL DEFAULT 'healthy',
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
          deleted_at TEXT
        );
        CREATE INDEX IF NOT EXISTS comics_sha_format ON comics(sha256,format,deleted_at);
        CREATE INDEX IF NOT EXISTS comics_name ON comics(title,author,format,deleted_at);
        CREATE INDEX IF NOT EXISTS comics_updated ON comics(updated_at,id);
        CREATE TABLE IF NOT EXISTS comic_idempotency (
          device_id TEXT NOT NULL, method TEXT NOT NULL, path TEXT NOT NULL,
          key TEXT NOT NULL, semantic_digest TEXT NOT NULL,
          status INTEGER NOT NULL, response_json TEXT NOT NULL,
          comic_id TEXT, expires_at TEXT NOT NULL,
          PRIMARY KEY(device_id,method,path,key)
        );
        CREATE INDEX IF NOT EXISTS comic_idem_expiry ON comic_idempotency(expires_at);
      ''');
      ContentFileNames.createSchema(database);
      final integrity =
          database.select('PRAGMA quick_check').single.values.first;
      if (integrity != 'ok') throw StateError('Comic catalog integrity failed');
      _database = database;
    } catch (_) {
      database.dispose();
      rethrow;
    }
  }

  void close() {
    _database?.dispose();
    _database = null;
  }

  ComicRecord? find(String id, {bool includeUnhealthy = false}) {
    final rows = db
        .select('SELECT * FROM comics WHERE id=? AND deleted_at IS NULL', [id]);
    if (rows.isEmpty) return null;
    final record = ComicRecord.fromRow(rows.single);
    return includeUnhealthy || record.storageState == 'healthy' ? record : null;
  }

  Map<String, Object?> page(
      {String? query,
      String? sha256,
      String? format,
      String? storageState,
      required int number,
      required int size,
      required String sort,
      required String order,
      bool admin = false}) {
    if (number < 1 ||
        size < 1 ||
        size > 100 ||
        (query?.runes.length ?? 0) > 120) {
      throw const ComicFailure('invalid_request');
    }
    final column = switch (sort) {
      'title' => 'title',
      'createdAt' => 'created_at',
      'updatedAt' => 'updated_at',
      _ => throw const ComicFailure('invalid_request'),
    };
    final direction = switch (order) {
      'asc' => 'ASC',
      'desc' => 'DESC',
      _ => throw const ComicFailure('invalid_request'),
    };
    if ((sha256 == null) != (format == null) ||
        (query != null && sha256 != null) ||
        (sha256 != null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) ||
        (format != null && !const {'zip', 'cbz', 'pdf'}.contains(format)) ||
        (storageState != null &&
            !const {'all', 'healthy', 'missing', 'corrupt'}
                .contains(storageState))) {
      throw const ComicFailure('invalid_request');
    }
    final where = <String>['deleted_at IS NULL'];
    final args = <Object?>[];
    if (!admin) where.add("storage_state='healthy'");
    if (admin && storageState != null && storageState != 'all') {
      where.add('storage_state=?');
      args.add(storageState);
    }
    if (query != null && query.trim().isNotEmpty) {
      where.add(
          "(title LIKE ? ESCAPE '\\' OR author LIKE ? ESCAPE '\\' OR relative_path LIKE ? ESCAPE '\\')");
      final escaped = query
          .trim()
          .replaceAll('\\', '\\\\')
          .replaceAll('%', '\\%')
          .replaceAll('_', '\\_');
      args.addAll(['%$escaped%', '%$escaped%', '%$escaped%']);
    }
    if (sha256 != null) {
      where.add('sha256=? AND format=?');
      args.addAll([sha256, format]);
    }
    final condition = where.join(' AND ');
    final count = db
        .select('SELECT COUNT(*) AS n FROM comics WHERE $condition', args)
        .single['n'] as int;
    final rows = db.select(
        'SELECT * FROM comics WHERE $condition ORDER BY $column $direction, id $direction LIMIT ? OFFSET ?',
        [...args, size, (number - 1) * size]);
    return {
      'data': {
        'items': rows
            .map((row) => ComicRecord.fromRow(row).toJson(admin: admin))
            .toList()
      },
      'page': {
        'number': number,
        'size': size,
        'total': count,
        'hasMore': number * size < count
      }
    };
  }

  ComicRecord? byContent(String sha, String format) {
    final rows = db.select(
        'SELECT * FROM comics WHERE sha256=? AND format=? AND deleted_at IS NULL ORDER BY created_at LIMIT 1',
        [sha, format]);
    return rows.isEmpty ? null : ComicRecord.fromRow(rows.single);
  }

  int get logicalBytes => db
      .select(
          'SELECT COALESCE(SUM(size_bytes),0) AS n FROM comics WHERE deleted_at IS NULL')
      .single['n'] as int;

  void preflightCreate(Map<String, Object?> metadata, int? quotaBytes) {
    final sha = metadata['contentSha256'] as String;
    final format = metadata['format'] as String;
    final existing = byContent(sha, format);
    if (existing != null) {
      if (existing.storageState != 'healthy')
        throw const ComicFailure('comic_existing_content_unavailable');
      return;
    }
    final clash = db.select(
        'SELECT 1 FROM comics WHERE title=? AND author IS ? AND format=? AND deleted_at IS NULL LIMIT 1',
        [metadata['title'], metadata['author'], format]);
    if (clash.isNotEmpty && metadata['conflictPolicy'] != 'keep_both')
      throw const ComicFailure('comic_name_conflict');
    final size = metadata['sizeBytes'] as int;
    if (quotaBytes != null && logicalBytes + size > quotaBytes) {
      throw ComicFailure('quota_exceeded', {
        'scope': 'global',
        'limitBytes': quotaBytes,
        'remainingBytes': quotaBytes - logicalBytes
      });
    }
  }

  void preflightReplace(
      String id, int revision, Map<String, Object?> metadata, int? quotaBytes) {
    final old = find(id, includeUnhealthy: true);
    if (old == null) throw const ComicFailure('resource_not_found');
    if (old.revision != revision)
      throw const ComicFailure('comic_revision_conflict');
    final clash = db.select('''SELECT 1 FROM comics WHERE id!=? AND title=?
      AND author IS ? AND format=? AND deleted_at IS NULL LIMIT 1''',
        [id, metadata['title'], metadata['author'], metadata['format']]);
    if (clash.isNotEmpty) throw const ComicFailure('comic_name_conflict');
    final size = metadata['sizeBytes'] as int;
    if (quotaBytes != null &&
        logicalBytes - old.sizeBytes + size > quotaBytes) {
      throw ComicFailure('quota_exceeded', {
        'scope': 'global',
        'limitBytes': quotaBytes,
        'remainingBytes': quotaBytes - logicalBytes + old.sizeBytes,
      });
    }
  }

  bool hasActiveReference(String digest) => db.select(
      'SELECT 1 FROM comics WHERE sha256=? AND deleted_at IS NULL LIMIT 1',
      [digest]).isNotEmpty;

  void cleanupExpiredIdempotency() {
    db.execute('DELETE FROM comic_idempotency WHERE expires_at<=?',
        [DateTime.now().toUtc().toIso8601String()]);
  }

  Map<String, Object?>? replay(String deviceId, String method, String path,
      String key, String semanticDigest) {
    final rows = db.select(
        'SELECT * FROM comic_idempotency WHERE device_id=? AND method=? AND path=? AND key=?',
        [deviceId, method, path, key]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    if (row['semantic_digest'] != semanticDigest)
      throw const ComicFailure('idempotency_conflict');
    if (row['response_json'] == 'gone')
      throw const ComicFailure('idempotency_result_gone');
    return {
      'status': row['status'] as int,
      'body': jsonDecode(row['response_json'] as String)
    };
  }

  Map<String, Object?> recordSessionDedup(
      {required String deviceId,
      required String key,
      required String semanticDigest,
      required ComicRecord record}) {
    const path = '/api/v1/comics/upload-sessions';
    db.execute('BEGIN IMMEDIATE');
    try {
      final existing = replay(deviceId, 'POST', path, key, semanticDigest);
      if (existing != null) {
        db.execute('COMMIT');
        return existing;
      }
      final body = {
        'data': {'comic': record.toJson(), 'deduplicated': true}
      };
      _saveReplay(
          deviceId, 'POST', path, key, semanticDigest, 200, body, record.id);
      db.execute('COMMIT');
      return {'status': 200, 'body': body};
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _saveReplay(
      String deviceId,
      String method,
      String path,
      String key,
      String semanticDigest,
      int status,
      Map<String, Object?> body,
      String? comicId) {
    final expiry =
        DateTime.now().toUtc().add(const Duration(days: 7)).toIso8601String();
    db.execute('INSERT INTO comic_idempotency VALUES (?,?,?,?,?,?,?,?,?)', [
      deviceId,
      method,
      path,
      key,
      semanticDigest,
      status,
      jsonEncode(body),
      comicId,
      expiry
    ]);
  }

  Map<String, Object?> commitCreate(
      {required Map<String, Object?> metadata,
      required String deviceId,
      required String key,
      required String semanticDigest,
      required int? quotaBytes}) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final replayed =
          replay(deviceId, 'POST', '/api/v1/comics', key, semanticDigest);
      if (replayed != null) {
        db.execute('COMMIT');
        return replayed;
      }
      final sha = metadata['contentSha256'] as String;
      final format = metadata['format'] as String;
      final existing = byContent(sha, format);
      if (existing != null) {
        if (existing.storageState != 'healthy')
          throw const ComicFailure('comic_existing_content_unavailable');
        final body = {
          'data': {'comic': existing.toJson(), 'deduplicated': true}
        };
        _saveReplay(deviceId, 'POST', '/api/v1/comics', key, semanticDigest,
            200, body, existing.id);
        db.execute('COMMIT');
        return {'status': 200, 'body': body};
      }
      final title = metadata['title'] as String;
      final author = metadata['author'] as String?;
      final clash = db.select(
          'SELECT 1 FROM comics WHERE title=? AND author IS ? AND format=? AND deleted_at IS NULL LIMIT 1',
          [title, author, format]);
      if (clash.isNotEmpty && metadata['conflictPolicy'] != 'keep_both')
        throw const ComicFailure('comic_name_conflict');
      final size = metadata['sizeBytes'] as int;
      if (quotaBytes != null && logicalBytes + size > quotaBytes) {
        throw ComicFailure('quota_exceeded', {
          'scope': 'global',
          'limitBytes': quotaBytes,
          'remainingBytes': quotaBytes - logicalBytes
        });
      }
      final id = newUuidV4();
      final now = DateTime.now().toUtc().toIso8601String();
      db.execute(
          'INSERT INTO comics(id,title,author,relative_path,format,file_name,size_bytes,sha256,revision,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,1,?,?)',
          [
            id,
            title,
            author,
            metadata['relativePath'],
            format,
            metadata['fileName'],
            size,
            sha,
            now,
            now
          ]);
      final record = find(id)!;
      final body = {
        'data': {'comic': record.toJson(), 'deduplicated': false}
      };
      _saveReplay(deviceId, 'POST', '/api/v1/comics', key, semanticDigest, 201,
          body, id);
      db.execute('COMMIT');
      return {'status': 201, 'body': body};
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Map<String, Object?> commitReplace(
      {required String id,
      required int revision,
      required Map<String, Object?> metadata,
      required String deviceId,
      required String key,
      required String semanticDigest,
      required int? quotaBytes}) {
    final path = '/api/v1/admin/comics/$id';
    db.execute('BEGIN IMMEDIATE');
    try {
      final replayed = replay(deviceId, 'PUT', path, key, semanticDigest);
      if (replayed != null) {
        db.execute('COMMIT');
        return replayed;
      }
      final old = find(id, includeUnhealthy: true);
      if (old == null) throw const ComicFailure('resource_not_found');
      if (old.revision != revision)
        throw const ComicFailure('comic_revision_conflict');
      final title = metadata['title'] as String;
      final author = metadata['author'] as String?;
      final format = metadata['format'] as String;
      final clash = db.select(
          'SELECT 1 FROM comics WHERE id!=? AND title=? AND author IS ? AND format=? AND deleted_at IS NULL LIMIT 1',
          [id, title, author, format]);
      if (clash.isNotEmpty) throw const ComicFailure('comic_name_conflict');
      final size = metadata['sizeBytes'] as int;
      if (quotaBytes != null &&
          logicalBytes - old.sizeBytes + size > quotaBytes)
        throw ComicFailure('quota_exceeded', {
          'scope': 'global',
          'limitBytes': quotaBytes,
          'remainingBytes': quotaBytes - (logicalBytes - old.sizeBytes)
        });
      final changed = old.title != title ||
          old.author != author ||
          old.relativePath != metadata['relativePath'] ||
          old.format != format ||
          old.fileName != metadata['fileName'] ||
          old.sha256 != metadata['contentSha256'] ||
          old.storageState != 'healthy';
      if (changed) {
        db.execute(
            "UPDATE comics SET title=?,author=?,relative_path=?,format=?,file_name=?,size_bytes=?,sha256=?,revision=revision+1,storage_state='healthy',updated_at=? WHERE id=?",
            [
              title,
              author,
              metadata['relativePath'],
              format,
              metadata['fileName'],
              size,
              metadata['contentSha256'],
              DateTime.now().toUtc().toIso8601String(),
              id
            ]);
      }
      final record = find(id)!;
      final body = {
        'data': {'comic': record.toJson(), 'changed': changed}
      };
      _saveReplay(deviceId, 'PUT', path, key, semanticDigest, 200, body, id);
      db.execute('COMMIT');
      return {'status': 200, 'body': body};
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void delete(String id, int revision, String actorDeviceId) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final record = find(id, includeUnhealthy: true);
      if (record == null) throw const ComicFailure('resource_not_found');
      if (record.revision != revision)
        throw const ComicFailure('comic_revision_conflict');
      db.execute('UPDATE comics SET deleted_at=?,updated_at=? WHERE id=?', [
        DateTime.now().toUtc().toIso8601String(),
        DateTime.now().toUtc().toIso8601String(),
        id
      ]);
      db.execute(
          "UPDATE comic_idempotency SET response_json='gone' WHERE comic_id=?",
          [id]);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void markState(String sha, String state) => db.execute(
      'UPDATE comics SET storage_state=? WHERE sha256=? AND deleted_at IS NULL',
      [state, sha]);
  Iterable<ComicRecord> get activeRecords => db
      .select('SELECT * FROM comics WHERE deleted_at IS NULL')
      .map(ComicRecord.fromRow);
}
