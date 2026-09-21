import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mime/mime.dart';

import 'novel_metadata.dart';
import 'novel_models.dart';
import 'novel_storage.dart';

class NasNovelMultipartException implements Exception {
  const NasNovelMultipartException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

class NasNovelMultipartPayload {
  const NasNovelMultipartPayload({
    required this.metadata,
    required this.content,
  });

  final NasNovelMetadata metadata;
  final NasNovelTemporaryContent content;
}

Future<NasNovelMultipartPayload> readNovelMultipart(
  HttpRequest request, {
  required NasNovelStorage storage,
  required bool allowConflictPolicy,
  required bool allowKeepBoth,
}) async {
  final contentType = request.headers.contentType;
  final boundary = contentType?.parameters['boundary'];
  if (contentType == null ||
      contentType.mimeType.toLowerCase() != 'multipart/form-data' ||
      boundary == null ||
      boundary.isEmpty ||
      boundary.length > 200) {
    throw const NasNovelMultipartException(
      'invalid_request',
      'Content-Type must be multipart/form-data with a valid boundary',
    );
  }

  NasNovelMetadata? metadata;
  NasNovelTemporaryContent? temporary;
  Object? deferredError;
  StackTrace? deferredStackTrace;
  var index = 0;
  try {
    await for (final part in request
        .cast<List<int>>()
        .transform(MimeMultipartTransformer(boundary))) {
      try {
        if (deferredError != null) {
          await part.drain<void>();
          continue;
        }
        final dispositionValue = part.headers['content-disposition'];
        HeaderValue disposition;
        try {
          disposition = HeaderValue.parse(dispositionValue ?? '');
        } on FormatException {
          throw const NasNovelMultipartException(
            'invalid_request',
            'multipart Content-Disposition is invalid',
          );
        }
        if (disposition.value.toLowerCase() != 'form-data') {
          throw const NasNovelMultipartException(
            'invalid_request',
            'multipart parts must use form-data disposition',
          );
        }
        final name = disposition.parameters['name'];
        if (name == 'cover') {
          throw const NasNovelMultipartException(
            'unsupported_cover',
            'cover upload is not supported in v1',
          );
        }
        if (index == 0 && name == 'metadata') {
          _requirePartContentType(
            part.headers['content-type'],
            expectedMimeType: 'application/json',
          );
          final bytes = await _readLimited(part, 16 * 1024);
          Object? decoded;
          try {
            decoded = jsonDecode(
                const Utf8Decoder(allowMalformed: false).convert(bytes));
          } on FormatException {
            throw const NasNovelMultipartException(
              'invalid_metadata',
              'metadata must be valid UTF-8 JSON',
            );
          }
          try {
            metadata = parseNovelMetadata(
              decoded,
              allowConflictPolicy: allowConflictPolicy,
              allowKeepBoth: allowKeepBoth,
            );
          } on NasNovelMetadataException catch (error) {
            throw NasNovelMultipartException(error.code, error.message);
          }
        } else if (index == 1 && name == 'file' && metadata != null) {
          _requirePartContentType(
            part.headers['content-type'],
            expectedMimeType: 'text/plain',
          );
          temporary = await storage.receiveText(
            part,
            declaredSizeBytes: metadata.sizeBytes,
            declaredSha256: metadata.contentSha256,
          );
        } else {
          throw const NasNovelMultipartException(
            'invalid_metadata',
            'multipart parts must be metadata followed by file',
          );
        }
      } catch (error, stackTrace) {
        deferredError ??= error;
        deferredStackTrace ??= stackTrace;
        try {
          await part.drain<void>();
        } catch (_) {
          // A fully consumed single-subscription part cannot be drained again.
        }
      } finally {
        index++;
      }
    }
    if (deferredError != null) {
      Error.throwWithStackTrace(deferredError, deferredStackTrace!);
    }
    if (index != 2 || metadata == null || temporary == null) {
      throw const NasNovelMultipartException(
        'invalid_request',
        'multipart request must contain metadata and file parts',
      );
    }
    return NasNovelMultipartPayload(metadata: metadata, content: temporary);
  } catch (_) {
    if (temporary != null) await storage.discardTemporary(temporary);
    rethrow;
  }
}

void _requirePartContentType(
  String? value, {
  required String expectedMimeType,
}) {
  ContentType parsed;
  try {
    parsed = ContentType.parse(value ?? '');
  } on FormatException {
    throw const NasNovelMultipartException(
      'invalid_request',
      'multipart part Content-Type is invalid',
    );
  }
  final charset = parsed.charset?.toLowerCase();
  if (parsed.mimeType.toLowerCase() != expectedMimeType || charset != 'utf-8') {
    throw NasNovelMultipartException(
      expectedMimeType == 'text/plain'
          ? 'unsupported_novel_format'
          : 'invalid_request',
      'multipart part has an unsupported Content-Type',
    );
  }
}

Future<List<int>> _readLimited(Stream<List<int>> source, int limit) async {
  final builder = BytesBuilder(copy: false);
  var length = 0;
  var exceeded = false;
  await for (final chunk in source) {
    length += chunk.length;
    if (length > limit) {
      exceeded = true;
    } else {
      builder.add(chunk);
    }
  }
  if (exceeded) {
    throw const NasNovelMultipartException(
      'payload_too_large',
      'metadata part exceeds 16 KiB',
    );
  }
  return builder.takeBytes();
}
