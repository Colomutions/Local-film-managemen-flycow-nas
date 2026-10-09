import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/src/content_file_names.dart';
import '../lib/src/novels/novel_storage.dart';

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('readable-content-');
  var database = sqlite3.open('${root.path}/index.sqlite');
  try {
    ContentFileNames.createSchema(database);
    final storage = NasNovelStorage(rootPath: root.path, maxUploadBytes: 1024)
      ..fileNames = ContentFileNames(database);
    await storage.initialize();
    final contents = await Future.wait([
      for (final text in ['第一本', '第二本', '第三本'])
        storage.receiveText(Stream.value(utf8.encode(text))),
    ]);
    final published = await Future.wait([
      for (final content in contents)
        storage.publish(content, fileName: 'aaa.txt'),
    ]);
    for (var i = 0; i < 3; i++) {
      final name = i == 0 ? 'aaa.txt' : 'aaa-$i.txt';
      check(published[i].file.uri.pathSegments.last == name,
          'collision suffix $i');
      await storage.verifyObject(contents[i].sha256,
          expectedSizeBytes: contents[i].sizeBytes);
    }
    database.dispose();
    database = sqlite3.open('${root.path}/index.sqlite');
    storage.fileNames = ContentFileNames(database);
    await storage.quarantineOrphans(contents.map((e) => e.sha256).toSet());
    check(await storage.objectFile(contents[1].sha256).readAsString() == '第二本',
        'restart and orphan cleanup preserve named files');
    final duplicate =
        await storage.receiveText(Stream.value(utf8.encode('第一本')));
    final reused = await storage.publish(duplicate, fileName: 'other.txt');
    check(!reused.created && reused.file.path == published.first.file.path,
        'identical content reuses its original file');
    await storage.deleteUnreferencedObject(contents[1].sha256);
    check(!await published[1].file.exists() && await published[0].file.exists(),
        'delete resolves only the requested object');

    await File('${storage.objectDirectory.path}/occupied.txt')
        .writeAsString('manual');
    final occupied =
        await storage.receiveText(Stream.value(utf8.encode('uploaded')));
    final allocated = await storage.publish(occupied, fileName: 'occupied.txt');
    check(
        allocated.file.uri.pathSegments.last == 'occupied-1.txt' &&
            await File('${storage.objectDirectory.path}/occupied.txt')
                    .readAsString() ==
                'manual',
        'unindexed file is never overwritten');
    final caseVariant =
        await storage.receiveText(Stream.value(utf8.encode('case')));
    check(
        (await storage.publish(caseVariant, fileName: 'AAA.txt'))
                .file
                .uri
                .pathSegments
                .last ==
            'AAA-3.txt',
        'case-insensitive reservations');

    final longName = '${List.filled(256, '漫').join()}.cbz';
    final safe = safeContentFileName(longName, suffix: 12);
    check(utf8.encode(safe).length <= 240 && safe.endsWith('-12.cbz'),
        'UTF-8 byte limit preserves suffix and extension');
    check(safeContentFileName('../../CON.txt') == '_.._CON.txt',
        'path separators cannot escape the object directory');
    check(safeContentFileName('CON.txt') == '_CON.txt', 'SMB reserved name');

    final legacy =
        await storage.receiveText(Stream.value(utf8.encode('legacy')));
    await storage.publish(legacy);
    final again =
        await storage.receiveText(Stream.value(utf8.encode('legacy')));
    final legacyReused = await storage.publish(again, fileName: '旧书.txt');
    check(
        !legacyReused.created &&
            legacyReused.file.uri.pathSegments.last == legacy.sha256,
        'legacy digest files remain readable without migration');
    print('content_file_names_test: PASS');
  } finally {
    database.dispose();
    await root.delete(recursive: true);
  }
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}
