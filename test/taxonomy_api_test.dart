import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-nas-taxonomy-test-');
  final mediaRoot =
      Directory('${directory.path}${Platform.pathSeparator}media');
  final video = File('${mediaRoot.path}${Platform.pathSeparator}sample.mp4');
  await video.parent.create(recursive: true);
  await video.writeAsBytes(List<int>.generate(12, (index) => index));
  final server = NasHealthServer(
    NasConfig(
      bindHost: '127.0.0.1',
      port: 0,
      serverName: 'Test NAS',
      advertiseUrl: null,
      pairingCode: 'test-pairing-code',
      fixtureMediaRelativePath: null,
      mediaRootName: '测试媒体根',
      scanOnStart: true,
      dataDir: '${directory.path}${Platform.pathSeparator}data',
      mediaDir: mediaRoot.path,
      timezone: 'Asia/Shanghai',
    ),
  );

  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await _request(base, 'GET', '/api/v1/server-info');
    final serverId =
        (info.json['data'] as Map<String, dynamic>)['serverId'] as String;
    final viewerToken = await _pair(base, serverId);
    final adminToken = await _pair(base, serverId, scope: 'admin');

    final viewerOverview = await _request(
      base,
      'GET',
      '/api/v1/admin/tag-management/overview',
      token: viewerToken,
    );
    _expectError(viewerOverview, HttpStatus.forbidden, 'insufficient_scope');

    final genre = await _createTag(base, adminToken, name: '题材', level: 1);
    final mood = await _createTag(base, adminToken, name: '氛围', level: 1);
    final crime = await _createTag(
      base,
      adminToken,
      name: '刑侦',
      level: 2,
      parents: [genre['id'] as String, mood['id'] as String],
    );
    final noir = await _createTag(
      base,
      adminToken,
      name: '黑色电影',
      level: 2,
      parents: [genre['id'] as String],
    );
    final deduction = await _createTag(
      base,
      adminToken,
      name: '本格推理',
      description: '直接关联影片只在本标签展示',
      color: '#0FAF8F',
      level: 3,
      parents: [crime['id'] as String, noir['id'] as String],
    );
    _expect(deduction['level'] == 3 && deduction['description'] != null,
        '三级标签资料被保存');

    final overview = await _request(
      base,
      'GET',
      '/api/v1/admin/tag-management/overview',
      token: adminToken,
    );
    final overviewData = overview.json['data'] as Map<String, dynamic>;
    _expect(
      overviewData['total'] == 5 &&
          overviewData['levelOne'] == 2 &&
          overviewData['levelTwo'] == 2 &&
          overviewData['levelThree'] == 1,
      '概览由服务端计算三级数量',
    );

    final directoryResponse = await _request(
      base,
      'GET',
      '/api/v1/admin/tag-management/directory?q=${Uri.encodeQueryComponent('刑')}',
      token: adminToken,
    );
    final directoryItems = ((directoryResponse.json['data']
            as Map<String, dynamic>)['items'] as List)
        .cast<Map<String, dynamic>>();
    _expect(directoryItems.length == 2, '目录搜索只返回匹配二级关系的一级节点');
    _expect(
      directoryItems.every((root) => (root['children'] as List).any((child) =>
          (child as Map<String, dynamic>)['tag']['id'] == crime['id'])),
      '多父二级标签在两个一级节点下展示',
    );

    final details = await _request(
      base,
      'GET',
      '/api/v1/admin/tag-management/tags/${deduction['id']}?contextParentId=${crime['id']}&contextRootId=${mood['id']}',
      token: adminToken,
    );
    final detailData = details.json['data'] as Map<String, dynamic>;
    final pathNames = (detailData['path'] as List)
        .map((item) => (item as Map<String, dynamic>)['name'])
        .toList();
    _expect(pathNames.toString() == '[氛围, 刑侦, 本格推理]', '三级路径保留进入的一级和二级上下文');
    _expect((detailData['parents'] as List).length == 2, '详情同时展示三级标签的全部父级');

    final changedLevel = await _request(
      base,
      'PATCH',
      '/api/v1/admin/tag-management/tags/${deduction['id']}',
      token: adminToken,
      body: {
        'name': deduction['name'],
        'description': deduction['description'],
        'color': deduction['color'],
        'level': 2,
        'parentIds': [crime['id']],
      },
    );
    _expectError(changedLevel, HttpStatus.badRequest, 'invalid_request');
    final removedLastParent = await _request(
      base,
      'PATCH',
      '/api/v1/admin/tag-management/tags/${deduction['id']}',
      token: adminToken,
      body: {
        'name': deduction['name'],
        'description': deduction['description'],
        'color': deduction['color'],
        'parentIds': <String>[],
      },
    );
    _expectError(removedLastParent, HttpStatus.badRequest, 'invalid_request');

    final movies =
        await _request(base, 'GET', '/api/v1/movies', token: viewerToken);
    final movie =
        ((movies.json['data'] as Map<String, dynamic>)['items'] as List).single
            as Map<String, dynamic>;
    final movieId = movie['id'] as String;
    final linked = await _request(
      base,
      'PATCH',
      '/api/v1/admin/movies/$movieId',
      token: adminToken,
      body: {
        'tagIds': [deduction['id']]
      },
    );
    _expect(linked.statusCode == HttpStatus.ok, '影片关联标签实体 ID');
    final directMovies = await _request(
      base,
      'GET',
      '/api/v1/admin/tag-management/tags/${deduction['id']}/movies?page=1&pageSize=15',
      token: adminToken,
    );
    final secondLevelMovies = await _request(
      base,
      'GET',
      '/api/v1/admin/tag-management/tags/${crime['id']}/movies?page=1&pageSize=15',
      token: adminToken,
    );
    final firstLevelMovies = await _request(
      base,
      'GET',
      '/api/v1/admin/tag-management/tags/${mood['id']}/movies?page=1&pageSize=15',
      token: adminToken,
    );
    _expect(
        _pageTotal(directMovies) == 1 &&
            _pageTotal(secondLevelMovies) == 1 &&
            _pageTotal(firstLevelMovies) == 1,
        '递归聚合按影片 ID 去重');

    for (var index = 0; index < 12; index++) {
      await _createTag(
        base,
        adminToken,
        name: '刑侦子级 $index',
        level: 3,
        parents: [crime['id'] as String],
      );
    }
    final firstChildren = await _request(
      base,
      'GET',
      '/api/v1/admin/tag-management/tags/${crime['id']}/children?sort=name&order=asc&page=1&pageSize=10',
      token: adminToken,
    );
    final secondChildren = await _request(
      base,
      'GET',
      '/api/v1/admin/tag-management/tags/${crime['id']}/children?sort=name&order=asc&page=2&pageSize=10',
      token: adminToken,
    );
    _expect(
        _pageItems(firstChildren).length == 10 &&
            _pageItems(secondChildren).length == 3,
        '直属子标签固定十条分页');
    final linkedChildren = await _request(
      base,
      'GET',
      '/api/v1/admin/tag-management/tags/${crime['id']}/children?scope=linked&page=1&pageSize=10',
      token: adminToken,
    );
    _expect(_pageTotal(linkedChildren) == 1, '直属子标签支持已关联筛选');

    final candidates = await _request(
      base,
      'GET',
      '/api/v1/admin/tag-management/parent-candidates?level=2&page=1&pageSize=20',
      token: adminToken,
    );
    _expect(_pageItems(candidates).length == 2, '新增二级标签按需取得一级父级候选');
    final template = await _request(
      base,
      'GET',
      '/api/v1/admin/tag-management/template',
      token: adminToken,
    );
    final templateData = template.json['data'] as Map<String, dynamic>;
    final templateTags = templateData['tags'] as List;
    _expect(
      templateData['version'] == 2 &&
          templateTags.length == 4 &&
          (templateTags.last as Map<String, dynamic>)['level'] == 3 &&
          ((templateTags.last as Map<String, dynamic>)['parents'] as List)
                  .length ==
              2,
      '下载的是包含三级多父示例的导入模板',
    );
    final exported = await _request(
      base,
      'GET',
      '/api/v1/admin/tag-management/export',
      token: adminToken,
    );
    final exportData = exported.json['data'] as Map<String, dynamic>;
    _expect(
      exportData['version'] == 2 && (exportData['tags'] as List).isNotEmpty,
      '标签导出返回当前三级标签定义',
    );

    final conflictImport = await _request(
      base,
      'POST',
      '/api/v1/admin/tag-management/import',
      token: adminToken,
      body: {
        'format': 'mujing-tags',
        'version': 2,
        'tags': [
          {'name': '无归属二级', 'level': 2, 'parents': <String>[]},
        ],
      },
    );
    _expect(conflictImport.statusCode == HttpStatus.conflict, '导入冲突整体拒绝写入');

    final deleteLinked = await _request(
      base,
      'DELETE',
      '/api/v1/admin/tag-management/tags/${deduction['id']}',
      token: adminToken,
    );
    _expectError(deleteLinked, HttpStatus.conflict, 'tag_has_references');
    final archived = await _request(
      base,
      'POST',
      '/api/v1/admin/tag-management/tags/${deduction['id']}/archive',
      token: adminToken,
    );
    _expect(archived.statusCode == HttpStatus.ok, '有关联影片的标签可以归档');
    final selectable = await _request(
      base,
      'GET',
      '/api/v1/admin/tag-management/selectable?level=3&page=1&pageSize=50',
      token: adminToken,
    );
    _expect(
        !_pageItems(selectable).any((item) => item['id'] == deduction['id']),
        '归档标签不出现在影片选择器分页结果');
    final historical = await _request(base, 'GET', '/api/v1/movies/$movieId',
        token: viewerToken);
    _expect(
      ((historical.json['data'] as Map<String, dynamic>)['tags'] as List)
          .any((tag) => (tag as Map<String, dynamic>)['id'] == deduction['id']),
      '归档后历史影片仍展示标签',
    );
    final preserveArchived = await _request(
      base,
      'PATCH',
      '/api/v1/admin/movies/$movieId',
      token: adminToken,
      body: {
        'tagIds': [deduction['id']]
      },
    );
    _expect(
      preserveArchived.statusCode == HttpStatus.ok,
      '编辑历史影片时可以保留其已归档标签',
    );
  } finally {
    await server.stop();
    await directory.delete(recursive: true);
  }

  stdout.writeln('taxonomy_api_test: PASS');
}

Future<Map<String, dynamic>> _createTag(
  Uri base,
  String token, {
  required String name,
  required int level,
  String description = '',
  String? color,
  List<String> parents = const [],
}) async {
  final response = await _request(
    base,
    'POST',
    '/api/v1/admin/tag-management/tags',
    token: token,
    body: {
      'name': name,
      'description': description,
      'color': color,
      'level': level,
      'parentIds': parents,
    },
  );
  _expect(response.statusCode == HttpStatus.created, '管理员创建三级标签');
  return response.json['data'] as Map<String, dynamic>;
}

int _pageTotal(_Response response) =>
    (response.json['page'] as Map<String, dynamic>)['total'] as int;

List<Map<String, dynamic>> _pageItems(_Response response) =>
    ((response.json['data'] as Map<String, dynamic>)['items'] as List)
        .cast<Map<String, dynamic>>();

Future<String> _pair(Uri base, String serverId, {String? scope}) async {
  final session = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions',
    body: {'serverId': serverId, if (scope != null) 'requestedScope': scope},
  );
  final sessionId = (session.json['data']
      as Map<String, dynamic>)['pairingSessionId'] as String;
  final confirmed = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions/$sessionId/confirm',
    body: {'pairingPassword': 'test-pairing-code'},
  );
  return (confirmed.json['data'] as Map<String, dynamic>)['accessToken']
      as String;
}

Future<_Response> _request(
  Uri base,
  String method,
  String path, {
  Object? body,
  String? token,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, base.resolve(path));
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return _Response(
      response.statusCode,
      text.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>,
    );
  } finally {
    client.close(force: true);
  }
}

class _Response {
  const _Response(this.statusCode, this.json);

  final int statusCode;
  final Map<String, dynamic> json;
}

void _expectError(_Response response, int statusCode, String code) {
  _expect(response.statusCode == statusCode, '响应状态为 $statusCode');
  _expect(response.json['error']['code'] == code, '响应错误码为 $code');
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('Assertion failed: $message');
}
