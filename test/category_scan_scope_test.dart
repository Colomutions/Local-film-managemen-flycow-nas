import 'dart:async';
import 'dart:io';
import '../lib/mujing_nas.dart';
import 'scrape_api_test.dart' show request;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

class ScopeDatabase extends NasLibraryDatabase {
  ScopeDatabase(super.dataDir);
  final categories = <String>[];
  final probed = <String>[];
  Completer<void>? scanGate;
  @override
  Future<NasScanResult> scanCategory({required String categoryId,
      Future<void> Function()? beforeFile, required String mediaRootId,
      required NasMediaService mediaService,
      NasMediaMetadataProbe metadataProbe = const NasMediaMetadataProbe()}) async {
    categories.add(categoryId);
    await scanGate?.future;
    return super.scanCategory(categoryId: categoryId, beforeFile: beforeFile,
      mediaRootId: mediaRootId, mediaService: mediaService,
      metadataProbe: NasMediaMetadataProbe(runner: (_, args) async {
        probed.add(args.last.replaceAll('\\', '/'));
        return ProcessResult(0, 0, '{"streams":[],"format":{}}', '');
      }));
  }
}

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('mujing-scan-scope-');
  final media = Directory('${temp.path}${Platform.pathSeparator}media');
  Future<void> video(String path) async {
    final file = File('${media.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1,2,3]);
  }
  await video('disk1/av/A1.mp4');
  await video('disk2/av/A2.mp4');
  await video('disk1/movies/B1.mp4');
  await video('disk2/av2/C1.mp4');
  await video('disk3/drama/D1.mp4');
  final db = ScopeDatabase('${temp.path}/data');
  final server = NasHealthServer(NasConfig(bindHost: '127.0.0.1', port: 0,
    serverName: '测试', advertiseUrl: null, pairingCode: 'test-pairing-code',
    fixtureMediaRelativePath: null, mediaRootName: '媒体库', scanOnStart: false,
    managedCategoryLibrary: true, dataDir: db.dataDir, mediaDir: media.path,
    timezone: 'Asia/Shanghai'), libraryDatabase: db);
  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await request(base,'GET','/api/v1/server-info');
    final session = await request(base,'POST','/api/v1/pairing/sessions',
      body: {'serverId': info.$2['data']['serverId'], 'requestedScope':'admin'});
    final paired = await request(base,'POST','/api/v1/pairing/sessions/${session.$2['data']['pairingSessionId']}/confirm',
      body: {'pairingPassword':'test-pairing-code'});
    final token = paired.$2['data']['accessToken'] as String;
    Future<Map> wait(String id) async {
      for (var i=0;i<200;i++) {
        final res = await request(base,'GET','/api/v1/admin/scan-jobs/$id',token:token);
        final job = res.$2['data'] as Map;
        if (job['status']=='succeeded') return job;
        check(job['status']!='failed', '扫描失败');
        await Future<void>.delayed(const Duration(milliseconds:20));
      }
      throw StateError('扫描超时');
    }
    Future<String> category(String name,List<String> paths) async {
      final res = await request(base,'POST','/api/v1/admin/categories',token:token,
        body:{'name':name,'directoryKeys': paths});
      check(res.$1==201, '创建分类 $name 失败：${res.$2}');
      await wait(res.$2['data']['scanJob']['id'] as String);
      return res.$2['data']['id'] as String;
    }
    final a = await category('AV',['disk1/av','disk2/av']);
    final b = await category('电影',['disk1/movies']);
    final c = await category('AV2',['disk2/av2']);
    final bMovie = db.listMovies().singleWhere((m)=>m.title=='B1');
    final cMovie = db.listMovies().singleWhere((m)=>m.title=='C1');
    final bEpisode = db.episodesForMovie(bMovie.id).single;
    final cEpisode = db.episodesForMovie(cMovie.id).single;
    await File('${media.path}/disk1/movies/B1.mp4').delete();
    await File('${media.path}/disk2/av2/C1.mp4').delete();
    await video('disk1/movies/B2.mp4');
    await video('disk2/av2/C2.mp4');
    await video('disk1/av/A3.mp4');
    await video('disk2/av/A4.mp4');
    db.categories.clear(); db.probed.clear();
    final scan = await request(base,'POST','/api/v1/admin/scan-jobs',token:token,body:{'categoryId':a});
    check(scan.$1==202 && scan.$2['data']['categoryId']==a,'任务保持当前分类身份');
    final done = await wait(scan.$2['data']['id'] as String);
    check(done['scannedFiles']==4 && done['availableEpisodes']==4,'数量仅为 AV 两个绑定目录的四个文件');
    check(db.categories.length==1 && db.categories.single==a,'仅调用一次当前分类扫描');
    check(db.probed.length==2 && db.probed.every((p)=>p.contains('/av/')),'只探测当前分类新增文件');
    check(db.findCategory(a)!.movieCount==4 && db.findCategory(b)!.movieCount==1 && db.findCategory(c)!.movieCount==1,
      '其他分类新增文件未入库');
    check(db.findEpisode(bEpisode.id)!.isAvailable && db.findEpisode(cEpisode.id)!.isAvailable &&
      db.findEpisode(bEpisode.id)!.updatedAt==bEpisode.updatedAt && db.findEpisode(cEpisode.id)!.updatedAt==cEpisode.updatedAt,
      '其他分类缺失文件没有被扫描或更新');
    check((await request(base,'POST','/api/v1/admin/scan-jobs',token:token,body:{})).$1==400,
      '缺少分类 ID 时不能降级为全库扫描');
    db.categories.clear(); db.probed.clear();
    final reordered = await request(base, 'PATCH', '/api/v1/admin/categories/$a', token: token,
      body: {'name': 'AV 重命名', 'directoryKeys': ['disk2/av', 'disk1/av']});
    check(reordered.$1 == 200 && reordered.$2['data']['scanJob'] == null,
      '只改名称或调整目录顺序不会自动扫描');
    await video('disk1/av/A5.mp4');
    await video('disk2/av/A6.mp4');
    final rebound = await request(base, 'PATCH', '/api/v1/admin/categories/$a', token: token,
      body: {'name': 'AV', 'directoryKeys': ['disk1/av']});
    check(rebound.$1 == 200 && rebound.$2['data']['scanJob']['categoryId'] == a,
      '移除第二个路径后只自动调度当前分类');
    final reboundDone = await wait(rebound.$2['data']['scanJob']['id'] as String);
    check(reboundDone['scannedFiles'] == 3 && reboundDone['removedEpisodes'] == 2,
      '自动扫描只读取保留目录，并移除已解绑目录的两个旧索引');
    check(db.categories.length == 1 && db.categories.single == a &&
      db.probed.length == 1 && db.probed.single.endsWith('/disk1/av/A5.mp4'),
      '没有扫描已解绑目录的新文件或其他分类');
    check(db.findCategory(a)!.movieCount == 3 && db.findCategory(b)!.movieCount == 1 &&
      db.findCategory(c)!.movieCount == 1 && db.findEpisode(bEpisode.id)!.isAvailable &&
      db.findEpisode(cEpisode.id)!.isAvailable, '修改路径没有更新其他分类索引');
    final overlapping = await request(base, 'PATCH', '/api/v1/admin/categories/$a', token: token,
      body: {'name': 'AV', 'directoryKeys': ['disk1']});
    if (overlapping.$1 == 200 && overlapping.$2['data']['scanJob'] != null) {
      await wait(overlapping.$2['data']['scanJob']['id'] as String);
    }
    check(overlapping.$1 == 400, '不能绑定包含其他分类目录的整盘路径');
    check(db.categories.length == 1 && db.findCategory(a)!.movieCount == 3,
      '拒绝重叠路径后不调度扫描或变更当前分类');
    final selfOverlap = await request(base, 'PATCH', '/api/v1/admin/categories/$a', token: token,
      body: {'name': 'AV', 'directoryKeys': ['disk3', 'disk3/drama']});
    check(selfOverlap.$1 == 400, '同一分类也不能绑定相互包含的目录');
    final disk3 = await category('整盘分类', ['disk3']);
    final childOverlap = await request(base, 'POST', '/api/v1/admin/categories', token: token,
      body: {'name': '子目录分类', 'directoryKeys': ['disk3/drama']});
    check(childOverlap.$1 == 400 && db.findCategory(disk3)!.movieCount == 1,
      '已绑定上级目录时也不能反向新建重叠分类');
    db.categories.clear();
    final gate = db.scanGate = Completer<void>();
    final firstQueued = await request(base, 'POST', '/api/v1/admin/scan-jobs', token: token,
      body: {'categoryId': b});
    final queuedRebind = await request(base, 'PATCH', '/api/v1/admin/categories/$a', token: token,
      body: {'name': 'AV', 'directoryKeys': ['disk1/av', 'disk2/av']});
    check(queuedRebind.$1 == 200 && queuedRebind.$2['data']['scanJob']['status'] == 'queued',
      '其他分类正在扫描时，改路径仅排入当前分类任务');
    final queuedJobId = queuedRebind.$2['data']['scanJob']['id'] as String;
    final duplicateScan = await request(base, 'POST', '/api/v1/admin/scan-jobs', token: token,
      body: {'categoryId': a});
    check(duplicateScan.$2['data']['id'] == queuedJobId, '再次点击重扫复用该分类已排队任务');
    final blockedRebind = await request(base, 'PATCH', '/api/v1/admin/categories/$a', token: token,
      body: {'name': 'AV', 'directoryKeys': ['disk1/av']});
    check(blockedRebind.$1 == 409 && blockedRebind.$2['error']['code'] == 'scan_running',
      '已排队的分类不能继续修改路径，避免旧任务读取过期绑定');
    gate.complete();
    db.scanGate = null;
    await wait(firstQueued.$2['data']['id'] as String);
    await wait(queuedJobId);
    check(db.categories.length == 2 && db.categories[0] == b && db.categories[1] == a,
      '只顺序执行原有其他分类任务和本次改路径任务，没有调度全库扫描');
    stdout.writeln('category_scan_scope_test: PASS');
  } finally {
    if (db.scanGate case final gate? when !gate.isCompleted) gate.complete();
    await server.stop();
    if(!temp.absolute.path.startsWith('${Directory.systemTemp.absolute.path}${Platform.pathSeparator}')) throw StateError('临时目录边界');
    await temp.delete(recursive:true);
  }
}
