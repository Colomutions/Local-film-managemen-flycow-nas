import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import '../lib/mujing_nas.dart';
import 'scrape_service_test.dart' show FakeWorker, waitJob;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

class SupplementWorker extends FakeWorker {
  Map<String, dynamic>? shot;
  bool failGallery = false;
  @override
  Future<Map<String, dynamic>> execute(Map<String, dynamic> input) async {
    calls.add(input);
    if (input['type'] == 'actor') {
      check(input['identityOnly'] == true, '演员只读取身份线索');
      return {'profile': {'name': '外站名字', 'aliases':
        (input['url'] as String).endsWith('/alias') ? ['别名线索'] : <String>[]}};
    }
    check(input['type'] == 'movie' && input['galleryOnly'] == true, '独立补关联模式');
    return {
      'metadata': {'code': input['code'], 'title': '禁止写入标题', 'summary': '补全简介',
        'originalTitle': '禁止写入原名'},
      'entities': [
        entity('actor', 'actor', 'same', '共同名字'),
        entity('actor', 'actor', 'alias', '来源异名'),
        entity('actor', 'actor', 'missing', '后来导入'),
        entity('actor', 'actor', 'manual', '需要手动对应'),
        entity('company', 'maker', 'unused', '不应创建厂商'),
      ],
      'assets': input['movieImages'] == true && shot != null ? {'gallery-1': shot, 'gallery-2': shot} : {},
      'warnings': <String>[if (failGallery) 'gallery-2: 临时下载失败'],
    };
  }
}

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('mujing-supplement-');
  final media = Directory('${temp.path}/media');
  await media.create();
  for (final name in ['ABC-001', 'ABC-002', 'ABC-003']) {
    await File('${media.path}/$name.mp4').writeAsBytes([1, 2, 3]);
  }
  final db = NasLibraryDatabase('${temp.path}/data');
  final worker = SupplementWorker();
  NasScrapeService? service;
  sqlite.Database? raw;
  try {
    await db.open();
    await db.scanConfiguredRoot(rootName: '盘', containerPath: media.path,
      mediaService: NasMediaService(mediaDir: media.path, fixtureRelativePath: null),
      metadataProbe: NasMediaMetadataProbe(runner: (_, __) async => ProcessResult(0, 0, '{"streams":[],"format":{}}', '')));
    final movies = db.listMovies()..sort((a, b) => a.title.compareTo(b.title));
    final a = db.createActor(stageName: 'MDCNG 甲', aliases: ['共同名字']);
    final b = db.createActor(stageName: 'MDCNG 乙', originalName: '共同名字');
    final alias = db.createActor(stageName: 'MDCNG 丙', aliases: ['别名线索']);
    final manual = db.createActor(stageName: '人工演员');
    db.setMovieActorIds(movieId: movies[0].id, actorIds: [manual.id]);
    db.markMovieMetadataFieldsManual(movieId: movies[0].id, fieldKeys: ['actors']);
    db.updateMovieMetadata(movieId: movies[0].id, summary: '原简介');
    db.updateMovieMetadata(movieId: movies[1].id, summary: '   ');
    raw = sqlite.sqlite3.open('${db.dataDir}/db/mujing.sqlite');
    raw.execute('PRAGMA foreign_keys=ON');
    final actorSnapshot = raw.select('SELECT * FROM actors ORDER BY id').map((r) => Map.of(r)).toList().toString();
    final artwork = NasArtworkService(db.dataDir);
    final cover = await artwork.saveCarouselImage(movieId: movies[0].id, mimeType: 'image/jpeg', bytes: [255,216,255,1]);
    final coverRow = db.addCarouselImage(movieId: movies[0].id, fileName: cover)!;
    db.recordGalleryOrigin(coverRow.id, 'mdcng_cover');
    final existing = await artwork.saveCarouselImage(movieId: movies[2].id, mimeType: 'image/jpeg', bytes: [255,216,255,2]);
    db.addCarouselImage(movieId: movies[2].id, fileName: existing);
    final bytes = [255,216,255,3], hash = sha256.convert([255,216,255,3]).toString();
    final cache = File('${db.dataDir}/scraper/assets/$hash.jpg');
    await cache.parent.create(recursive: true);
    await cache.writeAsBytes(bytes);
    worker.shot = {'file': 'assets/$hash.jpg', 'sha256': hash, 'mimeType': 'image/jpeg'};
    service = NasScrapeService(db, artwork, worker, cacheDir: '${db.dataDir}/scraper')..start();
    Future<Map<String, dynamic>> run() async {
      final job = service!.create({'kind': 'movies', 'movieIds': movies.map((m) => m.id).toList(), 'supplementOnly': true});
      await waitJob(db, job['id'] as String);
      return db.scrapeJob(job['id'] as String)!;
    }
    worker.failGallery = true;
    await run();
    check(db.carouselImagesForMovie(movies[0].id).length == 1 && db.carouselImagesForMovie(movies[1].id).isEmpty,
      '截图部分下载失败时保留缓存，避免已有半批截图阻止重试');
    worker.failGallery = false;
    final job = await run();
    final linked = db.actorsForMovie(movies[0].id).map((a) => a.id).toSet();
    check(linked.containsAll([a.id,b.id,alias.id,manual.id]) && linked.length == 4,
      '全部同名候选与网站异名均关联，人工关系保留');
    check(raw.select('SELECT * FROM actors ORDER BY id').map((r) => Map.of(r)).toList().toString() == actorSnapshot,
      '所有演员档案逐字段不变且不创建新演员');
    check(db.listPublishers().isEmpty, '不创建发行商或厂商');
    for (final movie in movies) {
      final after = db.findMovie(movie.id)!;
      check(after.title == movie.title && after.catalogNumber == movie.catalogNumber && after.originalTitle == movie.originalTitle,
        '影片标题、番号、原名不变');
    }
    check(db.findMovie(movies[0].id)!.summary == '原简介' && db.findMovie(movies[1].id)!.summary == '补全简介', '简介只补空值');
    check(db.carouselImagesForMovie(movies[0].id).length == 2 && db.carouselImagesForMovie(movies[1].id).length == 1,
      '仅封面或空画廊补截图，重复图片去重');
    check(db.carouselImagesForMovie(movies[2].id).single.fileName == existing, '已有实际截图不追加');
    check(worker.calls.where((c) => c['code'] == 'ABC-003').every((c) => c['movieImages'] == false), '已有截图不请求图片');
    check(db.supplementPending(movies[0].id).length == 2, '不存在与异名未匹配演员保留待关联');
    final task = (job['items'] as List).whereType<Map>().singleWhere((t) => (t['payload'] as Map)['movieId'] == movies[0].id);
    final manualKey = worker.entity('actor','actor','manual','需要手动对应')['id'] as String;
    await service.resolve(task['id'] as String, [], actorMappings: {manualKey: manual.id});
    check(movies.every((m) => db.actorsForMovie(m.id).any((a) => a.id == manual.id)), '确认来源映射后跨影片补关联');
    final later = db.createActor(stageName: '后来导入');
    db.linkActorToMdcngSource(sourceId: 'mdcng', embyId: 'late', actorId: later.id, sourceName: '后来导入', profileKey: 'late');
    check(movies.every((m) => db.actorsForMovie(m.id).any((a) => a.id == later.id)), '后导 MDCNG 自动完成待关联');
    check(db.supplementPending(movies[0].id).isEmpty, '待关联已解决');
    final second = await run();
    check((second['counts'] as Map)['done'] == 3, '重复执行重新评估演员，完成任务');
    check(db.carouselImagesForMovie(movies[0].id).length == 2 && db.actorsForMovie(movies[0].id).length == 5,
      '重复执行不增加重复关系或截图');
    await service.close(); service = null;
    await db.close(); await db.open();
    check(db.supplementPending(movies[0].id).isEmpty && db.actorsForMovie(movies[0].id).length == 5, '重启保留身份映射与关联');
    check(raw.select('PRAGMA foreign_key_check').isEmpty, '外键完整');
    final localCast = {'kind': 'actor', 'name': '没有来源身份', 'provisional': true};
    db.saveSupplementCast(movies[0].id, [localCast]);
    db.saveSupplementCast(movies[1].id, [localCast]);
    final localKey = db.supplementPending(movies[0].id).single['sourceKey'] as String;
    final localJob = db.createScrapeJob('局部确认');
    final localTask = db.enqueueScrapeTask([localJob], 'movie', 'local-confirm',
      {'movieId': movies[0].id, 'supplementOnly': true});
    db.finishScrapeTask(localTask, 'review', conflicts: db.supplementPending(movies[0].id));
    db.resolveScrapeConflicts(localTask, [], actorMappings: {localKey: manual.id});
    db.saveSupplementCast(movies[0].id, [localCast]);
    check(db.supplementPending(movies[0].id).isEmpty && db.supplementPending(movies[1].id).length == 1,
      '无稳定身份的确认重复执行仍有效，但不推广到其他影片');
    final legacyId = db.addCarouselImage(movieId: movies[1].id, fileName: 'legacy.jpg')!.id;
    raw.execute("UPDATE movie_carousel_images SET created_at='legacy-time' WHERE id=?", [legacyId]);
    raw.execute('''INSERT INTO mdcng_import_records(id,movie_id,episode_id,nfo_file_name,nfo_content_hash,applied_fields_json,created_at)
      VALUES ('legacy-nfo',?,?,'movie.nfo','hash','["fanart"]','legacy-time')''', [movies[1].id, db.episodesForMovie(movies[1].id).first.id]);
    await db.close(); await db.open();
    check(db.galleryOrigin(legacyId) == 'mdcng_cover', '旧 MDCNG 封面根据导入记录恢复来源，不依赖图片张数');
    db.removeMovieFromIndex(movies[1].id);
    check(raw.select('SELECT * FROM supplement_cast WHERE movie_id=?', [movies[1].id]).isEmpty &&
        db.galleryOrigin(legacyId) == null && raw.select('PRAGMA foreign_key_check').isEmpty, '影片删除级联清理待关联名单和图片来源');
    stdout.writeln('cast_supplement_test: PASS');
  } finally {
    await service?.close(); raw?.dispose(); await db.close();
    if (!temp.absolute.path.startsWith('${Directory.systemTemp.absolute.path}${Platform.pathSeparator}')) throw StateError('临时目录边界');
    await temp.delete(recursive: true);
  }
}
