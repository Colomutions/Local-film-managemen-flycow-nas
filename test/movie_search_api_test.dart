import 'dart:convert';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-nas-movie-search-test-');
  final mediaRoot =
      Directory('${directory.path}${Platform.pathSeparator}media');
  for (final name in ['alpha.mp4', 'beta.mp4', 'gamma.mp4']) {
    final file = File('${mediaRoot.path}${Platform.pathSeparator}$name');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(24, 1));
  }
  final database =
      NasLibraryDatabase('${directory.path}${Platform.pathSeparator}data');
  final mediaService = NasMediaService(
    mediaDir: mediaRoot.path,
    fixtureRelativePath: null,
  );
  await database.open();
  final root = database.ensureConfiguredMediaRoot(
    rootName: '测试媒体根',
    containerPath: mediaRoot.path,
  );
  await database.scanMediaRoot(
    mediaRootId: root.id,
    mediaService: mediaService,
    metadataProbe: NasMediaMetadataProbe(
      runner: (_, __) async => ProcessResult(
        0,
        0,
        '{"streams":[{"width":1920,"height":1080}],"format":{"duration":"12"}}',
        '',
      ),
    ),
  );
  final server = NasHealthServer(
    NasConfig(
      bindHost: '127.0.0.1',
      port: 0,
      serverName: 'Test NAS',
      advertiseUrl: null,
      pairingCode: 'test-pairing-code',
      fixtureMediaRelativePath: null,
      mediaRootName: '测试媒体根',
      scanOnStart: false,
      dataDir: '${directory.path}${Platform.pathSeparator}data',
      mediaDir: mediaRoot.path,
      timezone: 'Asia/Shanghai',
    ),
    libraryDatabase: database,
    mediaService: mediaService,
  );

  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await _request(base, 'GET', '/api/v1/server-info');
    final serverId =
        (info.json['data'] as Map<String, dynamic>)['serverId'] as String;
    final viewerToken = await _pair(base, serverId, scope: 'viewer');
    final adminToken = await _pair(base, serverId, scope: 'admin');
    final movies =
        await _request(base, 'GET', '/api/v1/movies', token: viewerToken);
    final movieIds = <String, String>{
      for (final item in ((movies.json['data'] as Map)['items'] as List))
        (item as Map)['title'] as String: item['id'] as String,
    };
    final category = await _request(
      base,
      'POST',
      '/api/v1/admin/categories',
      token: adminToken,
      body: {'name': '推理'},
    );
    final categoryId = (category.json['data'] as Map)['id'] as String;
    final rootOne = await _tag(base, adminToken, name: '题材', level: 1);
    final rootTwo = await _tag(base, adminToken, name: '氛围', level: 1);
    final second = await _tag(
      base,
      adminToken,
      name: '刑侦',
      level: 2,
      parents: [rootOne, rootTwo],
    );
    final third = await _tag(
      base,
      adminToken,
      name: '本格推理',
      level: 3,
      parents: [second],
    );
    await _patchMovie(base, adminToken, movieIds['alpha']!, [third]);
    await _patchMovie(
        base, adminToken, movieIds['beta']!, [second], categoryId);
    await _patchMovie(base, adminToken, movieIds['gamma']!, [rootTwo]);

    final combined = await _search(base, viewerToken, {
      'all': [
        {'tagId': rootOne, 'includeDescendants': true},
      ],
      'any': [
        {'tagId': second, 'includeDescendants': true},
      ],
      'exclude': [
        {'tagId': third, 'includeDescendants': false},
      ],
    });
    _expect(
      _ids(combined).single == movieIds['beta'],
      'all / any / exclude 在 SQLite 中组合匹配',
    );

    final exactThird = await _search(base, viewerToken, {
      'all': [
        {'tagId': third, 'includeDescendants': false},
      ],
      'any': [],
      'exclude': [],
    });
    _expect(
      _ids(exactThird).single == movieIds['alpha'],
      '三级标签只匹配自身',
    );

    final multiParent = await _search(base, viewerToken, {
      'all': [
        {'tagId': rootTwo, 'includeDescendants': true},
      ],
      'any': [],
      'exclude': [],
    });
    _expect(
      _ids(multiParent).toSet().length == 3,
      '多父路径按影片实体去重',
    );

    final filtered = await _search(
      base,
      viewerToken,
      {'all': [], 'any': [], 'exclude': []},
      q: 'beta',
      categoryId: categoryId,
      resolutions: const ['1080P'],
    );
    _expect(_ids(filtered).single == movieIds['beta'], '关键词、分类与分辨率共同筛选');

    final betaEpisode = database.episodesForMovie(movieIds['beta']!).single;
    database
      ..recordPlaybackStarted(
        movieId: movieIds['beta']!,
        episodeId: betaEpisode.id,
      )
      ..savePlaybackProgress(
        movieId: movieIds['beta']!,
        episodeId: betaEpisode.id,
        positionMs: 3000,
        durationMs: 12000,
      );
    final continuing = await _search(
      base,
      viewerToken,
      {'all': [], 'any': [], 'exclude': []},
      watchStates: const ['continue'],
    );
    _expect(
      _ids(continuing).single == movieIds['beta'],
      '继续观看按 NAS 汇总的分集进度筛选',
    );
    final unwatched = await _search(
      base,
      viewerToken,
      {'all': [], 'any': [], 'exclude': []},
      watchStates: const ['unwatched'],
    );
    _expect(
      _ids(unwatched).toSet().containsAll([
            movieIds['alpha']!,
            movieIds['gamma']!,
          ]) &&
          !_ids(unwatched).contains(movieIds['beta']),
      '未观看以 NAS 全局播放历史为准，不区分客户端设备',
    );

    database
      ..updateMovieMetadata(movieId: movieIds['alpha']!, title: 'Orbit')
      ..updateMovieMetadata(
        movieId: movieIds['beta']!,
        summary: 'Orbit documentary',
      )
      ..updateMovieMetadata(
        movieId: movieIds['gamma']!,
        originalTitle: 'Orbit Origin',
        updateOriginalTitle: true,
      );
    final relevance = await _search(
      base,
      viewerToken,
      {'all': [], 'any': [], 'exclude': []},
      q: 'Orbit',
      sort: 'relevance',
      order: 'desc',
    );
    _expect(
      _ids(relevance).take(3).join('|') ==
          [
            movieIds['alpha']!,
            movieIds['gamma']!,
            movieIds['beta']!,
          ].join('|'),
      '相关度按标题、原名、番号、演员、标签、简介依次降权排序',
    );

    final first = await _search(
      base,
      viewerToken,
      {'all': [], 'any': [], 'exclude': []},
      page: 1,
      pageSize: 1,
    );
    final secondPage = await _search(
      base,
      viewerToken,
      {'all': [], 'any': [], 'exclude': []},
      page: 2,
      pageSize: 1,
    );
    _expect(
      _ids(first).single != _ids(secondPage).single &&
          (first.json['page'] as Map)['total'] == 3,
      '排序使用稳定次级键，分页不重复',
    );

    final directoryResponse = await _request(
      base,
      'GET',
      '/api/v1/movie-search/tags/directory?q=${Uri.encodeQueryComponent('刑')}',
      token: viewerToken,
    );
    final roots = ((directoryResponse.json['data'] as Map)['items'] as List)
        .cast<Map<String, dynamic>>();
    _expect(
      roots.length == 2 &&
          roots.every((item) =>
              ((item['children'] as List).single as Map)['tag']['id'] ==
              second),
      '二级命中保留全部一级父级上下文，目录不返回三级',
    );
    final thirdPage = await _request(
      base,
      'GET',
      '/api/v1/movie-search/tags/third-level?parentTagId=$second&page=1&pageSize=30',
      token: viewerToken,
    );
    _expect(
      (thirdPage.json['page'] as Map)['size'] == 30 &&
          ((thirdPage.json['data'] as Map)['items'] as List).length == 1,
      '三级标签固定 30 条分页且只返回当前二级的直属标签',
    );

    // 三级标签很多时，目录仍只返回一级/二级，三级端点始终按固定页大小响应。
    for (var index = 0; index < 2000; index++) {
      database.createTag(
        name: '三级扩展标签$index',
        level: 3,
        parentIds: [second],
      );
    }
    final boundedDirectory = await _request(
      base,
      'GET',
      '/api/v1/movie-search/tags/directory',
      token: viewerToken,
    );
    final boundedThirdPage = await _request(
      base,
      'GET',
      '/api/v1/movie-search/tags/third-level?parentTagId=$second&page=2&pageSize=30',
      token: viewerToken,
    );
    _expect(
      ((boundedDirectory.json['data'] as Map)['items'] as List)
              .cast<Map<String, dynamic>>()
              .every((root) => root['children'] is List) &&
          (boundedThirdPage.json['page'] as Map)['total'] == 2001 &&
          ((boundedThirdPage.json['data'] as Map)['items'] as List).length ==
              30,
      '2,000+ 三级标签时目录不展开三级且三级响应保持有界',
    );

    final lateFile = File(
      '${mediaRoot.path}${Platform.pathSeparator}delta.mp4',
    );
    await lateFile.writeAsBytes(List<int>.filled(24, 2));
    await database.scanMediaRoot(
      mediaRootId: root.id,
      mediaService: mediaService,
      metadataProbe: NasMediaMetadataProbe(
        runner: (_, __) async => ProcessResult(
          0,
          0,
          '{"streams":[{"width":1920,"height":1080}],"format":{"duration":"12"}}',
          '',
        ),
      ),
    );
    final lateMovie = await _search(
      base,
      viewerToken,
      {'all': [], 'any': [], 'exclude': []},
      q: 'delta',
    );
    final recentlyImported = await _search(
      base,
      viewerToken,
      {'all': [], 'any': [], 'exclude': []},
      sort: 'createdAt',
      order: 'desc',
      pageSize: 1,
    );
    _expect(
      _ids(recentlyImported).single == _ids(lateMovie).single,
      '最近入库按首次扫描创建的影片记录排序',
    );

    final duplicate = await _search(
      base,
      viewerToken,
      {
        'all': [
          {'tagId': second, 'includeDescendants': true},
        ],
        'any': [
          {'tagId': second, 'includeDescendants': true},
        ],
        'exclude': [],
      },
    );
    _expectError(duplicate, HttpStatus.badRequest, 'invalid_request');
    final invalidWatchState = await _search(
      base,
      viewerToken,
      {'all': [], 'any': [], 'exclude': []},
      watchStates: const ['completed'],
    );
    _expectError(invalidWatchState, HttpStatus.badRequest, 'invalid_request');
    final invalidScope = await _search(base, viewerToken, {
      'all': [
        {'tagId': third, 'includeDescendants': true},
      ],
      'any': [],
      'exclude': [],
    });
    _expectError(invalidScope, HttpStatus.badRequest, 'invalid_request');
    final nonexistent = await _search(base, viewerToken, {
      'all': [
        {'tagId': 'tag-does-not-exist', 'includeDescendants': false},
      ],
      'any': [],
      'exclude': [],
    });
    _expectError(nonexistent, HttpStatus.badRequest, 'invalid_request');
    await _request(
      base,
      'POST',
      '/api/v1/admin/tag-management/tags/$third/archive',
      token: adminToken,
      body: const {},
    );
    final archived = await _search(base, viewerToken, {
      'all': [
        {'tagId': third, 'includeDescendants': false},
      ],
      'any': [],
      'exclude': [],
    });
    _expectError(archived, HttpStatus.badRequest, 'invalid_request');
  } finally {
    await server.stop();
    await directory.delete(recursive: true);
  }

  stdout.writeln('movie_search_api_test: PASS');
}

Future<String> _pair(Uri base, String serverId, {required String scope}) async {
  final session = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions',
    body: {
      'serverId': serverId,
      if (scope == 'admin') 'requestedScope': 'admin'
    },
  );
  final sessionId = (session.json['data'] as Map)['pairingSessionId'] as String;
  final confirmed = await _request(
    base,
    'POST',
    '/api/v1/pairing/sessions/$sessionId/confirm',
    body: {'pairingPassword': 'test-pairing-code'},
  );
  return (confirmed.json['data'] as Map)['accessToken'] as String;
}

Future<String> _tag(
  Uri base,
  String token, {
  required String name,
  required int level,
  List<String> parents = const [],
}) async {
  final response = await _request(
    base,
    'POST',
    '/api/v1/admin/tag-management/tags',
    token: token,
    body: {
      'name': name,
      'description': '',
      'color': null,
      'level': level,
      'parentIds': parents,
    },
  );
  return (response.json['data'] as Map)['id'] as String;
}

Future<void> _patchMovie(
  Uri base,
  String token,
  String movieId,
  List<String> tagIds, [
  String? categoryId,
]) async {
  final body = <String, Object>{'tagIds': tagIds};
  if (categoryId != null) body['categoryId'] = categoryId;
  await _request(
    base,
    'PATCH',
    '/api/v1/admin/movies/$movieId',
    token: token,
    body: body,
  );
}

Future<_Response> _search(
  Uri base,
  String token,
  Map<String, Object> tagConditions, {
  String q = '',
  String? categoryId,
  List<String> resolutions = const [],
  List<String> watchStates = const [],
  String sort = 'title',
  String order = 'asc',
  int page = 1,
  int pageSize = 30,
}) =>
    _request(
      base,
      'POST',
      '/api/v1/movies/search',
      token: token,
      body: {
        'q': q,
        'categoryId': categoryId,
        'resolutions': resolutions,
        'watchStates': watchStates,
        'sort': sort,
        'order': order,
        'page': page,
        'pageSize': pageSize,
        'tagConditions': tagConditions,
      },
    );

List<String> _ids(_Response response) =>
    ((response.json['data'] as Map)['items'] as List)
        .map((item) => (item as Map)['id'] as String)
        .toList(growable: false);

Future<_Response> _request(
  Uri base,
  String method,
  String path, {
  String? token,
  Object? body,
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
          ? const {}
          : Map<String, dynamic>.from(jsonDecode(text) as Map),
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

void _expectError(_Response response, int status, String code) {
  _expect(response.statusCode == status, '响应状态应为 $status');
  _expect(response.json['error']['code'] == code, '错误码应为 $code');
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('Assertion failed: $message');
}
