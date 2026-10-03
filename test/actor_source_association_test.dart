import 'dart:io';

import '../lib/mujing_nas.dart';
import 'scrape_service_test.dart' as scraping;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('mujing-actor-association-');
  final media = Directory('${temp.path}/media');
  await media.create();
  for (final name in ['ABC-001', 'ABC-002', 'ABC-003', 'ABC-004']) {
    await File('${media.path}/$name.mp4').writeAsBytes([0, 1, 2]);
  }
  final db = NasLibraryDatabase('${temp.path}/data');
  NasScrapeService? service;
  try {
    await db.open();
    await db.scanConfiguredRoot(
        rootName: '测试盘', containerPath: media.path,
        mediaService: NasMediaService(mediaDir: media.path, fixtureRelativePath: null),
        metadataProbe: NasMediaMetadataProbe(runner: (command, args) async =>
            ProcessResult(1, 0, '{"streams":[],"format":{}}', '')));
    final movies = db.listMovies()..sort((a, b) => a.title.compareTo(b.title));
    final actor = db.createActor(stageName: 'MDCNG 中文名', originalName: '来源演员',
        aliases: ['旧艺名'], birthMonth: '1995-03', country: '日本');
    db.linkActorToMdcngSource(sourceId: 'mdcng', embyId: '1', actorId: actor.id,
        sourceName: '导入时使用的名字', profileKey: 'profile-1');
    final worker = _AssociationWorker();
    service = NasScrapeService(db, NasArtworkService(db.dataDir), worker,
        cacheDir: '${db.dataDir}/scraper')..start();
    final job = service.create({'kind': 'movies',
      'movieIds': [movies[0].id], 'movieImages': false});
    await scraping.waitJob(db, job['id'] as String);
    check(db.listActors().length == 1, '先导入 MDCNG 后刮影片不重复建演员');
    check(db.actorsForMovie(movies[0].id).single.id == actor.id, '影片复用 MDCNG 演员 ID');
    check(db.findActor(actor.id)!.stageName == 'MDCNG 中文名' &&
        db.findActor(actor.id)!.birthMonth == '1995-03', '来源资料不覆盖 MDCNG 姓名与生日');
    check(db.findActor(actor.id)!.birthplace == '来源出生地', 'WhatsAV 仍可补充空白字段');
    check(db.findActor(actor.id)!.birthDate == null, '不补入与 MDCNG 出生年月矛盾的生日');
    check(db.findActiveActorByExactName('导入时使用的名字')?.id == actor.id,
        '保留导入来源姓名用于后续出演名单匹配');
    final source = worker.entity('actor', 'actor', '7', '网站修改后的名字');
    check(db.scrapeEntity(source) == actor.id, '稳定来源 ID 优先于后来变化的姓名');
    var sameNameRejected = false;
    try {
      db.scrapeEntity(worker.entity('actor', 'actor', 'different-id', '来源演员'));
    } on ArgumentError { sameNameRejected = true; }
    check(sameNameRejected, '同站不同身份不能仅因同名被自动合并');

    db.saveScrapeMovieProfile(movies[1].id, {'actorSources': [
      worker.entity('actor', 'actor', 'different-id', '来源演员'),
    ]});
    check(db.reconcileScrapeActorMovies(actor.id) == 0, '补关联也不能绕过同站不同身份保护');
    db.saveScrapeMovieProfile(movies[1].id, {'actors': [{'name': '旧艺名'}]});
    db.saveScrapeMovieProfile(movies[2].id, {'actors': [{'name': '旧艺名'}]});
    db.markMovieMetadataFieldsManual(movieId: movies[2].id, fieldKeys: ['actors']);
    db.saveScrapeMovieProfile(movies[3].id, {'actorSources': [source]});
    check(db.reconcileScrapeActorMovies(actor.id) == 2, '按别名及稳定来源补关联已有影片');
    check(db.actorsForMovie(movies[2].id).isEmpty, '保护手动清空的出演名单');
    check(db.reconcileScrapeActorMovies(actor.id) == 0, '重复补关联幂等');
    check(db.findActor(actor.id)!.movieCount == 3, '演员关联数量与影片一致');

    final other = db.createActor(stageName: '同名者', aliases: ['重名']);
    db.createActor(stageName: '另一人', aliases: ['重名']);
    var rejected = false;
    try {
      db.scrapeEntity(worker.entity('actor', 'actor', 'ambiguous', '重名'));
    } on ArgumentError { rejected = true; }
    check(rejected && db.scrapeProfiles('actor', other.id).isEmpty,
        '重名不能自动绑定或产生新档案');
    worker.ambiguous = true;
    final ambiguousJob = service.create({'kind': 'movies',
      'movieIds': [movies[3].id], 'movieImages': false, 'refresh': true});
    await scraping.waitJob(db, ambiguousJob['id'] as String);
    final review = (db.scrapeJob(ambiguousJob['id'] as String)!['items'] as List)
        .cast<Map>().singleWhere((task) => task['kind'] == 'movie');
    final conflict = (review['conflicts'] as List).cast<Map>().single;
    check(review['status'] == 'review' && (conflict['candidates'] as List).length == 2,
        '真实任务保留影片资料，并提供重名演员候选');
    await service.resolve(review['id'] as String, [],
        actorMappings: {conflict['sourceKey'] as String: other.id});
    await scraping.waitJob(db, ambiguousJob['id'] as String);
    check(db.actorsForMovie(movies[3].id).any((actor) => actor.id == other.id) &&
        db.scrapeTask(review['id'] as String)!['status'] == 'done',
        '核对身份后后台继续完成影片关联');
    worker.ambiguous = false;
    final reviewJob = db.createScrapeJob('人工核对重名');
    db.pauseScrapeJob(reviewJob, true);
    final taskId = db.enqueueScrapeTask([reviewJob], 'actor', 'ambiguous', {'name': '重名'});
    final ambiguousSource = worker.entity('actor', 'actor', 'ambiguous', '重名');
    db.finishScrapeTask(taskId, 'review', conflicts: [{
      'field': 'identity', 'sourceKey': ambiguousSource['id'], 'sourceUrl': ambiguousSource['url'],
      'candidates': [{'id': other.id}], 'proposed': '重名',
    }]);
    db.resolveScrapeConflicts(taskId, []);
    check(db.scrapeTask(taskId)!['status'] == 'review', '未选择演员不能把身份冲突标记完成');
    rejected = false;
    try {
      db.resolveScrapeConflicts(taskId, [], actorMappings: {ambiguousSource['id'] as String: actor.id});
    } on ArgumentError { rejected = true; }
    check(rejected, '不能通过审核请求绑定候选以外的演员');
    db.resolveScrapeConflicts(taskId, [], actorMappings: {ambiguousSource['id'] as String: other.id});
    check(db.scrapeTask(taskId)!['status'] == 'pending' && db.scrapeEntity(ambiguousSource) == other.id,
        '人工确认保存稳定映射并继续原任务');
    final archive = db.createActor(stageName: '归档演员');
    db.archiveActor(archive.id);
    rejected = false;
    try {
      db.scrapeEntity(worker.entity('actor', 'actor', 'archived', '归档演员'));
    } on ArgumentError { rejected = true; }
    check(rejected, '归档演员不能绕过归档保护再次建档');

    final asset = db.addManagedAsset(id: 'mdcng-photo', purpose: 'actor_photo',
        fileName: 'mdcng.jpg', mimeType: 'image/jpeg');
    db.updateActor(actor.id, {'photo_asset_id': asset.id});
    db.applyScrapeFields('actor', actor.id, {'stage_name': '覆盖名字',
      'photo_asset_id': 'new-image', 'birth_month': null, 'aliases_json': '[]'});
    check(db.findActor(actor.id)!.photoAssetId == asset.id &&
        db.findActor(actor.id)!.aliases.contains('旧艺名'), '保留 MDCNG 头像与别名，忽略缺失值');
    db.updateActor(actor.id, {'birthplace': null});
    db.applyScrapeFields('actor', actor.id, {'birthplace': '再次填入'});
    check(db.findActor(actor.id)!.birthplace == null, '人工清空仍受保护');

    await service.close();
    service = null;
    await db.close();
    await db.open();
    check(db.scrapeEntity(source) == actor.id && db.findActor(actor.id)!.movieCount == 3,
        '来源映射和关联跨重启保留');
    db.markMovieMetadataFieldsManual(movieId: movies[3].id, fieldKeys: ['actors']);
    final late = db.createActor(stageName: '升级前遗漏的演员');
    db.saveScrapeMovieProfile(movies[0].id, {'actors': [{'name': '升级前遗漏的演员'}]});
    db.setScrapeSetting('actorAssociationVersion', 0);
    await db.close();
    await db.open();
    check(db.actorsForMovie(movies[0].id).any((actor) => actor.id == late.id),
        '升级时按已有出演名单补关联，无需重新联网刮削');
    stdout.writeln('actor_source_association_test: PASS');
  } finally {
    await service?.close();
    await db.close();
    await temp.delete(recursive: true);
  }
}

class _AssociationWorker extends scraping.FakeWorker {
  bool ambiguous = false;

  @override
  Future<Map<String, dynamic>> execute(Map<String, dynamic> input) async {
    final result = await super.execute(input);
    if (ambiguous && input['type'] == 'movie') {
      result['entities'] = [entity('actor', 'actor', 'live-ambiguous', '重名')];
    }
    return result;
  }
}
