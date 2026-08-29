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
    if (config.scanOnStart) {
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
        return await _emptyItems(request);
      }
      if ((request.method == 'GET' || request.method == 'HEAD') &&
          RegExp(r'^/api/v1/assets/posters/[^/]+$').hasMatch(path)) {
        return await _poster(request);
      }
      if (request.method == 'POST' && path == '/api/v1/playback/sessions') {
        return await _createPlaybackSession(request, tokenHash);
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
        'comics': false,
        'novels': false,
        'hiddenContent': false,
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
    final hasDatabaseLibrary = _libraryDatabase.hasScannedMediaRoots;
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
        : !_libraryDatabase.hasScannedMediaRoots
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
        'actors': const [],
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
        'playCount': 0,
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
    };
  }

  Future<void> _tagPaths(HttpRequest request) => _writeJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {
            'items': _libraryDatabase.hasScannedMediaRoots
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

  Future<void> _createAdminCategory(HttpRequest request) async {
    final name = await _requiredName(request);
    if (name == null || _libraryDatabase.hasCategoryName(name)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final category = _libraryDatabase.createCategory(name);
    await _writeJson(request.response, HttpStatus.created, {
      'data': _categoryPayload(category),
    });
  }

  Future<void> _updateAdminCategory(HttpRequest request) async {
    final name = await _requiredName(request);
    final categoryId = request.uri.pathSegments.last;
    if (name == null ||
        _libraryDatabase.hasCategoryName(name, excludingId: categoryId)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final category = _libraryDatabase.updateCategoryName(categoryId, name);
    if (category == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _categoryPayload(category),
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

  Future<void> _createAdminTag(HttpRequest request) async {
    final name = await _requiredName(request);
    if (name == null || _libraryDatabase.hasTagName(name)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final tag = _libraryDatabase.createTag(name);
    await _writeJson(request.response, HttpStatus.created, {
      'data': _tagPayload(tag),
    });
  }

  Future<void> _updateAdminTag(HttpRequest request) async {
    final name = await _requiredName(request);
    final tagId = request.uri.pathSegments.last;
    if (name == null || _libraryDatabase.hasTagName(name, excludingId: tagId)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final tag = _libraryDatabase.updateTagName(tagId, name);
    if (tag == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _tagPayload(tag),
    });
  }

  Future<void> _deleteAdminTag(HttpRequest request) async {
    if (!_libraryDatabase.deleteTag(request.uri.pathSegments.last)) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
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
    final placement = _libraryDatabase.createTagPlacement(
      tagId: tagId,
      parentPlacementId: parentPlacementId as String?,
    );
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
    final placement = _libraryDatabase.updateTagPlacementParent(
      placementId: placementId,
      parentPlacementId: parentPlacementId,
    );
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _tagPlacementPayload(placement!),
    });
  }

  Future<void> _deleteAdminTagPlacement(HttpRequest request) async {
    if (!_libraryDatabase.deleteTagPlacement(request.uri.pathSegments.last)) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
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
            key != 'categoryId' &&
            key != 'tagPlacementIds')) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final rawTitle = body['title'];
    final rawSummary = body['summary'];
    final hasCategoryId = body.containsKey('categoryId');
    final rawCategoryId = body['categoryId'];
    final hasTagPlacementIds = body.containsKey('tagPlacementIds');
    final rawTagPlacementIds = body['tagPlacementIds'];
    if ((rawTitle != null && rawTitle is! String) ||
        (rawSummary != null && rawSummary is! String) ||
        (rawTitle == null &&
            rawSummary == null &&
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

  Future<void> _createScanJob(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final mediaRootId = body?['mediaRootId'];
    if (mediaRootId is! String ||
        mediaRootId.isEmpty ||
        _configuredMediaRoot?.id != mediaRootId) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final job = _ScanJob(
      id: newUuidV4(),
      mediaRootId: mediaRootId,
      createdAt: DateTime.now().toUtc(),
    );
    _scanJobs[job.id] = job;
    unawaited(_runScanJob(job));
    await _writeJson(request.response, HttpStatus.accepted, {
      'data': _scanJobPayload(job),
    });
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
      final result = await _libraryDatabase.scanMediaRoot(
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

  Future<String?> _requiredName(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body == null || body.length != 1 || body['name'] is! String)
      return null;
    final name = (body['name'] as String).trim();
    return name.isEmpty ? null : name;
  }

  Map<String, Object?> _scanJobPayload(_ScanJob job) => {
        'id': job.id,
        'mediaRootId': job.mediaRootId,
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

  Future<void> _poster(HttpRequest request) async {
    final movieId = request.uri.pathSegments.last;
    final databaseMovie = _libraryDatabase.findMovie(movieId);
    if (databaseMovie != null) {
      final artwork =
          await _artworkService.poster(databaseMovie.posterFileName);
      if (artwork == null) {
        return _error(request, HttpStatus.notFound, 'resource_not_found');
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

  Future<void> _createPlaybackSession(
      HttpRequest request, String tokenHash) async {
    final body = await _readJsonBody(request);
    final requestedMovieId = body?['contentId'];
    final requestedEpisodeId = body?['episodeId'];
    if (requestedMovieId is! String) {
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
    );
  }

  Future<void> _writePlaybackSession(
    HttpRequest request, {
    required String tokenHash,
    required String movieId,
    required String episodeId,
    required String relativePath,
    required int durationMs,
  }) async {
    final resumePositionMs = _fixturePlaybackState?.positionMs ?? 0;
    final sessionId = newUuidV4();
    _playbackSessions[sessionId] = _PlaybackSession(
      tokenHash: tokenHash,
      relativePath: relativePath,
    );
    _logger.event('playback.session.create', fields: {
      'component': 'nas.playback',
      'playbackSessionId': nasShortId(sessionId),
      'movieIdShort': nasShortId(movieId),
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
    _fixturePlaybackState = _FixturePlaybackState(
      positionMs: positionMs > durationMs ? durationMs : positionMs,
      durationMs: durationMs,
    );
    _logger.event('playback.progress', level: 'DEBUG', fields: {
      'component': 'nas.playback',
      'playbackSessionId': nasShortId(request.uri.pathSegments[4]),
      'outcome': 'success',
    });
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {'updatedAt': DateTime.now().toUtc().toIso8601String()},
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
    final file = session == null
        ? null
        : await _mediaService.fileForRelativePath(session.relativePath);
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

  Future<void> _persistState() => _stateStore.save(_state!);

  Future<void> _error(HttpRequest request, int statusCode, String code) {
    final messages = <String, String>{
      'authentication_required': 'A valid device token is required.',
      'insufficient_scope': 'This device does not have the required scope.',
      'invalid_request': 'The request is invalid.',
      'method_not_allowed':
          'The HTTP method is not supported for this resource.',
      'pairing_failed': 'Pairing could not be confirmed.',
      'pairing_not_configured': 'Pairing is not configured on this server.',
      'resource_not_found': 'Resource not found.',
      'service_unavailable': 'Service is unavailable.',
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
  const _PlaybackSession({required this.tokenHash, required this.relativePath});

  final String tokenHash;
  final String relativePath;
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
    required this.createdAt,
  });

  final String id;
  final String mediaRootId;
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
