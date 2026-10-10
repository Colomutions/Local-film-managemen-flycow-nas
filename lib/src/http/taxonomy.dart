import 'dart:async';
import 'dart:io';

import '../artwork_service.dart';
import '../config.dart';
import '../fixture_library.dart';
import '../library/taxonomy_transfer.dart';
import '../library_database.dart';
import '../media_service.dart';

import 'response.dart';
import 'presenter.dart';
import 'scan.dart';

/// Category bindings, tag hierarchy and taxonomy transfers.
class NasTaxonomyHttpApi {
  NasTaxonomyHttpApi({
    required NasLibraryDatabase libraryDatabase,
    required NasMediaService mediaService,
    required NasArtworkService artworkService,
    required NasFixtureLibrary library,
    required this.config,
    required NasScanHttpApi scans,
    required this.configuredRoot,
    required this.activeImport,
    required NasLibraryPresenter presenter,
  })  : _libraryDatabase = libraryDatabase,
        _mediaService = mediaService,
        _artworkService = artworkService,
        _library = library,
        _scans = scans,
        _presenter = presenter;
  final NasLibraryDatabase _libraryDatabase;
  final NasConfig config;
  final NasLibraryPresenter _presenter;
  final NasArtworkService _artworkService;
  final NasFixtureLibrary _library;
  final NasMediaService _mediaService;
  final NasScanHttpApi _scans;
  final NasMediaRoot? Function() configuredRoot;
  NasMediaRoot? get _configuredMediaRoot => configuredRoot();
  final Future<void>? Function() activeImport;
  Future<void>? get _activeMdcngBatchTask => activeImport();

  Future<void> tagPaths(HttpRequest request) => writeApiJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {
            'items': (config.managedCategoryLibrary ||
                    _libraryDatabase.hasScannedMediaRoots)
                ? _libraryDatabase
                    .allTagPaths()
                    .map((path) => path.names)
                    .toList(growable: false)
                : _library.tagPaths(),
          },
        },
      );

  Future<void> adminCategories(HttpRequest request) => categories(request);

  Future<void> exportAdminCategoryTaxonomy(HttpRequest request) async {
    final conflicts = _libraryDatabase.categoryTaxonomyViolations();
    if (conflicts.isNotEmpty) {
      return await writeTaxonomyResult(
        request,
        NasTaxonomyTransferResult(
          added: const [],
          skipped: const [],
          conflicts: conflicts,
        ),
      );
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _libraryDatabase.exportCategoryTaxonomy().toJson(),
    });
  }

  Future<void> importAdminCategoryTaxonomy(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    if (body == null) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    try {
      return await writeTaxonomyResult(
        request,
        _libraryDatabase.importCategoryTaxonomy(
          NasCategoryTaxonomyTransfer.decode(body),
        ),
      );
    } on FormatException {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_taxonomy');
    }
  }

  Future<void> categories(HttpRequest request) async {
    final sort = request.uri.queryParameters['sort'] ?? 'name';
    if (!const {'name', 'movieCount', 'directory'}.contains(sort)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final categories = _libraryDatabase.listCategories();
    String directory(NasLibraryCategory category) => category
            .mediaSources.isEmpty
        ? category.mediaRelativePath ?? '尚未绑定 NAS 目录'
        : category.mediaSources
            .map((source) =>
                '${source.sourceName} · ${source.relativePath.split('/').last}')
            .join('；');
    if (sort != 'name') {
      categories.sort((a, b) {
        final compared = sort == 'movieCount'
            ? b.movieCount.compareTo(a.movieCount)
            : directory(a).compareTo(directory(b));
        if (compared != 0) return compared;
        final nameOrder = a.name.compareTo(b.name);
        return nameOrder == 0 ? a.id.compareTo(b.id) : nameOrder;
      });
    }
    await writeApiJson(
      request.response,
      HttpStatus.ok,
      {
        'data': {
          'items': categories
              .map(_presenter.categoryPayload)
              .toList(growable: false),
        },
      },
    );
  }

  Future<void> createAdminCategory(HttpRequest request) async {
    if (_activeMdcngBatchTask != null) {
      return writeApiError(request, HttpStatus.conflict, 'mdcng_batch_running');
    }
    final body = await readApiJsonBody(request);
    final name = _categoryName(body);
    final sources = await _categorySourceInputs(body);
    final color = _taxonomyColor(body);
    if (name == null ||
        color == _invalidTaxonomyColor ||
        _libraryDatabase.hasCategoryName(name) ||
        sources == null ||
        (config.managedCategoryLibrary && sources.isEmpty) ||
        !await _canBindCategorySources(sources)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final category = _libraryDatabase.createCategory(
      name,
      color: color,
    );
    if (!_libraryDatabase.replaceCategoryMediaSources(
      categoryId: category.id,
      sources: sources,
    )) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final savedCategory = _libraryDatabase.findCategory(category.id)!;
    final scanJob = _scans.scheduleCategoryScan(category.id);
    await writeApiJson(request.response, HttpStatus.created, {
      'data': {
        ..._presenter.categoryPayload(savedCategory),
        if (scanJob != null) 'scanJob': _scans.scanJobPayload(scanJob),
      },
    });
  }

  Future<void> updateAdminCategory(HttpRequest request) async {
    if (_activeMdcngBatchTask != null) {
      return writeApiError(request, HttpStatus.conflict, 'mdcng_batch_running');
    }
    final body = await readApiJsonBody(request);
    final name = _categoryName(body);
    final categoryId = request.uri.pathSegments.last;
    final hasSources = body?.containsKey('directoryKey') == true ||
        body?.containsKey('directoryKeys') == true;
    final sources = hasSources ? await _categorySourceInputs(body) : null;
    final color = _taxonomyColor(body);
    final previous = _libraryDatabase.findCategory(categoryId);
    if (name == null ||
        color == _invalidTaxonomyColor ||
        previous == null ||
        _libraryDatabase.hasCategoryName(name, excludingId: categoryId) ||
        (config.managedCategoryLibrary &&
            previous.mediaSources.isNotEmpty &&
            (!hasSources || sources == null || sources.isEmpty)) ||
        (hasSources &&
            (sources == null ||
                !await _canBindCategorySources(
                  sources,
                  excludingCategoryId: categoryId,
                )))) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final directoryChanged =
        hasSources && !_sameCategorySources(previous.mediaSources, sources!);
    if (directoryChanged &&
        _scans.jobs.any((job) =>
            job.categoryId == categoryId &&
            (job.status == 'queued' || job.status == 'running'))) {
      return writeApiError(request, HttpStatus.conflict, 'scan_running');
    }
    final category = _libraryDatabase.updateCategory(
      categoryId,
      name: name,
      updateMediaRelativePath: false,
      color: color,
      updateColor: body?.containsKey('color') ?? false,
    );
    if (category == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (directoryChanged &&
        !_libraryDatabase.replaceCategoryMediaSources(
          categoryId: categoryId,
          sources: sources,
        )) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final savedCategory = _libraryDatabase.findCategory(categoryId)!;
    final scanJob =
        directoryChanged ? _scans.scheduleCategoryScan(category.id) : null;
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        ..._presenter.categoryPayload(savedCategory),
        if (scanJob != null) 'scanJob': _scans.scanJobPayload(scanJob),
      },
    });
  }

  Future<void> deleteAdminCategory(HttpRequest request) async {
    if (_activeMdcngBatchTask != null) {
      return writeApiError(request, HttpStatus.conflict, 'mdcng_batch_running');
    }
    final categoryId = request.uri.pathSegments.last;
    if (_scans.jobs.any((job) =>
        (job.categoryId == null || job.categoryId == categoryId) &&
        (job.status == 'queued' || job.status == 'running'))) {
      return writeApiError(request, HttpStatus.conflict, 'scan_running');
    }
    final removed = _libraryDatabase.deleteCategoryWithIndexes(
      categoryId,
      deleteMovies: config.managedCategoryLibrary,
    );
    if (removed == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    for (final movie in removed) {
      await _artworkService.deletePoster(movie.posterFileName);
      for (final fileName in movie.carouselFileNames) {
        await _artworkService.deleteCarouselImage(fileName);
      }
    }
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> tagManagementOverview(HttpRequest request) async {
    final overview = _libraryDatabase.tagOverview();
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'total': overview.total,
        'levelOne': overview.levelOne,
        'levelTwo': overview.levelTwo,
        'levelThree': overview.levelThree,
        'movieLinks': overview.movieLinks,
      },
    });
  }

  Future<void> tagManagementDirectory(HttpRequest request) async {
    final roots = _libraryDatabase.tagDirectory(
      query: request.uri.queryParameters['q'] ?? '',
    );
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': roots
            .map((root) => {
                  'tag': _presenter.tagPayload(root.tag),
                  'movieCount': root.movieCount,
                  'children': root.children
                      .map((child) => {
                            'tag': _presenter.tagPayload(child.tag),
                            'movieCount': child.movieCount,
                          })
                      .toList(growable: false),
                })
            .toList(growable: false),
      },
    });
  }

  Future<void> tagManagementParentCandidates(HttpRequest request) async {
    final parameters = request.uri.queryParameters;
    final level = int.tryParse(parameters['level'] ?? '') ?? 0;
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '20') ?? 0;
    if (level < 2 || level > 3 || page < 1 || pageSize < 1 || pageSize > 50) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final query = parameters['q']?.trim().toLowerCase() ?? '';
    final candidates = _libraryDatabase
        .listTags(level: level - 1)
        .where(
          (tag) => query.isEmpty || tag.name.toLowerCase().contains(query),
        )
        .toList(growable: false);
    final offset = (page - 1) * pageSize;
    final items = offset >= candidates.length
        ? const <NasLibraryTag>[]
        : candidates.skip(offset).take(pageSize).toList(growable: false);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items.map(_presenter.tagPayload).toList(growable: false)
      },
      'page': {
        'number': page,
        'size': pageSize,
        'total': candidates.length,
        'hasMore': offset + items.length < candidates.length,
      },
    });
  }

  Future<void> tagManagementSelectableTags(HttpRequest request) async {
    final parameters = request.uri.queryParameters;
    final level = int.tryParse(parameters['level'] ?? '') ?? 0;
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '20') ?? 0;
    if (level < 1 || level > 3 || page < 1 || pageSize < 1 || pageSize > 50) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final query = parameters['q']?.trim().toLowerCase() ?? '';
    final tags = _libraryDatabase
        .listTags(level: level)
        .where(
          (tag) => query.isEmpty || tag.name.toLowerCase().contains(query),
        )
        .toList(growable: false);
    final offset = (page - 1) * pageSize;
    final items = offset >= tags.length
        ? const <NasLibraryTag>[]
        : tags.skip(offset).take(pageSize).toList(growable: false);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items.map(_presenter.tagPayload).toList(growable: false)
      },
      'page': {
        'number': page,
        'size': pageSize,
        'total': tags.length,
        'hasMore': offset + items.length < tags.length,
      },
    });
  }

  Future<void> tagManagementDetails(HttpRequest request) async {
    final details = _libraryDatabase.tagDetails(
      tagId: request.uri.pathSegments.last,
      contextParentId: request.uri.queryParameters['contextParentId'],
      contextRootId: request.uri.queryParameters['contextRootId'],
    );
    if (details == null)
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'tag': _presenter.tagPayload(details.tag),
        'parents':
            details.parents.map(_presenter.tagPayload).toList(growable: false),
        'directChildCount': details.directChildCount,
        'movieCount': details.movieCount,
        'path': details.path.map(_presenter.tagPayload).toList(growable: false),
      },
    });
  }

  Future<void> tagManagementChildren(HttpRequest request) async {
    final parameters = request.uri.queryParameters;
    final scope = parameters['scope'] ?? 'all';
    final associated = switch (scope) {
      'all' => null,
      'linked' => true,
      'unlinked' => false,
      _ => null,
    };
    if (!const {'all', 'linked', 'unlinked'}.contains(scope)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    try {
      final page = _libraryDatabase.tagChildren(
        parentTagId:
            request.uri.pathSegments[request.uri.pathSegments.length - 2],
        query: parameters['q'] ?? '',
        associated: associated,
        sort: parameters['sort'] ?? 'movieCount',
        order: parameters['order'] ?? 'desc',
        page: int.tryParse(parameters['page'] ?? '1') ?? 0,
        pageSize: int.tryParse(parameters['pageSize'] ?? '10') ?? 0,
      );
      await writeApiJson(request.response, HttpStatus.ok, {
        'data': {
          'items': page.items
              .map((item) => {
                    'tag': _presenter.tagPayload(item.tag),
                    'movieCount': item.movieCount,
                  })
              .toList(growable: false)
        },
        'page': {
          'number': page.number,
          'size': page.size,
          'total': page.total,
          'hasMore': page.hasMore,
        },
      });
    } on ArgumentError {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
  }

  Future<void> tagManagementMovies(HttpRequest request) async {
    final parameters = request.uri.queryParameters;
    try {
      final page = _libraryDatabase.tagMovies(
        tagId: request.uri.pathSegments[request.uri.pathSegments.length - 2],
        query: parameters['q'] ?? '',
        categoryId: parameters['categoryId'],
        resolution: parameters['resolution'],
        sort: parameters['sort'] ?? 'lastPlayedAt',
        order: parameters['order'] ?? 'desc',
        page: int.tryParse(parameters['page'] ?? '1') ?? 0,
        pageSize: int.tryParse(parameters['pageSize'] ?? '15') ?? 0,
      );
      final movies = page.movieIds
          .map(_libraryDatabase.findMovieForAdmin)
          .whereType<NasLibraryMovie>()
          .map(_presenter.databaseSummary)
          .toList(growable: false);
      await writeApiJson(request.response, HttpStatus.ok, {
        'data': {'items': movies},
        'page': {
          'number': page.number,
          'size': page.size,
          'total': page.total,
          'hasMore': page.hasMore,
        },
      });
    } on ArgumentError {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
  }

  Future<void> tagManagementTemplate(HttpRequest request) => writeApiJson(
        request.response,
        HttpStatus.ok,
        {
          'data': const NasTagTaxonomyTransfer(
            tags: [
              NasTaxonomyTagDefinition(
                name: '一级标签示例',
                level: 1,
                description: '下载模板示例：可替换为自己的一级标签名称。',
                color: '#58D5FF',
              ),
              NasTaxonomyTagDefinition(
                name: '二级标签示例 A',
                level: 2,
                description: '下载模板示例：二级标签必须关联一级父级。',
                color: '#FFC266',
                parents: ['一级标签示例'],
              ),
              NasTaxonomyTagDefinition(
                name: '二级标签示例 B',
                level: 2,
                description: '下载模板示例：可建立多个二级标签。',
                color: '#FFC266',
                parents: ['一级标签示例'],
              ),
              NasTaxonomyTagDefinition(
                name: '三级标签示例（多父）',
                level: 3,
                description: '下载模板示例：三级标签可关联多个二级父级。',
                color: '#73D8A4',
                parents: ['二级标签示例 A', '二级标签示例 B'],
              ),
            ],
          ).toJson(),
        },
      );

  Future<void> tagManagementExport(HttpRequest request) => writeApiJson(
        request.response,
        HttpStatus.ok,
        {'data': _libraryDatabase.exportTagTaxonomy().toJson()},
      );

  Future<void> importTagManagement(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    if (body == null)
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    try {
      await writeTaxonomyResult(
        request,
        _libraryDatabase.importTagTaxonomy(NasTagTaxonomyTransfer.decode(body)),
      );
    } on FormatException {
      await writeApiError(request, HttpStatus.badRequest, 'invalid_taxonomy');
    }
  }

  Future<void> createTagManagementTag(HttpRequest request) async {
    final input =
        _tagManagementInput(await readApiJsonBody(request), creating: true);
    if (input == null)
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    try {
      final tag = _libraryDatabase.createTag(
        name: input.name,
        level: input.level!,
        description: input.description,
        color: input.color,
        parentIds: input.parentIds,
      );
      await writeApiJson(request.response, HttpStatus.created,
          {'data': _presenter.tagPayload(tag)});
    } on ArgumentError {
      await writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    } on StateError {
      await writeApiError(
          request, HttpStatus.conflict, 'tag_taxonomy_conflict');
    }
  }

  Future<void> updateTagManagementTag(HttpRequest request) async {
    final tagId = request.uri.pathSegments.last;
    final current = _libraryDatabase.findTag(tagId);
    if (current == null)
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    final input =
        _tagManagementInput(await readApiJsonBody(request), creating: false);
    if (input == null)
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    try {
      final tag = _libraryDatabase.updateTag(
        tagId: tagId,
        name: input.name,
        description: input.description,
        color: input.color,
        parentIds: input.parentIds,
      );
      if (tag == null) {
        await writeApiError(request, HttpStatus.notFound, 'resource_not_found');
        return;
      }
      await writeApiJson(request.response, HttpStatus.ok,
          {'data': _presenter.tagPayload(tag)});
    } on ArgumentError {
      await writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    } on StateError {
      await writeApiError(
          request, HttpStatus.conflict, 'tag_taxonomy_conflict');
    }
  }

  Future<void> archiveTagManagementTag(HttpRequest request) async {
    final tagId = request.uri.pathSegments[request.uri.pathSegments.length - 2];
    if (!_libraryDatabase.archiveTag(tagId)) {
      await writeApiError(request, HttpStatus.notFound, 'resource_not_found');
      return;
    }
    final tag = _libraryDatabase.findTag(tagId)!;
    await writeApiJson(
        request.response, HttpStatus.ok, {'data': _presenter.tagPayload(tag)});
  }

  Future<void> deleteTagManagementTag(HttpRequest request) async {
    try {
      if (!_libraryDatabase.deleteTag(request.uri.pathSegments.last)) {
        await writeApiError(request, HttpStatus.notFound, 'resource_not_found');
        return;
      }
    } on StateError {
      await writeApiError(request, HttpStatus.conflict, 'tag_has_references');
      return;
    }
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  _TagManagementInput? _tagManagementInput(
    Map<String, dynamic>? body, {
    required bool creating,
  }) {
    if (body == null ||
        body.keys.any((key) => !{
              'name',
              'description',
              'color',
              if (creating) 'level',
              'parentIds',
            }.contains(key)) ||
        body['name'] is! String ||
        body['description'] is! String ||
        (body['color'] != null && body['color'] is! String) ||
        body['parentIds'] is! List ||
        (creating && body['level'] is! int)) {
      return null;
    }
    final name = (body['name'] as String).trim();
    final description = (body['description'] as String).trim();
    final color = body['color'] as String?;
    final parentIds = (body['parentIds'] as List)
        .map((value) => value is String ? value.trim() : '')
        .toList(growable: false);
    if (name.isEmpty ||
        !isValidTaxonomyColor(color) ||
        parentIds.any((id) => id.isEmpty) ||
        parentIds.toSet().length != parentIds.length) {
      return null;
    }
    return _TagManagementInput(
      name: name,
      description: description,
      color: color,
      level: creating ? body['level'] as int : null,
      parentIds: parentIds,
    );
  }

  static const _invalidTaxonomyColor = '\u0000';

  String? _taxonomyName(
    Map<String, dynamic>? body, {
    required Set<String> allowed,
  }) {
    if (body == null ||
        body['name'] is! String ||
        body.keys.any((key) => !allowed.contains(key))) {
      return null;
    }
    final name = (body['name'] as String).trim();
    return name.isEmpty ? null : name;
  }

  String? _taxonomyColor(Map<String, dynamic>? body) {
    if (body == null || !body.containsKey('color')) return null;
    final color = body['color'];
    if (color == null) return null;
    return color is String && isValidTaxonomyColor(color)
        ? color
        : _invalidTaxonomyColor;
  }

  String? _categoryName(Map<String, dynamic>? body) {
    return _taxonomyName(
      body,
      allowed: const {'name', 'directoryKey', 'directoryKeys', 'color'},
    );
  }

  Future<List<NasCategoryMediaSourceInput>?> _categorySourceInputs(
    Map<String, dynamic>? body,
  ) async {
    if (body == null) return null;
    final hasSingle = body.containsKey('directoryKey');
    final hasMany = body.containsKey('directoryKeys');
    if (hasSingle && hasMany) return null;
    final raw = hasMany
        ? body['directoryKeys']
        : hasSingle
            ? [body['directoryKey']]
            : const <Object?>[];
    if (raw is! List || raw.length > 32 || raw.any((item) => item is! String)) {
      return null;
    }
    final inputs = <NasCategoryMediaSourceInput>[];
    for (final item in raw.cast<String>()) {
      final key = item.trim().replaceAll('\\', '/');
      final input = await _categorySourceInputForDirectoryKey(key);
      if (input == null) return null;
      inputs.add(input);
    }
    final identities = inputs
        .map((input) => '${input.mediaRootId}:${input.relativePath}')
        .toSet();
    return identities.length == inputs.length ? inputs : null;
  }

  Future<NasCategoryMediaSourceInput?> _categorySourceInputForDirectoryKey(
    String directoryKey,
  ) async {
    if (directoryKey.isEmpty ||
        await _mediaService.directoryForRelativePath(directoryKey) == null) {
      return null;
    }
    final segments = directoryKey.split('/');
    final roots = _libraryDatabase.listMediaRoots();
    for (final root in roots) {
      if (root.containerPath == config.mediaDir) continue;
      final rootName = root.containerPath
          .replaceAll('\\', '/')
          .split('/')
          .where((item) => item.isNotEmpty)
          .last;
      if (segments.first != rootName || segments.length < 2) continue;
      return NasCategoryMediaSourceInput(
        mediaRootId: root.id,
        relativePath: segments.skip(1).join('/'),
      );
    }
    final defaultRoot = _configuredMediaRoot;
    if (defaultRoot == null) return null;
    return NasCategoryMediaSourceInput(
      mediaRootId: defaultRoot.id,
      relativePath: directoryKey,
    );
  }

  Future<bool> _canBindCategorySources(
    List<NasCategoryMediaSourceInput> sources, {
    String? excludingCategoryId,
  }) async {
    // /media 下的 disk1 和 /media/disk1 下的子目录虽根 ID 不同，仍可能重叠。
    final roots = {
      for (final root in _libraryDatabase.listMediaRoots()) root.id: root,
    };
    String? sourcePath(String rootId, String relativePath) {
      final root = roots[rootId];
      if (root == null) return null;
      final rootPath = root.containerPath
          .replaceAll('\\', '/')
          .replaceFirst(RegExp(r'/+$'), '');
      return '$rootPath/$relativePath';
    }

    bool overlaps(String left, String right) =>
        left == right ||
        left.startsWith('$right/') ||
        right.startsWith('$left/');
    final paths = <String>[];
    for (final source in sources) {
      final path = sourcePath(source.mediaRootId, source.relativePath);
      if (path == null || paths.any((other) => overlaps(path, other)))
        return false;
      paths.add(path);
    }
    for (final category in _libraryDatabase.listCategories()) {
      if (category.id == excludingCategoryId) continue;
      for (final other in category.mediaSources) {
        final otherPath = sourcePath(other.mediaRootId, other.relativePath);
        if (otherPath == null || paths.any((path) => overlaps(path, otherPath)))
          return false;
      }
    }
    return true;
  }

  bool _sameCategorySources(
    List<NasCategoryMediaSource> current,
    List<NasCategoryMediaSourceInput> expected,
  ) {
    final left = current
        .map((source) => '${source.mediaRootId}:${source.relativePath}')
        .toSet();
    final right = expected
        .map((source) => '${source.mediaRootId}:${source.relativePath}')
        .toSet();
    return left.length == right.length && left.containsAll(right);
  }
}

class _TagManagementInput {
  const _TagManagementInput({
    required this.name,
    required this.description,
    required this.color,
    required this.level,
    required this.parentIds,
  });

  final String name;
  final String description;
  final String? color;
  final int? level;
  final List<String> parentIds;
}
