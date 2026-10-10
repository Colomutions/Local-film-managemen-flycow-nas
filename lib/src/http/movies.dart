import 'dart:async';
import 'dart:io';

import '../artwork_service.dart';
import '../config.dart';
import '../fixture_library.dart';
import '../library_database.dart';
import '../media_service.dart';

import 'response.dart';
import 'validation.dart';
import 'presenter.dart';

/// Movie browsing, editing and collection operations.
class NasMoviesHttpApi {
  NasMoviesHttpApi({
    required NasLibraryDatabase libraryDatabase,
    required NasFixtureLibrary library,
    required NasMediaService mediaService,
    required this.config,
    required NasLibraryPresenter presenter,
    required NasArtworkService artworkService,
  })  : _libraryDatabase = libraryDatabase,
        _library = library,
        _mediaService = mediaService,
        _presenter = presenter,
        _artworkService = artworkService;
  final NasLibraryDatabase _libraryDatabase;
  final NasConfig config;
  final NasLibraryPresenter _presenter;

  final NasFixtureLibrary _library;
  final NasMediaService _mediaService;
  final NasArtworkService _artworkService;

  Future<void> movies(HttpRequest request) {
    final hasDatabaseLibrary =
        config.managedCategoryLibrary || _libraryDatabase.hasScannedMediaRoots;
    final parameters = request.uri.queryParameters;
    final query = parameters['q'] ?? parameters['query'] ?? '';
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '24') ?? 0;
    final sort = parameters['sort'] ?? 'title';
    final order = parameters['order'] ?? 'asc';
    final categoryId = parameters['categoryId'];
    final isFavorite = nasFavoriteFilter(parameters['isFavorite']);
    final tagIds = parameters['tagIds']
        ?.split(',')
        .where((value) => value.isNotEmpty)
        .toSet();
    final resolutions = parameters['resolutions']
        ?.split(',')
        .where((value) => value.isNotEmpty)
        .toSet();
    if (page < 1 ||
        pageSize < 1 ||
        pageSize > 100 ||
        !const {'title', 'updatedAt', 'durationMs', 'recent'}.contains(sort) ||
        !const {'asc', 'desc'}.contains(order) ||
        !nasIsValidFavoriteFilter(parameters['isFavorite']) ||
        (hasDatabaseLibrary &&
            categoryId != null &&
            _libraryDatabase.findCategory(categoryId) == null) ||
        (!hasDatabaseLibrary &&
            (categoryId != null ||
                isFavorite != null ||
                (tagIds?.isNotEmpty ?? false) ||
                (resolutions?.isNotEmpty ?? false)))) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    if (!hasDatabaseLibrary) {
      final items = _library.listMovies(query: query);
      final offset = (page - 1) * pageSize;
      final paged = offset >= items.length
          ? const <Map<String, Object?>>[]
          : items.skip(offset).take(pageSize).toList(growable: false);
      return writeApiJson(request.response, HttpStatus.ok, {
        'data': {'items': paged},
        'page': {
          'number': page,
          'size': pageSize,
          'total': items.length,
          'hasMore': offset + paged.length < items.length,
        },
      });
    }
    final result = _libraryDatabase.searchMovies(NasMovieSearchFilter(
      query: query,
      categoryId: categoryId,
      isFavorite: isFavorite,
      resolutions: resolutions ?? const {},
      watchStates: const {},
      sort: sort,
      order: order,
      page: page,
      pageSize: pageSize,
      tagConditions: [
        for (final id in tagIds ?? <String>{})
          NasMovieSearchTagCondition(
              group: 'any', tagId: id, includeDescendants: false)
      ],
    ));
    final associations = _libraryDatabase
        .browseAssociations(result.items.map((movie) => movie.id).toList());
    return writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': result.items
            .map((movie) => {
                  ..._presenter.databaseSearchSummary(movie),
                  ...associations[movie.id]!,
                })
            .toList(growable: false)
      },
      'page': {
        'number': result.number,
        'size': result.size,
        'total': result.total,
        'hasMore': result.hasMore
      },
    });
  }

  Future<void> cinemaHome(HttpRequest request) async {
    final versions = _libraryDatabase.revisions;
    final etag = '"${versions['library']}:${versions['taxonomy']}"';
    if (request.headers.value(HttpHeaders.ifNoneMatchHeader) == etag) {
      request.response.statusCode = HttpStatus.notModified;
      request.response.headers.set(HttpHeaders.etagHeader, etag);
      return request.response.close();
    }
    Map<String, Object?> section(String? categoryId, String title) {
      final page = _libraryDatabase.searchMovies(NasMovieSearchFilter(
        query: '',
        categoryId: categoryId,
        resolutions: const {},
        watchStates: const {},
        sort: 'createdAt',
        order: 'desc',
        page: 1,
        pageSize: 8,
        tagConditions: const [],
      ));
      return {
        'id': categoryId ?? '',
        'name': title,
        'kind': categoryId == null ? 'all' : 'categories',
        'items': page.items
            .map(_presenter.databaseSearchSummary)
            .toList(growable: false),
        'page': {
          'number': 1,
          'size': 8,
          'total': page.total,
          'hasMore': page.hasMore
        }
      };
    }

    final categories = _libraryDatabase.listCategories();
    final sections = [
      section(null, '最近加入'),
      for (final category in categories.take(6))
        section(category.id, category.name)
    ];
    request.response.headers.set(HttpHeaders.etagHeader, etag);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {'sections': sections, 'revisions': versions},
    });
  }

  /// 影集管理目标只按需查询 NAS 中同一分类的影集，不能依赖影片墙当前页。
  Future<void> collections(HttpRequest request) async {
    final parameters = request.uri.queryParameters;
    final categoryId = parameters['categoryId'];
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '20') ?? 0;
    final query = parameters['q'] ?? '';
    if (categoryId == null ||
        categoryId.isEmpty ||
        page < 1 ||
        pageSize < 1 ||
        pageSize > 100 ||
        query.length > 120) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    try {
      final result = _libraryDatabase.searchSeries(
        categoryId: categoryId,
        query: query,
        page: page,
        pageSize: pageSize,
      );
      await writeApiJson(request.response, HttpStatus.ok, {
        'data': {
          'items': result.items
              .map(_presenter.databaseSummary)
              .toList(growable: false),
        },
        'page': {
          'number': result.number,
          'size': result.size,
          'total': result.total,
          'hasMore': result.hasMore,
        },
      });
    } on ArgumentError {
      await writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
  }

  /// 面向浏览端的全库结构化搜索；标签条件绝不在 Windows 侧二次计算。
  Future<void> movieSearch(HttpRequest request) async {
    final filter = nasMovieSearchFilter(await readApiJsonBody(request));
    if (filter == null) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final hasDatabaseLibrary =
        config.managedCategoryLibrary || _libraryDatabase.hasScannedMediaRoots;
    if (!hasDatabaseLibrary) {
      if (filter.hasEntityConditions ||
          filter.isFavorite != null ||
          filter.resolutions.isNotEmpty ||
          filter.watchStates.isNotEmpty ||
          filter.tagConditions.isNotEmpty) {
        return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
      }
      final items = _library.listMovies(query: filter.query);
      final offset = (filter.page - 1) * filter.pageSize;
      final paged = offset >= items.length
          ? const <Map<String, Object?>>[]
          : items.skip(offset).take(filter.pageSize).toList(growable: false);
      return writeApiJson(request.response, HttpStatus.ok, {
        'data': {'items': paged},
        'page': {
          'number': filter.page,
          'size': filter.pageSize,
          'total': items.length,
          'hasMore': offset + paged.length < items.length,
        },
      });
    }
    if (filter.effectiveCategoryIds.any(
          (id) => _libraryDatabase.findCategory(id) == null,
        ) ||
        filter.seriesIds.any((id) => _libraryDatabase.findSeries(id) == null) ||
        filter.publisherIds.any(
          (id) => _libraryDatabase.findPublisher(id) == null,
        ) ||
        filter.actorIds.any((id) => _libraryDatabase.findActor(id) == null)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    for (final condition in filter.tagConditions) {
      final tag = _libraryDatabase.findTag(condition.tagId);
      if (tag == null ||
          tag.archivedAt != null ||
          tag.level < 1 ||
          tag.level > 3 ||
          (tag.level == 3 && condition.includeDescendants)) {
        return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
      }
    }
    try {
      final page = _libraryDatabase.searchMovies(filter);
      await writeApiJson(request.response, HttpStatus.ok, {
        'data': {
          'items': page.items
              .map(_presenter.databaseSearchSummary)
              .toList(growable: false),
        },
        'page': {
          'number': page.number,
          'size': page.size,
          'total': page.total,
          'hasMore': page.hasMore,
        },
      });
    } on ArgumentError {
      await writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
  }

  /// 搜索抽屉仅请求一、二级目录，避免为打开抽屉读取全部三级标签。
  Future<void> movieSearchTagDirectory(HttpRequest request) async {
    final query = request.uri.queryParameters['q'] ?? '';
    if (query.length > 120) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final items = _libraryDatabase.movieSearchTagDirectory(query: query);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items
            .map(
              (root) => {
                'tag': _presenter.movieSearchTagPayload(root.tag),
                'movieCount': root.movieCount,
                'children': root.children
                    .map(
                      (child) => {
                        'tag': _presenter.movieSearchTagPayload(child.tag),
                        'movieCount': child.movieCount,
                        'thirdLevelCount': child.thirdLevelCount,
                      },
                    )
                    .toList(growable: false),
              },
            )
            .toList(growable: false),
      },
    });
  }

  /// 当前二级节点的三级标签固定分页，不能以目录预取替代。
  Future<void> movieSearchThirdLevelTags(HttpRequest request) async {
    final parameters = request.uri.queryParameters;
    final parentTagId = parameters['parentTagId']?.trim();
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '30') ?? 0;
    final query = parameters['q'] ?? '';
    if (parentTagId == null ||
        parentTagId.isEmpty ||
        page < 1 ||
        pageSize != 30 ||
        query.length > 120) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    try {
      final result = _libraryDatabase.movieSearchThirdLevelTags(
        parentTagId: parentTagId,
        query: query,
        page: page,
        pageSize: pageSize,
      );
      await writeApiJson(request.response, HttpStatus.ok, {
        'data': {
          'items': result.items
              .map(
                (item) => {
                  'tag': _presenter.movieSearchTagPayload(item.tag),
                  'movieCount': item.movieCount,
                },
              )
              .toList(growable: false),
        },
        'page': {
          'number': result.number,
          'size': result.size,
          'total': result.total,
          'hasMore': result.hasMore,
        },
      });
    } on ArgumentError {
      await writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
  }

  Future<void> movieDetails(HttpRequest request) async {
    final movieId = request.uri.pathSegments.last;
    final databaseMovie = _libraryDatabase.findMovie(movieId);
    final movie = databaseMovie != null
        ? await _presenter.databaseDetails(databaseMovie)
        : !config.managedCategoryLibrary &&
                !_libraryDatabase.hasScannedMediaRoots
            ? _library.movieDetails(
                movieId,
                isAvailable: await _mediaService.fixtureFile() != null,
              )
            : null;
    if (movie == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    await writeApiJson(request.response, HttpStatus.ok, {'data': movie});
  }

  /// 分集检索、搜索与分页始终在 NAS 完成，客户端不下载整部影集后过滤。
  Future<void> movieEpisodes(HttpRequest request) async {
    final parameters = request.uri.queryParameters;
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '10') ?? 0;
    final query = parameters['q'] ?? '';
    final episodeId = parameters['episodeId'];
    final movieId = request.uri.pathSegments[3];
    if (page < 1 || pageSize < 1 || pageSize > 100 || query.length > 120) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    if (_libraryDatabase.findMovieForAdmin(movieId) == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    try {
      final result = _libraryDatabase.episodePageForMovie(
        movieId: movieId,
        query: query,
        page: page,
        pageSize: pageSize,
        anchorEpisodeId: episodeId,
      );
      await writeApiJson(request.response, HttpStatus.ok, {
        'data': {
          'items': result.items
              .map(_presenter.episodePayload)
              .toList(growable: false),
        },
        'page': {
          'number': result.number,
          'size': result.size,
          'total': result.total,
          'hasMore': result.hasMore,
        },
      });
    } on ArgumentError {
      await writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
  }

  Future<void> updateAdminMovie(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    if (body == null ||
        body.keys.any((key) =>
            key != 'title' &&
            key != 'originalTitle' &&
            key != 'catalogNumber' &&
            key != 'publisherId' &&
            key != 'seriesId' &&
            key != 'summary' &&
            key != 'actorIds' &&
            key != 'categoryId' &&
            key != 'tagIds')) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final rawTitle = body['title'];
    final hasOriginalTitle = body.containsKey('originalTitle');
    final rawOriginalTitle = body['originalTitle'];
    final hasCatalogNumber = body.containsKey('catalogNumber');
    final rawCatalogNumber = body['catalogNumber'];
    final hasPublisherId = body.containsKey('publisherId');
    final rawPublisherId = body['publisherId'];
    final hasSeriesId = body.containsKey('seriesId');
    final rawSeriesId = body['seriesId'];
    final rawSummary = body['summary'];
    final hasActorIds = body.containsKey('actorIds');
    final rawActorIds = body['actorIds'];
    final hasCategoryId = body.containsKey('categoryId');
    final rawCategoryId = body['categoryId'];
    final hasTagIds = body.containsKey('tagIds');
    final rawTagIds = body['tagIds'];
    final movieId = request.uri.pathSegments.last;
    final existingMovie = _libraryDatabase.findMovieForAdmin(movieId);
    if (existingMovie == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if ((rawTitle != null && rawTitle is! String) ||
        (hasOriginalTitle &&
            rawOriginalTitle != null &&
            rawOriginalTitle is! String) ||
        (hasCatalogNumber &&
            rawCatalogNumber != null &&
            rawCatalogNumber is! String) ||
        (hasPublisherId &&
            rawPublisherId != null &&
            rawPublisherId is! String) ||
        (hasSeriesId && rawSeriesId != null && rawSeriesId is! String) ||
        (rawSummary != null && rawSummary is! String) ||
        (hasActorIds && rawActorIds is! List) ||
        (rawTitle == null &&
            !hasOriginalTitle &&
            !hasCatalogNumber &&
            !hasPublisherId &&
            !hasSeriesId &&
            rawSummary == null &&
            !hasActorIds &&
            !hasCategoryId &&
            !hasTagIds) ||
        (hasCategoryId && rawCategoryId != null && rawCategoryId is! String) ||
        (hasTagIds && rawTagIds is! List)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final title = (rawTitle as String?)?.trim();
    if (title != null && title.isEmpty) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final originalTitle = (rawOriginalTitle as String?)?.trim();
    final catalogNumber = (rawCatalogNumber as String?)?.trim();
    final publisherId = (rawPublisherId as String?)?.trim();
    final seriesId = (rawSeriesId as String?)?.trim();
    List<String>? actorIds;
    if (hasActorIds) {
      final rawList = rawActorIds as List;
      if (rawList.length > 80 || rawList.any((value) => value is! String)) {
        return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
      }
      actorIds = rawList.cast<String>();
      if (actorIds.any((id) => id.isEmpty) ||
          actorIds.toSet().length != actorIds.length ||
          actorIds.any((id) {
            final actor = _libraryDatabase.findActor(id);
            return actor == null || actor.archivedAt != null;
          })) {
        return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
      }
    }
    final categoryId = rawCategoryId as String?;
    if (hasCategoryId &&
        (categoryId?.isEmpty == true ||
            (categoryId != null &&
                _libraryDatabase.findCategory(categoryId) == null))) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final tagIds = hasTagIds
        ? (rawTagIds as List)
            .map((value) => value is String ? value : null)
            .toList(growable: false)
        : const <String?>[];
    final existingTagIds = hasTagIds
        ? _libraryDatabase.tagsForMovie(movieId).map((tag) => tag.id).toSet()
        : const <String>{};
    if (tagIds.any((id) => id == null || id.isEmpty) ||
        tagIds.toSet().length != tagIds.length ||
        tagIds.any((id) {
          final tag = id == null ? null : _libraryDatabase.findTag(id);
          return tag == null ||
              (tag.archivedAt != null && !existingTagIds.contains(tag.id));
        })) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    // 在写入任何影片字段前先验证系列与发行商的组合，避免 PATCH 局部成功。
    final relationPreview = _libraryDatabase.resolveMovieRelations(
      movieId: movieId,
      publisherId:
          publisherId == null || publisherId.isEmpty ? null : publisherId,
      updatePublisherId: hasPublisherId,
      seriesId: seriesId == null || seriesId.isEmpty ? null : seriesId,
      updateSeriesId: hasSeriesId,
    );
    if (relationPreview == null) {
      return writeApiError(
          request, HttpStatus.conflict, 'movie_series_publisher_conflict');
    }
    final movie = _libraryDatabase.updateMovieMetadata(
      movieId: movieId,
      title: title,
      originalTitle:
          originalTitle == null || originalTitle.isEmpty ? null : originalTitle,
      updateOriginalTitle: hasOriginalTitle,
      catalogNumber:
          catalogNumber == null || catalogNumber.isEmpty ? null : catalogNumber,
      updateCatalogNumber: hasCatalogNumber,
      summary: rawSummary as String?,
    );
    if (movie == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final updatedRelations = _libraryDatabase.updateMovieRelations(
      movieId: movie.id,
      publisherId:
          publisherId == null || publisherId.isEmpty ? null : publisherId,
      updatePublisherId: hasPublisherId,
      seriesId: seriesId == null || seriesId.isEmpty ? null : seriesId,
      updateSeriesId: hasSeriesId,
    );
    if (updatedRelations == null) {
      return writeApiError(
          request, HttpStatus.conflict, 'movie_series_publisher_conflict');
    }
    if (actorIds != null &&
        !_libraryDatabase.setMovieActorIds(
          movieId: movie.id,
          actorIds: actorIds,
        )) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    _libraryDatabase.setMovieTaxonomy(
      movieId: movie.id,
      updateCategory: hasCategoryId,
      categoryId: categoryId,
      updateTagIds: hasTagIds,
      tagIds: tagIds.cast<String>(),
    );
    _libraryDatabase.markMovieMetadataFieldsManual(
      movieId: movie.id,
      fieldKeys: [
        if (rawTitle != null) 'title',
        if (hasOriginalTitle) 'originalTitle',
        if (hasCatalogNumber) 'catalogNumber',
        if (rawSummary != null) 'summary',
        if (hasActorIds) 'actors',
        if (hasTagIds) 'tags',
        if (hasPublisherId) 'publisher',
        if (hasSeriesId) 'series',
        if (hasCategoryId) 'category',
      ],
    );
    final updatedMovie = _libraryDatabase.findMovieForAdmin(movie.id)!;
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': await _presenter.databaseDetails(updatedMovie),
    });
  }

  Future<void> updateAdminMovieFavorite(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    final isFavorite = body?['isFavorite'];
    if (body == null || body.keys.length != 1 || isFavorite is! bool) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final movie = _libraryDatabase.setMovieFavorite(
      movieId: request.uri.pathSegments[4],
      isFavorite: isFavorite,
    );
    if (movie == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _presenter.databaseSummary(movie),
    });
  }

  Future<void> removeAdminMovieFromIndex(HttpRequest request) async {
    final removed = _libraryDatabase.removeMovieFromIndex(
      request.uri.pathSegments.last,
    );
    if (removed == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (removed.posterFileName != null) {
      await _artworkService.deletePoster(removed.posterFileName!);
    }
    for (final fileName in removed.carouselFileNames) {
      await _artworkService.deleteCarouselImage(fileName);
    }
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> updateAdminEpisode(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    final rawTitle = body?['title'];
    if (body == null ||
        body.keys.any((key) => key != 'title') ||
        rawTitle is! String ||
        rawTitle.trim().isEmpty) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final episode = _libraryDatabase.updateEpisodeTitle(
      episodeId: request.uri.pathSegments.last,
      title: rawTitle.trim(),
    );
    if (episode == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _presenter.adminEpisodePayload(episode),
    });
  }

  Future<void> adminMediaFiles(HttpRequest request) async {
    final parameters = request.uri.queryParameters;
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '20') ?? 0;
    final query = parameters['q'] ?? '';
    try {
      final result = _libraryDatabase.scannedMediaFiles(
        page: page,
        pageSize: pageSize,
        query: query,
      );
      await writeApiJson(request.response, HttpStatus.ok, {
        'data': {
          'items': result.items
              .map(
                (item) => {
                  ..._presenter.adminEpisodePayload(item.episode),
                  'movieId': item.movieId,
                  'movieTitle': item.movieTitle,
                  'entryType': item.entryType,
                  'categoryId': item.categoryId,
                },
              )
              .toList(growable: false),
        },
        'page': {
          'number': result.number,
          'size': result.size,
          'total': result.total,
          'hasMore': result.hasMore,
        },
      });
    } on ArgumentError {
      await writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
  }

  Future<void> createAdminCollection(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    final title = body?['title'];
    final categoryId = body?['categoryId'];
    if (body == null ||
        body.keys.any((key) => key != 'title' && key != 'categoryId') ||
        title is! String ||
        title.trim().isEmpty ||
        categoryId is! String ||
        categoryId.isEmpty ||
        _libraryDatabase.findCategory(categoryId) == null) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    try {
      final movie = _libraryDatabase.createEmptySeries(
        title: title,
        categoryId: categoryId,
      );
      await writeApiJson(request.response, HttpStatus.created, {
        'data': await _presenter.databaseDetails(movie),
      });
    } on ArgumentError {
      await writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
  }

  Future<void> mergeAdminCollectionEpisodes(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    final episodeIds = body?['episodeIds'];
    final metadataSourceMovieId = body?['metadataSourceMovieId'];
    if (body == null ||
        body.length != 2 ||
        episodeIds is! List ||
        episodeIds.any((item) => item is! String) ||
        metadataSourceMovieId is! String) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final targetMovieId = request.uri.pathSegments[4];
    if (!_libraryDatabase.mergeEpisodesIntoSeries(
      targetMovieId: targetMovieId,
      episodeIds: episodeIds.cast<String>(),
      metadataSourceMovieId: metadataSourceMovieId,
    )) {
      return writeApiError(
          request, HttpStatus.conflict, 'collection_merge_conflict');
    }
    final movie = _libraryDatabase.findMovieForAdmin(targetMovieId)!;
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': await _presenter.databaseDetails(movie),
    });
  }

  Future<void> splitAdminCollectionEpisodes(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    final episodeIds = body?['episodeIds'];
    if (body == null ||
        body.length != 1 ||
        episodeIds is! List ||
        episodeIds.any((item) => item is! String)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final movieId = request.uri.pathSegments[4];
    final movies = _libraryDatabase.splitEpisodesIntoSingles(
      movieId: movieId,
      episodeIds: episodeIds.cast<String>(),
    );
    if (movies == null) {
      return writeApiError(
          request, HttpStatus.conflict, 'collection_split_conflict');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': movies.map(_presenter.databaseSummary).toList(growable: false),
      },
    });
  }

  Future<void> collectionMigrationPreview(HttpRequest request) async {
    final items = _libraryDatabase.collectionMigrationPreview();
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items
            .map(
              (item) => {
                'key': item.key,
                'categoryId': item.categoryId,
                'title': item.title,
                'episodeIds': item.episodeIds,
                'sourceMovieIds': item.sourceMovieIds,
                'metadataSources': item.sourceMovieIds
                    .map(_libraryDatabase.findMovieForAdmin)
                    .whereType<NasLibraryMovie>()
                    .map((movie) => {'id': movie.id, 'title': movie.title})
                    .toList(growable: false),
                'requiresMetadataChoice': item.requiresMetadataChoice,
              },
            )
            .toList(growable: false),
      },
    });
  }

  Future<void> applyCollectionMigration(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    final key = body?['key'];
    final metadataSourceMovieId = body?['metadataSourceMovieId'];
    if (body == null ||
        body.length != 2 ||
        key is! String ||
        metadataSourceMovieId is! String) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final movie = _libraryDatabase.applyCollectionMigration(
      key: key,
      metadataSourceMovieId: metadataSourceMovieId,
    );
    if (movie == null) {
      return writeApiError(
          request, HttpStatus.conflict, 'collection_migration_conflict');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': await _presenter.databaseDetails(movie),
    });
  }

  Future<void> renameAdminEpisodeSource(HttpRequest request) async {
    if (!config.allowSourceRename) {
      return writeApiError(
          request, HttpStatus.conflict, 'source_rename_disabled');
    }
    final body = await readApiJsonBody(request);
    final sourceName = body?['sourceName'];
    if (body == null || body.length != 1 || sourceName is! String) {
      return writeApiError(
          request, HttpStatus.badRequest, 'invalid_source_name');
    }
    final segments = request.uri.pathSegments;
    final episodeId = segments[segments.length - 2];
    final episode = _libraryDatabase.findEpisode(episodeId);
    if (episode == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    NasMediaFile? renamed;
    final mediaRoot = _libraryDatabase.findMediaRoot(episode.mediaRootId);
    if (mediaRoot == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    try {
      renamed = await _mediaService.renameFileInPlace(
        relativePath: episode.relativePath,
        sourceName: sourceName,
        rootPath: mediaRoot.containerPath == config.mediaDir
            ? null
            : mediaRoot.containerPath,
      );
      final stat = await renamed.file.stat();
      final updated = _libraryDatabase.updateEpisodeSourceAfterRename(
        episodeId: episode.id,
        relativePath: renamed.relativePath,
        title: nasSourceTitle(sourceName),
        fileSize: stat.size,
        mediaModifiedAt: stat.modified.microsecondsSinceEpoch,
      );
      if (updated == null)
        throw StateError('episode disappeared during rename');
      await writeApiJson(request.response, HttpStatus.ok, {
        'data': _presenter.adminEpisodePayload(updated),
      });
    } on NasMediaRenameException catch (error) {
      return writeApiError(
        request,
        error.code == 'source_name_conflict'
            ? HttpStatus.conflict
            : error.code == 'resource_not_found'
                ? HttpStatus.notFound
                : HttpStatus.badRequest,
        error.code,
      );
    } on Object {
      if (renamed != null) {
        await _mediaService.restoreRenamedFile(
          renamedFile: renamed,
          originalRelativePath: episode.relativePath,
          rootPath: mediaRoot.containerPath == config.mediaDir
              ? null
              : mediaRoot.containerPath,
        );
      }
      return writeApiError(request, HttpStatus.internalServerError,
          'source_metadata_update_failed');
    }
  }

  Future<void> emptyItems(HttpRequest request) => writeApiJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {'items': const []},
        },
      );
}
