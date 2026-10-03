import 'dart:io';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import '../lib/mujing_nas.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('mujing-source-cleanup-');
  final media = Directory('${temp.path}${Platform.pathSeparator}media');
  final one = Directory('${media.path}${Platform.pathSeparator}one');
  final two = Directory('${media.path}${Platform.pathSeparator}two');
  final db = NasLibraryDatabase('${temp.path}/data');
  sqlite.Database? raw;
  Future<void> video(Directory root, String path) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
  }
  final service = NasMediaService(mediaDir: media.path, fixtureRelativePath: null);
  final probe = NasMediaMetadataProbe(runner: (_, __) async =>
      ProcessResult(0, 0, '{"streams":[],"format":{}}', ''));
  try {
    await video(one, 'films/保留.mp4');
    await video(one, 'films/跨盘 - 影集/01.mp4');
    await video(two, 'films/移除.mp4');
    await video(two, 'films/跨盘 - 影集/02.mp4');
    await video(two, 'films/整部移除 - 影集/01.mp4');
    await video(two, 'other/其他分类.mp4');
    await db.open();
    final r1 = db.ensureConfiguredMediaRoot(rootName: 'one', containerPath: one.path);
    final r2 = db.ensureConfiguredMediaRoot(rootName: 'two', containerPath: two.path);
    final category = db.createCategory('双盘');
    final otherCategory = db.createCategory('其他');
    final s1 = NasCategoryMediaSourceInput(mediaRootId: r1.id, relativePath: 'films');
    final s2 = NasCategoryMediaSourceInput(mediaRootId: r2.id, relativePath: 'films');
    db.replaceCategoryMediaSources(categoryId: category.id, sources: [s1, s2]);
    db.replaceCategoryMediaSources(categoryId: otherCategory.id, sources: [
      NasCategoryMediaSourceInput(mediaRootId: r2.id, relativePath: 'other')]);
    Future<NasScanResult> scan(String id, {Future<void> Function()? beforeFile}) =>
        db.scanCategory(categoryId: id, mediaRootId: r1.id,
            mediaService: service, metadataProbe: probe, beforeFile: beforeFile);
    await scan(category.id);
    await scan(otherCategory.id);
    final empty = db.createEmptySeries(title: '手动空影集', categoryId: category.id);
    final films = db.listMovies();
    final kept = films.singleWhere((m) => m.title == '保留');
    final removed = films.singleWhere((m) => m.title == '移除');
    final series = films.singleWhere((m) => m.title == '跨盘');
    final removedSeries = films.singleWhere((m) => m.title == '整部移除');
    final other = films.singleWhere((m) => m.title == '其他分类');
    final episodes = db.episodesForMovie(series.id);
    final keptEpisode = episodes.singleWhere((e) => e.mediaRootId == r1.id);
    final removedEpisode = episodes.singleWhere((e) => e.mediaRootId == r2.id);
    final actor = db.createActor(stageName: '关联演员');
    db.setMovieActorIds(movieId: series.id, actorIds: [actor.id]);
    db.setMovieActorIds(movieId: removed.id, actorIds: [actor.id]);
    db.setMovieFavorite(movieId: series.id, isFavorite: true);
    db.updateMovieMetadata(movieId: series.id, summary: '保留简介');
    raw = sqlite.sqlite3.open('${db.dataDir}/db/mujing.sqlite');
    raw.execute('PRAGMA foreign_keys=ON');
    for (final episode in [keptEpisode, removedEpisode]) {
      raw.execute('''INSERT INTO playback_history(id,movie_id,episode_id,started_at)
        VALUES (?,?,?,?)''', ['history-${episode.id}', series.id, episode.id, '2026-10-03T00:00:00Z']);
    }
    raw.execute('''INSERT INTO mdcng_import_records(id,movie_id,episode_id,nfo_file_name,
      nfo_content_hash,applied_fields_json,created_at) VALUES ('nfo',?,?,'02.nfo','hash','[]','now')''',
      [series.id, removedEpisode.id]);
    raw.execute('''INSERT INTO movie_metadata_field_sources(movie_id,field_key,source_kind,
      import_record_id,updated_at) VALUES (?,'summary','mdcng','nfo','now')''', [series.id]);
    raw.execute('''INSERT INTO movies(id,title,created_at,updated_at,lifecycle_state,merged_into_movie_id)
      VALUES ('old-merged','旧归并','now','now','merged',?)''', [removedSeries.id]);

    final detached = await two.rename('${temp.path}/detached');
    final offline = await scan(category.id);
    check(offline.removedEpisodes == 0 && db.findMovie(removed.id) != null,
        '绑定未移除时仅离线，不能清除影片');
    check(db.findEpisode(removedEpisode.id)!.isAvailable &&
        !db.findEpisode(removedEpisode.id)!.sourceOnline, '离线状态与分集存在状态分开');
    db.replaceCategoryMediaSources(categoryId: category.id, sources: [s1]);
    // 绑定已在旧版本保存，重新打开数据库模拟升级后的第一次扫描。
    await db.close();
    await db.open();
    final revision = db.revisions['library'];
    final cleaned = await scan(category.id);
    check(db.revisions['library'] != revision, '清理索引会使客户端片库缓存失效');
    check(cleaned.removedEpisodes == 3 && cleaned.removedMovieIndexes.length == 2,
        '移除单片、整部影集及跨盘影集的旧盘分集');
    check(db.findMovie(removed.id) == null && db.findMovie(removedSeries.id) == null,
        '仅有旧盘文件的影片退出所有有效索引');
    final search = db.searchMovies(NasMovieSearchFilter(query: '移除', categoryId: category.id,
        resolutions: {}, watchStates: {}, sort: 'createdAt', order: 'desc',
        page: 1, pageSize: 20, tagConditions: []));
    check(search.total == 0, '服务端搜索数量不再包含旧来源影片');
    check(db.findMovie(kept.id) != null && db.findMovie(empty.id) != null &&
        db.findMovie(other.id) != null, '保留其他来源、手动空影集及其他分类');
    check(db.episodesForMovie(series.id).single.id == keptEpisode.id &&
        db.episodePageForMovie(movieId: series.id, page: 1, pageSize: 20).total == 1,
        '跨盘影集只剩有效分集，分集 ID 不变');
    check(db.findMovie(series.id)!.isFavorite && db.findMovie(series.id)!.summary == '保留简介' &&
        db.findActor(actor.id)!.movieCount == 1, '保留影集资料收藏并更新演员关联数量');
    check(raw.select('SELECT episode_id FROM playback_history').single['episode_id'] == keptEpisode.id,
        '只清除被移除分集的观影记录，保留剩余分集记录');
    check(db.metadataFieldSourcesForMovie(series.id)['summary']!.sourceKind == 'mdcng',
        '移除旧分集审计不清空影集资料来源类型');
    check(raw.select('PRAGMA foreign_key_check').isEmpty, '含 NFO 审计和归并引用时仍满足外键约束');
    check(await File('${detached.path}/films/移除.mp4').exists(), '索引清理不删除源视频');
    check((await scan(category.id)).removedEpisodes == 0, '重复扫描幂等');

    await detached.rename(two.path);
    db.replaceCategoryMediaSources(categoryId: category.id, sources: [s1, s2]);
    await scan(category.id);
    check(db.episodesForMovie(series.id).length == 2 &&
        db.listMovies().any((movie) => movie.title == '移除'), '重新绑定并扫描可以重新建索引');
    var changed = false;
    var rejected = false;
    try {
      await scan(category.id, beforeFile: () async {
        if (changed) return;
        changed = true;
        db.replaceCategoryMediaSources(categoryId: category.id, sources: [s1]);
      });
    } on StateError { rejected = true; }
    check(rejected && db.episodesForMovie(series.id).length == 2,
        '扫描中绑定变化时旧扫描不得清理索引');
    await scan(category.id);
    check(db.episodesForMovie(series.id).length == 1, '下一次扫描按新绑定清理');

    await video(one, 'films2/前缀相似.mp4');
    final wider = NasCategoryMediaSourceInput(mediaRootId: r1.id, relativePath: 'films2');
    db.replaceCategoryMediaSources(categoryId: category.id, sources: [s1, wider]);
    await scan(category.id);
    final similar = db.listMovies().singleWhere((m) => m.title == '前缀相似');
    db.replaceCategoryMediaSources(categoryId: category.id, sources: [s1]);
    await scan(category.id);
    check(db.findMovie(similar.id) == null && await File('${one.path}/films2/前缀相似.mp4').exists(),
        '目录按分段边界匹配，films 不包含 films2');
    await video(one, 'films/sub/子目录.mp4');
    await scan(category.id);
    final child = db.listMovies().singleWhere((movie) => movie.title == '子目录');
    final childEpisode = db.episodesForMovie(child.id).single;
    final childSource = NasCategoryMediaSourceInput(mediaRootId: r1.id, relativePath: 'films/sub');
    db.replaceCategoryMediaSources(categoryId: category.id, sources: [s1, childSource]);
    check((await scan(category.id)).removedEpisodes == 0, '重复覆盖的父子范围不误清理');
    db.replaceCategoryMediaSources(categoryId: category.id, sources: [childSource]);
    var failed = false;
    try {
      await scan(category.id, beforeFile: () async => throw StateError('模拟扫描失败'));
    } on StateError { failed = true; }
    check(failed && db.findMovie(kept.id) != null, '扫描失败不执行清理');
    await scan(category.id);
    check(db.findMovie(kept.id) == null && db.findMovie(child.id) != null &&
        db.episodesForMovie(child.id).single.id == childEpisode.id,
        '缩小为子目录时保留范围内影片及分集身份');
    check(db.findMovie(empty.id) != null && raw.select('PRAGMA foreign_key_check').isEmpty,
        '缩小路径后手动空影集及外键仍正确');
    stdout.writeln('category_source_removal_test: PASS');
  } finally {
    raw?.dispose();
    await db.close();
    final target = temp.absolute.path;
    if (!target.startsWith('${Directory.systemTemp.absolute.path}${Platform.pathSeparator}') ||
        !temp.uri.pathSegments.where((part) => part.isNotEmpty).last.startsWith('mujing-source-cleanup-')) {
      throw StateError('临时目录边界校验失败');
    }
    await temp.delete(recursive: true);
  }
}
