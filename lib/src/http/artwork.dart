import 'dart:async';
import 'dart:io';

import '../artwork_service.dart';
import '../auth.dart';
import '../config.dart';
import '../fixture_library.dart';
import '../library_database.dart';
import '../video_poster.dart';

import 'media_resolver.dart';
import 'response.dart';
import 'presenter.dart';

/// Artwork reads, uploads and managed asset changes.
class NasArtworkHttpApi {
  NasArtworkHttpApi({
    required NasLibraryDatabase libraryDatabase,
    required NasArtworkService artworkService,
    required NasFixtureLibrary library,
    required this.config,
    required NasLibraryPresenter presenter,
    required NasMediaResolver media,
  })  : _libraryDatabase = libraryDatabase,
        _artworkService = artworkService,
        _library = library,
        _presenter = presenter,
        _media = media;
  final NasLibraryDatabase _libraryDatabase;
  final NasConfig config;
  final NasFixtureLibrary _library;
  final NasArtworkService _artworkService;
  final NasLibraryPresenter _presenter;
  final NasMediaResolver _media;
  final _videoPoster = NasVideoPoster();

  Future<void> previewVideoPoster(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    final movieId = segments[4];
    final episodeId = segments[6];
    final query = request.uri.queryParameters;
    int? read(String key) => int.tryParse(query[key] ?? '');
    final startMs = read('startMs');
    final durationMs = read('durationMs') ?? 0;
    VideoPosterCrop? crop;
    if (startMs == null || startMs < 0 || startMs > 7 * 24 * 3600000) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    if (query.containsKey('durationMs')) {
      final x = read('x');
      final y = read('y');
      final width = read('width');
      final height = read('height');
      if (durationMs < 1000 ||
          durationMs > 8000 ||
          x == null ||
          y == null ||
          width == null ||
          height == null ||
          x < 0 ||
          y < 0 ||
          width < 600 ||
          height < 900 ||
          x + width > 16384 ||
          y + height > 16384 ||
          width * 3 != height * 2) {
        return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
      }
      crop = (x: x, y: y, width: width, height: height);
    }
    final episode = _libraryDatabase.findEpisode(episodeId);
    if (episode == null ||
        episode.movieId != movieId ||
        !episode.isAvailable ||
        _libraryDatabase.findMovie(movieId) == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final file = await _media.fileForEpisode(episode);
    if (file == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (_videoPoster.busy) {
      return writeApiError(request, HttpStatus.conflict, 'video_poster_busy');
    }
    final image = await _videoPoster.render(file.file,
        startMs: startMs, durationMs: durationMs, crop: crop);
    if (image == null) {
      return writeApiError(
          request, HttpStatus.badRequest, 'video_poster_failed');
    }
    if (_libraryDatabase.findEpisode(episodeId)?.movieId != movieId) {
      return writeApiError(
          request, HttpStatus.conflict, 'collection_selection_changed');
    }
    request.response.headers
      ..contentType =
          ContentType.parse(crop == null ? 'image/png' : 'image/webp')
      ..contentLength = image.length
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.add(image);
    await request.response.close();
  }

  Future<NasManagedAsset?> saveManagedImage(
    HttpRequest request,
    String purpose,
  ) async {
    final mimeType = request.headers.contentType?.mimeType;
    final bytes = await _readArtworkBytes(request, mimeType);
    if (bytes == null || mimeType == null) return null;
    final assetId = newUuidV4();
    String? fileName;
    try {
      fileName = await _artworkService.saveManagedAsset(
        assetId: assetId,
        mimeType: mimeType,
        bytes: bytes,
      );
      return _libraryDatabase.addManagedAsset(
        id: assetId,
        purpose: purpose,
        fileName: fileName,
        mimeType: mimeType,
      );
    } on ArgumentError {
      if (fileName != null) await _artworkService.deleteManagedAsset(fileName);
      return null;
    }
  }

  Future<void> deleteManagedAsset(NasManagedAsset? asset) async {
    if (asset == null) return;
    _libraryDatabase.removeManagedAsset(asset.id);
    await _artworkService.deleteManagedAsset(asset.fileName);
  }

  Future<void> uploadManagedImage(HttpRequest request) async {
    final purpose = request.uri.queryParameters['purpose'];
    final mimeType = request.headers.contentType?.mimeType;
    if (!const {
      'actor_photo',
      'actor_backdrop',
      'movie_poster',
      'publisher_logo',
      'series_poster',
    }.contains(purpose)) {
      await request.drain<void>();
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final bytes = await _readArtworkBytes(request, mimeType);
    if (bytes == null || mimeType == null) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final assetId = newUuidV4();
    String? fileName;
    try {
      fileName = await _artworkService.saveManagedAsset(
        assetId: assetId,
        mimeType: mimeType,
        bytes: bytes,
      );
      final asset = _libraryDatabase.addManagedAsset(
        id: assetId,
        purpose: purpose!,
        fileName: fileName,
        mimeType: mimeType,
      );
      await writeApiJson(request.response, HttpStatus.created, {
        'data': _presenter.managedAssetPayload(asset),
      });
    } on ArgumentError {
      if (fileName != null) await _artworkService.deleteManagedAsset(fileName);
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
  }

  Future<NasManagedAsset?> saveManagedImageBytes({
    required String purpose,
    required List<int>? bytes,
    required String? mimeType,
  }) async {
    if (bytes == null || mimeType == null) return null;
    final assetId = newUuidV4();
    String? fileName;
    try {
      fileName = await _artworkService.saveManagedAsset(
        assetId: assetId,
        mimeType: mimeType,
        bytes: bytes,
      );
      return _libraryDatabase.addManagedAsset(
        id: assetId,
        purpose: purpose,
        fileName: fileName,
        mimeType: mimeType,
      );
    } on ArgumentError {
      if (fileName != null) await _artworkService.deleteManagedAsset(fileName);
      return null;
    }
  }

  Future<void> managedAsset(HttpRequest request) async {
    final asset =
        _libraryDatabase.findManagedAsset(request.uri.pathSegments.last);
    if (asset == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final artwork = await _artworkService.managedAsset(asset.fileName);
    if (artwork == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    return _serveArtwork(request, artwork);
  }

  Future<void> _serveArtwork(
      HttpRequest request, NasArtworkFile artwork) async {
    final stat = await artwork.file.stat();
    final etag =
        'W/"${artwork.file.uri.pathSegments.last}-${stat.size}-${stat.modified.microsecondsSinceEpoch}"';
    request.response.headers.set(HttpHeaders.etagHeader, etag);
    request.response.headers
        .set(HttpHeaders.cacheControlHeader, 'private, no-cache');
    if (request.headers.value(HttpHeaders.ifNoneMatchHeader) == etag) {
      request.response.statusCode = HttpStatus.notModified;
      return request.response.close();
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.parse(artwork.mimeType);
    request.response.headers.contentLength = stat.size;
    if (request.method == 'GET')
      await request.response.addStream(artwork.file.openRead());
    await request.response.close();
  }

  Future<void> poster(HttpRequest request) async {
    final movieId = request.uri.pathSegments.last;
    final databaseMovie = _libraryDatabase.findMovie(movieId);
    if (databaseMovie != null) {
      final artwork =
          await _artworkService.poster(databaseMovie.posterFileName);
      if (artwork == null) {
        return await writeApiError(
            request, HttpStatus.notFound, 'resource_not_found');
      }
      return _serveArtwork(request, artwork);
    }
    final bytes = _library.poster(movieId);
    if (bytes == null)
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType('image', 'png');
    request.response.headers.contentLength = bytes.length;
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (request.method == 'GET') request.response.add(bytes);
    await request.response.close();
  }

  Future<void> uploadAdminMoviePoster(HttpRequest request) async {
    final movieId = request.uri.pathSegments[4];
    final movie = _libraryDatabase.findMovieForAdmin(movieId);
    final mimeType = request.headers.contentType?.mimeType;
    if (movie == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (mimeType == null ||
        !const {'image/png', 'image/jpeg', 'image/webp'}.contains(mimeType) ||
        request.headers.contentLength > NasArtworkService.maxPosterBytes) {
      // Consume an oversized request before writing the error response. If the
      // body is left unread, dart:io may close the connection early and clients
      // observe a truncated JSON error (for example curl error 18).
      await request.drain<void>();
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final bytes = <int>[];
    var oversized = false;
    await for (final chunk in request) {
      if (oversized) continue;
      if (bytes.length + chunk.length > NasArtworkService.maxPosterBytes) {
        oversized = true;
        continue;
      }
      bytes.addAll(chunk);
    }
    if (oversized) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    if (!NasArtworkService.isValidPosterBytes(
      mimeType: mimeType,
      bytes: bytes,
    )) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final fileName = await _artworkService.savePoster(
      movieId: movieId,
      mimeType: mimeType,
      bytes: bytes,
    );
    final updatedMovie = _libraryDatabase.updateMoviePosterFileName(
      movieId: movieId,
      posterFileName: fileName,
    );
    if (updatedMovie == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (movie.posterFileName != null && movie.posterFileName != fileName) {
      await _artworkService.deletePoster(movie.posterFileName);
    }
    _libraryDatabase.markMovieMetadataFieldsManual(
      movieId: movieId,
      fieldKeys: const ['poster'],
    );
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {'posterUrl': '/api/v1/assets/posters/$movieId'},
    });
  }

  Future<void> uploadAdminMovieCarouselImage(HttpRequest request) =>
      uploadMovieCarouselImage(
        request,
        movieIdForUpload: () => request.uri.pathSegments[4],
      );

  Future<void> uploadMovieCarouselImage(
    HttpRequest request, {
    required String? Function() movieIdForUpload,
    bool allowHiddenMovie = true,
  }) async {
    final movieId = movieIdForUpload();
    final findMovie = allowHiddenMovie
        ? _libraryDatabase.findMovieForAdmin
        : _libraryDatabase.findMovie;
    final mimeType = request.headers.contentType?.mimeType;
    if (movieId == null || findMovie(movieId) == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final bytes = await _readArtworkBytes(request, mimeType);
    if (bytes == null || mimeType == null) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    String? fileName;
    try {
      fileName = await _artworkService.saveCarouselImage(
        movieId: movieId,
        mimeType: mimeType,
        bytes: bytes,
      );
      if (movieIdForUpload() != movieId || findMovie(movieId) == null) {
        await _artworkService.deleteCarouselImage(fileName);
        return await writeApiError(
          request,
          HttpStatus.notFound,
          'resource_not_found',
        );
      }
      final image = _libraryDatabase.addCarouselImage(
        movieId: movieId,
        fileName: fileName,
      );
      if (image == null) {
        await _artworkService.deleteCarouselImage(fileName);
        return await writeApiError(
          request,
          HttpStatus.notFound,
          'resource_not_found',
        );
      }
      await writeApiJson(request.response, HttpStatus.created, {
        'data': {
          'id': image.id,
          'url': '/api/v1/assets/carousel-images/${image.id}',
        },
      });
    } on ArgumentError {
      if (fileName != null) await _artworkService.deleteCarouselImage(fileName);
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
  }

  Future<void> deleteAdminMovieCarouselImage(HttpRequest request) async {
    final image = _libraryDatabase.removeCarouselImage(
      movieId: request.uri.pathSegments[4],
      imageId: request.uri.pathSegments[6],
    );
    if (image == null)
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    await _artworkService.deleteCarouselImage(image.fileName);
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> carouselImage(HttpRequest request) async {
    final image =
        _libraryDatabase.findCarouselImage(request.uri.pathSegments.last);
    if (image == null)
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    final artwork = await _artworkService.carouselImage(image.fileName);
    if (artwork == null)
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    return _serveArtwork(request, artwork);
  }

  Future<List<int>?> _readArtworkBytes(
    HttpRequest request,
    String? mimeType,
  ) async {
    if (mimeType == null ||
        !const {'image/png', 'image/jpeg', 'image/webp'}.contains(mimeType) ||
        request.headers.contentLength > NasArtworkService.maxPosterBytes) {
      await request.drain<void>();
      return null;
    }
    final bytes = <int>[];
    var oversized = false;
    await for (final chunk in request) {
      if (oversized) continue;
      if (bytes.length + chunk.length > NasArtworkService.maxPosterBytes) {
        oversized = true;
        continue;
      }
      bytes.addAll(chunk);
    }
    if (oversized ||
        !NasArtworkService.isValidPosterBytes(
            mimeType: mimeType, bytes: bytes)) {
      return null;
    }
    return bytes;
  }
}
