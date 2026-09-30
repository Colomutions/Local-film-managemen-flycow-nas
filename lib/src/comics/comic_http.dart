import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';

import '../novels/novel_metadata.dart' show canonicalJson;
import '../range.dart';
import 'comic_catalog.dart';
import 'comic_files.dart';
import 'comic_sessions.dart';

final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$');

class ComicHttpApi {
  ComicHttpApi(
      {required this.rootPath,
      required this.maxUploadBytes,
      required this.maxChunkBytes,
      required this.quotaBytes,
      this.backgroundRead,
      this.paceRead})
      : files = ComicFiles(rootPath, maxUploadBytes),
        catalog = ComicCatalog(rootPath) {
    sessions = ComicSessions(rootPath, files, maxChunkBytes, maxUploadBytes);
  }
  final String rootPath;
  final int maxUploadBytes, maxChunkBytes;
  final int? quotaBytes;
  final Stream<List<int>> Function(Stream<List<int>> source)? backgroundRead;
  final Future<void> Function(int bytes)? paceRead;
  final ComicFiles files;
  final ComicCatalog catalog;
  late final ComicSessions sessions;
  bool ready = false;
  String? unavailableReason;
  Future<void> _writeQueue = Future.value();
  int _activeWrites = 0;
  final Set<String> _activeUploadKeys = {};
  Timer? _cleanupTimer;

  Future<void> initialize() async {
    try {
      if (maxChunkBytes < 8 * 1024 * 1024 || maxChunkBytes > maxUploadBytes) {
        throw StateError('Invalid comic chunk size');
      }
      await files.initialize();
      await catalog.open();
      catalog.cleanupExpiredIdempotency();
      await sessions.open();
      for (final session in sessions.all.where((value) =>
          value.status == 'failed' &&
          value.failureCode == 'comic_storage_unavailable')) {
        final semantic = _semanticDigest('comic-upload-v1\n', session.metadata);
        final replay = catalog.replay(
            session.deviceId, 'POST', '/api/v1/comics', session.key, semantic);
        if (replay != null) {
          sessions.setState(session.id, 'completed',
              resultStatus: replay['status'] as int,
              resultJson: jsonEncode(replay['body']));
        }
      }
      for (final record in catalog.activeRecords) {
        final state = await files.state(record.sha256, record.sizeBytes);
        if (state != record.storageState)
          catalog.markState(record.sha256, state);
      }
      ready = true;
      unavailableReason = null;
      _cleanupTimer = Timer.periodic(const Duration(hours: 24), (_) {
        unawaited(_serialized(() async {
          await sessions.recover();
          catalog.cleanupExpiredIdempotency();
        }).catchError((_) {}));
      });
    } catch (_) {
      ready = false;
      unavailableReason = 'comic_storage_unavailable';
      sessions.close();
      catalog.close();
    }
  }

  void close() {
    ready = false;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    sessions.close();
    catalog.close();
  }

  Future<void> invalidateSessionsForRestore() =>
      sessions.invalidateForRestore();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> handle(HttpRequest request,
      {required String deviceId, required bool admin}) async {
    try {
      if (!ready) throw const ComicFailure('comic_storage_unavailable');
      final path = request.uri.path;
      final parts = request.uri.pathSegments;
      if (path == '/api/v1/comics' && request.method == 'GET')
        return await _list(request);
      if (path == '/api/v1/admin/comics' && request.method == 'GET')
        return await _list(request, admin: true);
      if (path == '/api/v1/comics' && request.method == 'POST')
        return await _upload(request, deviceId, admin);
      if (path == '/api/v1/comics/upload-sessions' && request.method == 'POST')
        return await _createSession(request, deviceId, admin);
      if (parts.length == 5 &&
          parts[0] == 'api' &&
          parts[1] == 'v1' &&
          parts[2] == 'comics' &&
          parts[3] == 'upload-sessions') {
        final id = _id(parts[4]);
        if (request.method == 'GET')
          return await _getSession(request, id, deviceId, admin);
        if (request.method == 'PATCH')
          return await _patch(request, id, deviceId, admin);
        if (request.method == 'DELETE')
          return await _cancel(request, id, deviceId, admin);
      }
      if (parts.length == 6 &&
          parts[2] == 'comics' &&
          parts[3] == 'upload-sessions' &&
          parts[5] == 'complete' &&
          request.method == 'POST') {
        return await _complete(request, _id(parts[4]), deviceId, admin);
      }
      if (parts.length == 4 && parts[2] == 'comics' && request.method == 'GET')
        return await _detail(request, _id(parts[3]));
      if (parts.length == 5 &&
          parts[2] == 'comics' &&
          parts[4] == 'content' &&
          (request.method == 'GET' || request.method == 'HEAD'))
        return await _download(request, _id(parts[3]));
      if (parts.length == 5 && parts[2] == 'admin' && parts[3] == 'comics') {
        final id = _id(parts[4]);
        if (request.method == 'GET')
          return await _detail(request, id, admin: true);
        if (request.method == 'PUT')
          return await _upload(request, deviceId, admin, replaceId: id);
        if (request.method == 'DELETE')
          return await _delete(request, id, deviceId);
      }
      throw const ComicFailure('resource_not_found');
    } catch (error) {
      await _error(request, error);
    }
  }

  Future<void> _list(HttpRequest request, {bool admin = false}) async {
    final q = request.uri.queryParameters;
    int integer(String key, int fallback) =>
        q[key] == null ? fallback : int.tryParse(q[key]!) ?? 0;
    final body = catalog.page(
        query: q['q'],
        sha256: q['contentSha256'],
        format: q['format'],
        storageState: admin ? q['storageState'] : null,
        number: integer('page', 1),
        size: integer('pageSize', 30),
        sort: q['sort'] ?? 'updatedAt',
        order: q['order'] ?? 'desc',
        admin: admin);
    await _json(request.response, 200, body);
  }

  Future<void> _detail(HttpRequest request, String id,
      {bool admin = false}) async {
    final record = catalog.find(id, includeUnhealthy: admin);
    if (record == null) throw const ComicFailure('resource_not_found');
    request.response.headers
        .set(HttpHeaders.etagHeader, '"comic:$id:r${record.revision}"');
    await _json(request.response, 200, {'data': record.toJson(admin: admin)});
  }

  Future<void> _download(HttpRequest request, String id) async {
    final record = catalog.find(id, includeUnhealthy: true);
    if (record == null) throw const ComicFailure('resource_not_found');
    if (record.storageState != 'healthy')
      throw const ComicFailure('comic_content_unavailable');
    final state = await files.state(record.sha256, record.sizeBytes);
    if (state != 'healthy') {
      catalog.markState(record.sha256, state);
      throw const ComicFailure('comic_content_unavailable');
    }
    final file = files.object(record.sha256);
    RandomAccessFile? opened;
    try {
      opened = await file.open(mode: FileMode.read);
    } catch (_) {
      catalog.markState(record.sha256, 'corrupt');
      throw const ComicFailure('comic_content_unavailable');
    }
    var fileReadFailed = false;
    var responsePrepared = false;
    try {
      final size = record.sizeBytes;
      final etag = '"sha256:${record.sha256}"';
      final requested = request.headers.value(HttpHeaders.rangeHeader);
      final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
      final parsed = parseSingleByteRange(
          ifRange == null || ifRange == etag ? requested : null, size);
      if (parsed.requested && parsed.range == null) {
        request.response.statusCode = 416;
        request.response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        request.response.headers.contentLength = 0;
        await request.response.close();
        return;
      }
      final start = parsed.range?.start ?? 0;
      final end = parsed.range?.end ?? size - 1;
      try {
        await opened.setPosition(start);
      } catch (_) {
        catalog.markState(record.sha256, 'corrupt');
        throw const ComicFailure('comic_content_unavailable');
      }
      final response = request.response;
      response.statusCode = parsed.range == null ? 200 : 206;
      response.headers.contentType = ContentType.parse(
          record.format == 'pdf' ? 'application/pdf' : 'application/zip');
      response.headers.contentLength = end - start + 1;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.etagHeader, etag);
      final encoded = Uri.encodeComponent(record.fileName);
      response.headers.set('content-disposition',
          'attachment; filename="comic.${record.format}"; filename*=UTF-8\'\'$encoded');
      if (parsed.range != null)
        response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$size');
      responsePrepared = true;
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      var remaining = end - start + 1;
      while (remaining > 0) {
        await paceRead?.call(remaining < 64 * 1024 ? remaining : 64 * 1024);
        List<int> data;
        try {
          data =
              await opened.read(remaining < 64 * 1024 ? remaining : 64 * 1024);
          if (data.isEmpty)
            throw const ComicFailure('comic_content_unavailable');
        } catch (_) {
          fileReadFailed = true;
          rethrow;
        }
        response.add(data);
        await response.flush();
        remaining -= data.length;
      }
      await response.close();
    } catch (_) {
      if (fileReadFailed) catalog.markState(record.sha256, 'corrupt');
      if (responsePrepared) {
        try {
          final socket = await request.response.detachSocket();
          socket.destroy();
        } catch (_) {}
      } else {
        rethrow;
      }
    } finally {
      try {
        await opened.close();
      } catch (_) {}
    }
  }

  Future<void> _upload(HttpRequest request, String deviceId, bool admin,
      {String? replaceId}) async {
    final key = _id(request.headers.value('Idempotency-Key') ?? '');
    final operation =
        '$deviceId:${replaceId == null ? 'POST:/api/v1/comics' : 'PUT:/api/v1/admin/comics/$replaceId'}:$key';
    if (_activeUploadKeys.contains(operation))
      throw const ComicFailure('upload_in_progress');
    if (_activeWrites >= 1)
      throw const ComicFailure(
          'upload_rate_limited', {'reason': 'active_session_limit'});
    _activeWrites++;
    _activeUploadKeys.add(operation);
    ComicTemporaryFile? content;
    try {
      final revision = replaceId == null ? null : _ifMatch(request, replaceId);
      final payload = await _multipart(request,
          deviceId: deviceId, admin: admin, replace: replaceId != null);
      final metadata = payload.$1;
      content = payload.$2;
      await files.verify(content, metadata['format'] as String);
      final digest = _semanticDigest(
          replaceId == null ? 'comic-upload-v1\n' : 'comic-replace-v1\n', {
        ...metadata,
        if (replaceId != null) 'comicId': replaceId,
        if (revision != null) 'expectedEtag': '"comic:$replaceId:r$revision"',
        if (replaceId != null) 'conflictPolicy': null
      });
      final result = await _serialized(() async {
        final path = replaceId == null
            ? '/api/v1/comics'
            : '/api/v1/admin/comics/$replaceId';
        final replay = catalog.replay(
            deviceId, replaceId == null ? 'POST' : 'PUT', path, key, digest);
        if (replay != null) return replay;
        final old = replaceId == null
            ? null
            : catalog.find(replaceId, includeUnhealthy: true);
        if (replaceId == null) {
          catalog.preflightCreate(metadata, quotaBytes);
        } else {
          catalog.preflightReplace(replaceId, revision!, metadata, quotaBytes);
        }
        await files.publish(content!);
        final committed = replaceId == null
            ? catalog.commitCreate(
                metadata: metadata,
                deviceId: deviceId,
                key: key,
                semanticDigest: digest,
                quotaBytes: quotaBytes)
            : catalog.commitReplace(
                id: replaceId,
                revision: revision!,
                metadata: metadata,
                deviceId: deviceId,
                key: key,
                semanticDigest: digest,
                quotaBytes: quotaBytes);
        if (old != null &&
            old.sha256 != metadata['contentSha256'] &&
            !catalog.hasActiveReference(old.sha256)) {
          try {
            await files.retire(old.sha256);
          } catch (_) {}
        }
        return committed;
      });
      if (replaceId != null) {
        final comic = ((result['body'] as Map)['data'] as Map)['comic'] as Map;
        request.response.headers.set(
            HttpHeaders.etagHeader, '"comic:$replaceId:r${comic['revision']}"');
      }
      await _json(request.response, result['status'] as int,
          result['body'] as Map<String, Object?>);
    } finally {
      _activeWrites--;
      _activeUploadKeys.remove(operation);
      if (content != null && await content.file.exists())
        await content.file.delete();
    }
  }

  Future<(Map<String, Object?>, ComicTemporaryFile)> _multipart(
      HttpRequest request,
      {required String deviceId,
      required bool admin,
      required bool replace}) async {
    final type = request.headers.contentType;
    final boundary = type?.parameters['boundary'];
    if (type?.mimeType != 'multipart/form-data' ||
        boundary == null ||
        boundary.isEmpty ||
        boundary.length > 200) throw const ComicFailure('invalid_request');
    Map<String, Object?>? metadata;
    ComicTemporaryFile? content;
    var index = 0;
    try {
      await for (final part in request
          .cast<List<int>>()
          .transform(MimeMultipartTransformer(boundary))) {
        final disposition =
            HeaderValue.parse(part.headers['content-disposition'] ?? '');
        final name = disposition.parameters['name'];
        if (index == 0 && name == 'metadata') {
          if (ContentType.parse(part.headers['content-type'] ?? '').mimeType !=
              'application/json') throw const ComicFailure('invalid_request');
          final bytes = <int>[];
          await for (final chunk in part) {
            bytes.addAll(chunk);
            if (bytes.length > 16 * 1024)
              throw const ComicFailure('payload_too_large');
          }
          metadata = parseComicMetadata(
              jsonDecode(utf8.decode(bytes, allowMalformed: false)),
              admin: admin,
              replace: replace);
          if ((metadata['sizeBytes'] as int) > maxUploadBytes)
            throw const ComicFailure('payload_too_large');
          if (sessions.activeCount >= 2 || sessions.hasActiveDevice(deviceId)) {
            throw const ComicFailure(
                'upload_rate_limited', {'reason': 'active_session_limit'});
          }
          if (sessions.reservedBytes + (metadata['sizeBytes'] as int) >
              2 * maxUploadBytes) {
            throw const ComicFailure(
                'upload_rate_limited', {'reason': 'temporary_budget_exceeded'});
          }
          await _checkSpace(metadata['sizeBytes'] as int);
        } else if (index == 1 && name == 'file' && metadata != null) {
          final mime =
              ContentType.parse(part.headers['content-type'] ?? '').mimeType;
          final format = metadata['format'];
          if (format == 'pdf'
              ? mime != 'application/pdf'
              : !const {
                  'application/zip',
                  'application/x-cbz',
                  'application/vnd.comicbook+zip'
                }.contains(mime))
            throw const ComicFailure('unsupported_comic_format');
          content = await files.receive(part, metadata['sizeBytes'] as int,
              metadata['contentSha256'] as String);
        } else {
          throw const ComicFailure('invalid_metadata');
        }
        index++;
      }
      if (index != 2 || metadata == null || content == null)
        throw const ComicFailure('invalid_request');
      return (metadata, content);
    } catch (_) {
      if (content != null && await content.file.exists())
        await content.file.delete();
      rethrow;
    }
  }

  Future<void> _createSession(
      HttpRequest request, String deviceId, bool admin) async {
    final key = _id(request.headers.value('Idempotency-Key') ?? '');
    final bytes = await _readLimited(request, 16 * 1024);
    final metadata = parseComicMetadata(
        jsonDecode(utf8.decode(bytes, allowMalformed: false)),
        admin: admin,
        replace: false);
    if ((metadata['sizeBytes'] as int) > maxUploadBytes)
      throw const ComicFailure('payload_too_large');
    final semantic = _semanticDigest('comic-upload-v1\n', metadata);
    final preflight = catalog.replay(
        deviceId, 'POST', '/api/v1/comics/upload-sessions', key, semantic);
    if (preflight != null) {
      await _json(request.response, preflight['status'] as int,
          preflight['body'] as Map<String, Object?>);
      return;
    }
    final prior = sessions.byKey(deviceId, key);
    if (prior != null) {
      if (canonicalJson(prior.metadata) != canonicalJson(metadata))
        throw const ComicFailure('idempotency_conflict');
      if (prior.status == 'completed' && prior.resultJson != null) {
        await _json(request.response, prior.resultStatus!,
            jsonDecode(prior.resultJson!) as Map<String, Object?>);
        return;
      }
      if (prior.status != 'active')
        throw const ComicFailure('upload_session_closed');
      await _json(request.response, 201, {'data': prior.toJson(maxChunkBytes)});
      return;
    }
    final existing = catalog.byContent(
        metadata['contentSha256'] as String, metadata['format'] as String);
    if (existing != null) {
      final state = await files.state(existing.sha256, existing.sizeBytes);
      if (existing.storageState != 'healthy' || state != 'healthy') {
        if (state != 'healthy') catalog.markState(existing.sha256, state);
        throw const ComicFailure('comic_existing_content_unavailable');
      }
      final result = await _serialized(() async => catalog.recordSessionDedup(
          deviceId: deviceId,
          key: key,
          semanticDigest: semantic,
          record: existing));
      await _json(request.response, result['status'] as int,
          result['body'] as Map<String, Object?>);
      return;
    }
    if (_activeWrites >= 1)
      throw const ComicFailure(
          'upload_rate_limited', {'reason': 'active_session_limit'});
    await _checkSpace(metadata['sizeBytes'] as int);
    final session =
        await _serialized(() async => sessions.create(deviceId, key, metadata));
    await _json(request.response, 201, {'data': session.toJson(maxChunkBytes)});
  }

  ComicSession _authorizedSession(String id, String deviceId, bool admin) {
    final session = sessions.find(id);
    if (session == null || (!admin && session.deviceId != deviceId))
      throw const ComicFailure('resource_not_found');
    if (session.status == 'active' &&
        DateTime.parse(session.expiresAt).isBefore(DateTime.now().toUtc())) {
      sessions.setState(id, 'expired');
      return sessions.find(id)!;
    }
    return session;
  }

  Future<void> _getSession(
      HttpRequest request, String id, String deviceId, bool admin) async {
    final session = _authorizedSession(id, deviceId, admin);
    await _json(request.response, 200, {'data': session.toJson(maxChunkBytes)});
  }

  Future<void> _patch(
      HttpRequest request, String id, String deviceId, bool admin) async {
    if (_activeWrites >= 1)
      throw const ComicFailure(
          'upload_rate_limited', {'reason': 'active_session_limit'});
    _activeWrites++;
    try {
      final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
          request.headers.value(HttpHeaders.contentRangeHeader) ?? '');
      if (match == null) throw const ComicFailure('invalid_request');
      final start = int.parse(match[1]!);
      final end = int.parse(match[2]!);
      final total = int.parse(match[3]!);
      if (request.contentLength != end - start + 1)
        throw const ComicFailure('content_length_mismatch');
      final updated = await _serialized(() => sessions.patch(
          _authorizedSession(id, deviceId, admin), start, end, total, request));
      request.response.statusCode = 204;
      request.response.headers
          .set('Upload-Offset', updated.receivedBytes.toString());
      await request.response.close();
    } finally {
      _activeWrites--;
    }
  }

  Future<void> _complete(
      HttpRequest request, String id, String deviceId, bool admin) async {
    final result = await _serialized(() async {
      final session = _authorizedSession(id, deviceId, admin);
      if (session.status == 'completed') {
        return {
          'status': session.resultStatus!,
          'body': jsonDecode(session.resultJson!) as Map<String, Object?>
        };
      }
      if (session.status == 'verifying')
        throw const ComicFailure('upload_in_progress');
      if (session.status == 'expired')
        throw const ComicFailure('upload_session_expired');
      if (session.status != 'active')
        throw const ComicFailure('upload_session_closed');
      if (session.receivedBytes != session.metadata['sizeBytes'])
        throw ComicFailure(
            'upload_incomplete', {'offset': session.receivedBytes});
      sessions.setState(id, 'verifying');
      final file = files.sessionFile(id);
      try {
        if (!session.verified) {
          final source = file.openRead();
          final digest = (await sha256
                  .bind(backgroundRead?.call(source) ?? source)
                  .first)
              .toString();
          if (digest != session.metadata['contentSha256'])
            throw const ComicFailure('content_hash_mismatch');
        }
        final digest = session.metadata['contentSha256'] as String;
        final content = ComicTemporaryFile(file, session.receivedBytes, digest);
        if (!session.verified) {
          await files.verify(content, session.metadata['format'] as String);
          sessions.setVerified(id);
        }
        catalog.preflightCreate(session.metadata, quotaBytes);
        await files.publish(content);
        final metadata = session.metadata;
        final semantic = _semanticDigest('comic-upload-v1\n', metadata);
        final committed = catalog.commitCreate(
            metadata: metadata,
            deviceId: session.deviceId,
            key: session.key,
            semanticDigest: semantic,
            quotaBytes: quotaBytes);
        sessions.setState(id, 'completed',
            resultStatus: committed['status'] as int,
            resultJson: jsonEncode(committed['body']));
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        return committed;
      } catch (error) {
        final digest = session.metadata['contentSha256'] as String;
        final semantic = _semanticDigest('comic-upload-v1\n', session.metadata);
        final replay = catalog.replay(
            session.deviceId, 'POST', '/api/v1/comics', session.key, semantic);
        if (replay != null) {
          sessions.setState(id, 'completed',
              resultStatus: replay['status'] as int,
              resultJson: jsonEncode(replay['body']));
          return replay;
        }
        if (!catalog.hasActiveReference(digest)) {
          try {
            await files.restoreUncommitted(
                ComicTemporaryFile(file, session.receivedBytes, digest));
          } catch (_) {}
        }
        final code =
            error is ComicFailure ? error.code : 'comic_storage_unavailable';
        final terminal = const {
          'content_hash_mismatch',
          'invalid_comic_content',
          'unsupported_comic_format',
          'content_length_mismatch'
        }.contains(code);
        sessions.setState(id, terminal ? 'failed' : 'active',
            failureCode: code);
        if (terminal && await file.exists()) await file.delete();
        rethrow;
      }
    });
    await _json(request.response, result['status'] as int,
        result['body'] as Map<String, Object?>);
  }

  Future<void> _cancel(
      HttpRequest request, String id, String deviceId, bool admin) async {
    if (_authorizedSession(id, deviceId, admin).status == 'verifying')
      throw const ComicFailure('upload_in_progress');
    await _serialized(
        () => sessions.cancel(_authorizedSession(id, deviceId, admin)));
    request.response.statusCode = 204;
    await request.response.close();
  }

  Future<void> _delete(HttpRequest request, String id, String deviceId) async {
    final revision = _ifMatch(request, id);
    await _serialized(() async {
      final old = catalog.find(id, includeUnhealthy: true);
      catalog.delete(id, revision, deviceId);
      if (old != null && !catalog.hasActiveReference(old.sha256)) {
        try {
          await files.retire(old.sha256);
        } catch (_) {}
      }
    });
    request.response.statusCode = 204;
    await request.response.close();
  }

  int _ifMatch(HttpRequest request, String id) {
    final value = request.headers.value(HttpHeaders.ifMatchHeader);
    if (value == null) throw const ComicFailure('precondition_required');
    final match = RegExp('^"comic:$id:r([1-9][0-9]*)"\$').firstMatch(value);
    if (match == null) throw const ComicFailure('invalid_request');
    return int.parse(match[1]!);
  }

  String _id(String value) {
    if (!_uuid.hasMatch(value)) throw const ComicFailure('invalid_request');
    return value.toLowerCase();
  }

  String _semanticDigest(String prefix, Map<String, Object?> metadata) {
    final source = {...metadata}
      ..removeWhere((key, value) => value == null && key == 'conflictPolicy');
    return sha256
        .convert(utf8.encode('$prefix${canonicalJson(source)}'))
        .toString();
  }

  Future<List<int>> _readLimited(Stream<List<int>> source, int limit) async {
    final bytes = <int>[];
    await for (final chunk in source) {
      bytes.addAll(chunk);
      if (bytes.length > limit) throw const ComicFailure('payload_too_large');
    }
    return bytes;
  }

  Future<void> _checkSpace(int bytes) async {
    if (!Platform.isLinux) return;
    try {
      final result = await Process.run('df', ['-Pk', rootPath]);
      if (result.exitCode != 0)
        throw const ComicFailure('comic_storage_unavailable');
      final lines = (result.stdout as String).trim().split('\n');
      final columns = lines.last.trim().split(RegExp(r'\s+'));
      final available = int.parse(columns[3]) * 1024;
      if (available - sessions.reservedBytes - bytes < 1024 * 1024 * 1024)
        throw const ComicFailure('storage_insufficient');
    } catch (error) {
      if (error is ComicFailure) rethrow;
      throw const ComicFailure('comic_storage_unavailable');
    }
  }

  Future<void> _error(HttpRequest request, Object error) async {
    final failure = error is ComicFailure
        ? error
        : error is FormatException
            ? const ComicFailure('invalid_metadata')
            : error is FileSystemException
                ? const ComicFailure('storage_insufficient')
                : const ComicFailure('comic_storage_unavailable');
    final status = switch (failure.code) {
      'invalid_request' || 'invalid_metadata' => 400,
      'insufficient_scope' || 'quota_exceeded' => 403,
      'resource_not_found' => 404,
      'comic_name_conflict' ||
      'comic_existing_content_unavailable' ||
      'idempotency_conflict' ||
      'upload_offset_mismatch' ||
      'upload_incomplete' ||
      'upload_in_progress' ||
      'upload_already_completed' =>
        409,
      'upload_session_closed' ||
      'upload_session_expired' ||
      'idempotency_result_gone' =>
        410,
      'comic_revision_conflict' => 412,
      'payload_too_large' => 413,
      'unsupported_comic_format' => 415,
      'content_length_mismatch' ||
      'content_hash_mismatch' ||
      'invalid_comic_content' =>
        422,
      'precondition_required' => 428,
      'upload_rate_limited' => 429,
      'storage_insufficient' => 507,
      _ => 503
    };
    if (failure.code == 'upload_rate_limited')
      request.response.headers.set(HttpHeaders.retryAfterHeader, '2');
    if (failure.details?['offset'] case final offset?)
      request.response.headers.set('Upload-Offset', offset.toString());
    await _json(request.response, status, {
      'error': {
        'code': failure.code,
        'message': failure.code,
        if (failure.details != null) 'details': failure.details
      }
    });
  }

  Future<void> _json(
      HttpResponse response, int status, Map<String, Object?> body) async {
    final bytes = utf8.encode(jsonEncode(body));
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.headers.contentLength = bytes.length;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.add(bytes);
    await response.close();
  }
}
