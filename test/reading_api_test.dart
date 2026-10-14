import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import '../lib/mujing_nas.dart';
import '../lib/src/reading_content.dart';
import 'comic_api_test.dart' as fixture;

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('nas-reading-');
  final config = NasConfig(
      bindHost: '127.0.0.1',
      port: 0,
      serverName: 'Reading Test',
      advertiseUrl: null,
      pairingCode: 'test-pairing-code',
      fixtureMediaRelativePath: null,
      mediaRootName: 'test',
      scanOnStart: false,
      timezone: 'Asia/Shanghai',
      dataDir: '${root.path}/data',
      mediaDir: '${root.path}/media',
      novelDir: '${root.path}/novels',
      comicDir: '${root.path}/comics',
      maxComicUploadBytes: 64 * 1024 * 1024,
      maxComicChunkBytes: 32 * 1024 * 1024);
  final server = NasHealthServer(config);
  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = (await fixture.send(base, 'GET', '/api/v1/server-info'))
        .json['data'] as Map;
    fixture.check(
        (info['capabilities'] as Map)['comicReading'] == true &&
            (info['capabilities'] as Map)['novelReading'] == true,
        'reading capabilities');
    final viewer =
        await fixture.pair(base, info['serverId'] as String, 'viewer');
    final admin = await fixture.pair(base, info['serverId'] as String, 'admin');
    const cover =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2ioAAAAASUVORK5CYII=';
    final png = base64Decode(cover);
    final zip = ZipEncoder().encode(Archive()
      ..addFile(ArchiveFile('章/10.png', png.length, png))
      ..addFile(ArchiveFile('章/2.png', png.length, png)))!;
    final comicMeta = <String, Object?>{
      'title': '漫画',
      'author': '作者',
      'format': 'cbz',
      'relativePath': '',
      'sizeBytes': zip.length,
      'contentSha256': sha256.convert(zip).toString(),
      'coverBase64': cover
    };
    final created = await fixture.upload(base, viewer, comicMeta, zip,
        'application/zip', '10000000-0000-4000-8000-000000000001');
    fixture.check(created.status == 201, 'comic upload ${created.text}');
    final comic = (created.json['data'] as Map)['comic'] as Map;
    final id = comic['id'];
    await ReadingContent()
        .index(File('${config.comicDir}/objects/漫画.cbz'), 'zip-direct', 'cbz');
    fixture.check(comic['canRead'] == true && comic['coverUrl'] != null,
        'comic reading metadata');
    final directory = await fixture
        .send(base, 'GET', '/api/v1/comics/$id/reading?r=1', token: viewer);
    final pages = (directory.json['data'] as Map)['pages'] as List;
    fixture.check(
        pages.length == 2 &&
            (pages.first as Map)['title'] == '2.png' &&
            !(pages.first as Map).containsKey('entry'),
        'natural page order without internal locator');
    final page = await fixture
        .send(base, 'GET', '/api/v1/comics/$id/pages/1?r=1', token: viewer);
    fixture.check(base64Encode(page.bytes) == cover, 'single ZIP page');
    final artwork = await fixture.send(base, 'GET', comic['coverUrl'] as String,
        token: viewer);
    fixture.check(
        base64Encode(artwork.bytes) == cover, 'comic cover round trip');
    fixture.check(
        (await fixture.send(base, 'GET', '/api/v1/comics/$id/pages/0'))
                .status ==
            401,
        'page requires authentication');
    fixture.check(
        (await fixture.send(base, 'GET', '/api/v1/comics/$id/reading?r=99',
                    token: viewer))
                .status ==
            412,
        'revision conflict');
    fixture.check(
        (await fixture.send(base, 'GET', '/api/v1/comics/$id/pages/2',
                    token: viewer))
                .status ==
            400,
        'page bounds');
    fixture.check(
        (await fixture.send(base, 'DELETE', '/api/v1/admin/comics/$id',
                    token: viewer, headers: {'If-Match': '"comic:$id:r1"'}))
                .status ==
            403,
        'viewer cannot delete');

    final pdf = fixture.makePdf();
    final uploadedPdf = await fixture.upload(
        base,
        viewer,
        {
          'title': 'PDF',
          'format': 'pdf',
          'relativePath': '',
          'sizeBytes': pdf.length,
          'contentSha256': sha256.convert(pdf).toString()
        },
        pdf,
        'application/pdf',
        '10000000-0000-4000-8000-000000000002');
    fixture.check(uploadedPdf.status == 201, 'PDF uploaded');
    final pdfId = ((uploadedPdf.json['data'] as Map)['comic'] as Map)['id'];
    final pdfPage = await fixture
        .send(base, 'GET', '/api/v1/comics/$pdfId/pages/0?r=1', token: viewer);
    fixture.check(
        pdfPage.status == 200 &&
            pdfPage.bytes.take(8).join(',') == '137,80,78,71,13,10,26,10',
        'PDF rendered one page');

    final text = utf8.encode('\uFEFF第一章 开始\r\n正文一\r\n第二章 结束\r\n正文二');
    final novelMeta = <String, Object?>{
      'title': '小说',
      'author': '小说作者',
      'format': 'txt',
      'contentState': 'complete_file',
      'relativePath': '',
      'sizeBytes': text.length,
      'contentSha256': sha256.convert(text).toString(),
      'coverBase64': cover
    };
    final uploadedNovel = await fixture.upload(base, viewer, novelMeta, text,
        'text/plain; charset=utf-8', '10000000-0000-4000-8000-000000000003',
        path: '/api/v1/novels');
    fixture.check(
        uploadedNovel.status == 201, 'novel uploaded ${uploadedNovel.text}');
    final novel = (uploadedNovel.json['data'] as Map)['novel'] as Map;
    final novelId = novel['id'];
    final toc = await fixture.send(
        base, 'GET', '/api/v1/novels/$novelId/reading?r=1',
        token: viewer);
    fixture.check(((toc.json['data'] as Map)['chapters'] as List).length == 2,
        'TXT chapter directory');
    final chapter = await fixture.send(
        base, 'GET', '/api/v1/novels/$novelId/chapters/1?r=1',
        token: viewer);
    fixture.check((chapter.json['data'] as Map)['body'] == '第二章 结束\r\n正文二',
        'reads only requested chapter');
    final novelCover = await fixture
        .send(base, 'GET', novel['coverUrl'] as String, token: viewer);
    fixture.check(
        base64Encode(novelCover.bytes) == cover, 'novel cover round trip');
    fixture.check(
        (await fixture.send(base, 'GET', '/api/v1/novels/$novelId/chapters/0'))
                .status ==
            401,
        'chapter requires authentication');
    fixture.check(
        (await fixture.send(base, 'GET', '/api/v1/novels/$novelId/reading?r=99',
                    token: viewer))
                .status ==
            412,
        'novel revision conflict');
    final deleted = await fixture.send(
        base, 'DELETE', '/api/v1/admin/comics/$id',
        token: admin, headers: {'If-Match': '"comic:$id:r1"'});
    fixture.check(deleted.status == 204, 'admin delete');
    fixture.check(
        (await fixture.send(base, 'GET', '/api/v1/comics/$id/pages/0',
                    token: viewer))
                .status ==
            404,
        'deleted comic unavailable');
    fixture.check(!await File('${config.comicDir}/objects/漫画.cbz').exists(),
        'deleted content removed');

    final longText = List.filled(180000, '汉').join();
    final longFile =
        await File('${root.path}/long.txt').writeAsString(longText);
    final reader = ReadingContent();
    final longIndex = await reader.index(longFile, 'long', 'txt');
    fixture.check(
        longIndex.length >= 2, 'long lines split into bounded chapters');
    final restored = StringBuffer();
    for (final section in longIndex) {
      restored.write(await reader.chapter(longFile, section));
    }
    fixture.check(restored.toString() == longText,
        'UTF-8 split preserves all characters');
    print('reading_api_test: PASS');
  } finally {
    await server.stop();
    await root.delete(recursive: true);
  }
}
