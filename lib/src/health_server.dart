// Request handlers are dispatched independently so a long-lived media stream
// cannot block health checks or unrelated API requests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'artwork_service.dart';
import 'auth.dart';
import 'backup_service.dart';
import 'config.dart';
import 'diagnostic_log.dart';
import 'fixture_library.dart';
import 'library/taxonomy_transfer.dart';
import 'library_database.dart';
import 'media_service.dart';
import 'persistent_state.dart';
import 'range.dart';

class NasHealthServer {
  NasHealthServer(
    this.config, {
    NasPersistentStateStore? stateStore,
    NasFixtureLibrary? library,
    NasMediaService? mediaService,
    NasLibraryDatabase? libraryDatabase,
    NasArtworkService? artworkService,
    NasBackupService? backupService,
    NasDiagnosticLogger? logger,
  })  : _stateStore = stateStore ?? NasPersistentStateStore(config.dataDir),
        _library = library ?? NasFixtureLibrary(),
        _mediaService = mediaService ??
            NasMediaService(
              mediaDir: config.mediaDir,
              fixtureRelativePath: config.fixtureMediaRelativePath,
            ),
        _libraryDatabase =
            libraryDatabase ?? NasLibraryDatabase(config.dataDir),
        _artworkService = artworkService ?? NasArtworkService(config.dataDir),
        _backupService = backupService ?? NasBackupService(config.dataDir),
        _logger = logger ?? NasDiagnosticLogger();

  final NasConfig config;
  final NasPersistentStateStore _stateStore;
  final NasFixtureLibrary _library;
  final NasMediaService _mediaService;
  final NasLibraryDatabase _libraryDatabase;
  final NasArtworkService _artworkService;
  final NasBackupService _backupService;
  final NasDiagnosticLogger _logger;
  HttpServer? _server;
  NasPersistentState? _state;
  final Map<String, _PairingSession> _pairingSessions = {};
  final Map<String, _PlaybackSession> _playbackSessions = {};
  final Map<String, _ScanJob> _scanJobs = {};
  _FixturePlaybackState? _fixturePlaybackState;
  NasMediaRoot? _configuredMediaRoot;
  int _activeRequests = 0;
  int _activeStreams = 0;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? config.port;

  Future<void> start() async {
    if (_server != null) {
      throw StateError('NAS health server is already running.');
    }
    _logger.event('service.start', fields: {'component': 'nas.service', 'phase': 'startup'});
    _state =
        await _stateStore.load() ?? NasPersistentState(serverId: newUuidV4());
    await _persistState();
    await _libraryDatabase.open();
    _configuredMediaRoot = _libraryDatabase.ensureConfiguredMediaRoot(
      rootName: config.mediaRootName,
      containerPath: config.mediaDir,
    );
    if (!config.managedCategoryLibrary && config.scanOnStart) {
      await _libraryDatabase.scanMediaRoot(
        mediaRootId: _configuredMediaRoot!.id,
        mediaService: _mediaService,
      );
    }
    final server = await HttpServer.bind(config.bindHost, config.port);
    _server = server;
    _logger.event('service.ready', fields: {
      'component': 'nas.service',
      'serverIdShort': nasShortId(_state!.serverId),
      'port': server.port,
      'bindHost': config.bindHost,
      'activeRequests': _activeRequests,
      'activeStreams': _activeStreams,
    });
    unawaited(_serve(server));
  }

  Future<void> stop() async {
    _logger.event('service.stop', fields: {
      'component': 'nas.service',
      'activeRequests': _activeRequests,
      'activeStreams': _activeStreams,
      'cancelReason': 'shutdown',
    });
    final server = _server;
    _server = null;
    _pairingSessions.clear();
    _playbackSessions.clear();
    _scanJobs.clear();
    await server?.close(force: true);
    await _libraryDatabase.close();
  }

  Future<void> _serve(HttpServer server) async {
    try {
      await for (final request in server) {
        unawaited(_handle(request));
      }
    } on HttpException {
      // A client may disconnect while a health response is being sent.
      _logger.event('http.transport_error', level: 'WARN', fields: {
        'component': 'nas.http',
        'outcome': 'disconnect',
        'errorType': 'HttpException',
      });
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final stopwatch = Stopwatch()..start();
    final traceId = _safeIncomingId(request.headers.value('x-mujing-trace-id'), 't');
    final requestId = _safeIncomingId(request.headers.value('x-mujing-request-id'), 'r');
    final route = nasRouteTemplate(request.uri.path);
    _activeRequests++;
    _logger.event('http.request.start', fields: {
      'component': 'nas.http',
      'traceId': traceId,
      'requestId': requestId,
      'method': request.method,
      'route': route,
      'phase': 'handler_start',
      'pendingRequests': 0,
      'activeRequests': _activeRequests,
      'activeStreams': _activeStreams,
    });
    try {
      final path = request.uri.path;
      if (path == '/health') {
        return await _health(request);
      }
      if (request.method == 'GET' && path == '/api/v1/server-info') {
        return await _serverInfo(request);
      }
      if (request.method == 'POST' && path == '/api/v1/pairing/sessions') {
        return await _createPairingSession(request);
      }
      if (request.method == 'POST' &&
          RegExp(r'^/api/v1/pairing/sessions/[^/]+/confirm$').hasMatch(path)) {
        return await _confirmPairing(request);
      }
      if (!path.startsWith('/api/v1/')) {
        return await _error(request, HttpStatus.notFound, 'resource_not_found');
      }

      final tokenHash = _authenticatedTokenHash(request);
      final device = tokenHash == null ? null : _state!.tokens[tokenHash];
      if (device == null || tokenHash == null) {
        return await _error(
            request, HttpStatus.unauthorized, 'authentication_required');
      }
      if (path.startsWith('/api/v1/admin/') && device.scope != 'admin') {
        return await _error(request, HttpStatus.forbidden, 'insufficient_scope');
      }
      if (request.method == 'GET' && path == '/api/v1/admin/media-roots') {
        return await _adminMediaRoots(request);
      }
      if (request.method == 'GET' && path == '/api/v1/admin/media-directories') {
        return await _adminMediaDirectories(request);
      }
      if (request.method == 'GET' && path == '/api/v1/admin/devices') {
        return await _adminDevices(request);
      }
      if (request.method == 'DELETE' &&
          RegExp(r'^/api/v1/admin/devices/[^/]+$').hasMatch(path)) {
        return await _revokeAdminDevice(request);
      }
      if (request.method == 'POST' && path == '/api/v1/admin/backups') {
        return await _createAdminBackup(request);
      }
      if (request.method == 'GET' && path == '/api/v1/admin/backups') {
        return await _adminBackups(request);
      }
      if (request.method == 'GET' &&
          RegExp(r'^/api/v1/admin/backups/[^/]+$').hasMatch(path)) {
        return await _adminBackup(request);
      }
      if (request.method == 'GET' && path == '/api/v1/admin/categories') {
        return await _adminCategories(request);
      }
      if (request.method == 'GET' &&
          path == '/api/v1/admin/taxonomy/categories') {
        return await _exportAdminCategoryTaxonomy(request);
      }
      if (request.method == 'POST' &&
          path == '/api/v1/admin/taxonomy/categories') {
        return await _importAdminCategoryTaxonomy(request);
      }
      if (request.method == 'POST' && path == '/api/v1/admin/categories') {
        return await _createAdminCategory(request);
      }
      if (RegExp(r'^/api/v1/admin/categories/[^/]+$').hasMatch(path)) {
        if (request.method == 'PATCH') return await _updateAdminCategory(request);
        if (request.method == 'DELETE') return await _deleteAdminCategory(request);
      }
      if (request.method == 'GET' && path == '/api/v1/admin/tags') {
        return await _adminTags(request);
      }
      if (request.method == 'GET' && path == '/api/v1/admin/taxonomy/tags') {
        return await _exportAdminTagTaxonomy(request);
      }
      if (request.method == 'POST' && path == '/api/v1/admin/taxonomy/tags') {
        return await _importAdminTagTaxonomy(request);
      }
      if (request.method == 'POST' && path == '/api/v1/admin/tags') {
        return await _createAdminTag(request);
      }
      if (RegExp(r'^/api/v1/admin/tags/[^/]+$').hasMatch(path)) {
        if (request.method == 'PATCH') return await _updateAdminTag(request);
        if (request.method == 'DELETE') return await _deleteAdminTag(request);
      }
      if (request.method == 'GET' && path == '/api/v1/admin/tag-placements') {
        return await _adminTagPlacements(request);
      }
      if (request.method == 'POST' && path == '/api/v1/admin/tag-placements') {
        return await _createAdminTagPlacement(request);
      }
      if (RegExp(r'^/api/v1/admin/tag-placements/[^/]+$').hasMatch(path)) {
        if (request.method == 'PATCH') return await _updateAdminTagPlacement(request);
        if (request.method == 'DELETE')
          return await _deleteAdminTagPlacement(request);
      }
      if (request.method == 'PATCH' &&
          RegExp(r'^/api/v1/admin/movies/[^/]+$').hasMatch(path)) {
        return await _updateAdminMovie(request);
      }
      if (request.method == 'POST' &&
          RegExp(r'^/api/v1/admin/movies/[^/]+/poster$').hasMatch(path)) {
        return await _uploadAdminMoviePoster(request);
      }
      if (request.method == 'POST' &&
          RegExp(r'^/api/v1/admin/movies/[^/]+/carousel-images$').hasMatch(path)) {
        return await _uploadAdminMovieCarouselImage(request);
      }
      if (request.method == 'DELETE' &&
          RegExp(r'^/api/v1/admin/movies/[^/]+/carousel-images/[^/]+$')
              .hasMatch(path)) {
        return await _deleteAdminMovieCarouselImage(request);
      }
      if (request.method == 'PATCH' &&
          RegExp(r'^/api/v1/admin/episodes/[^/]+/source-name$').hasMatch(path)) {
        return await _renameAdminEpisodeSource(request);
      }
      if (request.method == 'PATCH' &&
          RegExp(r'^/api/v1/admin/episodes/[^/]+$').hasMatch(path)) {
        return await _updateAdminEpisode(request);
      }
      if (request.method == 'POST' && path == '/api/v1/admin/scan-jobs') {
        return await _createScanJob(request);
      }
      if (request.method == 'GET' && path == '/api/v1/admin/scan-jobs') {
        return await _listScanJobs(request);
      }
      if (request.method == 'GET' &&
          RegExp(r'^/api/v1/admin/scan-jobs/[^/]+$').hasMatch(path)) {
        return await _scanJob(request);
      }
      if (request.method == 'GET' && path == '/api/v1/movies') {
        return await _movies(request);
      }
      if (request.method == 'GET' && path == '/api/v1/categories') {
        return await _categories(request);
      }
      if (request.method == 'GET' &&
          RegExp(r'^/api/v1/movies/[^/]+$').hasMatch(path)) {
        return await _movieDetails(request);
      }
      if (request.method == 'GET' && path == '/api/v1/tag-paths') {
        return await _tagPaths(request);
      }
      if (request.method == 'GET' && path == '/api/v1/favorites') {
        return await _emptyItems(request);
      }
      if (request.method == 'GET' && path == '/api/v1/history') {
        return await _history(request);
      }
      if ((request.method == 'GET' || request.method == 'HEAD') &&
          RegExp(r'^/api/v1/assets/posters/[^/]+$').hasMatch(path)) {
        return await _poster(request);
      }
      if ((request.method == 'GET' || request.method == 'HEAD') &&
          RegExp(r'^/api/v1/assets/carousel-images/[^/]+$').hasMatch(path)) {
        return await _carouselImage(request);
      }
      if (request.method == 'POST' && path == '/api/v1/playback/sessions') {
        return await _createPlaybackSession(request, tokenHash);
      }
      if (request.method == 'POST' &&
          RegExp(r'^/api/v1/playback/sessions/[^/]+/started$')
              .hasMatch(path)) {
        return await _markPlaybackStarted(request, tokenHash);
      }
      if (request.method == 'PATCH' &&
          RegExp(r'^/api/v1/playback/sessions/[^/]+/progress$')
              .hasMatch(path)) {
        return await _savePlaybackProgress(request, tokenHash);
      }
      if (request.method == 'DELETE' &&
          RegExp(r'^/api/v1/playback/sessions/[^/]+$').hasMatch(path)) {
        return await _deletePlaybackSession(request, tokenHash);
      }
      if ((request.method == 'GET' || request.method == 'HEAD') &&
          RegExp(r'^/api/v1/playback/sessions/[^/]+/stream$').hasMatch(path)) {
        return await _streamPlayback(request, tokenHash);
      }
      await _error(request, HttpStatus.notFound, 'resource_not_found');
    } catch (error, stackTrace) {
      _logger.event('http.request.error', level: 'ERROR', fields: {
        'component': 'nas.http',
        'traceId': traceId,
        'requestId': requestId,
        'method': request.method,
        'route': route,
        'outcome': 'error',
        'errorType': error.runtimeType.toString(),
        'errorCode': 'service_unavailable',
        'stack': stackTrace.toString(),
      });
      try {
        await _error(
            request, HttpStatus.internalServerError, 'service_unavailable');
      } catch (_) {
        await request.response.close();
      }
    } finally {
      stopwatch.stop();
      final response = request.response;
      final status = response.statusCode;
      final bytes = response.headers.contentLength >= 0 ? response.headers.contentLength : null;
      _logger.event('http.response.headers', fields: {
        'component': 'nas.http',
        'traceId': traceId,
        'requestId': requestId,
        'method': request.method,
        'route': route,
        'status': status,
        'contentLength': bytes,
        'activeRequests': _activeRequests,
        'activeStreams': _activeStreams,
      });
      _logger.event('http.response.end', level: status >= 500 ? 'ERROR' : (status >= 400 ? 'WARN' : 'DEBUG'), fields: {
        'component': 'nas.http',
        'traceId': traceId,
        'requestId': requestId,
        'method': request.method,
        'route': route,
        'status': status,
        'outcome': status >= 400 ? 'http_error' : 'success',
        'durationMs': stopwatch.elapsedMilliseconds,
        'bytes': bytes,
        'phase': 'handler_end',
      });
      _activeRequests--;
    }
  }

  String _safeIncomingId(String? value, String prefix) {
    if (value != null && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(value)) return value;
    return _logger.newId(prefix);
  }

  Future<void> _health(HttpRequest request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      return _error(request, HttpStatus.methodNotAllowed, 'method_not_allowed');
    }
    await _writeJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {
            'status': 'ok',
            'service': 'mujing-nas',
            'version': '0.1.0',
          },
        },
        headOnly: request.method == 'HEAD');
  }

  Future<void> _serverInfo(HttpRequest request) async {
    final data = <String, Object>{
      'serverId': _state!.serverId,
      'serverName': config.serverName,
      'apiVersion': '1.0',
      'minimumClientVersion': '1.0.0',
      'pairingRequired': true,
      'capabilities': {
        'movies': true,
        'transcoding': false,
        'management': true,
      },
      'pairingScopes': const ['viewer', 'admin'],
    };
    if (config.advertiseUrl case final advertiseUrl?) {
      data['connection'] = {'endpoint': advertiseUrl};
    }
    await _writeJson(request.response, HttpStatus.ok, {'data': data});
  }

  Future<void> _createPairingSession(HttpRequest request) async {
    if (config.pairingCode == null) {
      return _error(
          request, HttpStatus.serviceUnavailable, 'pairing_not_configured');
    }
    final body = await _readJsonBody(request);
    if (body == null || body['serverId'] != _state!.serverId) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final requestedScope = body['requestedScope'] ?? 'viewer';
    if (requestedScope != 'viewer' && requestedScope != 'admin') {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 5));
    final sessionId = newUuidV4();
    _pairingSessions[sessionId] = _PairingSession(
      scope: requestedScope as String,
      expiresAt: expiresAt,
    );
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {
        'pairingSessionId': sessionId,
        'expiresAt': expiresAt.toIso8601String(),
      },
    });
  }

  Future<void> _confirmPairing(HttpRequest request) async {
    final sessionId = request.uri.pathSegments[4];
    final session = _pairingSessions.remove(sessionId);
    final body = await _readJsonBody(request);
    if (session == null ||
        session.expiresAt.isBefore(DateTime.now().toUtc()) ||
        body == null ||
        !constantTimeEquals(body['pairingPassword'] as String? ?? '',
            config.pairingCode ?? '')) {
      return _error(request, HttpStatus.unauthorized, 'pairing_failed');
    }
    final token = newOpaqueSecret();
    final deviceId = newUuidV4();
    final expiresAt = DateTime.now().toUtc().add(const Duration(days: 365));
    _state!.tokens[sha256Hex(token)] = NasDeviceToken(
      deviceId: deviceId,
      scope: session.scope,
      expiresAt: expiresAt,
    );
    await _persistState();
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {
        'deviceId': deviceId,
        'accessToken': token,
        'expiresAt': expiresAt.toIso8601String(),
        'scope': session.scope,
      },
    });
  }

  Future<void> _movies(HttpRequest request) {
    final hasDatabaseLibrary =
        config.managedCategoryLibrary || _libraryDatabase.hasScannedMediaRoots;
    final query = request.uri.queryParameters['query'] ?? '';
    final items = !hasDatabaseLibrary
        ? _library.listMovies(query: query)
        : _libraryDatabase
            .listMovies(query: query)
            .map(_databaseSummary)
            .toList();
    return _writeJson(request.response, HttpStatus.ok, {
      'data': {'items': items},
      'page': {'nextCursor': null, 'hasMore': false},
    });
  }

  Future<void> _movieDetails(HttpRequest request) async {
    final movieId = request.uri.pathSegments.last;
    final databaseMovie = _libraryDatabase.findMovie(movieId);
    final movie = databaseMovie != null
        ? await _databaseDetails(databaseMovie)
        : !config.managedCategoryLibrary && !_libraryDatabase.hasScannedMediaRoots
            ? _library.movieDetails(
                movieId,
                isAvailable: await _mediaService.fixtureFile() != null,
              )
            : null;
    if (movie == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    await _writeJson(request.response, HttpStatus.ok, {'data': movie});
  }

  Map<String, Object?> _databaseSummary(NasLibraryMovie movie) => {
        'id': movie.id,
        'title': movie.title,
        'actors': movie.actors,
        'category': _categoryForMoviePayload(movie.id),
        'tags': _libraryDatabase
            .tagsForMovie(movie.id)
            .map(_tagPayload)
            .toList(growable: false),
        'tagPaths': _libraryDatabase
            .tagPathsForMovie(movie.id)
            .map((path) => path.names)
            .toList(growable: false),
        'episodeCount': movie.episodeCount,
        'durationMs': movie.durationMs,
        'resolutionLabel': movie.resolutionLabel,
        'resolutionWidth': movie.videoWidth,
        'resolutionHeight': movie.videoHeight,
        'posterUrl': movie.posterFileName == null
            ? null
            : '/api/v1/assets/posters/${movie.id}',
        'isFavorite': false,
        'playCount': movie.playCount,
        'resumePositionMs': 0,
        'updatedAt': movie.updatedAt,
      };

  Future<Map<String, Object?>> _databaseDetails(NasLibraryMovie movie) async {
    final episodes = <Map<String, Object?>>[];
    for (final episode in _libraryDatabase.episodesForMovie(movie.id)) {
      final file =
          await _mediaService.fileForRelativePath(episode.relativePath);
      episodes.add({
        'id': episode.id,
        'title': episode.title,
        'sourceName': episode.relativePath.split('/').last,
        'durationMs': episode.durationMs,
        'resolutionLabel': episode.resolutionLabel,
        'videoWidth': episode.videoWidth,
        'videoHeight': episode.videoHeight,
        'fileSize': episode.fileSize,
        'isAvailable': episode.isAvailable && file != null,
      });
    }
    return {
      ..._databaseSummary(movie),
      'summary': movie.summary,
      'episodes': episodes,
      'carouselImages': _libraryDatabase
          .carouselImagesForMovie(movie.id)
          .map(
            (image) => {
              'id': image.id,
              'url': '/api/v1/assets/carousel-images/${image.id}',
            },
          )
          .toList(growable: false),
    };
  }

  Future<void> _tagPaths(HttpRequest request) => _writeJson(
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

  Future<void> _adminCategories(HttpRequest request) => _writeJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {
            'items': _libraryDatabase
                .listCategories()
                .map(_categoryPayload)
                .toList(growable: false),
          },
        },
      );

  Future<void> _exportAdminCategoryTaxonomy(HttpRequest request) async {
    final conflicts = _libraryDatabase.categoryTaxonomyViolations();
    if (conflicts.isNotEmpty) {
      return await _writeTaxonomyResult(
        request,
        NasTaxonomyTransferResult(
          added: const [],
          skipped: const [],
          conflicts: conflicts,
        ),
      );
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _libraryDatabase.exportCategoryTaxonomy().toJson(),
    });
  }

  Future<void> _importAdminCategoryTaxonomy(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body == null) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    try {
      return await _writeTaxonomyResult(
        request,
        _libraryDatabase.importCategoryTaxonomy(
          NasCategoryTaxonomyTransfer.decode(body),
        ),
      );
    } on FormatException {
      return _error(request, HttpStatus.badRequest, 'invalid_taxonomy');
    }
  }

  Future<void> _categories(HttpRequest request) => _writeJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {
            'items': _libraryDatabase
                .listCategories()
                .map(_categoryPayload)
                .toList(growable: false),
          },
        },
      );

  Future<void> _createAdminCategory(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final name = _categoryName(body);
    final directoryKey = _categoryDirectoryKey(body);
    final color = _taxonomyColor(body);
    if (name == null ||
        color == _invalidTaxonomyColor ||
        _libraryDatabase.hasCategoryName(name) ||
        (config.managedCategoryLibrary && directoryKey == null) ||
        (directoryKey != null && !await _canBindCategoryDirectory(directoryKey))) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final category = _libraryDatabase.createCategory(
      name,
      mediaRelativePath: directoryKey,
      color: color,
    );
    final scanJob = _scheduleCategoryScan(category.id);
    await _writeJson(request.response, HttpStatus.created, {
      'data': {
        ..._categoryPayload(category),
        if (scanJob != null) 'scanJob': _scanJobPayload(scanJob),
      },
    });
  }

  Future<void> _updateAdminCategory(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final name = _categoryName(body);
    final categoryId = request.uri.pathSegments.last;
    final hasDirectoryKey = body?.containsKey('directoryKey') ?? false;
    final directoryKey = _categoryDirectoryKey(body);
    final color = _taxonomyColor(body);
    final previous = _libraryDatabase.findCategory(categoryId);
    if (name == null ||
        color == _invalidTaxonomyColor ||
        previous == null ||
        _libraryDatabase.hasCategoryName(name, excludingId: categoryId) ||
        (config.managedCategoryLibrary &&
            previous.mediaRelativePath != null &&
            (!hasDirectoryKey || directoryKey == null)) ||
        (hasDirectoryKey &&
            (directoryKey == null ||
                !await _canBindCategoryDirectory(
                  directoryKey,
                  excludingCategoryId: categoryId,
                )))) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final directoryChanged =
        hasDirectoryKey && previous.mediaRelativePath != directoryKey;
    final category = _libraryDatabase.updateCategory(
      categoryId,
      name: name,
      mediaRelativePath: directoryKey,
      updateMediaRelativePath: directoryChanged,
      color: color,
      updateColor: body?.containsKey('color') ?? false,
    );
    if (category == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    final scanJob = directoryChanged ? _scheduleCategoryScan(category.id) : null;
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {
        ..._categoryPayload(category),
        if (scanJob != null) 'scanJob': _scanJobPayload(scanJob),
      },
    });
  }

  Future<void> _deleteAdminCategory(HttpRequest request) async {
    if (!_libraryDatabase.deleteCategory(request.uri.pathSegments.last)) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> _adminTags(HttpRequest request) => _writeJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {
            'items': _libraryDatabase
                .listTags()
                .map(_tagPayload)
                .toList(growable: false),
          },
        },
      );

  Future<void> _exportAdminTagTaxonomy(HttpRequest request) async {
    final conflicts = _libraryDatabase.taxonomyViolations();
    if (conflicts.isNotEmpty) {
      return _writeTaxonomyResult(
        request,
        NasTaxonomyTransferResult(
          added: const [],
          skipped: const [],
          conflicts: conflicts,
        ),
      );
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _libraryDatabase.exportTagTaxonomy().toJson(),
    });
  }

  Future<void> _importAdminTagTaxonomy(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body == null) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    try {
      return await _writeTaxonomyResult(
        request,
        _libraryDatabase.importTagTaxonomy(
          NasTagTaxonomyTransfer.decode(body),
        ),
      );
    } on FormatException {
      return _error(request, HttpStatus.badRequest, 'invalid_taxonomy');
    }
  }

  Future<void> _createAdminTag(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final name = body?['name'];
    final parentTagId = body?['parentTagId'];
    final color = _taxonomyColor(body);
    if (body == null ||
        body.keys.any((key) => key != 'name' && key != 'parentTagId' && key != 'color') ||
        name is! String ||
        name.trim().isEmpty ||
        (parentTagId != null && parentTagId is! String) ||
        _libraryDatabase.hasTagName(name.trim()) ||
        color == _invalidTaxonomyColor) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    try {
      final tag = parentTagId == null
          ? _libraryDatabase.createRootTag(name.trim(), color: color).$1
          : _libraryDatabase.createChildTag(
              name: name.trim(),
              parentTagId: parentTagId as String,
              color: color,
            ).$1;
      await _writeJson(request.response, HttpStatus.created, {
        'data': _tagPayload(tag),
      });
    } on ArgumentError catch (_) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    } on StateError catch (_) {
      return _writeTaxonomyResult(
        request,
        NasTaxonomyTransferResult(
          added: const [],
          skipped: const [],
          conflicts: _libraryDatabase.taxonomyViolations(),
        ),
      );
    }
  }

  Future<void> _updateAdminTag(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final name = _taxonomyName(body, allowed: const {'name', 'color'});
    final color = _taxonomyColor(body);
    final tagId = request.uri.pathSegments.last;
    if (name == null ||
        color == _invalidTaxonomyColor ||
        _libraryDatabase.hasTagName(name, excludingId: tagId)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    NasLibraryTag? tag;
    try {
      tag = _libraryDatabase.updateTagName(
        tagId,
        name,
        color: color,
        updateColor: body?.containsKey('color') ?? false,
      );
    } on ArgumentError {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    } on StateError {
      return _writeTaxonomyResult(
        request,
        NasTaxonomyTransferResult(
          added: const [],
          skipped: const [],
          conflicts: _libraryDatabase.taxonomyViolations(),
        ),
      );
    }
    if (tag == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _tagPayload(tag),
    });
  }

  Future<void> _deleteAdminTag(HttpRequest request) async {
    try {
      if (!_libraryDatabase.deleteTag(request.uri.pathSegments.last)) {
        return await _error(request, HttpStatus.badRequest, 'invalid_request');
      }
    } on StateError {
      return _writeTaxonomyResult(
        request,
        NasTaxonomyTransferResult(
          added: const [],
          skipped: const [],
          conflicts: _libraryDatabase.taxonomyViolations(),
        ),
      );
    }
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> _adminTagPlacements(HttpRequest request) => _writeJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {
            'items': _libraryDatabase
                .listTagPlacements()
                .map(_tagPlacementPayload)
                .toList(growable: false),
          },
        },
      );

  Future<void> _createAdminTagPlacement(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final tagId = body?['tagId'];
    final parentPlacementId = body?['parentPlacementId'];
    if (body == null ||
        body.keys.any((key) => key != 'tagId' && key != 'parentPlacementId') ||
        tagId is! String ||
        tagId.isEmpty ||
        (parentPlacementId != null && parentPlacementId is! String) ||
        _libraryDatabase.findTag(tagId) == null ||
        (parentPlacementId is String &&
            _libraryDatabase.findTagPlacement(parentPlacementId) == null)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    NasTagPlacement placement;
    try {
      placement = _libraryDatabase.createTagPlacement(
        tagId: tagId,
        parentPlacementId: parentPlacementId as String?,
      );
    } on ArgumentError {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    } on StateError {
      return _writeTaxonomyResult(
        request,
        NasTaxonomyTransferResult(
          added: const [],
          skipped: const [],
          conflicts: _libraryDatabase.taxonomyViolations(),
        ),
      );
    }
    await _writeJson(request.response, HttpStatus.created, {
      'data': _tagPlacementPayload(placement),
    });
  }

  Future<void> _updateAdminTagPlacement(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final placementId = request.uri.pathSegments.last;
    if (body == null ||
        body.length != 1 ||
        !body.containsKey('parentPlacementId') ||
        (body['parentPlacementId'] != null &&
            body['parentPlacementId'] is! String)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final parentPlacementId = body['parentPlacementId'] as String?;
    if (_libraryDatabase.findTagPlacement(placementId) == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (parentPlacementId != null &&
        (_libraryDatabase.findTagPlacement(parentPlacementId) == null ||
            _libraryDatabase.isTagPlacementDescendant(
              candidateParentId: parentPlacementId,
              placementId: placementId,
            ))) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    NasTagPlacement? placement;
    try {
      placement = _libraryDatabase.updateTagPlacementParent(
        placementId: placementId,
        parentPlacementId: parentPlacementId,
      );
    } on ArgumentError {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    } on StateError {
      return _writeTaxonomyResult(
        request,
        NasTaxonomyTransferResult(
          added: const [],
          skipped: const [],
          conflicts: _libraryDatabase.taxonomyViolations(),
        ),
      );
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _tagPlacementPayload(placement!),
    });
  }

  Future<void> _deleteAdminTagPlacement(HttpRequest request) async {
    try {
      if (!_libraryDatabase.deleteTagPlacement(request.uri.pathSegments.last)) {
        return await _error(request, HttpStatus.badRequest, 'invalid_request');
      }
    } on StateError {
      return _writeTaxonomyResult(
        request,
        NasTaxonomyTransferResult(
          added: const [],
          skipped: const [],
          conflicts: _libraryDatabase.taxonomyViolations(),
        ),
      );
    }
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> _adminMediaRoots(HttpRequest request) => _writeJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {
            'items': _libraryDatabase
                .listMediaRoots()
                .map(_mediaRootPayload)
                .toList(growable: false),
          },
        },
      );

  Future<void> _adminMediaDirectories(HttpRequest request) async {
    final parentKey = request.uri.queryParameters['parentKey'];
    if (parentKey != null &&
        (parentKey.isEmpty ||
            (await _mediaService.directoryForRelativePath(parentKey)) == null)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final directories = await _mediaService.childDirectories(parentKey);
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {
        'items': directories
            .map(
              (directory) => {
                'key': directory.relativePath,
                'name': directory.relativePath.split('/').last,
              },
            )
            .toList(growable: false),
      },
    });
  }

  Future<void> _adminDevices(HttpRequest request) => _writeJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {
            'items': _state!.tokens.values
                .map(_devicePayload)
                .toList(growable: false)
              ..sort((left, right) => (left['deviceId']! as String)
                  .compareTo(right['deviceId']! as String)),
          },
        },
      );

  Future<void> _revokeAdminDevice(HttpRequest request) async {
    final deviceId = request.uri.pathSegments.last;
    final removedTokenHashes = _state!.tokens.entries
        .where((entry) => entry.value.deviceId == deviceId)
        .map((entry) => entry.key)
        .toList(growable: false);
    if (removedTokenHashes.isEmpty) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    for (final tokenHash in removedTokenHashes) {
      _state!.tokens.remove(tokenHash);
    }
    await _persistState();
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> _createAdminBackup(HttpRequest request) async {
    final watch = Stopwatch()..start();
    _logger.event('backup.start', fields: {'component': 'nas.backup'});
    try {
      final backup = await _backupService.create(
        databaseSnapshot: _libraryDatabase.createBackupSnapshot,
      );
      _logger.event('backup.end', fields: {
        'component': 'nas.backup',
        'outcome': 'success',
        'durationMs': watch.elapsedMilliseconds,
        'bytes': backup.sizeBytes,
      });
      await _writeJson(request.response, HttpStatus.created, {
        'data': _backupPayload(backup),
      });
    } catch (error) {
      _logger.event('backup.error', level: 'ERROR', fields: {
        'component': 'nas.backup',
        'outcome': 'error',
        'durationMs': watch.elapsedMilliseconds,
        'errorType': error.runtimeType.toString(),
      });
      rethrow;
    }
  }

  Future<void> _adminBackups(HttpRequest request) async {
    final backups = await _backupService.list();
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {
        'items': backups.map(_backupPayload).toList(growable: false),
      },
    });
  }

  Future<void> _adminBackup(HttpRequest request) async {
    final backup = await _backupService.find(request.uri.pathSegments.last);
    if (backup == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _backupPayload(backup),
    });
  }

  Future<void> _updateAdminMovie(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body == null ||
        body.keys.any((key) =>
            key != 'title' &&
            key != 'summary' &&
            key != 'actors' &&
            key != 'categoryId' &&
            key != 'tagPlacementIds')) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final rawTitle = body['title'];
    final rawSummary = body['summary'];
    final hasActors = body.containsKey('actors');
    final rawActors = body['actors'];
    final hasCategoryId = body.containsKey('categoryId');
    final rawCategoryId = body['categoryId'];
    final hasTagPlacementIds = body.containsKey('tagPlacementIds');
    final rawTagPlacementIds = body['tagPlacementIds'];
    if ((rawTitle != null && rawTitle is! String) ||
        (rawSummary != null && rawSummary is! String) ||
        (hasActors && rawActors is! List) ||
        (rawTitle == null &&
            rawSummary == null &&
            !hasActors &&
            !hasCategoryId &&
            !hasTagPlacementIds) ||
        (hasCategoryId && rawCategoryId != null && rawCategoryId is! String) ||
        (hasTagPlacementIds && rawTagPlacementIds is! List)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final title = (rawTitle as String?)?.trim();
    if (title != null && title.isEmpty) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final actors = hasActors
        ? (rawActors as List)
            .map((value) => value is String ? value.trim() : null)
            .toList(growable: false)
        : const <String?>[];
    if (actors.length > 80 ||
        actors.any((actor) => actor == null || actor.isEmpty || actor.length > 120) ||
        actors.toSet().length != actors.length) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final categoryId = rawCategoryId as String?;
    if (hasCategoryId &&
        (categoryId?.isEmpty == true ||
            (categoryId != null &&
                _libraryDatabase.findCategory(categoryId) == null))) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final tagPlacementIds = hasTagPlacementIds
        ? (rawTagPlacementIds as List)
            .map((value) => value is String ? value : null)
            .toList(growable: false)
        : const <String?>[];
    if (tagPlacementIds.any((id) => id == null || id.isEmpty) ||
        tagPlacementIds.toSet().length != tagPlacementIds.length ||
        tagPlacementIds.any(
          (id) => _libraryDatabase.findTagPlacement(id!) == null,
        )) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final movie = _libraryDatabase.updateMovieMetadata(
      movieId: request.uri.pathSegments.last,
      title: title,
      summary: rawSummary as String?,
      actors: hasActors ? actors.cast<String>() : null,
    );
    if (movie == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    _libraryDatabase.setMovieTaxonomy(
      movieId: movie.id,
      updateCategory: hasCategoryId,
      categoryId: categoryId,
      updateTagPlacements: hasTagPlacementIds,
      tagPlacementIds: tagPlacementIds.cast<String>(),
    );
    final updatedMovie = _libraryDatabase.findMovieForAdmin(movie.id)!;
    await _writeJson(request.response, HttpStatus.ok, {
      'data': await _databaseDetails(updatedMovie),
    });
  }

  Future<void> _updateAdminEpisode(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final rawTitle = body?['title'];
    if (body == null ||
        body.keys.any((key) => key != 'title') ||
        rawTitle is! String ||
        rawTitle.trim().isEmpty) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final episode = _libraryDatabase.updateEpisodeTitle(
      episodeId: request.uri.pathSegments.last,
      title: rawTitle.trim(),
    );
    if (episode == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _adminEpisodePayload(episode),
    });
  }

  Future<void> _renameAdminEpisodeSource(HttpRequest request) async {
    if (!config.allowSourceRename) {
      return _error(request, HttpStatus.conflict, 'source_rename_disabled');
    }
    final body = await _readJsonBody(request);
    final sourceName = body?['sourceName'];
    if (body == null || body.length != 1 || sourceName is! String) {
      return _error(request, HttpStatus.badRequest, 'invalid_source_name');
    }
    final segments = request.uri.pathSegments;
    final episodeId = segments[segments.length - 2];
    final episode = _libraryDatabase.findEpisode(episodeId);
    if (episode == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    NasMediaFile? renamed;
    try {
      renamed = await _mediaService.renameFileInPlace(
        relativePath: episode.relativePath,
        sourceName: sourceName,
      );
      final stat = await renamed.file.stat();
      final updated = _libraryDatabase.updateEpisodeSourceAfterRename(
        episodeId: episode.id,
        relativePath: renamed.relativePath,
        title: _sourceTitle(sourceName),
        fileSize: stat.size,
        mediaModifiedAt: stat.modified.microsecondsSinceEpoch,
      );
      if (updated == null) throw StateError('episode disappeared during rename');
      await _writeJson(request.response, HttpStatus.ok, {
        'data': _adminEpisodePayload(updated),
      });
    } on NasMediaRenameException catch (error) {
      return _error(
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
        );
      }
      return _error(request, HttpStatus.internalServerError, 'source_metadata_update_failed');
    }
  }

  static String _sourceTitle(String sourceName) {
    final dot = sourceName.lastIndexOf('.');
    return dot <= 0 ? sourceName : sourceName.substring(0, dot);
  }

  Future<void> _createScanJob(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final categoryId = body?['categoryId'];
    final mediaRootId = body?['mediaRootId'];
    final categoryScan = config.managedCategoryLibrary;
    if (categoryScan
        ? (body == null ||
            body.length != 1 ||
            categoryId is! String ||
            categoryId.isEmpty ||
            _libraryDatabase.findCategory(categoryId) == null)
        : (mediaRootId is! String ||
            mediaRootId.isEmpty ||
            _configuredMediaRoot?.id != mediaRootId)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final job = _ScanJob(
      id: newUuidV4(),
      mediaRootId: categoryScan ? _configuredMediaRoot!.id : mediaRootId as String,
      categoryId: categoryScan ? categoryId as String : null,
      createdAt: DateTime.now().toUtc(),
    );
    _scanJobs[job.id] = job;
    unawaited(_runScanJob(job));
    await _writeJson(request.response, HttpStatus.accepted, {
      'data': _scanJobPayload(job),
    });
  }

  _ScanJob? _scheduleCategoryScan(String categoryId) {
    if (!config.managedCategoryLibrary || _configuredMediaRoot == null) {
      return null;
    }
    final job = _ScanJob(
      id: newUuidV4(),
      mediaRootId: _configuredMediaRoot!.id,
      categoryId: categoryId,
      createdAt: DateTime.now().toUtc(),
    );
    _scanJobs[job.id] = job;
    unawaited(_runScanJob(job));
    return job;
  }

  Future<void> _listScanJobs(HttpRequest request) => _writeJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {
            'items':
                _scanJobs.values.map(_scanJobPayload).toList(growable: false),
          },
        },
      );

  Future<void> _scanJob(HttpRequest request) {
    final job = _scanJobs[request.uri.pathSegments.last];
    if (job == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    return _writeJson(request.response, HttpStatus.ok, {
      'data': _scanJobPayload(job),
    });
  }

  Future<void> _runScanJob(_ScanJob job) async {
    job.status = 'running';
    job.startedAt = DateTime.now().toUtc();
    final watch = Stopwatch()..start();
    _logger.event('scan.start', fields: {
      'component': 'nas.scan',
      'sessionId': nasShortId(job.id),
    });
    try {
      final result = job.categoryId == null
          ? await _libraryDatabase.scanMediaRoot(
              mediaRootId: job.mediaRootId,
              mediaService: _mediaService,
            )
          : await _libraryDatabase.scanCategory(
              categoryId: job.categoryId!,
              mediaRootId: job.mediaRootId,
              mediaService: _mediaService,
            );
      job.status = 'succeeded';
      job.scannedFiles = result.scannedFiles;
      job.availableEpisodes = result.availableEpisodes;
      _logger.event('scan.end', fields: {
        'component': 'nas.scan',
        'sessionId': nasShortId(job.id),
        'outcome': 'success',
        'durationMs': watch.elapsedMilliseconds,
        'bytes': result.scannedFiles,
      });
    } catch (error) {
      job.status = 'failed';
      job.errorCode = 'service_unavailable';
      _logger.event('scan.error', level: 'ERROR', fields: {
        'component': 'nas.scan',
        'sessionId': nasShortId(job.id),
        'outcome': 'error',
        'durationMs': watch.elapsedMilliseconds,
        'errorType': error.runtimeType.toString(),
        'errorCode': job.errorCode,
      });
    } finally {
      job.finishedAt = DateTime.now().toUtc();
    }
  }

  Map<String, Object?> _mediaRootPayload(NasMediaRoot root) => {
        'id': root.id,
        'name': root.name,
        'readOnly': root.readOnly,
        'enabled': root.enabled,
        'createdAt': root.createdAt,
        'updatedAt': root.updatedAt,
        'lastScannedAt': root.lastScannedAt,
      };

  Map<String, Object?> _devicePayload(NasDeviceToken device) => {
        'deviceId': device.deviceId,
        'scope': device.scope,
        'expiresAt': device.expiresAt.toUtc().toIso8601String(),
      };

  Map<String, Object> _backupPayload(NasBackupRecord backup) => backup.toJson();

  Map<String, Object?> _categoryPayload(NasLibraryCategory category) => {
        'id': category.id,
        'name': category.name,
        'color': category.color,
        'directoryKey': category.mediaRelativePath,
        'directoryName': category.mediaRelativePath?.split('/').last,
        'createdAt': category.createdAt,
        'updatedAt': category.updatedAt,
      };

  Map<String, Object?>? _categoryForMoviePayload(String movieId) {
    final category = _libraryDatabase.categoryForMovie(movieId);
    return category == null ? null : _categoryPayload(category);
  }

  Map<String, Object?> _tagPayload(NasLibraryTag tag) => {
        'id': tag.id,
        'name': tag.name,
        'color': tag.color,
        'createdAt': tag.createdAt,
        'updatedAt': tag.updatedAt,
      };

  Map<String, Object?> _tagPlacementPayload(NasTagPlacement placement) {
    final path = _libraryDatabase.allTagPaths().where(
          (candidate) => candidate.placementId == placement.id,
        );
    return {
      'id': placement.id,
      'tagId': placement.tagId,
      'parentPlacementId': placement.parentPlacementId,
      'path': path.isEmpty ? const <String>[] : path.single.names,
      'createdAt': placement.createdAt,
      'updatedAt': placement.updatedAt,
    };
  }

  static const _invalidTaxonomyColor = '\u0000';

  String? _taxonomyName(
    Map<String, dynamic>? body, {
    required Set<String> allowed,
  }) {
    if (body == null || body['name'] is! String || body.keys.any((key) => !allowed.contains(key))) {
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
      allowed: const {'name', 'directoryKey', 'color'},
    );
  }

  String? _categoryDirectoryKey(Map<String, dynamic>? body) {
    if (body == null || !body.containsKey('directoryKey')) return null;
    final key = body['directoryKey'];
    if (key is! String) return null;
    final normalized = key.trim().replaceAll('\\', '/');
    return normalized.isEmpty ? null : normalized;
  }

  Future<bool> _canBindCategoryDirectory(
    String directoryKey, {
    String? excludingCategoryId,
  }) async {
    final directory = await _mediaService.directoryForRelativePath(directoryKey);
    if (directory == null) return false;
    final normalized = directory.relativePath;
    for (final category in _libraryDatabase.listCategories()) {
      if (category.id == excludingCategoryId) continue;
      final other = category.mediaRelativePath;
      if (other == null) continue;
      if (normalized == other ||
          normalized.startsWith('$other/') ||
          other.startsWith('$normalized/')) {
        return false;
      }
    }
    return true;
  }

  Map<String, Object?> _scanJobPayload(_ScanJob job) => {
        'id': job.id,
        'mediaRootId': job.mediaRootId,
        'categoryId': job.categoryId,
        'status': job.status,
        'scannedFiles': job.scannedFiles,
        'availableEpisodes': job.availableEpisodes,
        'createdAt': job.createdAt.toIso8601String(),
        'startedAt': job.startedAt?.toIso8601String(),
        'finishedAt': job.finishedAt?.toIso8601String(),
        'errorCode': job.errorCode,
      };

  Map<String, Object?> _adminEpisodePayload(NasLibraryEpisode episode) => {
        'id': episode.id,
        'movieId': episode.movieId,
        'title': episode.title,
        'sourceName': episode.relativePath.split('/').last,
        'durationMs': episode.durationMs,
        'resolutionLabel': episode.resolutionLabel,
        'videoWidth': episode.videoWidth,
        'videoHeight': episode.videoHeight,
        'fileSize': episode.fileSize,
        'isAvailable': episode.isAvailable,
        'updatedAt': episode.updatedAt,
      };

  Future<void> _emptyItems(HttpRequest request) => _writeJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {'items': const []},
        },
      );

  Future<void> _history(HttpRequest request) => _writeJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {
            'items': _libraryDatabase
                .listPlaybackHistory(
                  titleQuery: request.uri.queryParameters['q'] ?? '',
                )
                .map(
                  (item) => {
                    'id': item.id,
                    'movieId': item.movieId,
                    'episodeId': item.episodeId,
                    'title': item.title,
                    if (item.posterFileName != null)
                      'posterUrl': '/api/v1/assets/posters/${item.movieId}',
                    'startedAt': item.startedAt,
                    'endedAt': item.endedAt,
                    'endPositionMs': item.endPositionMs,
                    'durationMs': item.durationMs,
                  },
                )
                .toList(growable: false),
          },
        },
      );

  Future<void> _poster(HttpRequest request) async {
    final movieId = request.uri.pathSegments.last;
    final databaseMovie = _libraryDatabase.findMovie(movieId);
    if (databaseMovie != null) {
      final artwork =
          await _artworkService.poster(databaseMovie.posterFileName);
      if (artwork == null) {
        return await _error(request, HttpStatus.notFound, 'resource_not_found');
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType =
          ContentType.parse(artwork.mimeType);
      request.response.headers.contentLength = await artwork.file.length();
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (request.method == 'GET') {
        await request.response.addStream(artwork.file.openRead());
      }
      return request.response.close();
    }
    final bytes = _library.poster(movieId);
    if (bytes == null)
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType('image', 'png');
    request.response.headers.contentLength = bytes.length;
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (request.method == 'GET') request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _uploadAdminMoviePoster(HttpRequest request) async {
    final movieId = request.uri.pathSegments[4];
    final movie = _libraryDatabase.findMovieForAdmin(movieId);
    final mimeType = request.headers.contentType?.mimeType;
    if (movie == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (mimeType == null ||
        !const {'image/png', 'image/jpeg', 'image/webp'}.contains(mimeType) ||
        request.headers.contentLength > NasArtworkService.maxPosterBytes) {
      // Consume an oversized request before writing the error response. If the
      // body is left unread, dart:io may close the connection early and clients
      // observe a truncated JSON error (for example curl error 18).
      await request.drain<void>();
      return _error(request, HttpStatus.badRequest, 'invalid_request');
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
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    if (!NasArtworkService.isValidPosterBytes(
      mimeType: mimeType,
      bytes: bytes,
    )) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
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
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (movie.posterFileName != null && movie.posterFileName != fileName) {
      await _artworkService.deletePoster(movie.posterFileName);
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {'posterUrl': '/api/v1/assets/posters/$movieId'},
    });
  }

  Future<void> _uploadAdminMovieCarouselImage(HttpRequest request) async {
    final movieId = request.uri.pathSegments[4];
    final movie = _libraryDatabase.findMovieForAdmin(movieId);
    final mimeType = request.headers.contentType?.mimeType;
    if (movie == null) return _error(request, HttpStatus.notFound, 'resource_not_found');
    final bytes = await _readArtworkBytes(request, mimeType);
    if (bytes == null || mimeType == null) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    String? fileName;
    try {
      fileName = await _artworkService.saveCarouselImage(
        movieId: movieId,
        mimeType: mimeType,
        bytes: bytes,
      );
      final image = _libraryDatabase.addCarouselImage(
        movieId: movieId,
        fileName: fileName,
      );
      if (image == null) {
        await _artworkService.deleteCarouselImage(fileName);
        return await _error(
          request,
          HttpStatus.notFound,
          'resource_not_found',
        );
      }
      await _writeJson(request.response, HttpStatus.created, {
        'data': {
          'id': image.id,
          'url': '/api/v1/assets/carousel-images/${image.id}',
        },
      });
    } on ArgumentError {
      if (fileName != null) await _artworkService.deleteCarouselImage(fileName);
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
  }

  Future<void> _deleteAdminMovieCarouselImage(HttpRequest request) async {
    final image = _libraryDatabase.removeCarouselImage(
      movieId: request.uri.pathSegments[4],
      imageId: request.uri.pathSegments[6],
    );
    if (image == null) return _error(request, HttpStatus.notFound, 'resource_not_found');
    await _artworkService.deleteCarouselImage(image.fileName);
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> _carouselImage(HttpRequest request) async {
    final image = _libraryDatabase.findCarouselImage(request.uri.pathSegments.last);
    if (image == null) return _error(request, HttpStatus.notFound, 'resource_not_found');
    final artwork = await _artworkService.carouselImage(image.fileName);
    if (artwork == null) return _error(request, HttpStatus.notFound, 'resource_not_found');
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.parse(artwork.mimeType);
    request.response.headers.contentLength = await artwork.file.length();
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (request.method == 'GET') {
      await request.response.addStream(artwork.file.openRead());
    }
    await request.response.close();
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
        !NasArtworkService.isValidPosterBytes(mimeType: mimeType, bytes: bytes)) {
      return null;
    }
    return bytes;
  }

  Future<void> _createPlaybackSession(
      HttpRequest request, String tokenHash) async {
    final body = await _readJsonBody(request);
    final requestedMovieId = body?['contentId'];
    final requestedEpisodeId = body?['episodeId'];
    final purpose = body?['purpose'] ?? 'playback';
    if (requestedMovieId is! String ||
        purpose is! String ||
        !const {'playback', 'preview'}.contains(purpose)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final databaseMovie = _libraryDatabase.findMovie(requestedMovieId);
    if (databaseMovie != null) {
      final episodes = _libraryDatabase.episodesForMovie(databaseMovie.id);
      NasLibraryEpisode? episode;
      if (requestedEpisodeId is String) {
        for (final candidate in episodes) {
          if (candidate.id == requestedEpisodeId) {
            episode = candidate;
            break;
          }
        }
      } else if (episodes.length == 1) {
        episode = episodes.single;
      }
      if (episode == null || !episode.isAvailable) {
        return _error(request, HttpStatus.notFound, 'resource_not_found');
      }
      final file =
          await _mediaService.fileForRelativePath(episode.relativePath);
      if (file == null) {
        return _error(request, HttpStatus.notFound, 'resource_not_found');
      }
      return _writePlaybackSession(
        request,
        tokenHash: tokenHash,
        movieId: databaseMovie.id,
        episodeId: episode.id,
        relativePath: file.relativePath,
        durationMs: episode.durationMs ?? 600000,
        purpose: purpose,
      );
    }
    if (requestedMovieId != NasFixtureLibrary.movieId ||
        (requestedEpisodeId != null &&
            requestedEpisodeId != 'fixture-episode-1')) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    final file = await _mediaService.fixtureFile();
    if (file == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    return _writePlaybackSession(
      request,
      tokenHash: tokenHash,
      movieId: requestedMovieId,
      episodeId: 'fixture-episode-1',
      relativePath: file.relativePath,
      durationMs: _fixturePlaybackState?.durationMs ?? 600000,
      purpose: purpose,
    );
  }

  Future<void> _writePlaybackSession(
    HttpRequest request, {
    required String tokenHash,
    required String movieId,
    required String episodeId,
    required String relativePath,
    required int durationMs,
    required String purpose,
  }) async {
    final databaseResumePositionMs = purpose == 'preview'
        ? 0
        : _libraryDatabase.resumePositionMsForEpisode(
            movieId: movieId,
            episodeId: episodeId,
          );
    final resumePositionMs = databaseResumePositionMs > 0
        ? databaseResumePositionMs
        : purpose == 'playback'
            ? _fixturePlaybackState?.positionMs ?? 0
            : 0;
    final sessionId = newUuidV4();
    _playbackSessions[sessionId] = _PlaybackSession(
      tokenHash: tokenHash,
      relativePath: relativePath,
      movieId: movieId,
      episodeId: episodeId,
      purpose: purpose,
    );
    _logger.event('playback.session.create', fields: {
      'component': 'nas.playback',
      'playbackSessionId': nasShortId(sessionId),
      'movieIdShort': nasShortId(movieId),
      'purpose': purpose,
      'outcome': 'success',
    });
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {
        'sessionId': sessionId,
        'episodeId': episodeId,
        'resumePositionMs': resumePositionMs,
        'durationMs': durationMs,
        'playbackVariants': [
          {
            'type': 'direct',
            'url': '/api/v1/playback/sessions/$sessionId/stream',
            'mimeType': mimeTypeForMediaPath(relativePath),
          },
        ],
      },
    });
  }

  Future<void> _savePlaybackProgress(
      HttpRequest request, String tokenHash) async {
    final session = _playbackSession(request, tokenHash);
    final body = await _readJsonBody(request);
    final positionMs = (body?['positionMs'] as num?)?.toInt();
    final durationMs = (body?['durationMs'] as num?)?.toInt();
    if (session == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (positionMs == null ||
        durationMs == null ||
        positionMs < 0 ||
        durationMs < 0) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    if (session.purpose == 'playback' && session.started) {
      session.endPositionMs = positionMs > durationMs ? durationMs : positionMs;
      session.durationMs = durationMs;
      _libraryDatabase.savePlaybackProgress(
        movieId: session.movieId,
        episodeId: session.episodeId,
        positionMs: positionMs,
        durationMs: durationMs,
      );
      if (session.movieId == NasFixtureLibrary.movieId) {
        _fixturePlaybackState = _FixturePlaybackState(
          positionMs: positionMs > durationMs ? durationMs : positionMs,
          durationMs: durationMs,
        );
      }
    }
    _logger.event('playback.progress', level: 'DEBUG', fields: {
      'component': 'nas.playback',
      'playbackSessionId': nasShortId(request.uri.pathSegments[4]),
      'outcome': 'success',
    });
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {'updatedAt': DateTime.now().toUtc().toIso8601String()},
    });
  }

  Future<void> _markPlaybackStarted(
      HttpRequest request, String tokenHash) async {
    final session = _playbackSession(request, tokenHash);
    if (session == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (session.purpose == 'playback' && !session.streamRequested) {
      return _error(request, HttpStatus.conflict, 'playback_not_ready');
    }
    if (session.purpose == 'playback' && !session.started) {
      session.started = true;
      if (_libraryDatabase.findMovie(session.movieId) != null) {
        session.historyId = _libraryDatabase.recordPlaybackStarted(
          movieId: session.movieId,
          episodeId: session.episodeId,
        );
      }
      _logger.event('playback.started', fields: {
        'component': 'nas.playback',
        'playbackSessionId': nasShortId(request.uri.pathSegments[4]),
        'movieIdShort': nasShortId(session.movieId),
        'outcome': 'success',
      });
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {'started': session.started},
    });
  }

  Future<void> _deletePlaybackSession(
      HttpRequest request, String tokenHash) async {
    final sessionId = request.uri.pathSegments[4];
    final session = _playbackSessions[sessionId];
    if (session == null || session.tokenHash != tokenHash) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    _playbackSessions.remove(sessionId);
    final historyId = session.historyId;
    if (historyId != null) {
      _libraryDatabase.finishPlaybackHistory(
        historyId: historyId,
        endPositionMs: session.endPositionMs,
        durationMs: session.durationMs,
      );
    }
    _logger.event('playback.session.close', fields: {
      'component': 'nas.playback',
      'playbackSessionId': nasShortId(sessionId),
      'outcome': 'success',
    });
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> _streamPlayback(HttpRequest request, String tokenHash) async {
    final session = _playbackSession(request, tokenHash);
    if (session == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    final file = await _mediaService.fileForRelativePath(session.relativePath);
    if (file == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    final length = await file.length();
    final parsedRange = parseSingleByteRange(
      request.headers.value(HttpHeaders.rangeHeader),
      length,
    );
    if (parsedRange.requested && parsedRange.range == null) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes */$length');
      request.response.headers.contentLength = 0;
      _logger.event('playback.stream.error', level: 'WARN', fields: {
        'component': 'nas.playback',
        'playbackSessionId': nasShortId(request.uri.pathSegments[4]),
        'status': HttpStatus.requestedRangeNotSatisfiable,
        'outcome': 'http_error',
        'errorCode': 'invalid_range',
      });
      return request.response.close();
    }
    if (request.method == 'GET') session.streamRequested = true;
    final range = parsedRange.range;
    final start = range?.start ?? 0;
    final end = range?.end ?? length - 1;
    request.response.statusCode =
        range == null ? HttpStatus.ok : HttpStatus.partialContent;
    request.response.headers.contentType = ContentType.parse(
      mimeTypeForMediaPath(file.relativePath),
    );
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.contentLength = end - start + 1;
    if (range != null) {
      request.response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
    }
    final streamWatch = Stopwatch()..start();
    final sessionShort = nasShortId(request.uri.pathSegments[4]);
    _activeStreams++;
    _logger.event('playback.stream.start', fields: {
      'component': 'nas.playback',
      'playbackSessionId': sessionShort,
      'method': request.method,
      'range': '$start-$end/$length',
      'bytes': end - start + 1,
      'activeStreams': _activeStreams,
      'streamStart': true,
    });
    try {
      if (request.method == 'GET') {
        var firstByte = true;
        final monitored = file.openRead(start, end + 1).map((chunk) {
          if (firstByte) {
            firstByte = false;
            _logger.event('playback.stream.first_byte', fields: {
              'component': 'nas.playback',
              'playbackSessionId': sessionShort,
              'bytes': chunk.length,
              'durationMs': streamWatch.elapsedMilliseconds,
            });
          }
          return chunk;
        });
        await request.response.addStream(monitored);
      }
      await request.response.close();
      _logger.event('playback.stream.end', fields: {
        'component': 'nas.playback',
        'playbackSessionId': sessionShort,
        'outcome': 'success',
        'durationMs': streamWatch.elapsedMilliseconds,
        'bytes': request.method == 'GET' ? end - start + 1 : 0,
        'streamEnd': true,
      });
    } catch (error) {
      _logger.event('playback.stream.error', level: 'WARN', fields: {
        'component': 'nas.playback',
        'playbackSessionId': sessionShort,
        'outcome': 'disconnect',
        'cancelReason': 'client_disconnect',
        'durationMs': streamWatch.elapsedMilliseconds,
        'errorType': error.runtimeType.toString(),
      });
      rethrow;
    } finally {
      _activeStreams--;
    }
  }

  String? _authenticatedTokenHash(HttpRequest request) {
    final authorization =
        request.headers.value(HttpHeaders.authorizationHeader);
    if (authorization == null || !authorization.startsWith('Bearer '))
      return null;
    final token = authorization.substring('Bearer '.length).trim();
    if (token.isEmpty) return null;
    final tokenHash = sha256Hex(token);
    final device = _state!.tokens[tokenHash];
    return device != null && device.expiresAt.isAfter(DateTime.now().toUtc())
        ? tokenHash
        : null;
  }

  _PlaybackSession? _playbackSession(HttpRequest request, String tokenHash) {
    final session = _playbackSessions[request.uri.pathSegments[4]];
    return session?.tokenHash == tokenHash ? session : null;
  }

  Future<Map<String, dynamic>?> _readJsonBody(HttpRequest request) async {
    try {
      final value = jsonDecode(await utf8.decoder.bind(request).join());
      if (value is! Map) return null;
      return value.map((key, value) => MapEntry(key.toString(), value));
    } on FormatException {
      return null;
    }
  }

  Future<void> _writeTaxonomyResult(
    HttpRequest request,
    NasTaxonomyTransferResult result,
  ) =>
      _writeJson(
        request.response,
        result.conflicts.isEmpty ? HttpStatus.ok : HttpStatus.conflict,
        {'data': result.toJson()},
      );

  Future<void> _persistState() => _stateStore.save(_state!);

  Future<void> _error(HttpRequest request, int statusCode, String code) {
    final messages = <String, String>{
      'authentication_required': 'A valid device token is required.',
      'insufficient_scope': 'This device does not have the required scope.',
      'invalid_request': 'The request is invalid.',
      'invalid_taxonomy': 'The taxonomy definition file is invalid.',
      'method_not_allowed':
          'The HTTP method is not supported for this resource.',
      'pairing_failed': 'Pairing could not be confirmed.',
      'pairing_not_configured': 'Pairing is not configured on this server.',
      'playback_not_ready': 'The playback stream has not started.',
      'resource_not_found': 'Resource not found.',
      'service_unavailable': 'Service is unavailable.',
      'source_rename_disabled':
          'Source rename is disabled until the writable media deployment opt-in is enabled.',
      'invalid_source_name':
          'The requested source name is invalid or changes the file extension.',
      'source_name_conflict': 'A file with the requested name already exists.',
      'source_rename_failed': 'The source file could not be renamed.',
      'source_metadata_update_failed':
          'The source file rename could not be saved to the media database.',
    };
    return _writeJson(request.response, statusCode, {
      'error': {'code': code, 'message': messages[code] ?? 'Request failed.'},
    });
  }

  Future<void> _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, Object?> payload, {
    bool headOnly = false,
  }) async {
    final bytes = utf8.encode(jsonEncode(payload));
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.headers.contentLength = bytes.length;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (!headOnly) {
      response.add(bytes);
    }
    await response.close();
  }
}

class _PairingSession {
  const _PairingSession({required this.scope, required this.expiresAt});

  final String scope;
  final DateTime expiresAt;
}

class _PlaybackSession {
  _PlaybackSession({
    required this.tokenHash,
    required this.relativePath,
    required this.movieId,
    required this.episodeId,
    required this.purpose,
  });

  final String tokenHash;
  final String relativePath;
  final String movieId;
  final String episodeId;
  final String purpose;
  bool started = false;
  bool streamRequested = false;
  String? historyId;
  int? endPositionMs;
  int? durationMs;
}

class _FixturePlaybackState {
  const _FixturePlaybackState(
      {required this.positionMs, required this.durationMs});

  final int positionMs;
  final int durationMs;
}

class _ScanJob {
  _ScanJob({
    required this.id,
    required this.mediaRootId,
    required this.categoryId,
    required this.createdAt,
  });

  final String id;
  final String mediaRootId;
  final String? categoryId;
  final DateTime createdAt;
  String status = 'queued';
  int? scannedFiles;
  int? availableEpisodes;
  DateTime? startedAt;
  DateTime? finishedAt;
  String? errorCode;
}

Future<bool> checkLocalHealth(NasConfig config) async {
  final client = HttpClient();
  try {
    final host = config.bindHost == '0.0.0.0' ? '127.0.0.1' : config.bindHost;
    final request =
        await client.headUrl(Uri.http('$host:${config.port}', '/health'));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode == HttpStatus.ok;
  } on SocketException {
    return false;
  } finally {
    client.close(force: true);
  }
}
