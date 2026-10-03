import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';
import 'scrape_service_test.dart' show FakeWorker, expect;

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('mujing-scrape-api-');
  final media = await Directory('${temp.path}/media').create();
  final worker = FakeWorker();
  final library = NasLibraryDatabase('${temp.path}/data');
  final server = NasHealthServer(
      NasConfig(
          bindHost: '127.0.0.1',
          port: 0,
          serverName: 'Test',
          advertiseUrl: null,
          pairingCode: 'test-pairing-code',
          fixtureMediaRelativePath: null,
          mediaRootName: '测试盘',
          scanOnStart: false,
          dataDir: '${temp.path}/data',
          mediaDir: media.path,
          timezone: 'Asia/Shanghai'),
      scrapeWorker: worker, libraryDatabase: library);
  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await request(base, 'GET', '/api/v1/server-info');
    final data = info.$2['data'] as Map;
    expect(
        (data['capabilities'] as Map)['builtinScraping'] == true, '声明内置刮削能力');
    Future<String> pair(String scope) async {
      final session = await request(base, 'POST', '/api/v1/pairing/sessions',
          body: {'serverId': data['serverId'], 'requestedScope': scope});
      final id = (session.$2['data'] as Map)['pairingSessionId'];
      final result = await request(
          base, 'POST', '/api/v1/pairing/sessions/$id/confirm',
          body: {'pairingPassword': 'test-pairing-code'});
      return (result.$2['data'] as Map)['accessToken'] as String;
    }

    final viewer = await pair('viewer'), admin = await pair('admin');
    expect((await request(base, 'GET', '/api/v1/admin/scraping')).$1 == 401,
        '匿名无权查看任务');
    expect(
        (await request(base, 'POST', '/api/v1/admin/scraping/jobs',
                    token: viewer, body: {'kind': 'actors'}))
                .$1 ==
            403,
        'viewer 不能开始刮削');
    expect(
        (await request(base, 'POST', '/api/v1/admin/scraping/settings',
                    token: admin,
                    body: {'minIntervalSeconds': 30, 'maxIntervalSeconds': 10}))
                .$1 ==
            400,
        '间隔校验');
    expect(
        (await request(base, 'POST', '/api/v1/admin/scraping/jobs',
                    token: admin, body: {'kind': 'movies'}))
                .$1 ==
            400,
        '空片库不开始全库任务');
    expect(
        (await request(base, 'POST', '/api/v1/admin/scraping/jobs',
                    token: admin, body: {'kind': 'actors', 'limit': 0}))
                .$1 ==
            400,
        '排名数量校验');
    final created = await request(base, 'POST', '/api/v1/admin/scraping/jobs',
        token: admin, body: {'kind': 'actors', 'limit': 2});
    expect(created.$1 == 202, '异步创建排名任务');
    final jobId = (created.$2['data'] as Map)['id'];
    final end = DateTime.now().add(const Duration(seconds: 10));
    Map result = {};
    while (DateTime.now().isBefore(end)) {
      result = (await request(base, 'GET', '/api/v1/admin/scraping/jobs/$jobId',
              token: admin))
          .$2['data'] as Map;
      if ((result['counts'] as Map)['done'] == 3) break;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    expect((result['counts'] as Map)['done'] == 3, '后台完成排名及演员任务');
    final actors = await request(base, 'GET', '/api/v1/actors', token: viewer);
    expect(((actors.$2['data'] as Map)['items'] as List).length == 2,
        'Android viewer 可通过现有接口读取新演员');
    final listed =
        await request(base, 'GET', '/api/v1/admin/scraping', token: admin);
    expect(!jsonEncode(listed.$2).contains(temp.path), '管理接口不泄露宿主路径');
    expect(
        (await request(base, 'POST', '/api/v1/admin/scraping/jobs/$jobId/pause',
                    token: admin))
                .$1 ==
            200,
        '暂停入口');
    expect(
        (await request(
                    base, 'POST', '/api/v1/admin/scraping/jobs/$jobId/resume',
                    token: admin))
                .$1 ==
            200,
        '继续入口');
    expect(
        (await request(base, 'POST', '/api/v1/admin/scraping/jobs/$jobId/retry',
                    token: admin))
                .$1 ==
            200,
        '重试入口');
    expect(
        (await request(base, 'GET', '/api/v1/admin/scraping?offset=-1',
                    token: admin))
                .$1 ==
            400,
        '分页校验');
    final reviewJob = library.createScrapeJob('身份审核');
    library.pauseScrapeJob(reviewJob, true);
    final candidate = library.listActors().first;
    final task = library.enqueueScrapeTask([reviewJob], 'actor', 'manual-identity', {'name': '同名演员'});
    final source = worker.entity('actor', 'actor', 'manual-identity', '同名演员');
    library.finishScrapeTask(task, 'review', conflicts: [{
      'field': 'identity', 'sourceKey': source['id'], 'sourceUrl': source['url'],
      'candidates': [{'id': candidate.id}],
    }]);
    final resolution = {'fields': <String>[], 'actorMappings': {source['id'] as String: candidate.id}};
    expect((await request(base, 'POST', '/api/v1/admin/scraping/tasks/$task/resolve',
        token: viewer, body: resolution)).$1 == 403, '普通用户不能确认演员来源身份');
    expect((await request(base, 'POST', '/api/v1/admin/scraping/tasks/$task/resolve',
        token: admin, body: {'fields': [], 'actorMappings': []})).$1 == 400, '拒绝非法身份映射结构');
    expect((await request(base, 'POST', '/api/v1/admin/scraping/tasks/$task/resolve',
        token: admin, body: resolution)).$1 == 200, '管理员可以确认来源身份');
    expect(library.scrapeEntity(source) == candidate.id && library.scrapeTask(task)!['status'] == 'pending',
        '身份确认后沿用同一演员并准备继续任务');
    stdout.writeln('scrape_api_test: PASS');
  } finally {
    await server.stop();
    await temp.delete(recursive: true);
  }
}

Future<(int, Map<String, dynamic>)> request(
    Uri base, String method, String path,
    {String? token, Map<String, dynamic>? body}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, base.resolve(path));
    if (token != null) req.headers.set('Authorization', 'Bearer $token');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final response = await req.close();
    return (
      response.statusCode,
      jsonDecode(await utf8.decoder.bind(response).join())
          as Map<String, dynamic>
    );
  } finally {
    client.close(force: true);
  }
}
