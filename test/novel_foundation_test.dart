import 'dart:convert';
import 'dart:io';

import '../lib/src/config.dart';
import '../lib/src/library_database.dart';
import '../lib/src/novels/novel_metadata.dart';
import '../lib/src/novels/novel_models.dart';
import '../lib/src/novels/novel_repository.dart';
import '../lib/src/novels/novel_service.dart';
import '../lib/src/novels/novel_storage.dart';

Future<void> main() async {
  _testConfiguration();
  _testMetadata();
  await _testStorageAndRepository();
}

void _testConfiguration() {
  final config = NasConfig.fromEnvironment({
    'MUJING_NOVEL_DIR': '/novels',
    'MUJING_NOVEL_QUOTA_BYTES': '1024',
    'MUJING_MAX_NOVEL_UPLOAD_BYTES': '512',
    'MUJING_NOVEL_UPLOAD_CONCURRENCY': '2',
    'MUJING_NOVEL_UPLOAD_REQUESTS_PER_MINUTE': '12',
  });
  _expect(config.novelDir == '/novels', 'novel directory is parsed');
  _expect(config.novelQuotaBytes == 1024, 'novel quota is parsed');
  _expect(config.maxNovelUploadBytes == 512, 'upload limit is parsed');
  _expect(config.novelUploadConcurrency == 2, 'concurrency is parsed');
  _expect(config.novelUploadRequestsPerMinute == 12, 'rate is parsed');
  _expect(
    NasConfig.fromEnvironment(const {}).novelQuotaBytes == null,
    'omitted quota is unlimited',
  );
  var rejectedZeroQuota = false;
  try {
    NasConfig.fromEnvironment({'MUJING_NOVEL_QUOTA_BYTES': '0'});
  } on ArgumentError {
    rejectedZeroQuota = true;
  }
  _expect(rejectedZeroQuota, 'zero quota is rejected');
}

void _testMetadata() {
  final metadata = parseNovelMetadata(
    {
      'title': '  A\u030A\u3000书  ',
      'author': '\t ',
      'format': 'TXT',
      'contentState': 'complete_file',
      'relativePath': ' 分类 /第二层 ',
      'sizeBytes': 3,
      'contentSha256': List.filled(64, 'a').join(),
    },
    allowConflictPolicy: true,
    allowKeepBoth: false,
  );
  _expect(metadata.title == 'Å 书', 'title is NFC and whitespace normalized');
  _expect(metadata.author == null, 'empty author becomes null');
  _expect(metadata.relativePath == '分类 /第二层', 'logical path is normalized');
  _expect(
    normalizeNovelText('\uFEFF书名\uFEFF') == '\uFEFF书名\uFEFF',
    'normalization trims only the contract whitespace set',
  );
  _expect(
    postNovelSemanticDigest(metadata) == postNovelSemanticDigest(metadata),
    'semantic digest is deterministic',
  );
  _expect(
    canonicalJson({'z': 1, 'a': '书'}) == '{"a":"书","z":1}',
    'canonical JSON sorts fixed semantic keys',
  );

  var rejectedTraversal = false;
  try {
    normalizeNovelRelativePath('../private');
  } on NasNovelMetadataException {
    rejectedTraversal = true;
  }
  _expect(rejectedTraversal, 'relative path traversal is rejected');
}

Future<void> _testStorageAndRepository() async {
  final temporary = await Directory.systemTemp.createTemp('mujing-novel-test-');
  final contentRoot = Directory(
    '${temporary.path}${Platform.pathSeparator}novels',
  );
  final database = NasLibraryDatabase(
    '${temporary.path}${Platform.pathSeparator}data',
  );
  final storage = NasNovelStorage(
    rootPath: contentRoot.path,
    maxUploadBytes: 1024,
  );
  try {
    await storage.initialize();
    await database.open();
    final repository = database.novels;
    _expect(repository.logicalUsageBytes == 0, 'novel quota starts empty');

    final failedPublication =
        await storage.receiveText(Stream.value(utf8.encode('discarded')));
    await failedPublication.file.delete();
    try {
      await storage.publish(failedPublication);
    } on NasNovelStorageException {
      // The next publication must still run after this expected failure.
    }

    final bytes = utf8.encode('第一章\n正文');
    final received = await storage.receiveText(Stream.value(bytes));
    _expect(received.sizeBytes == bytes.length, 'streamed size is recorded');
    final published = await storage.publish(received);
    _expect(published.created, 'first content publication creates an object');
    await storage.verifyObject(
      received.sha256,
      expectedSizeBytes: bytes.length,
    );

    final metadata = parseNovelMetadata(
      {
        'title': '测试小说',
        'author': null,
        'format': 'txt',
        'contentState': 'complete_file',
        'relativePath': '',
        'sizeBytes': bytes.length,
        'contentSha256': received.sha256,
        'conflictPolicy': 'reject',
      },
      allowConflictPolicy: true,
      allowKeepBoth: false,
    );
    final scope = NasNovelIdempotencyScope(
      deviceId: 'device-a',
      method: 'POST',
      canonicalPath: '/api/v1/novels',
      key: '00000000-0000-4000-8000-000000000001',
    );
    final acquired = repository.acquireIdempotency(
      scope: scope,
      semanticDigest: postNovelSemanticDigest(metadata),
    );
    _expect(
      acquired.decision == NasNovelIdempotencyDecision.acquired,
      'new idempotency key is acquired',
    );
    final created = repository.commitPost(
      scope: scope,
      ownerNonce: acquired.ownerNonce!,
      metadata: metadata,
      quotaBytes: 1024,
    );
    _expect(created.statusCode == 201, 'new novel returns 201');
    _expect(!created.deduplicated, 'new novel is not deduplicated');
    _expect(repository.logicalUsageBytes == bytes.length, 'quota is charged');

    final replay = repository.acquireIdempotency(
      scope: scope,
      semanticDigest: postNovelSemanticDigest(metadata),
    );
    _expect(
      replay.decision == NasNovelIdempotencyDecision.replay &&
          replay.record.httpStatus == 201,
      'completed idempotency result is replayed',
    );

    final expiryScope = NasNovelIdempotencyScope(
      deviceId: 'device-a',
      method: 'POST',
      canonicalPath: '/api/v1/novels',
      key: '00000000-0000-4000-8000-000000000004',
    );
    final expiryStart = DateTime.utc(2026, 1, 1);
    final expiryOwner = repository.acquireIdempotency(
      scope: expiryScope,
      semanticDigest: postNovelSemanticDigest(metadata),
      now: expiryStart,
    );
    repository.commitPost(
      scope: expiryScope,
      ownerNonce: expiryOwner.ownerNonce!,
      metadata: metadata,
      quotaBytes: 1024,
      now: expiryStart,
    );
    final afterExpiry = repository.acquireIdempotency(
      scope: expiryScope,
      semanticDigest: postNovelSemanticDigest(metadata),
      now: expiryStart.add(const Duration(days: 8)),
    );
    _expect(
      afterExpiry.decision == NasNovelIdempotencyDecision.acquired,
      'expired success records do not replay during long server uptime',
    );
    repository.releaseIdempotency(
      scope: expiryScope,
      ownerNonce: afterExpiry.ownerNonce!,
    );

    final secondScope = NasNovelIdempotencyScope(
      deviceId: 'device-a',
      method: 'POST',
      canonicalPath: '/api/v1/novels',
      key: '00000000-0000-4000-8000-000000000002',
    );
    final secondLease = repository.acquireIdempotency(
      scope: secondScope,
      semanticDigest: postNovelSemanticDigest(metadata),
    );
    final duplicate = repository.commitPost(
      scope: secondScope,
      ownerNonce: secondLease.ownerNonce!,
      metadata: metadata,
      quotaBytes: bytes.length,
    );
    _expect(duplicate.statusCode == 200, 'digest dedup returns 200');
    _expect(duplicate.deduplicated, 'digest dedup is reported');
    _expect(
      repository.logicalUsageBytes == bytes.length,
      'digest dedup does not consume quota',
    );
    _expect(
        repository.list().items.length == 1, 'only one logical record exists');

    final leaseScope = NasNovelIdempotencyScope(
      deviceId: 'device-a',
      method: 'POST',
      canonicalPath: '/api/v1/novels',
      key: '00000000-0000-4000-8000-000000000003',
    );
    final leaseStart = DateTime.utc(2026, 1, 1);
    final firstOwner = repository.acquireIdempotency(
      scope: leaseScope,
      semanticDigest: List.filled(64, 'b').join(),
      now: leaseStart,
      leaseDuration: const Duration(seconds: 1),
    );
    final takeover = repository.acquireIdempotency(
      scope: leaseScope,
      semanticDigest: List.filled(64, 'b').join(),
      now: leaseStart.add(const Duration(seconds: 2)),
    );
    _expect(
      takeover.decision == NasNovelIdempotencyDecision.acquired &&
          takeover.ownerNonce != firstOwner.ownerNonce,
      'expired lease is fenced and acquired by a new owner',
    );
    _expect(
      !repository.renewIdempotencyLease(
        scope: leaseScope,
        ownerNonce: firstOwner.ownerNonce!,
      ),
      'old owner cannot renew after takeover',
    );

    var invalidUtf8Rejected = false;
    try {
      await storage.receiveText(Stream.value(const [0xC3, 0x28]));
    } on NasNovelStorageException catch (error) {
      invalidUtf8Rejected = error.code == 'unsupported_novel_format';
    }
    _expect(invalidUtf8Rejected, 'invalid UTF-8 is rejected');

    await storage.objectFile(received.sha256).delete();
    final service = NasNovelService(
      repository: repository,
      storage: storage,
      quotaBytes: null,
      uploadConcurrency: 1,
      uploadRequestsPerMinute: 30,
    );
    await service.initialize();
    _expect(
      repository.find(created.novel.id) == null &&
          repository.find(created.novel.id, includeUnhealthy: true) != null,
      'startup integrity scan hides records whose content is missing',
    );
  } finally {
    await database.close();
    await temporary.delete(recursive: true);
  }
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
