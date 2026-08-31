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
  final config = NasConfig(
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
  );
  final server = NasHealthServer(config);

  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await _request(base, 'GET', '/api/v1/server-info');
    final serverId =
        (info.json['data'] as Map<String, dynamic>)['serverId'] as String;
    final viewerToken = await _pair(base, serverId);
    final adminToken = await _pair(base, serverId, scope: 'admin');

    final viewerCategories = await _request(
      base,
      'GET',
      '/api/v1/admin/categories',
      token: viewerToken,
    );
    _expectError(viewerCategories, HttpStatus.forbidden, 'insufficient_scope');
    final category = await _createNamed(
      base,
      '/api/v1/admin/categories',
      '刑侦',
      adminToken,
      color: '#123456',
    );
    _expect(category['color'] == '#123456', 'category create returns color');
    final duplicateCategory = await _request(
      base,
      'POST',
      '/api/v1/admin/categories',
      token: adminToken,
      body: {'name': '刑侦'},
    );
    _expectError(duplicateCategory, HttpStatus.badRequest, 'invalid_request');
    final renamedCategory = await _request(
      base,
      'PATCH',
      '/api/v1/admin/categories/${category['id']}',
      token: adminToken,
      body: {'name': '犯罪', 'color': '#654321'},
    );
    _expect(
        renamedCategory.statusCode == HttpStatus.ok, 'admin renames category');
    _expect(
      (renamedCategory.json['data'] as Map<String, dynamic>)['color'] ==
          '#654321',
      'category update persists color',
    );

    final rootTag = await _createNamed(
      base,
      '/api/v1/admin/tags',
      '题材',
      adminToken,
      color: '#0FAF8F',
    );
    _expect(rootTag['color'] == '#0FAF8F', 'tag create returns color');
    final childTag = await _createNamed(
      base,
      '/api/v1/admin/tags',
      '刑侦',
      adminToken,
      color: '#E86A33',
      parentTagId: rootTag['id'] as String,
    );
    final placements = await _request(
      base,
      'GET',
      '/api/v1/admin/tag-placements',
      token: adminToken,
    );
    final placementItems = ((placements.json['data']
            as Map<String, dynamic>)['items'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final rootPlacement = placementItems.singleWhere(
      (item) => item['tagId'] == rootTag['id'],
    );
    final childPlacement = placementItems.singleWhere(
      (item) => item['tagId'] == childTag['id'],
    );
    _expect(childPlacement['path'].toString() == '[题材, 刑侦]',
        'placement returns hierarchy path');
    final cycle = await _request(
      base,
      'PATCH',
      '/api/v1/admin/tag-placements/${rootPlacement['id']}',
      token: adminToken,
      body: {'parentPlacementId': childPlacement['id']},
    );
    _expectError(cycle, HttpStatus.badRequest, 'invalid_request');

    final movies =
        await _request(base, 'GET', '/api/v1/movies', token: viewerToken);
    final movie = ((movies.json['data'] as Map<String, dynamic>)['items']
            as List<dynamic>)
        .single as Map<String, dynamic>;
    final taxonomyUpdate = await _request(
      base,
      'PATCH',
      '/api/v1/admin/movies/${movie['id']}',
      token: adminToken,
      body: {
        'categoryId': category['id'],
        'tagPlacementIds': [childPlacement['id']],
      },
    );
    _expect(taxonomyUpdate.statusCode == HttpStatus.ok,
        'admin assigns category and tag placement');
    final details = await _request(
      base,
      'GET',
      '/api/v1/movies/${movie['id']}',
      token: viewerToken,
    );
    final data = details.json['data'] as Map<String, dynamic>;
    _expect(
        data['category']['name'] == '犯罪', 'viewer receives assigned category');
    _expect((data['tags'] as List<dynamic>).single['name'] == '刑侦',
        'viewer receives assigned tag');
    _expect((data['tagPaths'] as List<dynamic>).single.toString() == '[题材, 刑侦]',
        'viewer receives hierarchy path');
    _expect(!jsonEncode(data).contains(mediaRoot.path),
        'viewer taxonomy response hides media path');
    final categories = await _request(
      base,
      'GET',
      '/api/v1/admin/categories',
      token: adminToken,
    );
    final categoryDto = ((categories.json['data'] as Map<String, dynamic>)['items']
            as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .singleWhere((item) => item['id'] == category['id']);
    _expect(categoryDto['color'] == '#654321', 'category list returns color');
    final tags = await _request(
      base,
      'GET',
      '/api/v1/admin/tags',
      token: adminToken,
    );
    final rootTagDto = ((tags.json['data'] as Map<String, dynamic>)['items']
            as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .singleWhere((item) => item['id'] == rootTag['id']);
    _expect(rootTagDto['color'] == '#0FAF8F', 'tag list returns color');

    final renamedTag = await _request(
      base,
      'PATCH',
      '/api/v1/admin/tags/${childTag['id']}',
      token: adminToken,
      body: {'name': '推理', 'color': null},
    );
    _expect(renamedTag.statusCode == HttpStatus.ok, 'admin renames tag');
    _expect(
      (renamedTag.json['data'] as Map<String, dynamic>)['color'] == null,
      'tag color can be cleared without changing its placement',
    );
    final renamedDetails = await _request(
      base,
      'GET',
      '/api/v1/movies/${movie['id']}',
      token: viewerToken,
    );
    _expect(
        (renamedDetails.json['data']['tagPaths'] as List<dynamic>)
                .single
                .toString() ==
            '[题材, 推理]',
        'renamed tag updates browse path');

    final invalidTaxonomy = await _request(
      base,
      'PATCH',
      '/api/v1/admin/movies/${movie['id']}',
      token: adminToken,
      body: {'relativePath': '../forbidden.mp4'},
    );
    _expectError(invalidTaxonomy, HttpStatus.badRequest, 'invalid_request');
    final deletedCategory = await _request(
      base,
      'DELETE',
      '/api/v1/admin/categories/${category['id']}',
      token: adminToken,
    );
    _expect(deletedCategory.statusCode == HttpStatus.noContent,
        'admin deletes category');
    final directTagDelete = await _request(
      base,
      'DELETE',
      '/api/v1/admin/tags/${childTag['id']}',
      token: adminToken,
    );
    _expectError(
      directTagDelete,
      HttpStatus.badRequest,
      'invalid_request',
    );
    final deletedTagPlacement = await _request(
      base,
      'DELETE',
      '/api/v1/admin/tag-placements/${childPlacement['id']}',
      token: adminToken,
    );
    _expect(
      deletedTagPlacement.statusCode == HttpStatus.noContent,
      'deleting the last child placement deletes the tag',
    );
    final clearedDetails = await _request(
      base,
      'GET',
      '/api/v1/movies/${movie['id']}',
      token: viewerToken,
    );
    _expect(clearedDetails.json['data']['category'] == null,
        'deleted category clears movie assignment');
    _expect((clearedDetails.json['data']['tags'] as List<dynamic>).isEmpty,
        'deleted tag clears movie assignment');
  } finally {
    await server.stop();
    await directory.delete(recursive: true);
  }

  stdout.writeln('taxonomy_api_test: PASS');
}

Future<Map<String, dynamic>> _createNamed(
  Uri base,
  String path,
  String name,
  String token, {
  String? color,
  String? parentTagId,
}) async {
  final response = await _request(
    base,
    'POST',
    path,
    token: token,
    body: {
      'name': name,
      if (color != null) 'color': color,
      if (parentTagId != null) 'parentTagId': parentTagId,
    },
  );
  _expect(response.statusCode == HttpStatus.created,
      'admin creates named taxonomy entity');
  return response.json['data'] as Map<String, dynamic>;
}


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

Future<_Response> _request(Uri base, String method, String path,
    {Object? body, String? token}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, base.resolve(path));
    if (token != null)
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
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
            : jsonDecode(text) as Map<String, dynamic>);
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
  _expect(response.statusCode == statusCode, 'response status is $statusCode');
  _expect(response.json['error']['code'] == code, 'error code is $code');
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('Assertion failed: $message');
}
