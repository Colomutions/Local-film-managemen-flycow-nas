import 'dart:convert';
import 'dart:io';

import '../range.dart';
import 'novel_models.dart';
import 'novel_repository.dart';
import 'novel_service.dart';
import 'novel_storage.dart';

class NasNovelHttpApi {
  NasNovelHttpApi(this.service);

  final NasNovelService service;

  bool get isReady => service.isReady;
  String? get unavailableReason => service.unavailableReason;

  Future<void> list(HttpRequest request) async {
    try {
      service.requireReady();
      final page = _positiveInt(request.uri.queryParameters['page'], 1);
      final pageSize =
          _positiveInt(request.uri.queryParameters['pageSize'], 30);
      final result = service.repository.list(
        query: request.uri.queryParameters['q'],
        page: page,
        pageSize: pageSize,
        sort: request.uri.queryParameters['sort'] ?? 'updatedAt',
        order: request.uri.queryParameters['order'] ?? 'desc',
      );
      await _writeJson(request.response, HttpStatus.ok, result.toJson());
    } catch (error) {
      await _writeError(request, _translate(error));
    }
  }

  Future<void> detail(HttpRequest request, String novelId) async {
    try {
      service.requireReady();
      final canonicalId = _canonicalUuid(novelId);
      final novel = service.repository.find(canonicalId);
      if (novel == null) {
        throw const NasNovelServiceException(
          'resource_not_found',
          'novel does not exist',
        );
      }
      request.response.headers.set(HttpHeaders.etagHeader, _detailEtag(novel));
      await _writeJson(
          request.response, HttpStatus.ok, {'data': novel.toJson()});
    } catch (error) {
      await _writeError(request, _translate(error));
    }
  }

  Future<void> content(HttpRequest request, String novelId) async {
    try {
      service.requireReady();
      final canonicalId = _canonicalUuid(novelId);
      final novel =
          service.repository.find(canonicalId, includeUnhealthy: true);
      if (novel == null) {
        throw const NasNovelServiceException(
          'resource_not_found',
          'novel does not exist',
        );
      }
      if (novel.storageState != NasNovelStorageState.healthy) {
        throw const NasNovelServiceException(
          'novel_content_unavailable',
          'novel content is unavailable',
        );
      }
      try {
        await service.storage.verifyObject(
          novel.contentSha256,
          expectedSizeBytes: novel.sizeBytes,
        );
      } on NasNovelStorageException {
        final exists =
            await service.storage.objectFile(novel.contentSha256).exists();
        service.repository.setStorageState(
          novel.id,
          exists ? NasNovelStorageState.corrupt : NasNovelStorageState.missing,
        );
        throw const NasNovelServiceException(
          'novel_content_unavailable',
          'novel content is unavailable',
        );
      }
      final file = service.storage.objectFile(novel.contentSha256);
      final length = novel.sizeBytes;
      final etag = '"sha256:${novel.contentSha256}"';
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
      final effectiveRange =
          ifRange == null || ifRange == etag ? rangeHeader : null;
      final parsed = parseSingleByteRange(effectiveRange, length);
      if (parsed.requested && parsed.range == null) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        request.response.headers.contentLength = 0;
        await request.response.close();
        return;
      }
      final range = parsed.range;
      final start = range?.start ?? 0;
      final end = range?.end ?? length - 1;
      request.response.statusCode =
          range == null ? HttpStatus.ok : HttpStatus.partialContent;
      request.response.headers.contentType =
          ContentType('text', 'plain', charset: 'utf-8');
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set(HttpHeaders.etagHeader, etag);
      request.response.headers.set(
        'content-disposition',
        _contentDisposition(novel),
      );
      request.response.headers.contentLength =
          length == 0 ? 0 : end - start + 1;
      if (range != null) {
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$length',
        );
      }
      if (request.method == 'GET' && length > 0) {
        await request.response.addStream(file.openRead(start, end + 1));
      }
      await request.response.close();
    } catch (error) {
      await _writeError(request, _translate(error));
    }
  }

  Future<void> create(
    HttpRequest request, {
    required String deviceId,
    required bool isAdmin,
  }) async {
    try {
      final result = await service.create(
        request,
        deviceId: deviceId,
        isAdmin: isAdmin,
      );
      await _writeJson(request.response, result.statusCode, result.body);
    } catch (error) {
      await _writeError(request, _translate(error));
    }
  }

  Future<void> replace(
    HttpRequest request, {
    required String deviceId,
    required String novelId,
  }) async {
    try {
      final canonicalId = _canonicalUuid(novelId);
      final conditional = _parseIfMatch(request, canonicalId);
      final result = await service.replace(
        request,
        deviceId: deviceId,
        novelId: canonicalId,
        expectedEtag: conditional.etag,
        expectedRevision: conditional.revision,
      );
      request.response.headers.set(
        HttpHeaders.etagHeader,
        _detailEtagFromParts(canonicalId, _responseRevision(result.body)),
      );
      await _writeJson(request.response, result.statusCode, result.body);
    } catch (error) {
      await _writeError(request, _translate(error));
    }
  }

  Future<void> delete(
    HttpRequest request, {
    required String deviceId,
    required String novelId,
  }) async {
    try {
      final canonicalId = _canonicalUuid(novelId);
      final conditional = _parseIfMatch(request, canonicalId);
      await service.delete(
        novelId: canonicalId,
        expectedRevision: conditional.revision,
        actorDeviceId: deviceId,
      );
      request.response.statusCode = HttpStatus.noContent;
      request.response.headers.contentLength = 0;
      await request.response.close();
    } catch (error) {
      await _writeError(request, _translate(error));
    }
  }

  _IfMatch _parseIfMatch(HttpRequest request, String novelId) {
    final value = request.headers.value(HttpHeaders.ifMatchHeader);
    if (value == null) {
      throw const NasNovelServiceException(
        'precondition_required',
        'If-Match is required',
      );
    }
    final match = RegExp(
      r'^"novel:([0-9a-fA-F-]{36}):r([1-9][0-9]*)"$',
    ).firstMatch(value);
    if (match == null || match.group(1)!.toLowerCase() != novelId) {
      throw const NasNovelServiceException(
        'invalid_request',
        'If-Match must contain the detail ETag for this novel',
      );
    }
    return _IfMatch(etag: value, revision: int.parse(match.group(2)!));
  }
}

class _IfMatch {
  const _IfMatch({required this.etag, required this.revision});

  final String etag;
  final int revision;
}

NasNovelServiceException _translate(Object error) {
  if (error is NasNovelServiceException) return error;
  if (error is NasNovelRepositoryException) {
    return NasNovelServiceException(error.code, error.message);
  }
  if (error is FormatException || error is ArgumentError) {
    return const NasNovelServiceException(
      'invalid_request',
      'request parameters are invalid',
    );
  }
  return const NasNovelServiceException(
    'novel_storage_unavailable',
    'novel service is unavailable',
  );
}

Future<void> _writeError(
  HttpRequest request,
  NasNovelServiceException error,
) async {
  final status = switch (error.code) {
    'invalid_request' || 'invalid_metadata' || 'unsupported_cover' => 400,
    'authentication_required' => 401,
    'insufficient_scope' || 'quota_exceeded' => 403,
    'resource_not_found' => 404,
    'novel_name_conflict' ||
    'idempotency_conflict' ||
    'upload_in_progress' =>
      409,
    'idempotency_result_gone' => 410,
    'novel_revision_conflict' => 412,
    'payload_too_large' => 413,
    'unsupported_novel_format' => 415,
    'content_length_mismatch' || 'content_hash_mismatch' => 422,
    'precondition_required' => 428,
    'upload_rate_limited' => 429,
    'novel_content_unavailable' ||
    'novel_storage_unavailable' ||
    'service_maintenance' =>
      503,
    'storage_insufficient' => 507,
    _ => 503,
  };
  if (error.retryAfterSeconds case final seconds?) {
    request.response.headers
        .set(HttpHeaders.retryAfterHeader, seconds.toString());
  }
  final payload = <String, Object?>{
    'code': error.code,
    'message': error.message,
    if (error.details != null) 'details': error.details,
  };
  await _writeJson(request.response, status, {'error': payload});
}

Future<void> _writeJson(
  HttpResponse response,
  int statusCode,
  Map<String, Object?> body,
) async {
  final bytes = utf8.encode(jsonEncode(body));
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.json;
  response.headers.contentLength = bytes.length;
  response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
  response.add(bytes);
  await response.close();
}

int _positiveInt(String? value, int fallback) {
  if (value == null) return fallback;
  final parsed = int.tryParse(value);
  if (parsed == null || parsed < 1) throw const FormatException();
  return parsed;
}

String _canonicalUuid(String value) {
  if (!RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  ).hasMatch(value)) {
    throw const FormatException('invalid UUID');
  }
  return value.toLowerCase();
}

String _detailEtag(NasNovel novel) =>
    _detailEtagFromParts(novel.id, novel.revision);

String _detailEtagFromParts(String novelId, int revision) =>
    '"novel:$novelId:r$revision"';

int _responseRevision(Map<String, Object?> body) {
  final data = body['data'] as Map<String, dynamic>;
  final novel = data['novel'] as Map<String, dynamic>;
  return novel['revision'] as int;
}

String _contentDisposition(NasNovel novel) {
  final encoded = utf8
      .encode(novel.fileName)
      .map((byte) => _attributeByte(byte)
          ? String.fromCharCode(byte)
          : '%${byte.toRadixString(16).padLeft(2, '0').toUpperCase()}')
      .join();
  return 'attachment; filename="novel-${novel.id}.txt"; filename*=UTF-8\'\'$encoded';
}

bool _attributeByte(int byte) =>
    (byte >= 0x30 && byte <= 0x39) ||
    (byte >= 0x41 && byte <= 0x5A) ||
    (byte >= 0x61 && byte <= 0x7A) ||
    const {
      0x21,
      0x23,
      0x24,
      0x26,
      0x2B,
      0x2D,
      0x2E,
      0x5E,
      0x5F,
      0x60,
      0x7C,
      0x7E
    }.contains(byte);
