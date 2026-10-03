import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import '../lib/mujing_nas.dart';

void expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('mujing-scrape-test-');
  final media = Directory('${temp.path}/media'), data = '${temp.path}/data';
  await media.create();
  for (final name in ['ABC-001.mp4', 'ABC-002.mp4', 'unknown.mp4']) {
    await File('${media.path}/$name').writeAsBytes([0, 1, 2]);
  }
  final db = NasLibraryDatabase(data);
  final worker = FakeWorker();
  NasScrapeService? service;
  try {
    final imageBytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=');
    final imageHash = sha256.convert(imageBytes).toString();
    final image = File('$data/scraper/assets/$imageHash.png');
    await image.parent.create(recursive: true);
    await image.writeAsBytes(imageBytes);
    worker.asset = {
      'file': 'assets/$imageHash.png',
      'sha256': imageHash,
      'mimeType': 'image/png'
    };
    await db.open();
    await db.scanConfiguredRoot(
        rootName: '测试盘',
        containerPath: media.path,
        mediaService:
            NasMediaService(mediaDir: media.path, fixtureRelativePath: null),
        metadataProbe: NasMediaMetadataProbe(
            runner: (command, args) async =>
                ProcessResult(1, 0, '{"streams":[],"format":{}}', '')));
    final films = db.listMovies();
    expect(films.length == 3 && worker.calls.isEmpty, '扫描不触发采集');
    final known = films.where((m) => m.title.startsWith('ABC')).toList();
    final unknown = films.singleWhere((m) => m.title == 'unknown');
    service = NasScrapeService(db, NasArtworkService(data), worker,
        cacheDir: '$data/scraper')
      ..start();
    final options = {
      'kind': 'movies',
      'movieIds': known.map((m) => m.id).toList(),
      'movieImages': false
    };
    final job = service.create(options);
    final duplicate = service.create(options);
    await waitJob(db, job['id'] as String);
    await waitJob(db, duplicate['id'] as String);
    expect(worker.calls.where((c) => c['type'] == 'movie').length == 2,
        '重复提交不重复抓影片');
    expect(worker.calls.where((c) => c['type'] == 'actor').length == 1,
        '共享演员只采集一次');
    expect(worker.calls.where((c) => c['type'] == 'company').length == 2,
        '制作商和厂牌分别采集一次');
    final actor = db.listActors().single;
    expect(actor.stageName == '来源演员' && actor.birthMonth == '1990-01',
        '演员档案及出生年月入库');
    expect(actor.movieCount == 2, '演员关联到真实影片');
    final film = db.findMovieForAdmin(known.first.id)!;
    expect(film.title.startsWith('来源影片') && film.catalogNumber != null,
        '扫描默认标题被来源替换');
    expect(film.publisherId == null, '制作商不误写成发行商');
    expect(db.movieCompanies(film.id).length == 2, '两个厂商角色保留');
    final company = db.movieCompanies(film.id).first;
    expect(db.findPublisher(company['id'] as String)!.movieCount == 2,
        '制作商和厂牌详情可统计关联影片');
    expect(
        db
                .searchMovies(NasMovieSearchFilter(
                    publisherIds: {company['id'] as String},
                    query: '',
                    categoryId: null,
                    resolutions: {},
                    watchStates: {},
                    sort: 'createdAt',
                    order: 'desc',
                    page: 1,
                    pageSize: 20,
                    tagConditions: []))
                .total ==
            2,
        '按厂商搜索包含独立角色关系');
    final afterCount = worker.calls.length;
    final incremental = service.create(options);
    await waitJob(db, incremental['id'] as String);
    expect(worker.calls.length == afterCount, '增量任务跳过完成结果');

    final invalid = service.create({
      'kind': 'movies',
      'movieIds': [unknown.id],
      'movieImages': false
    });
    await waitJob(db, invalid['id'] as String);
    expect(
        (db.scrapeJob(invalid['id'] as String)!['counts'] as Map)['review'] ==
            1,
        '无番号进入核对，不搜索猜测');

    db.updateActor(actor.id, {'stage_name': '人工姓名', 'birthplace': null});
    db.updateMovieMetadata(movieId: film.id, title: '人工标题');
    db.markMovieMetadataFieldsManual(movieId: film.id, fieldKeys: ['title']);
    worker.version = 2;
    final refreshed = service.create({...options, 'refresh': true});
    await waitJob(db, refreshed['id'] as String);
    expect(db.findActor(actor.id)!.stageName == '人工姓名', '强制获取保护手工姓名');
    expect(db.findActor(actor.id)!.birthplace == null, '人工清空字段不被重新补回');
    expect(db.findMovieForAdmin(film.id)!.title == '人工标题', '保护人工影片标题');
    final reviewItems =
        (db.scrapeJob(refreshed['id'] as String)!['items'] as List)
            .whereType<Map>()
            .where((t) => t['kind'] == 'movie' && t['status'] == 'review')
            .toList();
    expect(reviewItems.isNotEmpty, '覆盖冲突有明确审核项');
    await service.resolve(reviewItems.first['id'] as String, []);
    expect(db.findMovieForAdmin(film.id)!.title == '人工标题', '审核保留现有值');

    final images = service.create({
      'kind': 'movies',
      'movieIds': [film.id],
      'movieImages': true,
      'galleryLimit': 5
    });
    await waitJob(db, images['id'] as String);
    final withImages = db.findMovieForAdmin(film.id)!;
    expect(withImages.posterFileName != null, '海报进入幕境资产');
    expect(db.carouselImagesForMovie(film.id).length == 1, '重复封面和预览图按内容去重');
    expect(db.findActor(actor.id)!.photoAssetId != null, '演员头像进入管理资产');
    final assetsDir = Directory('$data/artwork/assets');
    final backupService = NasBackupService(data);
    final backup =
        await backupService.create(databaseSnapshot: db.createBackupSnapshot);
    final restored = Directory('${temp.path}/restored');
    await backupService.restoreToIsolatedDirectory(
        backupId: backup.id, target: restored);
    expect(
        await Directory('${restored.path}/artwork/assets').exists() &&
            await Directory('${restored.path}/artwork/carousel').exists(),
        '备份包含演员、厂商和轮播图片');
    expect((await assetsDir.list().toList()).isNotEmpty, '保存了实际图片文件');

    final ranking = service.create({'kind': 'actors', 'limit': 2});
    await waitJob(db, ranking['id'] as String);
    expect(db.listActors().length == 3, '前两位只新增两个来源演员');
    expect(
        !worker.calls.any((c) =>
            c['type'] == 'actor' && (c['url'] as String).contains('page=2')),
        '默认不遍历作品列表');
    final full =
        service.create({'kind': 'actors', 'limit': 1, 'filmography': true});
    await waitJob(db, full['id'] as String);
    expect(
        worker.calls.any((c) =>
            c['type'] == 'actor' && (c['url'] as String).contains('page=2')),
        '可选完整作品分页');

    await service.close();
    service = null;
    final pausedJob = db.createScrapeJob('重启恢复');
    final task = db.enqueueScrapeTask([pausedJob], 'actor', 'recovery',
        {'url': 'https://whatsav.net/zh/actor/recovery', 'name': '恢复演员'});
    expect(db.claimScrapeTask()?['id'] == task, '测试运行中任务');
    db.pauseScrapeJob(pausedJob, true);
    final snapshot = File('${temp.path}/backup.sqlite');
    await db.createBackupSnapshot(snapshot);
    await db.close();
    await db.open();
    expect(db.scrapeTask(task)!['status'] == 'pending', '重启恢复中断任务');
    expect(db.claimScrapeTask() == null, '手动暂停跨重启保留');
    service = NasScrapeService(db, NasArtworkService(data), worker,
        cacheDir: '$data/scraper')
      ..start();
    await service.control(pausedJob, 'resume');
    await waitJob(db, pausedJob);
    expect(db.scrapeTask(task)!['status'] == 'done', '恢复任务执行完成');
    expect(await snapshot.length() > 0, '队列和正式资料可在同库备份');
    stdout.writeln('scrape_service_test: PASS');
  } finally {
    await service?.close();
    await db.close();
    await temp.delete(recursive: true);
  }
}

Future<void> waitJob(NasLibraryDatabase db, String id) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    final counts = db.scrapeJob(id)!['counts'] as Map;
    if (!['pending', 'running', 'retry']
        .any((s) => (counts[s] as int? ?? 0) > 0)) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('任务未完成：${db.scrapeJob(id)}');
}

class FakeWorker implements NasScrapeWorker {
  final calls = <Map<String, dynamic>>[];
  int version = 1;
  Map<String, dynamic>? asset;
  @override
  bool get available => true;
  Map<String, dynamic> entity(
          String kind, String namespace, String id, String name) =>
      {
        'id': '${kind}_${sha256.convert(utf8.encode(jsonEncode([
                  'whatsav',
                  kind,
                  namespace,
                  id
                ]))).toString().substring(0, 32)}',
        'kind': kind,
        'name': name,
        'namespace': namespace,
        'sourceId': id,
        'provisional': false,
        'url': 'https://whatsav.net/zh/$namespace/$id',
        'role': kind == 'actor' ? 'cast' : namespace,
      };
  @override
  Future<Map<String, dynamic>> execute(Map<String, dynamic> input) async {
    calls.add(input);
    if (input['type'] == 'movie')
      return {
        'metadata': {
          'title': '来源影片 ${input['code']} v$version',
          'code': input['code'],
          'summary': '来源简介',
          'artwork': {},
          'source': {'name': 'whatsav', 'url': 'https://whatsav.net/zh/video/1'}
        },
        'entities': [
          entity('actor', 'actor', '7', '来源演员'),
          entity('company', 'maker', '1', '同名厂商'),
          entity('company', 'label', '1', '同名厂商')
        ],
        'assets': input['movieImages'] == true && asset != null
            ? {'poster': asset, 'cover': asset, 'gallery-1': asset}
            : {},
        'warnings': [],
      };
    if (input['type'] == 'actor') {
      final uri = Uri.parse(input['url'] as String), id = uri.pathSegments.last;
      final page = uri.queryParameters['page'] ?? '1';
      return {
        'profile': {
          'name': id == '7' ? '来源演员' : '排名演员$id',
          'aliases': ['别名$id'],
          'birthDate': '1990-01-02',
          'birthplace': '来源出生地',
          'source': {'name': 'whatsav', 'id': id, 'url': uri.toString()}
        },
        'assets': asset == null ? {} : {'avatar': asset},
        'warnings': [],
        'works': [
          {
            'sourceId': 'work-$page',
            'code': 'ABC-001',
            'title': '作品',
            'url': 'https://whatsav.net/zh/video/$page'
          }
        ],
        'nextUrl':
            page == '1' ? 'https://whatsav.net/zh/actor/$id?page=2' : null
      };
    }
    if (input['type'] == 'company')
      return {
        'profile': {
          'name': '同名厂商',
          'countryRegion': '来源国家',
          'foundedDate': null,
          'source': {'name': 'whatsav', 'url': input['url']}
        },
        'assets': asset == null ? {} : {'logo': asset},
        'warnings': []
      };
    if (input['type'] == 'ranking')
      return {
        'items': [
          for (final id in ['11', '12', '13'])
            {'name': '排名演员$id', 'url': 'https://whatsav.net/zh/actor/$id'}
        ],
        'nextUrl': null
      };
    return {};
  }

  @override
  void cancel() {}
  @override
  Future<void> close() async {}
}
