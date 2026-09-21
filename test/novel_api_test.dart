import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final temporary = await Directory.systemTemp.createTemp('mujing-novel-api-');
  final config = NasConfig(
    bindHost: '127.0.0.1',
    port: 0,
    serverName: 'Novel API Test',
    advertiseUrl: null,
    pairingCode: 'test-pairing-code',
    fixtureMediaRelativePath: null,
    mediaRootName: 'test',
    scanOnStart: false,
    dataDir: '${temporary.path}${Platform.pathSeparator}data',
    mediaDir: '${temporary.path}${Platform.pathSeparator}media',
    timezone: 'Asia/Shanghai',
    novelDir: '${temporary.path}${Platform.pathSeparator}novels',
    novelQuotaBytes: 1024 * 1024,
    maxNovelUploadBytes: 1024 * 1024,
    novelUploadConcurrency: 2,
    novelUploadRequestsPerMinute: 100,
  );
  final server = NasHealthServer(config);
  try {
    await _testDisabledCapabilities(temporary);
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await _request(base, 'GET', '/api/v1/server-info');
    final infoData = info.json['data'] as Map<String, dynamic>;
    final capabilities = infoData['capabilities'] as Map<String, dynamic>;
    _expect(capabilities['novels'] == true, 'ready server declares novels');
    _expect(
        capabilities['novelUpload'] == true, 'ready server declares upload');
    _expect(capabilities['novelProgress'] == false, 'progress stays disabled');
    _expect(
      capabilities['novelUploadResume'] == false,
      'resumable upload stays disabled',
    );
    _expect(
      capabilities['maxNovelUploadBytes'] == config.maxNovelUploadBytes,
      'server declares upload limit',
    );
    final serverId = infoData['serverId'] as String;
    final viewer = await _pair(base, serverId, scope: 'viewer');
    final admin = await _pair(base, serverId, scope: 'admin');

    final content = utf8.encode('第一章\n这是正文。\n第二章\n结束。');
    final sha = _sha256ForTest(content);
    final metadata = <String, Object?>{
      'title': '接口测试小说',
      'author': '测试作者',
      'format': 'txt',
      'contentState': 'complete_file',
      'relativePath': '测试',
      'sizeBytes': content.length,
      'contentSha256': sha,
      'conflictPolicy': 'reject',
    };
    const firstKey = '10000000-0000-4000-8000-000000000001';
    final created = await _upload(
      base,
      '/api/v1/novels',
      token: viewer.token,
      idempotencyKey: firstKey,
      metadata: metadata,
      content: content,
    );
    _expect(created.statusCode == 201, 'POST creates a novel');
    final createdNovel = (created.json['data'] as Map<String, dynamic>)['novel']
        as Map<String, dynamic>;
    final novelId = createdNovel['id'] as String;
    _expect(createdNovel['coverUrl'] == null, 'cover remains null');
    _expect(
      created.headers['x-mujing-trace-id']?.isNotEmpty == true &&
          created.headers['x-mujing-request-id']?.isNotEmpty == true,
      'responses contain trace and request IDs',
    );

    final replay = await _upload(
      base,
      '/api/v1/novels',
      token: viewer.token,
      idempotencyKey: firstKey,
      metadata: metadata,
      content: content,
    );
    _expect(replay.statusCode == 201, 'idempotent replay preserves 201');
    _expect(replay.text == created.text, 'idempotent replay preserves body');

    final duplicate = await _upload(
      base,
      '/api/v1/novels',
      token: viewer.token,
      idempotencyKey: '10000000-0000-4000-8000-000000000002',
      metadata: metadata,
      content: content,
    );
    _expect(duplicate.statusCode == 200, 'content dedup returns 200');
    _expect(
      (duplicate.json['data'] as Map<String, dynamic>)['deduplicated'] == true,
      'content dedup is explicit',
    );

    final unknownMetadata = Map<String, Object?>.from(metadata)
      ..['sourceBookUrl'] = 'https://example.invalid/private?token=secret';
    final unknownField = await _upload(
      base,
      '/api/v1/novels',
      token: viewer.token,
      idempotencyKey: '10000000-0000-4000-8000-000000000006',
      metadata: unknownMetadata,
      content: content,
    );
    _expectError(unknownField, 400, 'invalid_metadata');

    final cover = await _upload(
      base,
      '/api/v1/novels',
      token: viewer.token,
      idempotencyKey: '10000000-0000-4000-8000-000000000007',
      metadata: metadata,
      content: content,
      includeCover: true,
    );
    _expectError(cover, 400, 'unsupported_cover');

    final quotaContent = List<int>.filled(config.novelQuotaBytes!, 0x61);
    final quotaMetadata = <String, Object?>{
      'title': '配额边界测试',
      'author': null,
      'format': 'txt',
      'contentState': 'complete_file',
      'relativePath': '',
      'sizeBytes': quotaContent.length,
      'contentSha256': _sha256ForTest(quotaContent),
      'conflictPolicy': 'reject',
    };
    final quota = await _upload(
      base,
      '/api/v1/novels',
      token: viewer.token,
      idempotencyKey: '10000000-0000-4000-8000-000000000008',
      metadata: quotaMetadata,
      content: quotaContent,
    );
    _expectError(quota, 403, 'quota_exceeded');
    final quotaError = quota.json['error'] as Map<String, dynamic>;
    final quotaDetails = quotaError['details'] as Map<String, dynamic>;
    _expect(
      quotaDetails['scope'] == 'global' &&
          quotaDetails['limitBytes'] == config.novelQuotaBytes &&
          quotaDetails['remainingBytes'] ==
              config.novelQuotaBytes! - content.length,
      'quota errors expose the contracted global details',
    );

    final list = await _request(
      base,
      'GET',
      '/api/v1/novels?page=1&pageSize=30&sort=updatedAt&order=desc',
      token: viewer.token,
    );
    _expect(list.statusCode == 200, 'novel list succeeds');
    final items =
        ((list.json['data'] as Map<String, dynamic>)['items'] as List);
    _expect(items.length == 1, 'dedup creates one logical record');

    final detail = await _request(
      base,
      'GET',
      '/api/v1/novels/$novelId',
      token: viewer.token,
    );
    _expect(detail.statusCode == 200, 'novel detail succeeds');
    final etag = detail.headers[HttpHeaders.etagHeader]!;
    _expect(
        etag == '"novel:$novelId:r1"', 'detail returns strong revision ETag');

    final range = await _request(
      base,
      'GET',
      '/api/v1/novels/$novelId/content',
      token: viewer.token,
      headers: {HttpHeaders.rangeHeader: 'bytes=0-5'},
    );
    _expect(range.statusCode == 206 && range.bytes.length == 6,
        'Range returns 206');
    _expect(
      range.headers[HttpHeaders.etagHeader] == '"sha256:$sha"',
      'content uses SHA-256 ETag',
    );

    final head = await _request(
      base,
      'HEAD',
      '/api/v1/novels/$novelId/content',
      token: viewer.token,
    );
    _expect(head.statusCode == 200 && head.bytes.isEmpty, 'HEAD has no body');
    _expect(
      head.headers[HttpHeaders.contentLengthHeader] ==
          content.length.toString(),
      'HEAD preserves content length',
    );

    final invalidRange = await _request(
      base,
      'GET',
      '/api/v1/novels/$novelId/content',
      token: viewer.token,
      headers: {HttpHeaders.rangeHeader: 'bytes=999999-'},
    );
    _expect(invalidRange.statusCode == 416, 'unsatisfiable Range returns 416');
    _expect(invalidRange.bytes.isEmpty, '416 body is empty');

    final backup = await _request(
      base,
      'POST',
      '/api/v1/admin/backups',
      token: admin.token,
    );
    _expect(backup.statusCode == 201, 'backup with novel content succeeds');
    final backupId =
        (backup.json['data'] as Map<String, dynamic>)['id'] as String;
    final backupRoot = Directory(
      '${config.dataDir}${Platform.pathSeparator}backups'
      '${Platform.pathSeparator}$backupId',
    );
    final backupObject = File(
      '${backupRoot.path}${Platform.pathSeparator}novels'
      '${Platform.pathSeparator}objects${Platform.pathSeparator}$sha',
    );
    _expect(await backupObject.exists(),
        'backup is self-contained with TXT content');
    final manifest = jsonDecode(
      await File('${backupRoot.path}${Platform.pathSeparator}manifest.json')
          .readAsString(),
    ) as Map<String, dynamic>;
    _expect(
      ((manifest['novels'] as Map<String, dynamic>)['items'] as List).length ==
          1,
      'backup manifest contains the logical novel',
    );
    final restoreTarget = Directory(
      '${temporary.path}${Platform.pathSeparator}isolated-restore',
    );
    await NasBackupRecoveryHarness(NasBackupService(config.dataDir)).restore(
      backupId: backupId,
      target: restoreTarget,
    );
    _expect(
      await File(
        '${restoreTarget.path}${Platform.pathSeparator}novels'
        '${Platform.pathSeparator}objects${Platform.pathSeparator}$sha',
      ).exists(),
      'isolated restore retains validated novel content',
    );

    final noChange = await _upload(
      base,
      '/api/v1/admin/novels/$novelId',
      method: 'PUT',
      token: admin.token,
      idempotencyKey: '10000000-0000-4000-8000-000000000003',
      ifMatch: etag,
      metadata: Map<String, Object?>.from(metadata)..remove('conflictPolicy'),
      content: content,
    );
    _expect(noChange.statusCode == 200, 'no-op PUT succeeds');
    _expect(
      (noChange.json['data'] as Map<String, dynamic>)['changed'] == false,
      'no-op PUT reports changed=false',
    );
    _expect(
      noChange.headers[HttpHeaders.etagHeader] == etag,
      'no-op PUT preserves revision',
    );

    final replacementContent = utf8.encode('替换后的完整正文');
    final replacementMetadata = <String, Object?>{
      'title': '接口测试小说（修订）',
      'author': null,
      'format': 'txt',
      'contentState': 'complete_file',
      'relativePath': '测试',
      'sizeBytes': replacementContent.length,
      'contentSha256': _sha256ForTest(replacementContent),
    };
    final replaced = await _upload(
      base,
      '/api/v1/admin/novels/$novelId',
      method: 'PUT',
      token: admin.token,
      idempotencyKey: '10000000-0000-4000-8000-000000000004',
      ifMatch: etag,
      metadata: replacementMetadata,
      content: replacementContent,
    );
    _expect(replaced.statusCode == 200, 'PUT replaces a novel');
    _expect(
      (replaced.json['data'] as Map<String, dynamic>)['changed'] == true,
      'replacement reports changed=true',
    );
    final replacementEtag = replaced.headers[HttpHeaders.etagHeader]!;
    _expect(
        replacementEtag.endsWith(':r2"'), 'replacement increments revision');

    final staleReplace = await _upload(
      base,
      '/api/v1/admin/novels/$novelId',
      method: 'PUT',
      token: admin.token,
      idempotencyKey: '10000000-0000-4000-8000-000000000005',
      ifMatch: etag,
      metadata: replacementMetadata,
      content: replacementContent,
    );
    _expectError(staleReplace, 412, 'novel_revision_conflict');

    final viewerDelete = await _request(
      base,
      'DELETE',
      '/api/v1/admin/novels/$novelId',
      token: viewer.token,
      headers: {HttpHeaders.ifMatchHeader: replacementEtag},
    );
    _expectError(viewerDelete, 403, 'insufficient_scope');
    final deleted = await _request(
      base,
      'DELETE',
      '/api/v1/admin/novels/$novelId',
      token: admin.token,
      headers: {HttpHeaders.ifMatchHeader: replacementEtag},
    );
    _expect(deleted.statusCode == 204, 'admin DELETE succeeds');

    final goneReplay = await _upload(
      base,
      '/api/v1/novels',
      token: viewer.token,
      idempotencyKey: firstKey,
      metadata: metadata,
      content: content,
    );
    _expectError(goneReplay, 410, 'idempotency_result_gone');

    await server.restoreBackup(backupId);
    final restoredDetail = await _request(
      base,
      'GET',
      '/api/v1/novels/$novelId',
      token: admin.token,
    );
    _expect(
        restoredDetail.statusCode == 200, 'activated backup restores novel');
    _expect(
      restoredDetail.headers[HttpHeaders.etagHeader] == etag,
      'activated backup restores original revision',
    );
    final restoredContent = await _request(
      base,
      'GET',
      '/api/v1/novels/$novelId/content',
      token: admin.token,
    );
    _expect(
      restoredContent.bytes.toString() == content.toString(),
      'activated backup restores original TXT content',
    );
  } finally {
    await server.stop();
    await temporary.delete(recursive: true);
  }
}

String _sha256ForTest(List<int> bytes) {
  return sha256.convert(bytes).toString();
}

Future<_PairedDevice> _pair(Uri base, String serverId,
    {required String scope}) async {
  final session = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions',
    jsonBody: {'serverId': serverId, 'requestedScope': scope},
  );
  final id = (session.json['data'] as Map<String, dynamic>)['pairingSessionId']
      as String;
  final confirmed = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions/$id/confirm',
    jsonBody: {'pairingPassword': 'test-pairing-code'},
  );
  final data = confirmed.json['data'] as Map<String, dynamic>;
  return _PairedDevice(token: data['accessToken'] as String);
}

Future<void> _testDisabledCapabilities(Directory root) async {
  final server = NasHealthServer(
    NasConfig(
      bindHost: '127.0.0.1',
      port: 0,
      serverName: 'Novel Disabled Test',
      advertiseUrl: null,
      pairingCode: 'test-pairing-code',
      fixtureMediaRelativePath: null,
      mediaRootName: 'test',
      scanOnStart: false,
      dataDir: '${root.path}${Platform.pathSeparator}disabled-data',
      mediaDir: '${root.path}${Platform.pathSeparator}disabled-media',
      timezone: 'Asia/Shanghai',
    ),
  );
  try {
    await server.start();
    final response = await _request(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'GET',
      '/api/v1/server-info',
    );
    final data = response.json['data'] as Map<String, dynamic>;
    final capabilities = data['capabilities'] as Map<String, dynamic>;
    final status = data['capabilityStatus'] as Map<String, dynamic>;
    _expect(
      capabilities['novels'] == false &&
          capabilities['novelUpload'] == false &&
          !capabilities.containsKey('maxNovelUploadBytes') &&
          status['novels'] == 'storage_not_configured',
      'server-info keeps novel capabilities disabled without storage',
    );
  } finally {
    await server.stop();
  }
}

Future<_Response> _upload(
  Uri base,
  String path, {
  String method = 'POST',
  required String token,
  required String idempotencyKey,
  required Map<String, Object?> metadata,
  required List<int> content,
  String? ifMatch,
  bool includeCover = false,
}) async {
  const boundary = 'mujing-novel-test-boundary';
  final body = <int>[]
    ..addAll(utf8.encode('--$boundary\r\n'))
    ..addAll(utf8.encode(
      'Content-Disposition: form-data; name="metadata"\r\n'
      'Content-Type: application/json; charset=utf-8\r\n\r\n',
    ))
    ..addAll(utf8.encode(jsonEncode(metadata)))
    ..addAll(utf8.encode('\r\n--$boundary\r\n'))
    ..addAll(utf8.encode(
      'Content-Disposition: form-data; name="file"; filename="book.txt"\r\n'
      'Content-Type: text/plain; charset=utf-8\r\n\r\n',
    ))
    ..addAll(content);
  if (includeCover) {
    body
      ..addAll(utf8.encode('\r\n--$boundary\r\n'))
      ..addAll(utf8.encode(
        'Content-Disposition: form-data; name="cover"; filename="cover.jpg"\r\n'
        'Content-Type: image/jpeg\r\n\r\n',
      ))
      ..addAll(const [0xFF, 0xD8, 0xFF]);
  }
  body.addAll(utf8.encode('\r\n--$boundary--\r\n'));
  return _request(
    base,
    method,
    path,
    token: token,
    rawBody: body,
    headers: {
      HttpHeaders.contentTypeHeader: 'multipart/form-data; boundary=$boundary',
      'idempotency-key': idempotencyKey,
      if (ifMatch != null) HttpHeaders.ifMatchHeader: ifMatch,
    },
  );
}

Future<_Response> _request(
  Uri base,
  String method,
  String path, {
  String? token,
  Map<String, Object?>? jsonBody,
  List<int>? rawBody,
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, base.resolve(path));
    if (token != null)
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (jsonBody != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(jsonBody)));
    } else if (rawBody != null) {
      request.contentLength = rawBody.length;
      request.add(rawBody);
    }
    final response = await request.close();
    final bytes = await response
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    final responseHeaders = <String, String>{};
    response.headers.forEach((name, values) {
      responseHeaders[name] = values.join(',');
    });
    return _Response(
      statusCode: response.statusCode,
      bytes: bytes,
      headers: responseHeaders,
    );
  } finally {
    client.close(force: true);
  }
}

void _expectError(_Response response, int status, String code) {
  _expect(response.statusCode == status, '$code uses HTTP $status');
  _expect(
    (response.json['error'] as Map<String, dynamic>)['code'] == code,
    '$code uses its error code',
  );
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class _PairedDevice {
  const _PairedDevice({required this.token});
  final String token;
}

class _Response {
  const _Response({
    required this.statusCode,
    required this.bytes,
    required this.headers,
  });

  final int statusCode;
  final List<int> bytes;
  final Map<String, String> headers;
  String get text => utf8.decode(bytes);
  Map<String, dynamic> get json => jsonDecode(text) as Map<String, dynamic>;
}
