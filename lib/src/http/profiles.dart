import 'dart:async';
import 'dart:io';

import '../artwork_service.dart';
import '../library_database.dart';

import 'response.dart';
import 'validation.dart';
import 'presenter.dart';
import 'artwork.dart';

/// Actor, publisher and series profile operations.
class NasProfilesHttpApi {
  NasProfilesHttpApi({
    required NasLibraryDatabase libraryDatabase,
    required NasArtworkService artworkService,
    required NasLibraryPresenter presenter,
    required NasArtworkHttpApi assets,
  })  : _libraryDatabase = libraryDatabase,
        _artworkService = artworkService,
        _presenter = presenter,
        _assets = assets;
  final NasLibraryDatabase _libraryDatabase;
  final NasLibraryPresenter _presenter;
  final NasArtworkHttpApi _assets;
  final NasArtworkService _artworkService;

  Future<void> actors(HttpRequest request) async {
    final parameters = request.uri.queryParameters;
    final gender = parameters['gender'];
    final includeArchived = parameters['includeArchived'] == 'true';
    final allowedGenders = const {'female', 'intersex', 'male'};
    if (gender != null && !allowedGenders.contains(gender)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '24') ?? 0;
    final sort = parameters['sort'] ?? 'createdAt';
    final order = parameters['order'] ?? 'desc';
    if (page < 1 ||
        pageSize < 1 ||
        pageSize > 100 ||
        !const {'age', 'movieCount', 'createdAt', 'debutMonth'}
            .contains(sort) ||
        !const {'asc', 'desc'}.contains(order)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final actors = _libraryDatabase
        .listActors(
          query: parameters['q'] ?? '',
          gender: gender,
          includeArchived: includeArchived,
        )
        .toList();
    actors.sort((left, right) => nasCompareActors(left, right, sort, order));
    final offset = (page - 1) * pageSize;
    final items = offset >= actors.length
        ? const <NasActor>[]
        : actors.skip(offset).take(pageSize).toList(growable: false);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items.map(_presenter.actorPayload).toList(growable: false),
      },
      'page': {
        'number': page,
        'size': pageSize,
        'total': actors.length,
        'hasMore': offset + items.length < actors.length,
      },
    });
  }

  Future<void> actorDetails(HttpRequest request) async {
    final actor = _libraryDatabase.findActor(request.uri.pathSegments.last);
    if (actor == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _presenter.actorPayload(actor),
    });
  }

  Future<void> actorCoactors(HttpRequest request) async {
    final actorId = request.uri.pathSegments[3];
    if (_libraryDatabase.findActor(actorId) == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final page = int.tryParse(request.uri.queryParameters['page'] ?? '1') ?? 0;
    final pageSize =
        int.tryParse(request.uri.queryParameters['pageSize'] ?? '9') ?? 0;
    if (page < 1 || pageSize < 1 || pageSize > 9) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final coactors = _libraryDatabase.coactorsForActor(actorId);
    final offset = (page - 1) * pageSize;
    final items = offset >= coactors.length
        ? const <NasActorCoactor>[]
        : coactors.skip(offset).take(pageSize).toList(growable: false);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items
            .map(
              (item) => {
                'actor': _presenter.actorPayload(item.actor),
                'movieCount': item.movieCount,
              },
            )
            .toList(growable: false),
      },
      'page': {
        'number': page,
        'size': pageSize,
        'total': coactors.length,
        'hasMore': offset + items.length < coactors.length,
      },
    });
  }

  Future<void> actorMovies(HttpRequest request) async {
    final actorId = request.uri.pathSegments[3];
    if (_libraryDatabase.findActor(actorId) == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final parameters = request.uri.queryParameters;
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '14') ?? 0;
    final sort = parameters['sort'] ?? 'recent';
    final order = parameters['order'] ?? 'desc';
    final categoryId = parameters['categoryId'];
    final isFavorite = nasFavoriteFilter(parameters['isFavorite']);
    final resolutions = parameters['resolutions']
        ?.split(',')
        .where((value) => value.isNotEmpty)
        .toSet();
    if (page < 1 ||
        pageSize < 1 ||
        pageSize > 14 ||
        !const {'recent', 'createdAt', 'title', 'durationMs'}.contains(sort) ||
        !const {'asc', 'desc'}.contains(order) ||
        !nasIsValidFavoriteFilter(parameters['isFavorite']) ||
        (categoryId != null &&
            _libraryDatabase.findCategory(categoryId) == null)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final movies = _libraryDatabase
        .moviesForActor(actorId, query: parameters['q'] ?? '')
        .where((movie) =>
            (categoryId == null ||
                _presenter.categoryForMoviePayload(movie.id)?['id'] ==
                    categoryId) &&
            (isFavorite == null || movie.isFavorite == isFavorite) &&
            (resolutions == null ||
                resolutions.isEmpty ||
                (movie.resolutionLabel != null &&
                    resolutions.contains(movie.resolutionLabel))))
        .toList();
    movies
        .sort((left, right) => nasCompareActorMovies(left, right, sort, order));
    final offset = (page - 1) * pageSize;
    final items = offset >= movies.length
        ? const <NasLibraryMovie>[]
        : movies.skip(offset).take(pageSize).toList(growable: false);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items.map(_presenter.databaseSummary).toList(growable: false),
      },
      'page': {
        'number': page,
        'size': pageSize,
        'total': movies.length,
        'hasMore': offset + items.length < movies.length,
      },
    });
  }

  Future<void> createAdminActor(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    final values = nasActorInputValues(body, creating: true);
    if (values == null) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final photoAssetId = values['photo_asset_id'] as String?;
    if (photoAssetId != null &&
        _libraryDatabase.findManagedAsset(photoAssetId)?.purpose !=
            'actor_photo') {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final aliases = nasStringListFromJson(values['aliases_json'] as String?);
    final publisherIds =
        (values.remove('publisher_ids') as List<String>?) ?? const <String>[];
    final similarActors = _libraryDatabase.findSimilarActors(
      stageName: values['stage_name'] as String?,
      originalName: values['original_name'] as String?,
      translatedName: values['translated_name'] as String?,
      aliases: aliases,
    );
    final actor = _libraryDatabase.createActor(
      stageName: values['stage_name'] as String?,
      originalName: values['original_name'] as String?,
      translatedName: values['translated_name'] as String?,
      aliases: aliases,
      gender: values['gender'] as String?,
      romanizedName: values['romanized_name'] as String?,
      birthDate: values['birth_date'] as String?,
      birthMonth: values['birth_month'] as String?,
      heightCm: values['height_cm'] as int?,
      weightKg: values['weight_kg'] as int?,
      measurements: values['measurements'] as String?,
      bodyType: values['body_type'] as String?,
      country: values['country'] as String?,
      debutMonth: values['debut_month'] as String?,
      debutDescription: values['debut_description'] as String?,
      photoAssetId: photoAssetId,
    );
    if (!_libraryDatabase.setActorPublisherIds(
      actorId: actor.id,
      publisherIds: publisherIds,
    )) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    await writeApiJson(request.response, HttpStatus.created, {
      'data': {
        'actor': _presenter.actorPayload(actor),
        'similarActors':
            similarActors.map(_presenter.actorPayload).toList(growable: false),
      },
    });
  }

  Future<void> updateAdminActor(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    final values = nasActorInputValues(body, creating: false);
    if (values == null || values.isEmpty) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final photoAssetId = values['photo_asset_id'] as String?;
    if (values.containsKey('photo_asset_id') &&
        photoAssetId != null &&
        _libraryDatabase.findManagedAsset(photoAssetId)?.purpose !=
            'actor_photo') {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final publisherIds = values.remove('publisher_ids') as List<String>?;
    final actor = _libraryDatabase.updateActor(
      request.uri.pathSegments.last,
      values,
    );
    if (actor == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (publisherIds != null &&
        !_libraryDatabase.setActorPublisherIds(
          actorId: actor.id,
          publisherIds: publisherIds,
        )) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _presenter.actorPayload(actor),
    });
  }

  Future<void> archiveAdminActor(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    if (body == null || body.isNotEmpty) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final actor = _libraryDatabase.archiveActor(request.uri.pathSegments[4]);
    if (actor == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _presenter.actorPayload(actor),
    });
  }

  Future<void> deleteAdminActor(HttpRequest request) async {
    final actorId = request.uri.pathSegments.last;
    final actor = _libraryDatabase.findActor(actorId);
    if (actor == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (actor.movieCount > 0) {
      return writeApiError(request, HttpStatus.conflict, 'actor_in_use');
    }
    final photoAsset = actor.photoAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(actor.photoAssetId!);
    final backdropAsset = actor.backdropAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(actor.backdropAssetId!);
    if (!_libraryDatabase.deleteActor(actorId)) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (photoAsset != null) {
      // 删除演员时同步移除其 NAS 受管理照片，避免遗留孤立资产记录或文件。
      _libraryDatabase.removeManagedAsset(photoAsset.id);
      await _artworkService.deleteManagedAsset(photoAsset.fileName);
    }
    if (backdropAsset != null) {
      _libraryDatabase.removeManagedAsset(backdropAsset.id);
      await _artworkService.deleteManagedAsset(backdropAsset.fileName);
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {'deleted': true},
    });
  }

  Future<void> publishers(HttpRequest request) async {
    final parameters = request.uri.queryParameters;
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '24') ?? 0;
    final sort = parameters['sort'] ?? 'createdAt';
    final order = parameters['order'] ?? 'desc';
    if (page < 1 ||
        pageSize < 1 ||
        pageSize > 100 ||
        !const {'createdAt', 'name', 'movieCount', 'seriesCount'}
            .contains(sort) ||
        !const {'asc', 'desc'}.contains(order)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final publishers = _libraryDatabase
        .listPublishers(
          query: parameters['q'] ?? '',
          includeArchived: parameters['includeArchived'] == 'true',
        )
        .toList()
      ..sort((left, right) => nasComparePublishers(left, right, sort, order));
    final offset = (page - 1) * pageSize;
    final items = offset >= publishers.length
        ? const <NasPublisher>[]
        : publishers.skip(offset).take(pageSize).toList(growable: false);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items.map(_presenter.publisherPayload).toList(growable: false)
      },
      'page': {
        'number': page,
        'size': pageSize,
        'total': publishers.length,
        'hasMore': offset + items.length < publishers.length,
      },
    });
  }

  Future<void> publisherDetails(HttpRequest request) async {
    final publisher =
        _libraryDatabase.findPublisher(request.uri.pathSegments.last);
    if (publisher == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _presenter.publisherPayload(publisher, includeTags: true),
    });
  }

  Future<void> publisherMovies(HttpRequest request) async {
    final publisherId = request.uri.pathSegments[3];
    if (_libraryDatabase.findPublisher(publisherId) == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    return _relatedMovies(
      request,
      _libraryDatabase.moviesForPublisher(
        publisherId,
        query: request.uri.queryParameters['q'] ?? '',
      ),
    );
  }

  Future<void> publisherSeries(HttpRequest request) async {
    final publisherId = request.uri.pathSegments[3];
    if (_libraryDatabase.findPublisher(publisherId) == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final parameters = request.uri.queryParameters;
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '24') ?? 0;
    final sort = parameters['sort'] ?? 'createdAt';
    final order = parameters['order'] ?? 'desc';
    if (page < 1 ||
        pageSize < 1 ||
        pageSize > 100 ||
        !const {'createdAt', 'name', 'movieCount', 'releaseDate'}
            .contains(sort) ||
        !const {'asc', 'desc'}.contains(order)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final series = _libraryDatabase
        .seriesForPublisher(publisherId, query: parameters['q'] ?? '')
        .toList()
      ..sort((left, right) => nasCompareSeries(left, right, sort, order));
    final offset = (page - 1) * pageSize;
    final items = offset >= series.length
        ? const <NasSeries>[]
        : series.skip(offset).take(pageSize).toList(growable: false);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items.map(_presenter.seriesPayload).toList(growable: false)
      },
      'page': {
        'number': page,
        'size': pageSize,
        'total': series.length,
        'hasMore': offset + items.length < series.length,
      },
    });
  }

  Future<void> publisherActors(HttpRequest request) async {
    final publisherId = request.uri.pathSegments[3];
    if (_libraryDatabase.findPublisher(publisherId) == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    return _relatedActors(
      request,
      _libraryDatabase.actorsForPublisher(publisherId),
    );
  }

  Future<void> series(HttpRequest request) async {
    final parameters = request.uri.queryParameters;
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '24') ?? 0;
    final sort = parameters['sort'] ?? 'createdAt';
    final order = parameters['order'] ?? 'desc';
    final publisherId = parameters['publisherId'];
    if (page < 1 ||
        pageSize < 1 ||
        pageSize > 100 ||
        (publisherId != null &&
            _libraryDatabase.findPublisher(publisherId) == null) ||
        !const {'createdAt', 'name', 'movieCount', 'releaseDate'}
            .contains(sort) ||
        !const {'asc', 'desc'}.contains(order)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final series = _libraryDatabase
        .listSeries(
          query: parameters['q'] ?? '',
          publisherId: publisherId,
          includeArchived: parameters['includeArchived'] == 'true',
        )
        .toList()
      ..sort((left, right) => nasCompareSeries(left, right, sort, order));
    final offset = (page - 1) * pageSize;
    final items = offset >= series.length
        ? const <NasSeries>[]
        : series.skip(offset).take(pageSize).toList(growable: false);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items.map(_presenter.seriesPayload).toList(growable: false)
      },
      'page': {
        'number': page,
        'size': pageSize,
        'total': series.length,
        'hasMore': offset + items.length < series.length,
      },
    });
  }

  Future<void> seriesDetails(HttpRequest request) async {
    final series = _libraryDatabase.findSeries(request.uri.pathSegments.last);
    if (series == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _presenter.seriesPayload(series, includeTags: true),
    });
  }

  Future<void> seriesMovies(HttpRequest request) async {
    final seriesId = request.uri.pathSegments[3];
    if (_libraryDatabase.findSeries(seriesId) == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    return _relatedMovies(
      request,
      _libraryDatabase.moviesForSeries(
        seriesId,
        query: request.uri.queryParameters['q'] ?? '',
      ),
    );
  }

  Future<void> seriesActors(HttpRequest request) async {
    final seriesId = request.uri.pathSegments[3];
    if (_libraryDatabase.findSeries(seriesId) == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    return _relatedActors(
      request,
      _libraryDatabase.actorsForSeries(seriesId),
    );
  }

  Future<void> _relatedMovies(
    HttpRequest request,
    List<NasLibraryMovie> source,
  ) async {
    final parameters = request.uri.queryParameters;
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '14') ?? 0;
    final sort = parameters['sort'] ?? 'recent';
    final order = parameters['order'] ?? 'desc';
    final categoryId = parameters['categoryId'];
    final isFavorite = nasFavoriteFilter(parameters['isFavorite']);
    final resolutions = parameters['resolutions']
        ?.split(',')
        .where((value) => value.isNotEmpty)
        .toSet();
    if (page < 1 ||
        pageSize < 1 ||
        pageSize > 14 ||
        !const {'recent', 'createdAt', 'title', 'durationMs'}.contains(sort) ||
        !const {'asc', 'desc'}.contains(order) ||
        !nasIsValidFavoriteFilter(parameters['isFavorite']) ||
        (categoryId != null &&
            _libraryDatabase.findCategory(categoryId) == null)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final movies = source
        .where((movie) =>
            (categoryId == null ||
                _presenter.categoryForMoviePayload(movie.id)?['id'] ==
                    categoryId) &&
            (isFavorite == null || movie.isFavorite == isFavorite) &&
            (resolutions == null ||
                resolutions.isEmpty ||
                (movie.resolutionLabel != null &&
                    resolutions.contains(movie.resolutionLabel))))
        .toList()
      ..sort((left, right) => nasCompareActorMovies(left, right, sort, order));
    final offset = (page - 1) * pageSize;
    final items = offset >= movies.length
        ? const <NasLibraryMovie>[]
        : movies.skip(offset).take(pageSize).toList(growable: false);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items.map(_presenter.databaseSummary).toList(growable: false)
      },
      'page': {
        'number': page,
        'size': pageSize,
        'total': movies.length,
        'hasMore': offset + items.length < movies.length,
      },
    });
  }

  Future<void> _relatedActors(
    HttpRequest request,
    List<NasRelatedActor> source,
  ) async {
    final page = int.tryParse(request.uri.queryParameters['page'] ?? '1') ?? 0;
    final pageSize =
        int.tryParse(request.uri.queryParameters['pageSize'] ?? '9') ?? 0;
    if (page < 1 || pageSize < 1 || pageSize > 100) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final offset = (page - 1) * pageSize;
    final items = offset >= source.length
        ? const <NasRelatedActor>[]
        : source.skip(offset).take(pageSize).toList(growable: false);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items
            .map((item) => {
                  'actor': _presenter.actorPayload(item.actor),
                  'movieCount': item.movieCount,
                })
            .toList(growable: false),
      },
      'page': {
        'number': page,
        'size': pageSize,
        'total': source.length,
        'hasMore': offset + items.length < source.length,
      },
    });
  }

  Future<void> createAdminPublisher(HttpRequest request) async {
    final values =
        nasPublisherInputValues(await readApiJsonBody(request), creating: true);
    if (values == null) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final logoAssetId = values['logo_asset_id'] as String?;
    if (logoAssetId != null &&
        _libraryDatabase.findManagedAsset(logoAssetId)?.purpose !=
            'publisher_logo') {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final publisher = _libraryDatabase.createPublisher(
      displayName: values['display_name'] as String,
      originalName: values['original_name'] as String?,
      countryRegion: values['country_region'] as String?,
      foundedDate: values['founded_date'] as String?,
      logoAssetId: logoAssetId,
    );
    await writeApiJson(request.response, HttpStatus.created, {
      'data': _presenter.publisherPayload(publisher),
    });
  }

  Future<void> updateAdminPublisher(HttpRequest request) async {
    final values = nasPublisherInputValues(await readApiJsonBody(request),
        creating: false);
    if (values == null || values.isEmpty) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final logoAssetId = values['logo_asset_id'] as String?;
    if (values.containsKey('logo_asset_id') &&
        logoAssetId != null &&
        _libraryDatabase.findManagedAsset(logoAssetId)?.purpose !=
            'publisher_logo') {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final publisher = _libraryDatabase.updatePublisher(
      request.uri.pathSegments.last,
      values,
    );
    if (publisher == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _presenter.publisherPayload(publisher),
    });
  }

  Future<void> archiveAdminPublisher(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    if (body == null || body.isNotEmpty) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final publisher =
        _libraryDatabase.archivePublisher(request.uri.pathSegments[4]);
    if (publisher == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _presenter.publisherPayload(publisher),
    });
  }

  Future<void> deleteAdminPublisher(HttpRequest request) async {
    final id = request.uri.pathSegments.last;
    final publisher = _libraryDatabase.findPublisher(id);
    if (publisher == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (_libraryDatabase.publisherHasReferences(id)) {
      return writeApiError(request, HttpStatus.conflict, 'publisher_in_use');
    }
    final logo = publisher.logoAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(publisher.logoAssetId!);
    if (!_libraryDatabase.deletePublisher(id)) {
      return writeApiError(request, HttpStatus.conflict, 'publisher_in_use');
    }
    await _assets.deleteManagedAsset(logo);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {'deleted': true},
    });
  }

  Future<void> createAdminSeries(HttpRequest request) async {
    final values =
        nasSeriesInputValues(await readApiJsonBody(request), creating: true);
    if (values == null) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final publisherId = values['publisher_id'] as String?;
    final publisher = publisherId == null
        ? null
        : _libraryDatabase.findPublisher(publisherId);
    final posterAssetId = values['poster_asset_id'] as String?;
    if ((publisherId != null &&
            (publisher == null || publisher.archivedAt != null)) ||
        (posterAssetId != null &&
            _libraryDatabase.findManagedAsset(posterAssetId)?.purpose !=
                'series_poster')) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final series = _libraryDatabase.createSeries(
      displayName: values['display_name'] as String,
      publisherId: publisherId,
      originalName: values['original_name'] as String?,
      translatedName: values['translated_name'] as String?,
      releaseDate: values['release_date'] as String?,
      posterAssetId: posterAssetId,
    );
    await writeApiJson(request.response, HttpStatus.created, {
      'data': _presenter.seriesPayload(series),
    });
  }

  Future<void> updateAdminSeries(HttpRequest request) async {
    final seriesId = request.uri.pathSegments.last;
    final existing = _libraryDatabase.findSeries(seriesId);
    if (existing == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final values =
        nasSeriesInputValues(await readApiJsonBody(request), creating: false);
    if (values == null || values.isEmpty) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final publisherId = values['publisher_id'] as String?;
    final posterAssetId = values['poster_asset_id'] as String?;
    if ((publisherId != null &&
            (_libraryDatabase.findPublisher(publisherId)?.archivedAt != null ||
                _libraryDatabase.findPublisher(publisherId) == null)) ||
        (values.containsKey('publisher_id') &&
            publisherId != existing.publisherId &&
            existing.movieCount > 0) ||
        (values.containsKey('poster_asset_id') &&
            posterAssetId != null &&
            _libraryDatabase.findManagedAsset(posterAssetId)?.purpose !=
                'series_poster')) {
      return writeApiError(request, HttpStatus.conflict, 'series_in_use');
    }
    final series = _libraryDatabase.updateSeries(seriesId, values);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _presenter.seriesPayload(series!),
    });
  }

  Future<void> archiveAdminSeries(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    if (body == null || body.isNotEmpty) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final series = _libraryDatabase.archiveSeries(request.uri.pathSegments[4]);
    if (series == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _presenter.seriesPayload(series),
    });
  }

  Future<void> deleteAdminSeries(HttpRequest request) async {
    final id = request.uri.pathSegments.last;
    final series = _libraryDatabase.findSeries(id);
    if (series == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (series.movieCount > 0) {
      return writeApiError(request, HttpStatus.conflict, 'series_in_use');
    }
    final poster = series.posterAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(series.posterAssetId!);
    if (!_libraryDatabase.deleteSeries(id)) {
      return writeApiError(request, HttpStatus.conflict, 'series_in_use');
    }
    await _assets.deleteManagedAsset(poster);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {'deleted': true},
    });
  }

  Future<void> uploadAdminPublisherLogo(HttpRequest request) async {
    final publisher =
        _libraryDatabase.findPublisher(request.uri.pathSegments[4]);
    if (publisher == null) {
      await request.drain<void>();
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final asset = await _assets.saveManagedImage(request, 'publisher_logo');
    if (asset == null)
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    final previous = publisher.logoAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(publisher.logoAssetId!);
    final updated = _libraryDatabase.updatePublisher(
      publisher.id,
      {'logo_asset_id': asset.id},
    );
    if (updated == null)
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    await _assets.deleteManagedAsset(previous);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _presenter.publisherPayload(updated),
    });
  }

  Future<void> uploadAdminSeriesPoster(HttpRequest request) async {
    final series = _libraryDatabase.findSeries(request.uri.pathSegments[4]);
    if (series == null) {
      await request.drain<void>();
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final asset = await _assets.saveManagedImage(request, 'series_poster');
    if (asset == null)
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    final previous = series.posterAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(series.posterAssetId!);
    final updated = _libraryDatabase.updateSeries(
      series.id,
      {'poster_asset_id': asset.id},
    );
    if (updated == null)
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    await _assets.deleteManagedAsset(previous);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _presenter.seriesPayload(updated),
    });
  }
}
