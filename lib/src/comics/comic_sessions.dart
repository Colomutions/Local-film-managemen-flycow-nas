import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';
import 'comic_catalog.dart';
import 'comic_files.dart';

class ComicSession {
  const ComicSession(
      {required this.id,
      required this.deviceId,
      required this.key,
      required this.metadata,
      required this.receivedBytes,
      required this.status,
      required this.expiresAt,
      required this.verified,
      this.failureCode,
      this.resultJson,
      this.resultStatus});
  final String id, deviceId, key, status, expiresAt;
  final Map<String, Object?> metadata;
  final int receivedBytes;
  final bool verified;
  final String? failureCode, resultJson;
  final int? resultStatus;
  Map<String, Object?> toJson(int maxChunkBytes) => {
        'uploadId': id,
        'receivedBytes': receivedBytes,
        'expiresAt': expiresAt,
        'maxChunkBytes': maxChunkBytes,
        'status': status,
        if (failureCode != null) 'failureCode': failureCode,
        if (status == 'completed' && resultJson != null)
          ...((jsonDecode(resultJson!) as Map<String, dynamic>)['data']
              as Map<String, dynamic>),
      };
}

class ComicSessions {
  ComicSessions(
      this.rootPath, this.files, this.maxChunkBytes, this.maxUploadBytes);
  final String rootPath;
  final ComicFiles files;
  final int maxChunkBytes, maxUploadBytes;
  Database? _database;
  Database get db =>
      _database ?? (throw StateError('Comic sessions are closed'));

  Future<void> open() async {
    final database =
        sqlite3.open('$rootPath${Platform.pathSeparator}sessions.sqlite');
    database.execute('PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;');
    database.execute('''CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,device_id TEXT NOT NULL,key TEXT NOT NULL,
      metadata_json TEXT NOT NULL,received_bytes INTEGER NOT NULL,
      status TEXT NOT NULL,expires_at TEXT NOT NULL,created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,failure_code TEXT,result_json TEXT,result_status INTEGER,
      verified INTEGER NOT NULL DEFAULT 0,
      UNIQUE(device_id,key)
    );''');
    final columns = database
        .select('PRAGMA table_info(sessions)')
        .map((row) => row['name'])
        .toSet();
    if (!columns.contains('verified'))
      database.execute(
          'ALTER TABLE sessions ADD COLUMN verified INTEGER NOT NULL DEFAULT 0');
    _database = database;
    await recover();
  }

  void close() {
    _database?.dispose();
    _database = null;
  }

  ComicSession? find(String id) {
    final rows = db.select('SELECT * FROM sessions WHERE id=?', [id]);
    return rows.isEmpty ? null : _fromRow(rows.single);
  }

  ComicSession? byKey(String device, String key) {
    final rows = db.select(
        'SELECT * FROM sessions WHERE device_id=? AND key=?', [device, key]);
    return rows.isEmpty ? null : _fromRow(rows.single);
  }

  int get reservedBytes {
    var total = 0;
    for (final row in db.select(
        "SELECT metadata_json FROM sessions WHERE status IN ('active','verifying')")) {
      total += (jsonDecode(row['metadata_json'] as String) as Map)['sizeBytes']
          as int;
    }
    return total;
  }

  int get activeCount => db
      .select(
          "SELECT COUNT(*) AS n FROM sessions WHERE status IN ('active','verifying')")
      .single['n'] as int;

  bool hasActiveDevice(String deviceId) => db.select(
      "SELECT 1 FROM sessions WHERE device_id=? AND status IN ('active','verifying') LIMIT 1",
      [deviceId]).isNotEmpty;

  Iterable<ComicSession> get all =>
      db.select('SELECT * FROM sessions').map(_fromRow);
  ComicSession _fromRow(Row row) => ComicSession(
      id: row['id'] as String,
      deviceId: row['device_id'] as String,
      key: row['key'] as String,
      metadata:
          (jsonDecode(row['metadata_json'] as String) as Map<String, dynamic>)
              .cast<String, Object?>(),
      receivedBytes: row['received_bytes'] as int,
      status: row['status'] as String,
      expiresAt: row['expires_at'] as String,
      failureCode: row['failure_code'] as String?,
      resultJson: row['result_json'] as String?,
      resultStatus: row['result_status'] as int?,
      verified: (row['verified'] as int) != 0);

  ComicSession create(
      String device, String key, Map<String, Object?> metadata) {
    final existing = byKey(device, key);
    if (existing != null) {
      if (jsonEncode(existing.metadata) != jsonEncode(metadata))
        throw const ComicFailure('idempotency_conflict');
      return existing;
    }
    final now = DateTime.now().toUtc();
    final active = db.select(
        "SELECT device_id,metadata_json FROM sessions WHERE status='active'");
    if (active.length >= 2 || active.any((row) => row['device_id'] == device)) {
      throw const ComicFailure(
          'upload_rate_limited', {'reason': 'active_session_limit'});
    }
    var reserved = 0;
    for (final row in active) {
      reserved += (jsonDecode(row['metadata_json'] as String)
          as Map)['sizeBytes'] as int;
    }
    if (reserved + (metadata['sizeBytes'] as int) > 2 * maxUploadBytes) {
      throw const ComicFailure(
          'upload_rate_limited', {'reason': 'temporary_budget_exceeded'});
    }
    final id = newUuidV4();
    final timestamp = now.toIso8601String();
    final expiry = now.add(const Duration(hours: 24)).toIso8601String();
    db.execute(
        'INSERT INTO sessions(id,device_id,key,metadata_json,received_bytes,status,expires_at,created_at,updated_at,failure_code,result_json,result_status) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
        [
          id,
          device,
          key,
          jsonEncode(metadata),
          0,
          'active',
          expiry,
          timestamp,
          timestamp,
          null,
          null,
          null
        ]);
    return find(id)!;
  }

  Future<ComicSession> patch(ComicSession session, int start, int end,
      int total, Stream<List<int>> bytes) async {
    if (session.status == 'verifying')
      throw const ComicFailure('upload_in_progress');
    if (session.status == 'expired')
      throw const ComicFailure('upload_session_expired');
    if (session.status != 'active')
      throw const ComicFailure('upload_session_closed');
    if (start != session.receivedBytes)
      throw ComicFailure(
          'upload_offset_mismatch', {'offset': session.receivedBytes});
    final length = end - start + 1;
    if (length < 1 ||
        length > maxChunkBytes ||
        total != session.metadata['sizeBytes'] ||
        end >= total ||
        (end != total - 1 && length < 8 * 1024 * 1024))
      throw const ComicFailure('invalid_request');
    final file = files.sessionFile(session.id);
    final random = await file.open(mode: FileMode.append);
    var count = 0;
    try {
      final actual = await file.length();
      if (actual > start) await random.truncate(start);
      if (actual < start) throw const ComicFailure('comic_storage_unavailable');
      await for (final chunk in bytes) {
        count += chunk.length;
        if (count > length) throw const ComicFailure('content_length_mismatch');
        await random.writeFrom(chunk);
      }
      if (count != length) throw const ComicFailure('content_length_mismatch');
      await random.flush();
    } catch (_) {
      await random.truncate(start);
      rethrow;
    } finally {
      await random.close();
    }
    final now = DateTime.now().toUtc();
    final created = DateTime.parse(db.select(
        'SELECT created_at FROM sessions WHERE id=?',
        [session.id]).single['created_at'] as String);
    final idle = now.add(const Duration(hours: 24));
    final absolute = created.add(const Duration(days: 7));
    final expiry = idle.isBefore(absolute) ? idle : absolute;
    db.execute(
        'UPDATE sessions SET received_bytes=?,updated_at=?,expires_at=? WHERE id=?',
        [end + 1, now.toIso8601String(), expiry.toIso8601String(), session.id]);
    return find(session.id)!;
  }

  void setState(String id, String status,
      {String? failureCode, String? resultJson, int? resultStatus}) {
    final now = DateTime.now().toUtc();
    final terminal =
        const {'completed', 'failed', 'canceled', 'expired'}.contains(status);
    db.execute(
        'UPDATE sessions SET status=?,failure_code=?,result_json=?,result_status=?,updated_at=?,expires_at=COALESCE(?,expires_at) WHERE id=?',
        [
          status,
          failureCode,
          resultJson,
          resultStatus,
          now.toIso8601String(),
          terminal ? now.add(const Duration(days: 7)).toIso8601String() : null,
          id
        ]);
  }

  void setVerified(String id) =>
      db.execute('UPDATE sessions SET verified=1 WHERE id=?', [id]);

  Future<void> cancel(ComicSession session) async {
    if (session.status == 'completed')
      throw const ComicFailure('upload_already_completed');
    if (session.status == 'verifying')
      throw const ComicFailure('upload_in_progress');
    if (session.status == 'expired')
      throw const ComicFailure('upload_session_expired');
    if (session.status != 'active')
      throw const ComicFailure('upload_session_closed');
    setState(session.id, 'canceled');
    final file = files.sessionFile(session.id);
    if (await file.exists()) await file.delete();
  }

  Future<void> recover() async {
    final now = DateTime.now().toUtc().toIso8601String();
    for (final row in db.select(
        "SELECT * FROM sessions WHERE status IN ('active','verifying')")) {
      final session = _fromRow(row);
      final file = files.sessionFile(session.id);
      if (session.status == 'verifying') setState(session.id, 'active');
      if (!await file.exists()) {
        setState(session.id, 'failed',
            failureCode: 'comic_storage_unavailable');
        continue;
      }
      final actual = await file.length();
      if (actual < session.receivedBytes) {
        setState(session.id, 'failed',
            failureCode: 'comic_storage_unavailable');
        continue;
      }
      if (actual > session.receivedBytes) {
        final random = await file.open(mode: FileMode.append);
        await random.truncate(session.receivedBytes);
        await random.close();
      }
      if (session.expiresAt.compareTo(now) <= 0) {
        setState(session.id, 'expired');
        await file.delete();
      }
    }
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 7))
        .toIso8601String();
    db.execute(
        "DELETE FROM sessions WHERE status NOT IN ('active','verifying') AND updated_at<?",
        [cutoff]);
    final activeIds = db
        .select(
            "SELECT id FROM sessions WHERE status IN ('active','verifying')")
        .map((row) => row['id'] as String)
        .toSet();
    final sevenDaysAgo =
        DateTime.now().toUtc().subtract(const Duration(days: 7));
    await for (final entity in files.temporary.list(followLinks: false)) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.upload')) {
        if ((await entity.stat()).modified.toUtc().isBefore(sevenDaysAgo)) {
          await entity.delete();
        }
        continue;
      }
      if (!entity.path.endsWith('.part')) continue;
      final name = entity.uri.pathSegments.last;
      final id = name.substring(0, name.length - '.part'.length);
      if (!activeIds.contains(id)) await entity.delete();
    }
  }

  Future<void> invalidateForRestore() async {
    for (final session in all.where(
        (item) => item.status == 'active' || item.status == 'verifying')) {
      setState(session.id, 'failed', failureCode: 'service_maintenance');
      final file = files.sessionFile(session.id);
      if (await file.exists()) await file.delete();
    }
  }
}
