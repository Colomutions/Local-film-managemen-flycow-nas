import 'dart:convert';
import 'dart:io';

import '../content_file_names.dart';
import 'novel_metadata.dart';
import 'novel_models.dart';
import 'novel_multipart.dart';
import 'novel_repository.dart';
import 'novel_storage.dart';
import 'novel_write_barrier.dart';

class NasNovelServiceException implements Exception {
  const NasNovelServiceException(
    this.code,
    this.message, {
    this.retryAfterSeconds,
    this.details,
  });

  final String code;
  final String message;
  final int? retryAfterSeconds;
  final Map<String, Object?>? details;

  @override
  String toString() => '$code: $message';
}

class NasNovelHttpResult {
  const NasNovelHttpResult({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, Object?> body;
}

class NasNovelUploadAdmission {
  NasNovelUploadAdmission._(this._limiter);

  final NasNovelUploadLimiter _limiter;
  var _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _limiter._release();
  }
}

class NasNovelUploadLimiter {
  NasNovelUploadLimiter({
    required this.maxConcurrent,
    required this.maxPerMinute,
  });

  final int maxConcurrent;
  final int maxPerMinute;
  final List<DateTime> _admittedAt = [];
  int _active = 0;

  NasNovelUploadAdmission acquire({DateTime? now}) {
    final timestamp = (now ?? DateTime.now().toUtc()).toUtc();
    _admittedAt.removeWhere(
      (value) => !value.isAfter(timestamp.subtract(const Duration(minutes: 1))),
    );
    if (_active >= maxConcurrent || _admittedAt.length >= maxPerMinute) {
      final retryAfter = _active >= maxConcurrent || _admittedAt.isEmpty
          ? 2
          : 60 - timestamp.difference(_admittedAt.first).inSeconds;
      throw NasNovelServiceException(
        'upload_rate_limited',
        'novel upload admission limit was reached',
        retryAfterSeconds: retryAfter.clamp(1, 60),
      );
    }
    _active++;
    _admittedAt.add(timestamp);
    return NasNovelUploadAdmission._(this);
  }

  void _release() {
    if (_active > 0) _active--;
  }
}

class NasNovelService {
  NasNovelService({
    required this.repository,
    required this.storage,
    required this.quotaBytes,
    required int uploadConcurrency,
    required int uploadRequestsPerMinute,
    NasNovelWriteBarrier? writeBarrier,
  })  : uploadLimiter = NasNovelUploadLimiter(
          maxConcurrent: uploadConcurrency,
          maxPerMinute: uploadRequestsPerMinute,
        ),
        writeBarrier = writeBarrier ?? NasNovelWriteBarrier();

  final NasNovelRepository repository;
  final NasNovelStorage storage;
  final int? quotaBytes;
  final NasNovelUploadLimiter uploadLimiter;
  final NasNovelWriteBarrier writeBarrier;

  bool _ready = false;
  String? _unavailableReason;

  bool get isReady => _ready;
  String? get unavailableReason => _unavailableReason;

  Future<void> initialize() async {
    try {
      storage.fileNames = ContentFileNames(repository.database);
      await storage.initialize();
      repository.cleanupRuntimeState();
      for (final novel in repository.allIncludingUnhealthy()) {
        try {
          await storage.verifyObjectMetadata(
            novel.contentSha256,
            expectedSizeBytes: novel.sizeBytes,
          );
          repository.setStorageState(novel.id, NasNovelStorageState.healthy);
        } on NasNovelStorageException {
          final exists = await storage.objectFile(novel.contentSha256).exists();
          repository.setStorageState(
            novel.id,
            exists
                ? NasNovelStorageState.corrupt
                : NasNovelStorageState.missing,
          );
        }
      }
      await storage.quarantineOrphans(repository.referencedContentDigests());
      _ready = true;
      _unavailableReason = null;
    } on NasNovelStorageException catch (error) {
      _ready = false;
      _unavailableReason = error.code;
    }
  }

  void requireReady() {
    if (!_ready) {
      throw NasNovelServiceException(
        'novel_storage_unavailable',
        _unavailableReason ?? 'novel storage is unavailable',
      );
    }
  }

  Future<NasNovelHttpResult> create(
    HttpRequest request, {
    required String deviceId,
    required bool isAdmin,
  }) async {
    requireReady();
    final admission = uploadLimiter.acquire();
    NasNovelMultipartPayload? payload;
    NasNovelIdempotencyScope? scope;
    String? ownerNonce;
    try {
      final key = _idempotencyKey(request);
      payload = await readNovelMultipart(
        request,
        storage: storage,
        allowConflictPolicy: true,
        allowKeepBoth: true,
      );
      final digest = postNovelSemanticDigest(payload.metadata);
      scope = NasNovelIdempotencyScope(
        deviceId: deviceId,
        method: 'POST',
        canonicalPath: '/api/v1/novels',
        key: key,
      );
      final acquisition = repository.acquireIdempotency(
        scope: scope,
        semanticDigest: digest,
      );
      final replay = _handleAcquisition(acquisition);
      if (replay != null) {
        await storage.discardTemporary(payload.content);
        return replay;
      }
      ownerNonce = acquisition.ownerNonce!;
      final committed = await writeBarrier.runMutation(() async {
        await storage.publish(payload!.content,
            fileName: '${payload.metadata.title}.txt');
        return repository.commitPost(
          scope: scope!,
          ownerNonce: ownerNonce!,
          metadata: payload!.metadata,
          quotaBytes: quotaBytes,
        );
      });
      return NasNovelHttpResult(
        statusCode: committed.statusCode,
        body: committed.toResponseJson(),
      );
    } catch (error) {
      if (scope != null && ownerNonce != null) {
        repository.releaseIdempotency(scope: scope, ownerNonce: ownerNonce);
      }
      if (payload != null) await storage.discardTemporary(payload.content);
      throw _translateError(error);
    } finally {
      admission.release();
    }
  }

  Future<NasNovelHttpResult> replace(
    HttpRequest request, {
    required String deviceId,
    required String novelId,
    required String expectedEtag,
    required int expectedRevision,
  }) async {
    requireReady();
    final admission = uploadLimiter.acquire();
    NasNovelMultipartPayload? payload;
    NasNovelIdempotencyScope? scope;
    String? ownerNonce;
    try {
      final key = _idempotencyKey(request);
      payload = await readNovelMultipart(
        request,
        storage: storage,
        allowConflictPolicy: false,
        allowKeepBoth: false,
      );
      final canonicalId = novelId.toLowerCase();
      final digest = putNovelSemanticDigest(
        payload.metadata,
        novelId: canonicalId,
        expectedEtag: expectedEtag,
      );
      scope = NasNovelIdempotencyScope(
        deviceId: deviceId,
        method: 'PUT',
        canonicalPath: '/api/v1/admin/novels/$canonicalId',
        key: key,
      );
      final acquisition = repository.acquireIdempotency(
        scope: scope,
        semanticDigest: digest,
      );
      final replay = _handleAcquisition(acquisition);
      if (replay != null) {
        await storage.discardTemporary(payload.content);
        return replay;
      }
      ownerNonce = acquisition.ownerNonce!;
      final current = repository.find(canonicalId);
      if (current == null) {
        throw const NasNovelRepositoryException(
          'resource_not_found',
          'novel does not exist',
        );
      }
      final changesContent =
          current.contentSha256 != payload.metadata.contentSha256;
      final committed = await writeBarrier.runMutation(() async {
        if (changesContent) {
          await storage.publish(payload!.content,
              fileName: '${payload.metadata.title}.txt');
        }
        return repository.commitPut(
          scope: scope!,
          ownerNonce: ownerNonce!,
          novelId: canonicalId,
          expectedRevision: expectedRevision,
          metadata: payload!.metadata,
          quotaBytes: quotaBytes,
        );
      });
      await storage.discardTemporary(payload.content);
      if (committed.unreferencedContentSha256 case final digest?) {
        await storage.deleteUnreferencedObject(digest);
      }
      return NasNovelHttpResult(
        statusCode: 200,
        body: committed.toResponseJson(),
      );
    } catch (error) {
      if (scope != null && ownerNonce != null) {
        repository.releaseIdempotency(scope: scope, ownerNonce: ownerNonce);
      }
      if (payload != null) await storage.discardTemporary(payload.content);
      throw _translateError(error);
    } finally {
      admission.release();
    }
  }

  Future<void> delete({
    required String novelId,
    required int expectedRevision,
    required String actorDeviceId,
  }) async {
    requireReady();
    try {
      final committed =
          await writeBarrier.runMutation(() async => repository.delete(
                novelId: novelId.toLowerCase(),
                expectedRevision: expectedRevision,
                actorDeviceId: actorDeviceId,
              ));
      if (committed.unreferencedContentSha256 case final digest?) {
        await storage.deleteUnreferencedObject(digest);
      }
    } catch (error) {
      throw _translateError(error);
    }
  }

  NasNovelHttpResult? _handleAcquisition(
    NasNovelIdempotencyAcquisition acquisition,
  ) {
    switch (acquisition.decision) {
      case NasNovelIdempotencyDecision.acquired:
        return null;
      case NasNovelIdempotencyDecision.replay:
        final status = acquisition.record.httpStatus;
        final body = acquisition.record.decodedResponse;
        if (status == null || body == null) {
          throw const NasNovelServiceException(
            'novel_storage_unavailable',
            'stored idempotency result is incomplete',
          );
        }
        return NasNovelHttpResult(statusCode: status, body: body);
      case NasNovelIdempotencyDecision.inProgress:
        throw const NasNovelServiceException(
          'upload_in_progress',
          'the same idempotent upload is still running',
          retryAfterSeconds: 2,
        );
      case NasNovelIdempotencyDecision.conflict:
        throw const NasNovelServiceException(
          'idempotency_conflict',
          'the idempotency key was used for a different request',
        );
      case NasNovelIdempotencyDecision.gone:
        throw const NasNovelServiceException(
          'idempotency_result_gone',
          'the idempotent upload result was deleted',
        );
    }
  }

  NasNovelServiceException _translateError(Object error) {
    if (error is NasNovelRepositoryException &&
        error.code == 'quota_exceeded') {
      final limit = quotaBytes;
      final remaining = limit == null
          ? 0
          : (limit - repository.logicalUsageBytes).clamp(0, limit);
      return NasNovelServiceException(
        error.code,
        error.message,
        details: {
          'scope': 'global',
          if (limit != null) 'limitBytes': limit,
          'remainingBytes': remaining,
        },
      );
    }
    return _serviceError(error);
  }
}

String _idempotencyKey(HttpRequest request) {
  final value = request.headers.value('idempotency-key');
  if (value == null ||
      !RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
      ).hasMatch(value)) {
    throw const NasNovelServiceException(
      'invalid_request',
      'Idempotency-Key must be a UUID',
    );
  }
  return value.toLowerCase();
}

NasNovelServiceException _serviceError(Object error) {
  if (error is NasNovelServiceException) return error;
  if (error is NasNovelMultipartException) {
    return NasNovelServiceException(error.code, error.message);
  }
  if (error is NasNovelStorageException) {
    return NasNovelServiceException(error.code, error.message);
  }
  if (error is NasNovelRepositoryException) {
    return NasNovelServiceException(error.code, error.message);
  }
  if (error is FormatException || error is JsonUnsupportedObjectError) {
    return const NasNovelServiceException(
      'invalid_request',
      'request encoding is invalid',
    );
  }
  return NasNovelServiceException(
    'novel_storage_unavailable',
    'novel request failed',
  );
}
