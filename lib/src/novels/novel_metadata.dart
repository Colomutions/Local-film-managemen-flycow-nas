import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'novel_models.dart';

class NasNovelMetadataException implements Exception {
  const NasNovelMetadataException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

final RegExp _unicodeWhitespace = RegExp(
  r'[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+',
  unicode: true,
);
final RegExp _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

NasNovelMetadata parseNovelMetadata(
  Object? value, {
  required bool allowConflictPolicy,
  required bool allowKeepBoth,
}) {
  if (value is! Map<String, dynamic>) {
    throw const NasNovelMetadataException(
      'invalid_metadata',
      'metadata must be a JSON object',
    );
  }
  final allowed = <String>{
    'title',
    'author',
    'format',
    'contentState',
    'relativePath',
    'sizeBytes',
    'contentSha256',
    if (allowConflictPolicy) 'conflictPolicy',
  };
  final unknown = value.keys.where((key) => !allowed.contains(key)).toList();
  if (unknown.isNotEmpty) {
    throw NasNovelMetadataException(
      'invalid_metadata',
      'unknown metadata field: ${unknown.first}',
    );
  }

  final rawTitle = value['title'];
  final rawAuthor = value['author'];
  final rawRelativePath = value['relativePath'] ?? '';
  final rawFormat = value['format'];
  final rawContentState = value['contentState'];
  final rawSize = value['sizeBytes'];
  final rawSha256 = value['contentSha256'];
  if (rawTitle is! String ||
      rawRelativePath is! String ||
      rawFormat is! String ||
      rawContentState is! String ||
      rawSize is! int ||
      rawSha256 is! String ||
      (rawAuthor != null && rawAuthor is! String)) {
    throw const NasNovelMetadataException(
      'invalid_metadata',
      'metadata fields have invalid types',
    );
  }

  final title = normalizeNovelText(rawTitle);
  final author = rawAuthor == null ? null : normalizeNovelText(rawAuthor);
  final relativePath = normalizeNovelRelativePath(rawRelativePath);
  final format = normalizeNovelText(rawFormat).toLowerCase();
  final contentState = normalizeNovelText(rawContentState);
  if (title.isEmpty || _scalarLength(title) > 256) {
    throw const NasNovelMetadataException(
      'invalid_metadata',
      'title must contain 1 to 256 Unicode scalars',
    );
  }
  if (author != null && author.isNotEmpty && _scalarLength(author) > 128) {
    throw const NasNovelMetadataException(
      'invalid_metadata',
      'author must contain at most 128 Unicode scalars',
    );
  }
  if (format != 'txt' || contentState != 'complete_file') {
    throw const NasNovelMetadataException(
      'unsupported_novel_format',
      'v1 only accepts complete UTF-8 TXT files',
    );
  }
  if (rawSize < 0 || !_sha256Pattern.hasMatch(rawSha256)) {
    throw const NasNovelMetadataException(
      'invalid_metadata',
      'sizeBytes or contentSha256 is invalid',
    );
  }

  final rawPolicy =
      allowConflictPolicy ? value['conflictPolicy'] ?? 'reject' : 'reject';
  if (rawPolicy is! String ||
      (rawPolicy != 'reject' && rawPolicy != 'keep_both')) {
    throw const NasNovelMetadataException(
      'invalid_metadata',
      'conflictPolicy is invalid',
    );
  }
  if (rawPolicy == 'keep_both' && !allowKeepBoth) {
    throw const NasNovelMetadataException(
      'insufficient_scope',
      'keep_both requires admin scope',
    );
  }

  return NasNovelMetadata(
    title: title,
    author: author == null || author.isEmpty ? null : author,
    relativePath: relativePath,
    sizeBytes: rawSize,
    contentSha256: rawSha256,
    conflictPolicy: rawPolicy == 'keep_both'
        ? NasNovelConflictPolicy.keepBoth
        : NasNovelConflictPolicy.reject,
  );
}

String normalizeNovelText(String value) {
  final normalized = unorm.nfc(value).replaceAll(_unicodeWhitespace, ' ');
  var start = 0;
  var end = normalized.length;
  while (start < end && normalized.codeUnitAt(start) == 0x20) {
    start++;
  }
  while (end > start && normalized.codeUnitAt(end - 1) == 0x20) {
    end--;
  }
  return normalized.substring(start, end);
}

String normalizeNovelRelativePath(String value) {
  final normalized = normalizeNovelText(value);
  if (normalized.isEmpty) return '';
  if (normalized.contains('\\') ||
      normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
      normalized.contains('\u0000') ||
      normalized.contains('%2f', 0) ||
      normalized.contains('%2F', 0) ||
      normalized.contains('%5c', 0) ||
      normalized.contains('%5C', 0)) {
    throw const NasNovelMetadataException(
      'invalid_metadata',
      'relativePath is invalid',
    );
  }
  final segments = normalized.split('/');
  if (segments.length > 16 ||
      segments.any((segment) =>
          segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          _scalarLength(segment) > 128) ||
      _scalarLength(normalized) > 512) {
    throw const NasNovelMetadataException(
      'invalid_metadata',
      'relativePath is invalid',
    );
  }
  return segments.join('/');
}

String postNovelSemanticDigest(NasNovelMetadata metadata) => _semanticDigest(
      'novel-upload-v1\n',
      metadata.toPostSemanticJson(),
    );

String putNovelSemanticDigest(
  NasNovelMetadata metadata, {
  required String novelId,
  required String expectedEtag,
}) =>
    _semanticDigest(
      'novel-replace-v1\n',
      metadata.toPutSemanticJson(
        novelId: novelId,
        expectedEtag: expectedEtag,
      ),
    );

String canonicalJson(Map<String, Object?> value) {
  final keys = value.keys.toList()..sort();
  return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalValue(value[key])}').join(',')}}';
}

String _canonicalValue(Object? value) {
  if (value == null || value is String || value is bool || value is int) {
    return jsonEncode(value);
  }
  if (value is List<Object?>) {
    return '[${value.map(_canonicalValue).join(',')}]';
  }
  if (value is Map<String, Object?>) return canonicalJson(value);
  throw ArgumentError.value(value, 'value', 'not supported by canonical JSON');
}

String _semanticDigest(String prefix, Map<String, Object?> value) =>
    sha256.convert(utf8.encode('$prefix${canonicalJson(value)}')).toString();

int _scalarLength(String value) => value.runes.length;
