import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../auth.dart';

class NasNovelStorageException implements Exception {
  const NasNovelStorageException(this.code, this.message, [this.cause]);

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => '$code: $message';
}

class NasNovelTemporaryContent {
  const NasNovelTemporaryContent({
    required this.file,
    required this.sizeBytes,
    required this.sha256,
  });

  final File file;
  final int sizeBytes;
  final String sha256;
}

class NasNovelPublishedContent {
  const NasNovelPublishedContent({
    required this.file,
    required this.created,
  });

  final File file;
  final bool created;
}

class NasNovelStorage {
  NasNovelStorage({
    required this.rootPath,
    required this.maxUploadBytes,
  });

  final String rootPath;
  final int maxUploadBytes;
  Future<void> _publicationQueue = Future.value();

  Directory get root => Directory(rootPath);
  Directory get objectDirectory =>
      Directory('$rootPath${Platform.pathSeparator}objects');
  Directory get temporaryDirectory =>
      Directory('$rootPath${Platform.pathSeparator}.tmp');
  Directory get quarantineDirectory =>
      Directory('$rootPath${Platform.pathSeparator}quarantine');

  Future<void> initialize() async {
    if (!root.isAbsolute) {
      throw const NasNovelStorageException(
        'novel_storage_unavailable',
        'novel storage path must be absolute',
      );
    }
    try {
      await objectDirectory.create(recursive: true);
      await temporaryDirectory.create(recursive: true);
      await quarantineDirectory.create(recursive: true);
      final probe = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}.write-probe-${newUuidV4()}',
      );
      await probe.writeAsBytes(const [0], flush: true);
      await probe.delete();
    } on FileSystemException catch (error) {
      throw NasNovelStorageException(
        'novel_storage_unavailable',
        'novel storage is not writable',
        error,
      );
    }
  }

  Future<NasNovelTemporaryContent> receiveText(
    Stream<List<int>> source, {
    int? declaredSizeBytes,
    String? declaredSha256,
  }) async {
    final file = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}${newUuidV4()}.upload',
    );
    IOSink? output;
    var completed = false;
    try {
      output = file.openWrite(mode: FileMode.writeOnly);
      final digestResult = _DigestResultSink();
      final digestInput = sha256.startChunkedConversion(digestResult);
      final utf8Input = const Utf8Decoder(allowMalformed: false)
          .startChunkedConversion(_DiscardStringSink());
      var sizeBytes = 0;
      NasNovelStorageException? validationError;
      await for (final chunk in source) {
        sizeBytes += chunk.length;
        if (validationError != null) continue;
        if (sizeBytes > maxUploadBytes) {
          validationError = const NasNovelStorageException(
            'payload_too_large',
            'novel file exceeds the configured upload limit',
          );
          continue;
        }
        output.add(chunk);
        digestInput.add(chunk);
        try {
          utf8Input.add(chunk);
        } on FormatException catch (error) {
          validationError = NasNovelStorageException(
            'unsupported_novel_format',
            'novel file must be valid UTF-8',
            error,
          );
        }
      }
      digestInput.close();
      try {
        utf8Input.close();
      } on FormatException catch (error) {
        validationError ??= NasNovelStorageException(
          'unsupported_novel_format',
          'novel file must be valid UTF-8',
          error,
        );
      }
      await output.flush();
      await output.close();
      output = null;

      if (validationError != null) throw validationError;

      final digest = digestResult.value?.toString();
      if (digest == null) {
        throw const NasNovelStorageException(
          'novel_storage_unavailable',
          'failed to calculate content digest',
        );
      }
      if (declaredSizeBytes != null && declaredSizeBytes != sizeBytes) {
        throw const NasNovelStorageException(
          'content_length_mismatch',
          'declared novel size does not match the received file',
        );
      }
      if (declaredSha256 != null && declaredSha256 != digest) {
        throw const NasNovelStorageException(
          'content_hash_mismatch',
          'declared novel digest does not match the received file',
        );
      }
      final result = NasNovelTemporaryContent(
        file: file,
        sizeBytes: sizeBytes,
        sha256: digest,
      );
      completed = true;
      return result;
    } on FileSystemException catch (error) {
      throw NasNovelStorageException(
        'storage_insufficient',
        'novel storage could not accept the uploaded file',
        error,
      );
    } finally {
      await output?.close();
      if (!completed) await _deleteIfExists(file);
    }
  }

  File objectFile(String digest) {
    _validateDigest(digest);
    return File('${objectDirectory.path}${Platform.pathSeparator}$digest');
  }

  Future<NasNovelPublishedContent> publish(
    NasNovelTemporaryContent temporary,
  ) {
    final completer = Completer<NasNovelPublishedContent>();
    _publicationQueue = _publicationQueue.catchError((_) {}).then((_) async {
      try {
        completer.complete(await _publishSerially(temporary));
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<NasNovelPublishedContent> _publishSerially(
    NasNovelTemporaryContent temporary,
  ) async {
    final destination = objectFile(temporary.sha256);
    if (await destination.exists()) {
      await verifyObject(
        temporary.sha256,
        expectedSizeBytes: temporary.sizeBytes,
      );
      await _deleteIfExists(temporary.file);
      return NasNovelPublishedContent(file: destination, created: false);
    }
    try {
      final published = await temporary.file.rename(destination.path);
      return NasNovelPublishedContent(file: published, created: true);
    } on FileSystemException catch (error) {
      if (await destination.exists()) {
        await verifyObject(
          temporary.sha256,
          expectedSizeBytes: temporary.sizeBytes,
        );
        await _deleteIfExists(temporary.file);
        return NasNovelPublishedContent(file: destination, created: false);
      }
      throw NasNovelStorageException(
        'novel_storage_unavailable',
        'failed to publish novel content',
        error,
      );
    }
  }

  Future<void> verifyObject(
    String digest, {
    required int expectedSizeBytes,
  }) async {
    await verifyObjectMetadata(digest, expectedSizeBytes: expectedSizeBytes);
    final file = objectFile(digest);
    try {
      final actual = await sha256.bind(file.openRead()).first;
      if (actual.toString() != digest) {
        throw const NasNovelStorageException(
          'novel_content_unavailable',
          'novel content digest verification failed',
        );
      }
    } on FileSystemException catch (error) {
      throw NasNovelStorageException(
        'novel_content_unavailable',
        'novel content could not be read',
        error,
      );
    }
  }

  Future<void> verifyObjectMetadata(
    String digest, {
    required int expectedSizeBytes,
  }) async {
    final file = objectFile(digest);
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size != expectedSizeBytes) {
        throw const NasNovelStorageException(
          'novel_content_unavailable',
          'novel content is missing or has an invalid size',
        );
      }
    } on FileSystemException catch (error) {
      throw NasNovelStorageException(
        'novel_content_unavailable',
        'novel content could not be checked',
        error,
      );
    }
  }

  Future<void> deleteUnreferencedObject(String digest) async {
    await _deleteIfExists(objectFile(digest));
  }

  Future<void> quarantineOrphans(Set<String> referencedDigests) async {
    if (!await objectDirectory.exists()) return;
    await for (final entity in objectDirectory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (referencedDigests.contains(name)) continue;
      final target = File(
        '${quarantineDirectory.path}${Platform.pathSeparator}'
        '${DateTime.now().toUtc().microsecondsSinceEpoch}-$name',
      );
      try {
        await entity.rename(target.path);
      } on FileSystemException {
        // Keep the orphan in place for a later diagnostic pass.
      }
    }
  }

  Future<void> discardTemporary(NasNovelTemporaryContent temporary) =>
      _deleteIfExists(temporary.file);

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Startup orphan cleanup can retry a failed best-effort deletion.
    }
  }

  void _validateDigest(String digest) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw ArgumentError.value(digest, 'digest', 'invalid SHA-256');
    }
  }
}

class _DigestResultSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

class _DiscardStringSink implements Sink<String> {
  @override
  void add(String data) {}

  @override
  void close() {}
}
