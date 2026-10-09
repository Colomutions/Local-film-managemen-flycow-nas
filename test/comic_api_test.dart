import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('mujing-comic-api-');
  final config = NasConfig(
      bindHost: '127.0.0.1',
      port: 0,
      serverName: 'Comic Test',
      advertiseUrl: null,
      pairingCode: 'test-pairing-code',
      fixtureMediaRelativePath: null,
      mediaRootName: 'test',
      scanOnStart: false,
      dataDir: '${root.path}${Platform.pathSeparator}data',
      mediaDir: '${root.path}${Platform.pathSeparator}media',
      timezone: 'Asia/Shanghai',
      comicDir: '${root.path}${Platform.pathSeparator}comics',
      maxComicUploadBytes: 64 * 1024 * 1024,
      maxComicChunkBytes: 32 * 1024 * 1024);
  final server = NasHealthServer(config);
  try {
    await server.start();
    var base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await send(base, 'GET', '/api/v1/server-info');
    final data = info.json['data'] as Map<String, dynamic>;
    final capabilities = data['capabilities'] as Map<String, dynamic>;
    check(
        capabilities['comics'] == true &&
            capabilities['comicUploadResume'] == true &&
            (capabilities['comicFormats'] as List).contains('pdf'),
        'capabilities');
    final viewer = await pair(base, data['serverId'] as String, 'viewer');
    final admin = await pair(base, data['serverId'] as String, 'admin');
    final archive = Archive()
      ..addFile(ArchiveFile('001.jpg', 4, [255, 216, 255, 217]));
    final zip = ZipEncoder().encode(archive)!;
    final sha = sha256.convert(zip).toString();
    final metadata = {
      'title': '漫画一',
      'author': null,
      'format': 'zip',
      'relativePath': '测试',
      'sizeBytes': zip.length,
      'contentSha256': sha,
      'conflictPolicy': 'reject'
    };
    final created = await upload(base, viewer, metadata, zip, 'application/zip',
        '10000000-0000-4000-8000-000000000001');
    check(created.status == 201, 'ZIP upload: ${created.text}');
    final comic = ((created.json['data'] as Map)['comic'] as Map);
    final id = comic['id'] as String;
    check(
        await File('${config.comicDir}/objects/漫画一.zip')
                .readAsBytes()
                .then((bytes) => sha256.convert(bytes).toString()) ==
            sha,
        'ZIP keeps its readable filename and original bytes');
    final list = await send(base, 'GET', '/api/v1/comics', token: viewer);
    check(((list.json['data'] as Map)['items'] as List).length == 1, 'list');
    final range = await send(base, 'GET', '/api/v1/comics/$id/content',
        token: viewer, headers: {'Range': 'bytes=0-3'});
    check(range.status == 206 && range.bytes.length == 4, 'range');
    final backup =
        await send(base, 'POST', '/api/v1/admin/backups', token: admin);
    check(backup.status == 201, 'backup');
    final backupId = (backup.json['data'] as Map)['id'] as String;
    final manifest = File(
        '${config.dataDir}${Platform.pathSeparator}backups${Platform.pathSeparator}$backupId${Platform.pathSeparator}manifest.json');
    check(
        (jsonDecode(await manifest.readAsString())
                as Map)['comicContentIncluded'] ==
            false,
        'backup excludes comic bytes');
    final pdf = makePdf();
    final pdfSha = sha256.convert(pdf).toString();
    final pdfMeta = {
      'title': 'PDF 漫画',
      'author': '作者',
      'format': 'pdf',
      'relativePath': '',
      'sizeBytes': pdf.length,
      'contentSha256': pdfSha,
      'conflictPolicy': 'reject'
    };
    final session = await send(base, 'POST', '/api/v1/comics/upload-sessions',
        token: viewer,
        jsonBody: pdfMeta,
        headers: {'Idempotency-Key': '10000000-0000-4000-8000-000000000002'});
    check(session.status == 201, 'session: ${session.text}');
    final uploadId = (session.json['data'] as Map)['uploadId'] as String;
    final patch = await send(
        base, 'PATCH', '/api/v1/comics/upload-sessions/$uploadId',
        token: viewer,
        body: pdf,
        headers: {'Content-Range': 'bytes 0-${pdf.length - 1}/${pdf.length}'});
    check(patch.status == 204, 'patch: ${patch.text}');
    final complete = await send(
        base, 'POST', '/api/v1/comics/upload-sessions/$uploadId/complete',
        token: viewer);
    check(complete.status == 201, 'PDF complete: ${complete.text}');
    final pdfId =
        (((complete.json['data'] as Map)['comic'] as Map)['id']) as String;
    final download =
        await send(base, 'GET', '/api/v1/comics/$pdfId/content', token: viewer);
    check(
        download.status == 200 &&
            sha256.convert(download.bytes).toString() == pdfSha,
        'PDF download');
    final random = Random(42);
    final image =
        List<int>.generate(8 * 1024 * 1024 + 1024, (_) => random.nextInt(256));
    final cbz = ZipEncoder().encode(Archive()
      ..addFile(ArchiveFile('chapter/001.jpg', image.length, image)))!;
    final cbzSha = sha256.convert(cbz).toString();
    final cbzMeta = {
      'title': '分片漫画',
      'author': null,
      'format': 'cbz',
      'relativePath': '',
      'sizeBytes': cbz.length,
      'contentSha256': cbzSha
    };
    final cbzSession = await send(
        base, 'POST', '/api/v1/comics/upload-sessions',
        token: viewer,
        jsonBody: cbzMeta,
        headers: {'Idempotency-Key': '10000000-0000-4000-8000-000000000004'});
    check(cbzSession.status == 201, 'CBZ session');
    final cbzUploadId = (cbzSession.json['data'] as Map)['uploadId'] as String;
    const firstChunk = 8 * 1024 * 1024;
    final first = await send(
        base, 'PATCH', '/api/v1/comics/upload-sessions/$cbzUploadId',
        token: viewer,
        body: cbz.sublist(0, firstChunk),
        headers: {'Content-Range': 'bytes 0-${firstChunk - 1}/${cbz.length}'});
    check(first.status == 204, 'first CBZ chunk: ${first.text}');
    await server.stop();
    await server.start();
    base = Uri.parse('http://127.0.0.1:${server.port}');
    final resumed = await send(
        base, 'GET', '/api/v1/comics/upload-sessions/$cbzUploadId',
        token: viewer);
    check(
        resumed.status == 200 &&
            (resumed.json['data'] as Map)['receivedBytes'] == firstChunk,
        'resume offset');
    final second = await send(
        base, 'PATCH', '/api/v1/comics/upload-sessions/$cbzUploadId',
        token: viewer,
        body: cbz.sublist(firstChunk),
        headers: {
          'Content-Range': 'bytes $firstChunk-${cbz.length - 1}/${cbz.length}'
        });
    check(second.status == 204, 'second CBZ chunk: ${second.text}');
    final cbzComplete = await send(
        base, 'POST', '/api/v1/comics/upload-sessions/$cbzUploadId/complete',
        token: viewer);
    check(cbzComplete.status == 201, 'CBZ complete: ${cbzComplete.text}');
    final completedSession = await send(
        base, 'GET', '/api/v1/comics/upload-sessions/$cbzUploadId',
        token: viewer);
    check(
        completedSession.status == 200 &&
            (completedSession.json['data'] as Map)['comic'] != null,
        'completed session exposes comic result');
    final replayComplete = await send(
        base, 'POST', '/api/v1/comics/upload-sessions/$cbzUploadId/complete',
        token: viewer);
    check(replayComplete.status == 201, 'complete replay');
    final replayCreate = await send(
        base, 'POST', '/api/v1/comics/upload-sessions',
        token: viewer,
        jsonBody: cbzMeta,
        headers: {'Idempotency-Key': '10000000-0000-4000-8000-000000000004'});
    check(
        replayCreate.status == 201 &&
            (replayCreate.json['data'] as Map)['comic'] != null,
        'session creation replays completed result');
    final revisedPdf = [...pdf, 10];
    final revisedMeta = {
      ...pdfMeta,
      'sizeBytes': revisedPdf.length,
      'contentSha256': sha256.convert(revisedPdf).toString()
    }..remove('conflictPolicy');
    final replaced = await upload(base, admin, revisedMeta, revisedPdf,
        'application/pdf', '10000000-0000-4000-8000-000000000003',
        method: 'PUT',
        path: '/api/v1/admin/comics/$pdfId',
        ifMatch: '"comic:$pdfId:r1"');
    check(replaced.status == 200, 'admin replace: ${replaced.text}');
    check(
        !await File(
                '${config.comicDir}${Platform.pathSeparator}objects${Platform.pathSeparator}PDF 漫画.pdf')
            .exists(),
        'replaced unreferenced PDF object is reclaimed');
    final conflictZip = ZipEncoder().encode(
        Archive()..addFile(ArchiveFile('002.jpg', 4, [255, 216, 1, 217])))!;
    final conflictMeta = {
      'title': '漫画一',
      'author': null,
      'format': 'zip',
      'relativePath': '',
      'sizeBytes': conflictZip.length,
      'contentSha256': sha256.convert(conflictZip).toString()
    };
    final conflictSession = await send(
        base, 'POST', '/api/v1/comics/upload-sessions',
        token: viewer,
        jsonBody: conflictMeta,
        headers: {'Idempotency-Key': '10000000-0000-4000-8000-000000000005'});
    check(conflictSession.status == 201, 'conflict session');
    final conflictId =
        (conflictSession.json['data'] as Map)['uploadId'] as String;
    final conflictPatch = await send(
        base, 'PATCH', '/api/v1/comics/upload-sessions/$conflictId',
        token: viewer,
        body: conflictZip,
        headers: {
          'Content-Range':
              'bytes 0-${conflictZip.length - 1}/${conflictZip.length}'
        });
    check(conflictPatch.status == 204, 'conflict patch');
    final conflict = await send(
        base, 'POST', '/api/v1/comics/upload-sessions/$conflictId/complete',
        token: viewer);
    check(
        conflict.status == 409 &&
            (conflict.json['error'] as Map)['code'] == 'comic_name_conflict',
        'name conflict keeps session');
    final deleted = await send(base, 'DELETE', '/api/v1/admin/comics/$id',
        token: admin, headers: {'If-Match': '"comic:$id:r1"'});
    check(deleted.status == 204, 'admin delete');
    check(
        !await File(
                '${config.comicDir}${Platform.pathSeparator}objects${Platform.pathSeparator}漫画一.zip')
            .exists(),
        'deleted unreferenced ZIP object is reclaimed');
    final retry = await send(
        base, 'POST', '/api/v1/comics/upload-sessions/$conflictId/complete',
        token: viewer);
    check(retry.status == 201,
        'complete succeeds after resolving conflict: ${retry.text}');
    final sameName = await upload(
        base,
        viewer,
        {...metadata, 'conflictPolicy': 'keep_both'},
        zip,
        'application/zip',
        '10000000-0000-4000-8000-000000000006');
    check(sameName.status == 201, 'viewer keeps both on a complete upload');
    final secondComic = (sameName.json['data'] as Map)['comic'] as Map;
    final firstComic = (retry.json['data'] as Map)['comic'] as Map;
    check(
        secondComic['title'] == firstComic['title'] &&
            secondComic['fileName'] == firstComic['fileName'],
        'display names do not expose collision suffixes');
    final thirdZip = ZipEncoder().encode(
        Archive()..addFile(ArchiveFile('003.jpg', 4, [255, 216, 2, 217])))!;
    final thirdSha = sha256.convert(thirdZip).toString();
    final sameNameSession = await send(
        base, 'POST', '/api/v1/comics/upload-sessions',
        token: viewer,
        jsonBody: {
          ...metadata,
          'conflictPolicy': 'keep_both',
          'sizeBytes': thirdZip.length,
          'contentSha256': thirdSha
        },
        headers: {
          'Idempotency-Key': '10000000-0000-4000-8000-000000000007'
        });
    check(sameNameSession.status == 201, 'viewer creates same-name session');
    final sameNameUploadId = (sameNameSession.json['data'] as Map)['uploadId'];
    final thirdPatch = await send(
        base, 'PATCH', '/api/v1/comics/upload-sessions/$sameNameUploadId',
        token: viewer,
        body: thirdZip,
        headers: {
          'Content-Range': 'bytes 0-${thirdZip.length - 1}/${thirdZip.length}'
        });
    check(thirdPatch.status == 204, 'same-name session patch');
    final thirdComplete = await send(base, 'POST',
        '/api/v1/comics/upload-sessions/$sameNameUploadId/complete',
        token: viewer);
    check(thirdComplete.status == 201, 'same-name session completes');
    final thirdId = ((thirdComplete.json['data'] as Map)['comic'] as Map)['id'];
    for (final entry in {
      '漫画一.zip': sha,
      '漫画一-1.zip': sha256.convert(conflictZip).toString(),
      '漫画一-2.zip': thirdSha
    }.entries) {
      check(
          sha256
                  .convert(await File('${config.comicDir}/objects/${entry.key}')
                      .readAsBytes())
                  .toString() ==
              entry.value,
          'collision preserves bytes: ${entry.key}');
    }
    final thirdReplay = await send(base, 'POST',
        '/api/v1/comics/upload-sessions/$sameNameUploadId/complete',
        token: viewer);
    check(thirdReplay.text == thirdComplete.text,
        'completion retry preserves the same record');
    await server.restoreBackup(backupId);
    final restored =
        await send(base, 'GET', '/api/v1/comics/$pdfId', token: viewer);
    check(restored.status == 200, 'comic remains after old backup restoration');
    final notResurrected =
        await send(base, 'GET', '/api/v1/comics/$id', token: viewer);
    check(notResurrected.status == 404,
        'deleted comic stays deleted after restore');
    await server.stop();
    await Directory(config.dataDir).delete(recursive: true);
    await server.start();
    base = Uri.parse('http://127.0.0.1:${server.port}');
    final newInfo = await send(base, 'GET', '/api/v1/server-info');
    final newViewer = await pair(
        base, (newInfo.json['data'] as Map)['serverId'] as String, 'viewer');
    final afterDataLoss =
        await send(base, 'GET', '/api/v1/comics/$pdfId', token: newViewer);
    check(afterDataLoss.status == 200, 'comic catalog survives /data loss');
    final namedDownload = await send(
        base, 'GET', '/api/v1/comics/$thirdId/content',
        token: newViewer);
    check(
        namedDownload.status == 200 &&
            sha256.convert(namedDownload.bytes).toString() == thirdSha,
        'named object mapping survives restart, system restore and /data loss');
    final deletedAfterDataLoss =
        await send(base, 'GET', '/api/v1/comics/$id', token: newViewer);
    check(deletedAfterDataLoss.status == 404,
        'deletion tombstone survives /data loss');
    final newAdmin = await pair(
        base, (newInfo.json['data'] as Map)['serverId'] as String, 'admin');
    final damaged = File(
        '${config.comicDir}${Platform.pathSeparator}objects${Platform.pathSeparator}PDF 漫画-1.pdf');
    await damaged.writeAsBytes([1], flush: true);
    final badDownload = await send(base, 'GET', '/api/v1/comics/$pdfId/content',
        token: newViewer);
    check(badDownload.status == 503, 'damaged file refuses download');
    final hidden =
        await send(base, 'GET', '/api/v1/comics/$pdfId', token: newViewer);
    check(hidden.status == 404, 'damaged file is hidden from viewer');
    final adminDetail =
        await send(base, 'GET', '/api/v1/admin/comics/$pdfId', token: newAdmin);
    check(
        adminDetail.status == 200 &&
            (adminDetail.json['data'] as Map)['storageState'] == 'corrupt',
        'admin can inspect damaged comic');
    print('comic_api_test: PASS');
  } finally {
    await server.stop();
    await root.delete(recursive: true);
  }
}

List<int> makePdf() {
  final result = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  void object(int id, String text) {
    offsets.add(utf8.encode(result.toString()).length);
    result.write('$id 0 obj\n$text\nendobj\n');
  }

  object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  object(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  object(3,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R >>');
  object(4, '<< /Length 0 >>\nstream\n\nendstream');
  final start = utf8.encode(result.toString()).length;
  result.write('xref\n0 5\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    result.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  result
      .write('trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n$start\n%%EOF\n');
  return utf8.encode(result.toString());
}

Future<String> pair(Uri base, String serverId, String scope) async {
  final session = await send(base, 'POST', '/api/v1/pairing/sessions',
      jsonBody: {'serverId': serverId, 'requestedScope': scope});
  final id = (session.json['data'] as Map)['pairingSessionId'];
  final confirmed = await send(
      base, 'POST', '/api/v1/pairing/sessions/$id/confirm',
      jsonBody: {'pairingPassword': 'test-pairing-code'});
  return (confirmed.json['data'] as Map)['accessToken'] as String;
}

Future<Response> upload(Uri base, String token, Map<String, Object?> metadata,
    List<int> bytes, String mime, String key,
    {String method = 'POST',
    String path = '/api/v1/comics',
    String? ifMatch}) async {
  const boundary = 'mujing-comic-test';
  final body = <int>[]
    ..addAll(utf8.encode(
        '--$boundary\r\nContent-Disposition: form-data; name="metadata"\r\nContent-Type: application/json; charset=utf-8\r\n\r\n'))
    ..addAll(utf8.encode(jsonEncode(metadata)))
    ..addAll(utf8.encode(
        '\r\n--$boundary\r\nContent-Disposition: form-data; name="file"; filename="comic.zip"\r\nContent-Type: $mime\r\n\r\n'))
    ..addAll(bytes)
    ..addAll(utf8.encode('\r\n--$boundary--\r\n'));
  return send(base, method, path, token: token, body: body, headers: {
    'Content-Type': 'multipart/form-data; boundary=$boundary',
    'Idempotency-Key': key,
    if (ifMatch != null) 'If-Match': ifMatch
  });
}

Future<Response> send(Uri base, String method, String path,
    {String? token,
    Map<String, Object?>? jsonBody,
    List<int>? body,
    Map<String, String> headers = const {}}) async {
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
    } else if (body != null) {
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close();
    final bytes =
        await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    return Response(response.statusCode, bytes);
  } finally {
    client.close(force: true);
  }
}

class Response {
  const Response(this.status, this.bytes);
  final int status;
  final List<int> bytes;
  String get text => utf8.decode(bytes);
  Map<String, dynamic> get json => jsonDecode(text) as Map<String, dynamic>;
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}
