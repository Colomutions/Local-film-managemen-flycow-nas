import 'dart:convert';

enum NasNovelStorageState { healthy, missing, corrupt }

class NasNovel {
  const NasNovel({
    required this.id,
    required this.title,
    required this.author,
    required this.relativePath,
    required this.fileName,
    required this.sizeBytes,
    required this.contentSha256,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.storageState = NasNovelStorageState.healthy,
  });

  final String id;
  final String title;
  final String? author;
  final String relativePath;
  final String fileName;
  final int sizeBytes;
  final String contentSha256;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
  final NasNovelStorageState storageState;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'format': 'txt',
        'contentState': 'complete_file',
        'sizeBytes': sizeBytes,
        'contentSha256': contentSha256,
        'relativePath': relativePath,
        'fileName': fileName,
        'coverUrl': null,
        'canDownload': true,
        'revision': revision,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };
}

enum NasNovelConflictPolicy { reject, keepBoth }

class NasNovelMetadata {
  const NasNovelMetadata({
    required this.title,
    required this.author,
    required this.relativePath,
    required this.sizeBytes,
    required this.contentSha256,
    required this.conflictPolicy,
  });

  final String title;
  final String? author;
  final String relativePath;
  final int sizeBytes;
  final String contentSha256;
  final NasNovelConflictPolicy conflictPolicy;

  Map<String, Object?> toPostSemanticJson() => {
        'author': author,
        'conflictPolicy': switch (conflictPolicy) {
          NasNovelConflictPolicy.reject => 'reject',
          NasNovelConflictPolicy.keepBoth => 'keep_both',
        },
        'contentSha256': contentSha256,
        'contentState': 'complete_file',
        'format': 'txt',
        'relativePath': relativePath,
        'sizeBytes': sizeBytes,
        'title': title,
      };

  Map<String, Object?> toPutSemanticJson({
    required String novelId,
    required String expectedEtag,
  }) =>
      {
        'author': author,
        'contentSha256': contentSha256,
        'contentState': 'complete_file',
        'expectedEtag': expectedEtag,
        'format': 'txt',
        'novelId': novelId,
        'relativePath': relativePath,
        'sizeBytes': sizeBytes,
        'title': title,
      };
}

class NasNovelPage {
  const NasNovelPage({
    required this.items,
    required this.number,
    required this.size,
    required this.total,
  });

  final List<NasNovel> items;
  final int number;
  final int size;
  final int total;

  bool get hasMore => number * size < total;

  Map<String, Object?> toJson() => {
        'data': {
          'items': items.map((item) => item.toJson()).toList(growable: false),
        },
        'page': {
          'number': number,
          'size': size,
          'total': total,
          'hasMore': hasMore,
        },
      };
}

enum NasNovelIdempotencyState { inProgress, succeeded, gone }

class NasNovelIdempotencyScope {
  const NasNovelIdempotencyScope({
    required this.deviceId,
    required this.method,
    required this.canonicalPath,
    required this.key,
  });

  final String deviceId;
  final String method;
  final String canonicalPath;
  final String key;
}

class NasNovelIdempotencyRecord {
  const NasNovelIdempotencyRecord({
    required this.scope,
    required this.semanticDigest,
    required this.state,
    required this.ownerNonce,
    required this.leaseExpiresAt,
    required this.httpStatus,
    required this.responseJson,
    required this.novelId,
    required this.expiresAt,
  });

  final NasNovelIdempotencyScope scope;
  final String semanticDigest;
  final NasNovelIdempotencyState state;
  final String? ownerNonce;
  final DateTime? leaseExpiresAt;
  final int? httpStatus;
  final String? responseJson;
  final String? novelId;
  final DateTime? expiresAt;

  Map<String, Object?>? get decodedResponse {
    final encoded = responseJson;
    if (encoded == null) return null;
    final value = jsonDecode(encoded);
    return value is Map<String, Object?> ? value : null;
  }
}

class NasNovelDeletionAudit {
  const NasNovelDeletionAudit({
    required this.actorDeviceId,
    required this.novelId,
    required this.deletedRevision,
    required this.contentSha256,
    required this.deletedAt,
  });

  final String actorDeviceId;
  final String novelId;
  final int deletedRevision;
  final String contentSha256;
  final DateTime deletedAt;
}

class NasNovelBackupEntry {
  const NasNovelBackupEntry({
    required this.novelId,
    required this.revision,
    required this.contentSha256,
    required this.sizeBytes,
  });

  final String novelId;
  final int revision;
  final String contentSha256;
  final int sizeBytes;

  String get relativeObjectPath => 'novels/objects/$contentSha256';

  Map<String, Object> toJson() => {
        'novelId': novelId,
        'revision': revision,
        'relativePath': relativeObjectPath,
        'sizeBytes': sizeBytes,
        'sha256': contentSha256,
      };
}
