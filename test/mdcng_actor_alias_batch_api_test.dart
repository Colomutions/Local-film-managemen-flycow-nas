import 'dart:io';

import '../lib/mujing_nas.dart';
import '../lib/src/library/mdcng_nfo.dart';
import 'scrape_api_test.dart' show request;

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

// 可传入本地 NFO，使用真实字段复现；默认 fixture 不依赖个人文件。
Future<void> main(List<String> arguments) async {
  final nfo = arguments.isEmpty
      ? '<movie><title>演员别名回归</title><num>TEST-085</num><plot>测试简介</plot>'
          '<actor><name>妃月るい</name></actor>'
          '<actor><name>音琴るい</name></actor>'
          '<actor><name>另一位演员</name></actor></movie>'
      : await File(arguments.single).readAsString();
  final parsed = const MdcngNfoParser().parse(nfo);
  check(
      parsed.actors.any((actor) => actor.name == '妃月るい') &&
          parsed.actors.any((actor) => actor.name == '音琴るい'),
      '输入包含两个演员名称');
  final temp = await Directory.systemTemp.createTemp('mujing-mdcng-alias-');
  final media = Directory('${temp.path}${Platform.pathSeparator}media');
  final directory = Directory('${media.path}${Platform.pathSeparator}disk1'
      '${Platform.pathSeparator}影片');
  await directory.create(recursive: true);
  await File('${directory.path}${Platform.pathSeparator}TEST-085.mp4')
      .writeAsBytes([1, 2, 3]);
  await File('${directory.path}${Platform.pathSeparator}TEST-085.nfo')
      .writeAsString(nfo);
  final db = NasLibraryDatabase('${temp.path}${Platform.pathSeparator}data');
  final server = NasHealthServer(
    NasConfig(
      bindHost: '127.0.0.1',
      port: 0,
      serverName: 'Test',
      advertiseUrl: null,
      pairingCode: 'test-pairing-code',
      fixtureMediaRelativePath: null,
      mediaRootName: '测试',
      scanOnStart: false,
      managedCategoryLibrary: true,
      dataDir: db.dataDir,
      mediaDir: media.path,
      timezone: 'Asia/Shanghai',
    ),
    libraryDatabase: db,
  );
  try {
    await server.start();
    final sharedActor = db.createActor(stageName: '音琴るい', aliases: ['妃月るい']);
    final expectedActorIds = {sharedActor.id};
    for (final name in parsed.actors.map((actor) => actor.name).toSet()) {
      if (name == '妃月るい' || name == '音琴るい') continue;
      expectedActorIds.add(db.createActor(stageName: name).id);
    }
    check(
        db.findActiveActorByExactName('妃月るい')!.id == sharedActor.id &&
            db.findActiveActorByExactName('音琴るい')!.id == sharedActor.id,
        '不同名称精确匹配到同一演员 ID');
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await request(base, 'GET', '/api/v1/server-info');
    final session =
        await request(base, 'POST', '/api/v1/pairing/sessions', body: {
      'serverId': info.$2['data']['serverId'],
      'requestedScope': 'admin',
    });
    final paired = await request(base, 'POST',
        '/api/v1/pairing/sessions/${session.$2['data']['pairingSessionId']}/confirm',
        body: {'pairingPassword': 'test-pairing-code'});
    final token = paired.$2['data']['accessToken'] as String;
    Future<Map> waitForJob(String path) async {
      for (var i = 0; i < 200; i++) {
        final response = await request(base, 'GET', path, token: token);
        check(response.$1 == 200, '查询任务成功');
        final job = response.$2['data'] as Map;
        if (job['status'] == 'succeeded') return job;
        check(job['status'] != 'failed', '任务未中断');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      throw StateError('任务超时');
    }

    final category = await request(base, 'POST', '/api/v1/admin/categories',
        token: token, body: {'name': '影片', 'directoryKey': 'disk1/影片'});
    check(category.$1 == 201, '创建分类成功');
    final categoryId = category.$2['data']['id'] as String;
    await waitForJob(
        '/api/v1/admin/scan-jobs/${category.$2['data']['scanJob']['id']}');
    final batch = await request(base, 'POST', '/api/v1/admin/mdcng-import-jobs',
        token: token, body: {'categoryId': categoryId});
    final done = await waitForJob(
        '/api/v1/admin/mdcng-import-jobs/${batch.$2['data']['id']}');
    check(done['failed'] == 0 && done['applied'] == 1,
        '别名同 ID 的演员名单应正常导入，实际结果：$done');
    final movie = db.listMovies().single;
    final actorIds =
        db.actorsForMovie(movie.id).map((actor) => actor.id).toSet();
    check(
        actorIds.length == expectedActorIds.length &&
            actorIds.containsAll(expectedActorIds),
        '保留所有不同演员，每个 ID 只关联一次');
    check(movie.title == parsed.title && movie.summary == parsed.plot,
        '演员别名不阻止其他 NFO 文本字段导入');
    stdout.writeln(
        'mdcng_actor_alias_batch_api_test: PASS (${parsed.actors.length} NFO names, ${actorIds.length} linked actors)');
  } finally {
    await server.stop();
    if (!temp.absolute.path.startsWith(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}')) {
      throw StateError('临时目录边界无效');
    }
    await temp.delete(recursive: true);
  }
}
