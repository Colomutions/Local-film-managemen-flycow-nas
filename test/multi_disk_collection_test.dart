import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../lib/src/library_database.dart';
import '../lib/src/media_service.dart';
import '../lib/src/metadata_probe.dart';

Future<void> main() async {
  final temporaryDirectory =
      await Directory.systemTemp.createTemp('mujing-nas-multi-disk-test-');
  final mediaDirectory = Directory(
    '${temporaryDirectory.path}${Platform.pathSeparator}media',
  );
  final diskOne =
      Directory('${mediaDirectory.path}${Platform.pathSeparator}disk1');
  final diskTwo =
      Directory('${mediaDirectory.path}${Platform.pathSeparator}disk2');
  final dataDirectory =
      '${temporaryDirectory.path}${Platform.pathSeparator}data';
  final database = NasLibraryDatabase(dataDirectory);
  final mediaService = NasMediaService(
    mediaDir: mediaDirectory.path,
    fixtureRelativePath: null,
  );
  final metadataProbe = NasMediaMetadataProbe(
    runner: (_, __) async => ProcessResult(
      0,
      0,
      '{"streams":[{"width":1920,"height":1080}],"format":{"duration":"8"}}',
      '',
    ),
  );

  try {
    await _writeVideo(diskOne, '日本影片/ABF/火影忍者 - 影集/002.mkv');
    await _writeVideo(diskOne, '日本影片/ABF/火影忍者 - 影集/010.mkv');
    await _writeVideo(diskTwo, '日本影片/ABF/火影忍者 - 影集/001.mkv');
    await _writeVideo(diskTwo, '日本影片/ABW/火影忍者－影集/001.mkv');

    await database.open();
    final firstRoot = database.ensureConfiguredMediaRoot(
      rootName: 'disk1',
      containerPath: diskOne.path,
    );
    final secondRoot = database.ensureConfiguredMediaRoot(
      rootName: 'disk2',
      containerPath: diskTwo.path,
    );
    final category = database.createCategory('日本影片');
    _expect(
      database.replaceCategoryMediaSources(
        categoryId: category.id,
        sources: [
          NasCategoryMediaSourceInput(
            mediaRootId: firstRoot.id,
            relativePath: '日本影片',
          ),
          NasCategoryMediaSourceInput(
            mediaRootId: secondRoot.id,
            relativePath: '日本影片',
          ),
        ],
      ),
      '逻辑分类可绑定两个来源盘目录',
    );
    final firstScan = await database.scanCategory(
      categoryId: category.id,
      mediaRootId: firstRoot.id,
      mediaService: mediaService,
      metadataProbe: metadataProbe,
    );
    _expect(firstScan.scannedFiles == 4, '扫描两个来源盘的全部视频文件');
    final movies = database.listMovies();
    _expect(movies.length == 2, '相同相对影集目录跨盘合并，但不同父目录不会合并');
    final merged = movies.singleWhere((movie) => movie.episodeCount == 3);
    _expect(merged.entryType == 'series', '影集使用影视条目而非发行商系列');
    _expect(merged.title == '火影忍者', '展示名称移除影集目录标记');
    final mergedEpisodes = database.episodesForMovie(merged.id);
    _expect(
      mergedEpisodes.map((episode) => episode.title).join(',') == '001,002,010',
      '分集按自然文件名排序',
    );
    _expect(
      mergedEpisodes.map((episode) => episode.sourceName).toSet().length == 2,
      '同一影集中的分集保留各自来源盘身份',
    );
    final page = database.episodePageForMovie(
      movieId: merged.id,
      page: 2,
      pageSize: 1,
    );
    _expect(page.items.single.title == '002', '分集分页在 NAS 端按需排序');
    final search = database.searchMovies(const NasMovieSearchFilter(
      query: '010',
      categoryId: null,
      resolutions: {},
      watchStates: {},
      sort: 'relevance',
      order: 'desc',
      page: 1,
      pageSize: 20,
      tagConditions: [],
    ));
    _expect(
      search.items.map((movie) => movie.id).contains(merged.id),
      '集名命中只返回父级影视条目',
    );

    await diskTwo.delete(recursive: true);
    final offlineScan = await database.scanCategory(
      categoryId: category.id,
      mediaRootId: firstRoot.id,
      mediaService: mediaService,
      metadataProbe: metadataProbe,
    );
    _expect(offlineScan.scannedFiles == 2, '在线来源继续可扫描');
    final offlineEpisode = database
        .episodesForMovie(merged.id)
        .singleWhere((episode) => episode.sourceName == 'disk2');
    _expect(!offlineEpisode.sourceOnline, '离线来源盘状态独立记录');
    _expect(offlineEpisode.isAvailable, '来源盘离线不把既有分集认定为删除');
    _expect(
      database.listMovies().any((movie) => movie.id == merged.id),
      '全部或部分来源离线时影集仍然可见',
    );

    await _writeVideo(
      diskOne,
      '日本影片/冲突 - 影集/季一/子影集—影集/001.mkv',
    );
    final conflictScan = await database.scanCategory(
      categoryId: category.id,
      mediaRootId: firstRoot.id,
      mediaService: mediaService,
      metadataProbe: metadataProbe,
    );
    _expect(conflictScan.conflicts.isNotEmpty, '嵌套影集目录会报告扫描冲突');
    _expect(
      database.listMovies().every((movie) => movie.title != '冲突'),
      '嵌套影集冲突范围不会被静默创建为影视条目',
    );

    final episodeForMigration = mergedEpisodes.first;
    final carouselDirectory = Directory(
      '$dataDirectory${Platform.pathSeparator}artwork${Platform.pathSeparator}carousel',
    );
    const sourceCarouselFileName = '源影集截图.png';
    final sourceCarouselFile = File(
      '${carouselDirectory.path}${Platform.pathSeparator}$sourceCarouselFileName',
    );
    await sourceCarouselFile.writeAsBytes(const [137, 80, 78, 71]);
    _expect(
      database.addCarouselImage(
            movieId: merged.id,
            fileName: sourceCarouselFileName,
          ) !=
          null,
      '为拆分测试建立影集截图',
    );
    database.recordPlaybackStarted(
      movieId: merged.id,
      episodeId: episodeForMigration.id,
    );
    final separated = database.splitEpisodesIntoSingles(
      movieId: merged.id,
      episodeIds: [episodeForMigration.id],
    )!.single;
    _expect(
      database.lastPlaybackStartedAtForMovie(separated.id) != null,
      '拆分分集会迁移既有播放关联到新的影视条目',
    );
    final afterSplitHistory = database.watchHistoryPage(
      const NasWatchHistoryQuery(
        query: '',
        startedOnOrAfter: null,
        startedBefore: null,
        devicePlatform: null,
        sort: 'startedAt',
        order: 'desc',
        page: 1,
        pageSize: 20,
      ),
    );
    _expect(
      afterSplitHistory.items.single.movieId == separated.id &&
          afterSplitHistory.items.single.episodeId == episodeForMigration.id,
      '拆分后新观影历史仍指向拆分出的影视和原稳定分集',
    );
    final partialSourceImages = database.carouselImagesForMovie(merged.id);
    final partialNewImages = database.carouselImagesForMovie(separated.id);
    _expect(partialSourceImages.length == 1, '部分拆分后原影集继续保留截图');
    _expect(partialNewImages.length == 1, '部分拆分出的影视条目得到截图副本');
    _expect(
      partialSourceImages.single.fileName != partialNewImages.single.fileName &&
          File(
            '${carouselDirectory.path}${Platform.pathSeparator}${partialNewImages.single.fileName}',
          ).existsSync(),
      '部分拆分的截图使用独立图片资产',
    );

    final otherCategory = database.createCategory('不同分类');
    final crossCategorySeries = database.createEmptySeries(
      title: '跨分类目标影集',
      categoryId: otherCategory.id,
    );
    _expect(
      !database.mergeEpisodesIntoSeries(
        targetMovieId: crossCategorySeries.id,
        episodeIds: [mergedEpisodes[1].id],
        metadataSourceMovieId: merged.id,
      ),
      'NAS 拒绝跨分类合并',
    );
    _expect(
      database.findMovieForAdmin(crossCategorySeries.id)?.categoryId ==
          otherCategory.id,
      '拒绝跨分类合并后目标影集分类不被资料来源覆盖',
    );

    final publisher = database.createPublisher(displayName: '统计发行商');
    final originalSeries = database.createSeries(
      displayName: '统计原有系列',
      publisherId: publisher.id,
    );
    final actor = database.createActor(stageName: '统计演员');
    final tag = database.createTag(name: '统计标签', level: 1);
    _expect(
      database.updateMovieRelations(
            movieId: separated.id,
            publisherId: publisher.id,
            updatePublisherId: true,
            seriesId: originalSeries.id,
            updateSeriesId: true,
          ) !=
          null,
      '为来源条目建立发行商和原有系列关联',
    );
    _expect(
      database.setMovieActorIds(movieId: separated.id, actorIds: [actor.id]),
      '为来源条目建立演员关联',
    );
    _expect(
      database.setMovieTaxonomy(
        movieId: separated.id,
        updateCategory: false,
        categoryId: null,
        updateTagIds: true,
        tagIds: [tag.id],
      ),
      '为来源条目建立标签关联',
    );

    final manualSeries = database.createEmptySeries(
      title: '管理员影集',
      categoryId: category.id,
    );
    _expect(
      database.mergeEpisodesIntoSeries(
        targetMovieId: manualSeries.id,
        episodeIds: [episodeForMigration.id],
        metadataSourceMovieId: separated.id,
      ),
      '管理员可把已扫描文件合并到空影集',
    );
    _expect(
      database.lastPlaybackStartedAtForMovie(manualSeries.id) != null,
      '合并分集会迁移既有播放关联到目标影集',
    );
    final afterMergeHistory = database.watchHistoryPage(
      const NasWatchHistoryQuery(
        query: '',
        startedOnOrAfter: null,
        startedBefore: null,
        devicePlatform: null,
        sort: 'startedAt',
        order: 'desc',
        page: 1,
        pageSize: 20,
      ),
    );
    _expect(
      afterMergeHistory.items.single.movieId == manualSeries.id &&
          afterMergeHistory.items.single.episodeId == episodeForMigration.id,
      '合并后新观影历史仍指向目标影集和原稳定分集',
    );
    _expect(
      database.carouselImagesForMovie(manualSeries.id).length == 1,
      '手工合并保留管理员选择的资料来源截图',
    );
    _expect(
      database.listMovies().where((movie) => movie.id == separated.id).isEmpty,
      '已归并来源条目不再出现在普通影视列表',
    );
    _expect(database.findPublisher(publisher.id)?.movieCount == 1, '发行商统计不重复');
    _expect(
        database.findSeries(originalSeries.id)?.movieCount == 1, '原有系列统计不重复');
    _expect(database.findActor(actor.id)?.movieCount == 1, '演员统计不重复');
    _expect(database.tagDetails(tagId: tag.id)?.movieCount == 1, '标签统计不重复');

    _expect(
      database.updateMovieRelations(
            movieId: manualSeries.id,
            publisherId: null,
            updatePublisherId: true,
            seriesId: null,
            updateSeriesId: true,
          ) !=
          null,
      '可移除当前活动条目的发行商与原有系列关联',
    );
    _expect(
      database.setMovieActorIds(movieId: manualSeries.id, actorIds: const []),
      '可移除当前活动条目的演员关联',
    );
    _expect(
      database.setMovieTaxonomy(
        movieId: manualSeries.id,
        updateCategory: false,
        categoryId: null,
        updateTagIds: true,
        tagIds: const [],
      ),
      '可移除当前活动条目的标签关联',
    );
    _expect(database.deleteSeries(originalSeries.id), '删除前引用检查忽略已归并来源');
    _expect(database.deletePublisher(publisher.id), '发行商删除检查忽略已归并来源');
    _expect(database.deleteActor(actor.id), '演员删除检查忽略已归并来源');
    _expect(database.deleteTag(tag.id), '标签删除检查忽略已归并来源');

    final remainingEpisodeIds = database
        .episodesForMovie(merged.id)
        .map((episode) => episode.id)
        .toList(growable: false);
    final fullySeparated = database.splitEpisodesIntoSingles(
      movieId: merged.id,
      episodeIds: remainingEpisodeIds,
    )!;
    _expect(
      database.carouselImagesForMovie(merged.id).isEmpty,
      '完整拆分后截图不再留在不可访问的原影集',
    );
    _expect(
      fullySeparated.every(
        (movie) => database.carouselImagesForMovie(movie.id).length == 1,
      ),
      '完整拆分后的每个独立影视条目都有截图',
    );
    _expect(
      fullySeparated.every(
        (movie) => File(
          '${carouselDirectory.path}${Platform.pathSeparator}${database.carouselImagesForMovie(movie.id).single.fileName}',
        ).existsSync(),
      ),
      '完整拆分不删除原截图文件，并为其他条目安全复制资产',
    );

    await _writeVideo(diskOne, '日本影片/ABF/单集迁移 - 影集/001.mkv');
    await database.scanCategory(
      categoryId: category.id,
      mediaRootId: firstRoot.id,
      mediaService: mediaService,
      metadataProbe: metadataProbe,
    );
    final automaticSingleEpisodeSeries =
        database.listMovies().singleWhere((movie) => movie.title == '单集迁移');
    await database.close();
    final rawDatabase = sqlite.sqlite3.open(
      '$dataDirectory${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite',
    );
    rawDatabase.execute(
      "UPDATE movies SET entry_type = 'single', collection_key = NULL WHERE id = ?",
      [automaticSingleEpisodeSeries.id],
    );
    rawDatabase.dispose();
    await database.open();
    final singleEpisodeMigration =
        database.collectionMigrationPreview().singleWhere(
              (candidate) => candidate.title == '单集迁移',
            );
    _expect(singleEpisodeMigration.episodeIds.length == 1, '单文件旧影集进入迁移预览');
    _expect(
      !singleEpisodeMigration.requiresMetadataChoice,
      '单文件迁移不需要在多个资料来源之间选择',
    );
    final migratedSingleEpisode = database.applyCollectionMigration(
      key: singleEpisodeMigration.key,
      metadataSourceMovieId: singleEpisodeMigration.sourceMovieIds.single,
    );
    _expect(
      migratedSingleEpisode?.entryType == 'series' &&
          migratedSingleEpisode?.episodeCount == 1,
      '管理员确认后可迁移单文件旧影集',
    );
  } finally {
    await database.close();
    await temporaryDirectory.delete(recursive: true);
  }

  stdout.writeln('multi_disk_collection_test: PASS');
}

Future<void> _writeVideo(Directory root, String relativePath) async {
  final file = File(
    '${root.path}${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}',
  );
  await file.parent.create(recursive: true);
  await file.writeAsBytes(const [0, 1, 2, 3]);
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('断言失败：$message');
}
