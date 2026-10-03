import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

/// 在临时目录复现移除分类来源后的索引数量，绝不读取真实媒体目录。
Future<void> main() async {
  await reproduce(moveToRemainingDisk: false);
  await reproduce(moveToRemainingDisk: true);
}

Future<void> reproduce({required bool moveToRemainingDisk}) async {
  final temp = await Directory.systemTemp.createTemp('mujing-source-removal-');
  final media = Directory('${temp.path}${Platform.pathSeparator}media');
  final disk1 = Directory('${media.path}${Platform.pathSeparator}disk1');
  final disk2 = Directory('${media.path}${Platform.pathSeparator}disk2');
  final db = NasLibraryDatabase('${temp.path}/data');
  final service = NasMediaService(mediaDir: media.path, fixtureRelativePath: null);
  final probe = NasMediaMetadataProbe(
    runner: (_, __) async => ProcessResult(0, 0, '{"streams":[],"format":{}}', ''),
  );
  final stages = <Map<String, Object?>>[];
  try {
    for (final disk in [disk1, disk2]) {
      await Directory('${disk.path}/films').create(recursive: true);
    }
    await File('${disk1.path}/films/AAA-001.mp4').writeAsBytes([1]);
    final oldFile = File('${disk2.path}/films/BBB-002.mp4');
    await oldFile.writeAsBytes([2]);
    await db.open();
    final root1 = db.ensureConfiguredMediaRoot(rootName: 'disk1', containerPath: disk1.path);
    final root2 = db.ensureConfiguredMediaRoot(rootName: 'disk2', containerPath: disk2.path);
    final category = db.createCategory('测试分类');
    final first = NasCategoryMediaSourceInput(mediaRootId: root1.id, relativePath: 'films');
    final second = NasCategoryMediaSourceInput(mediaRootId: root2.id, relativePath: 'films');
    db.replaceCategoryMediaSources(categoryId: category.id, sources: [first, second]);

    Future<void> scan(String stage) async {
      final result = await db.scanCategory(categoryId: category.id, mediaRootId: root1.id,
          mediaService: service, metadataProbe: probe);
      final movies = db.listMovies().where((movie) => movie.categoryId == category.id).toList();
      stages.add({
        'stage': stage,
        'boundSources': db.mediaSourcesForCategory(category.id).length,
        'scannedFiles': result.scannedFiles,
        'indexedMovies': movies.length,
        'movies': [for (final movie in movies) {
          'title': movie.title,
          'episodes': [for (final episode in db.episodesForMovie(movie.id)) {
            'source': episode.sourceName,
            'available': episode.isAvailable,
            'sourceOnline': episode.sourceOnline,
          }],
        }],
      });
    }

    await scan('initial');
    if (stages.single['scannedFiles'] != 2 || stages.single['indexedMovies'] != 2) {
      throw StateError('初始双盘样本未正确建立，复现无效');
    }
    if (moveToRemainingDisk) {
      await oldFile.rename('${disk1.path}/films/BBB-002.mp4');
    }
    // 用临时目录改名模拟拔盘，不操作任何真实硬盘。
    await disk2.rename('${temp.path}/detached-disk2');
    db.replaceCategoryMediaSources(categoryId: category.id, sources: [first]);
    await scan('removed_source_then_rescan');
    await scan('rescan_again');
    final expected = moveToRemainingDisk ? 2 : 1;
    if (stages.skip(1).any((stage) => stage['indexedMovies'] != expected)) {
      throw StateError('移除来源后索引数量错误，预期 $expected');
    }
    stdout.writeln(jsonEncode({'moveToRemainingDisk': moveToRemainingDisk, 'stages': stages}));
  } finally {
    await db.close();
    final target = temp.absolute.path;
    final prefix = Directory.systemTemp.absolute.path;
    if (!target.startsWith('$prefix${Platform.pathSeparator}') ||
        !temp.uri.pathSegments.where((part) => part.isNotEmpty).last.startsWith('mujing-source-removal-')) {
      throw StateError('临时目录边界校验失败');
    }
    await temp.delete(recursive: true);
  }
}
