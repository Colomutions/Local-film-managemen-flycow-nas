// Request handlers are dispatched independently so a long-lived media stream
// cannot block health checks or unrelated API requests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_metadata_service.dart';
import 'artwork_service.dart';
import 'auth.dart';
import 'backup_service.dart';
import 'config.dart';
import 'diagnostic_log.dart';
import 'fixture_library.dart';
import 'library/taxonomy_transfer.dart';
import 'library_database.dart';
import 'media_service.dart';
import 'movie_actor.dart';
import 'persistent_state.dart';
import 'range.dart';

String? _nullableTrimmed(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

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
    NasAiMetadataClient? aiMetadataClient,
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
        _logger = logger ?? NasDiagnosticLogger(),
        _aiMetadataClient =
            aiMetadataClient ?? const NasDisabledAiMetadataClient();

  final NasConfig config;
  final NasPersistentStateStore _stateStore;
  final NasFixtureLibrary _library;
  final NasMediaService _mediaService;
  final NasLibraryDatabase _libraryDatabase;
  final NasArtworkService _artworkService;
  final NasBackupService _backupService;
  final NasDiagnosticLogger _logger;
  final NasAiMetadataClient _aiMetadataClient;
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
    _logger.event('service.start',
        fields: {'component': 'nas.service', 'phase': 'startup'});
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
    final traceId =
        _safeIncomingId(request.headers.value('x-mujing-trace-id'), 't');
    final requestId =
        _safeIncomingId(request.headers.value('x-mujing-request-id'), 'r');
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
        return await _error(
            request, HttpStatus.forbidden, 'insufficient_scope');
      }
      if (request.method == 'GET' && path == '/api/v1/admin/media-roots') {
        return await _adminMediaRoots(request);
      }
      if (request.method == 'GET' &&
          path == '/api/v1/admin/media-directories') {
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
        if (request.method == 'PATCH')
          return await _updateAdminCategory(request);
        if (request.method == 'DELETE')
          return await _deleteAdminCategory(request);
      }
      if (request.method == 'GET' &&
          path == '/api/v1/admin/tag-management/overview') {
        return await _tagManagementOverview(request);
      }
      if (request.method == 'GET' &&
          path == '/api/v1/admin/tag-management/directory') {
        return await _tagManagementDirectory(request);
      }
      if (request.method == 'GET' &&
          path == '/api/v1/admin/tag-management/parent-candidates') {
        return await _tagManagementParentCandidates(request);
      }
      if (request.method == 'GET' &&
          path == '/api/v1/admin/tag-management/selectable') {
        return await _tagManagementSelectableTags(request);
      }
      if (request.method == 'GET' &&
          path == '/api/v1/admin/tag-management/template') {
        return await _tagManagementTemplate(request);
      }
      if (request.method == 'GET' &&
          path == '/api/v1/admin/tag-management/export') {
        return await _tagManagementExport(request);
      }
      if (request.method == 'POST' &&
          path == '/api/v1/admin/tag-management/import') {
        return await _importTagManagement(request);
      }
      if (request.method == 'POST' &&
          path == '/api/v1/admin/tag-management/tags') {
        return await _createTagManagementTag(request);
      }
      if (RegExp(r'^/api/v1/admin/tag-management/tags/[^/]+/archive$')
          .hasMatch(path)) {
        if (request.method == 'POST')
          return await _archiveTagManagementTag(request);
      }
      if (RegExp(r'^/api/v1/admin/tag-management/tags/[^/]+/children$')
          .hasMatch(path)) {
        if (request.method == 'GET')
          return await _tagManagementChildren(request);
      }
      if (RegExp(r'^/api/v1/admin/tag-management/tags/[^/]+/movies$')
          .hasMatch(path)) {
        if (request.method == 'GET') return await _tagManagementMovies(request);
      }
      if (RegExp(r'^/api/v1/admin/tag-management/tags/[^/]+$').hasMatch(path)) {
        if (request.method == 'GET')
          return await _tagManagementDetails(request);
        if (request.method == 'PATCH')
          return await _updateTagManagementTag(request);
        if (request.method == 'DELETE')
          return await _deleteTagManagementTag(request);
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
          RegExp(r'^/api/v1/admin/movies/[^/]+/carousel-images$')
              .hasMatch(path)) {
        return await _uploadAdminMovieCarouselImage(request);
      }
      if (request.method == 'DELETE' &&
          RegExp(r'^/api/v1/admin/movies/[^/]+/carousel-images/[^/]+$')
              .hasMatch(path)) {
        return await _deleteAdminMovieCarouselImage(request);
      }
      if (request.method == 'PATCH' &&
          RegExp(r'^/api/v1/admin/episodes/[^/]+/source-name$')
              .hasMatch(path)) {
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
      if (request.method == 'POST' && path == '/api/v1/admin/assets/images') {
        return await _uploadManagedImage(request);
      }
      if (request.method == 'GET' && path == '/api/v1/admin/ai/settings') {
        return await _aiSettings(request);
      }
      if (request.method == 'PUT' && path == '/api/v1/admin/ai/settings') {
        return await _updateAiSettings(request);
      }
      if (request.method == 'POST' && path == '/api/v1/admin/ai/tasks') {
        return await _createAiTask(request);
      }
      if (request.method == 'GET' &&
          RegExp(r'^/api/v1/admin/ai/tasks/[^/]+$').hasMatch(path)) {
        return await _aiTask(request);
      }
      if (request.method == 'POST' &&
          RegExp(r'^/api/v1/admin/ai/tasks/[^/]+/apply$').hasMatch(path)) {
        return await _applyAiTask(request);
      }
      if (request.method == 'POST' && path == '/api/v1/admin/actors') {
        return await _createAdminActor(request);
      }
      if (request.method == 'PATCH' &&
          RegExp(r'^/api/v1/admin/actors/[^/]+$').hasMatch(path)) {
        return await _updateAdminActor(request);
      }
      if (request.method == 'DELETE' &&
          RegExp(r'^/api/v1/admin/actors/[^/]+$').hasMatch(path)) {
        return await _deleteAdminActor(request);
      }
      if (request.method == 'POST' &&
          RegExp(r'^/api/v1/admin/actors/[^/]+/archive$').hasMatch(path)) {
        return await _archiveAdminActor(request);
      }
      if (request.method == 'POST' && path == '/api/v1/admin/publishers') {
        return await _createAdminPublisher(request);
      }
      if (request.method == 'PATCH' &&
          RegExp(r'^/api/v1/admin/publishers/[^/]+$').hasMatch(path)) {
        return await _updateAdminPublisher(request);
      }
      if (request.method == 'DELETE' &&
          RegExp(r'^/api/v1/admin/publishers/[^/]+$').hasMatch(path)) {
        return await _deleteAdminPublisher(request);
      }
      if (request.method == 'POST' &&
          RegExp(r'^/api/v1/admin/publishers/[^/]+/archive$').hasMatch(path)) {
        return await _archiveAdminPublisher(request);
      }
      if (request.method == 'POST' &&
          RegExp(r'^/api/v1/admin/publishers/[^/]+/logo$').hasMatch(path)) {
        return await _uploadAdminPublisherLogo(request);
      }
      if (request.method == 'POST' && path == '/api/v1/admin/series') {
        return await _createAdminSeries(request);
      }
      if (request.method == 'PATCH' &&
          RegExp(r'^/api/v1/admin/series/[^/]+$').hasMatch(path)) {
        return await _updateAdminSeries(request);
      }
      if (request.method == 'DELETE' &&
          RegExp(r'^/api/v1/admin/series/[^/]+$').hasMatch(path)) {
        return await _deleteAdminSeries(request);
      }
      if (request.method == 'POST' &&
          RegExp(r'^/api/v1/admin/series/[^/]+/archive$').hasMatch(path)) {
        return await _archiveAdminSeries(request);
      }
      if (request.method == 'POST' &&
          RegExp(r'^/api/v1/admin/series/[^/]+/poster$').hasMatch(path)) {
        return await _uploadAdminSeriesPoster(request);
      }
      if (request.method == 'GET' && path == '/api/v1/movies') {
        return await _movies(request);
      }
      if (request.method == 'GET' && path == '/api/v1/categories') {
        return await _categories(request);
      }
      if (request.method == 'GET' && path == '/api/v1/actors') {
        return await _actors(request);
      }
      if (request.method == 'GET' && path == '/api/v1/publishers') {
        return await _publishers(request);
      }
      if (request.method == 'GET' && path == '/api/v1/series') {
        return await _series(request);
      }
      if (request.method == 'GET' &&
          RegExp(r'^/api/v1/publishers/[^/]+/movies$').hasMatch(path)) {
        return await _publisherMovies(request);
      }
      if (request.method == 'GET' &&
          RegExp(r'^/api/v1/publishers/[^/]+/series$').hasMatch(path)) {
        return await _publisherSeries(request);
      }
      if (request.method == 'GET' &&
          RegExp(r'^/api/v1/publishers/[^/]+/actors$').hasMatch(path)) {
        return await _publisherActors(request);
      }
      if (request.method == 'GET' &&
          RegExp(r'^/api/v1/publishers/[^/]+$').hasMatch(path)) {
        return await _publisherDetails(request);
      }
      if (request.method == 'GET' &&
          RegExp(r'^/api/v1/series/[^/]+/movies$').hasMatch(path)) {
        return await _seriesMovies(request);
      }
      if (request.method == 'GET' &&
          RegExp(r'^/api/v1/series/[^/]+/actors$').hasMatch(path)) {
        return await _seriesActors(request);
      }
      if (request.method == 'GET' &&
          RegExp(r'^/api/v1/series/[^/]+$').hasMatch(path)) {
        return await _seriesDetails(request);
      }
      if (request.method == 'GET' &&
          RegExp(r'^/api/v1/actors/[^/]+/coactors$').hasMatch(path)) {
        return await _actorCoactors(request);
      }
      if (request.method == 'GET' &&
          RegExp(r'^/api/v1/actors/[^/]+/movies$').hasMatch(path)) {
        return await _actorMovies(request);
      }
      if (request.method == 'GET' &&
          RegExp(r'^/api/v1/actors/[^/]+$').hasMatch(path)) {
        return await _actorDetails(request);
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
      if ((request.method == 'GET' || request.method == 'HEAD') &&
          RegExp(r'^/api/v1/assets/[^/]+$').hasMatch(path)) {
        return await _managedAsset(request);
      }
      if (request.method == 'POST' && path == '/api/v1/playback/sessions') {
        return await _createPlaybackSession(request, tokenHash);
      }
      if (request.method == 'POST' &&
          RegExp(r'^/api/v1/playback/sessions/[^/]+/started$').hasMatch(path)) {
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
      final bytes = response.headers.contentLength >= 0
          ? response.headers.contentLength
          : null;
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
      _logger.event('http.response.end',
          level: status >= 500 ? 'ERROR' : (status >= 400 ? 'WARN' : 'DEBUG'),
          fields: {
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
    if (value != null && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(value))
      return value;
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
    final parameters = request.uri.queryParameters;
    final query = parameters['q'] ?? parameters['query'] ?? '';
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '24') ?? 0;
    final sort = parameters['sort'] ?? 'title';
    final order = parameters['order'] ?? 'asc';
    final categoryId = parameters['categoryId'];
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
        (hasDatabaseLibrary &&
            categoryId != null &&
            _libraryDatabase.findCategory(categoryId) == null) ||
        (!hasDatabaseLibrary &&
            (categoryId != null ||
                (tagIds?.isNotEmpty ?? false) ||
                (resolutions?.isNotEmpty ?? false)))) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    if (!hasDatabaseLibrary) {
      final items = _library.listMovies(query: query);
      final offset = (page - 1) * pageSize;
      final paged = offset >= items.length
          ? const <Map<String, Object?>>[]
          : items.skip(offset).take(pageSize).toList(growable: false);
      return _writeJson(request.response, HttpStatus.ok, {
        'data': {'items': paged},
        'page': {
          'number': page,
          'size': pageSize,
          'total': items.length,
          'hasMore': offset + paged.length < items.length,
        },
      });
    }
    final movies = _libraryDatabase
        .listMovies(query: query)
        .where((movie) =>
            (categoryId == null ||
                _categoryForMoviePayload(movie.id)?['id'] == categoryId) &&
            (tagIds == null ||
                tagIds.isEmpty ||
                _libraryDatabase
                    .tagsForMovie(movie.id)
                    .any((tag) => tagIds.contains(tag.id))) &&
            (resolutions == null ||
                resolutions.isEmpty ||
                (movie.resolutionLabel != null &&
                    resolutions.contains(movie.resolutionLabel))))
        .toList();
    movies.sort((left, right) => _compareMovies(left, right, sort, order));
    final offset = (page - 1) * pageSize;
    final paged = offset >= movies.length
        ? const <NasLibraryMovie>[]
        : movies.skip(offset).take(pageSize).toList(growable: false);
    return _writeJson(request.response, HttpStatus.ok, {
      'data': {'items': paged.map(_databaseSummary).toList(growable: false)},
      'page': {
        'number': page,
        'size': pageSize,
        'total': movies.length,
        'hasMore': offset + paged.length < movies.length,
      },
    });
  }

  Future<void> _movieDetails(HttpRequest request) async {
    final movieId = request.uri.pathSegments.last;
    final databaseMovie = _libraryDatabase.findMovie(movieId);
    final movie = databaseMovie != null
        ? await _databaseDetails(databaseMovie)
        : !config.managedCategoryLibrary &&
                !_libraryDatabase.hasScannedMediaRoots
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

  Future<void> _actors(HttpRequest request) async {
    final parameters = request.uri.queryParameters;
    final gender = parameters['gender'];
    final includeArchived = parameters['includeArchived'] == 'true';
    final allowedGenders = const {'female', 'intersex', 'male'};
    if (gender != null && !allowedGenders.contains(gender)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
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
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final actors = _libraryDatabase
        .listActors(
          query: parameters['q'] ?? '',
          gender: gender,
          includeArchived: includeArchived,
        )
        .toList();
    actors.sort((left, right) => _compareActors(left, right, sort, order));
    final offset = (page - 1) * pageSize;
    final items = offset >= actors.length
        ? const <NasActor>[]
        : actors.skip(offset).take(pageSize).toList(growable: false);
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items.map(_actorPayload).toList(growable: false),
      },
      'page': {
        'number': page,
        'size': pageSize,
        'total': actors.length,
        'hasMore': offset + items.length < actors.length,
      },
    });
  }

  Future<void> _actorDetails(HttpRequest request) async {
    final actor = _libraryDatabase.findActor(request.uri.pathSegments.last);
    if (actor == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _actorPayload(actor),
    });
  }

  Future<void> _actorCoactors(HttpRequest request) async {
    final actorId = request.uri.pathSegments[3];
    if (_libraryDatabase.findActor(actorId) == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    final page = int.tryParse(request.uri.queryParameters['page'] ?? '1') ?? 0;
    final pageSize =
        int.tryParse(request.uri.queryParameters['pageSize'] ?? '9') ?? 0;
    if (page < 1 || pageSize < 1 || pageSize > 9) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final coactors = _libraryDatabase.coactorsForActor(actorId);
    final offset = (page - 1) * pageSize;
    final items = offset >= coactors.length
        ? const <NasActorCoactor>[]
        : coactors.skip(offset).take(pageSize).toList(growable: false);
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items
            .map(
              (item) => {
                'actor': _actorPayload(item.actor),
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

  Future<void> _actorMovies(HttpRequest request) async {
    final actorId = request.uri.pathSegments[3];
    if (_libraryDatabase.findActor(actorId) == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    final parameters = request.uri.queryParameters;
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '14') ?? 0;
    final sort = parameters['sort'] ?? 'recent';
    final order = parameters['order'] ?? 'desc';
    final categoryId = parameters['categoryId'];
    final resolutions = parameters['resolutions']
        ?.split(',')
        .where((value) => value.isNotEmpty)
        .toSet();
    if (page < 1 ||
        pageSize < 1 ||
        pageSize > 14 ||
        !const {'recent', 'createdAt', 'title', 'durationMs'}.contains(sort) ||
        !const {'asc', 'desc'}.contains(order) ||
        (categoryId != null &&
            _libraryDatabase.findCategory(categoryId) == null)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final movies = _libraryDatabase
        .moviesForActor(actorId, query: parameters['q'] ?? '')
        .where((movie) =>
            (categoryId == null ||
                _categoryForMoviePayload(movie.id)?['id'] == categoryId) &&
            (resolutions == null ||
                resolutions.isEmpty ||
                (movie.resolutionLabel != null &&
                    resolutions.contains(movie.resolutionLabel))))
        .toList();
    movies.sort((left, right) => _compareActorMovies(left, right, sort, order));
    final offset = (page - 1) * pageSize;
    final items = offset >= movies.length
        ? const <NasLibraryMovie>[]
        : movies.skip(offset).take(pageSize).toList(growable: false);
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items.map(_databaseSummary).toList(growable: false),
      },
      'page': {
        'number': page,
        'size': pageSize,
        'total': movies.length,
        'hasMore': offset + items.length < movies.length,
      },
    });
  }

  Future<void> _createAdminActor(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final values = _actorInputValues(body, creating: true);
    if (values == null) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final photoAssetId = values['photo_asset_id'] as String?;
    if (photoAssetId != null &&
        _libraryDatabase.findManagedAsset(photoAssetId)?.purpose !=
            'actor_photo') {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final aliases = _stringListFromJson(values['aliases_json'] as String?);
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
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    await _writeJson(request.response, HttpStatus.created, {
      'data': {
        'actor': _actorPayload(actor),
        'similarActors':
            similarActors.map(_actorPayload).toList(growable: false),
      },
    });
  }

  Future<void> _updateAdminActor(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final values = _actorInputValues(body, creating: false);
    if (values == null || values.isEmpty) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final photoAssetId = values['photo_asset_id'] as String?;
    if (values.containsKey('photo_asset_id') &&
        photoAssetId != null &&
        _libraryDatabase.findManagedAsset(photoAssetId)?.purpose !=
            'actor_photo') {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final publisherIds = values.remove('publisher_ids') as List<String>?;
    final actor = _libraryDatabase.updateActor(
      request.uri.pathSegments.last,
      values,
    );
    if (actor == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (publisherIds != null &&
        !_libraryDatabase.setActorPublisherIds(
          actorId: actor.id,
          publisherIds: publisherIds,
        )) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _actorPayload(actor),
    });
  }

  Future<void> _archiveAdminActor(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body == null || body.isNotEmpty) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final actor = _libraryDatabase.archiveActor(request.uri.pathSegments[4]);
    if (actor == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _actorPayload(actor),
    });
  }

  Future<void> _deleteAdminActor(HttpRequest request) async {
    final actorId = request.uri.pathSegments.last;
    final actor = _libraryDatabase.findActor(actorId);
    if (actor == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (actor.movieCount > 0) {
      return _error(request, HttpStatus.conflict, 'actor_in_use');
    }
    final photoAsset = actor.photoAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(actor.photoAssetId!);
    if (!_libraryDatabase.deleteActor(actorId)) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (photoAsset != null) {
      // 删除演员时同步移除其 NAS 受管理照片，避免遗留孤立资产记录或文件。
      _libraryDatabase.removeManagedAsset(photoAsset.id);
      await _artworkService.deleteManagedAsset(photoAsset.fileName);
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {'deleted': true},
    });
  }

  Future<void> _publishers(HttpRequest request) async {
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
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final publishers = _libraryDatabase
        .listPublishers(
          query: parameters['q'] ?? '',
          includeArchived: parameters['includeArchived'] == 'true',
        )
        .toList()
      ..sort((left, right) => _comparePublishers(left, right, sort, order));
    final offset = (page - 1) * pageSize;
    final items = offset >= publishers.length
        ? const <NasPublisher>[]
        : publishers.skip(offset).take(pageSize).toList(growable: false);
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {'items': items.map(_publisherPayload).toList(growable: false)},
      'page': {
        'number': page,
        'size': pageSize,
        'total': publishers.length,
        'hasMore': offset + items.length < publishers.length,
      },
    });
  }

  Future<void> _publisherDetails(HttpRequest request) async {
    final publisher =
        _libraryDatabase.findPublisher(request.uri.pathSegments.last);
    if (publisher == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _publisherPayload(publisher, includeTags: true),
    });
  }

  Future<void> _publisherMovies(HttpRequest request) async {
    final publisherId = request.uri.pathSegments[3];
    if (_libraryDatabase.findPublisher(publisherId) == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    return _relatedMovies(
      request,
      _libraryDatabase.moviesForPublisher(
        publisherId,
        query: request.uri.queryParameters['q'] ?? '',
      ),
    );
  }

  Future<void> _publisherSeries(HttpRequest request) async {
    final publisherId = request.uri.pathSegments[3];
    if (_libraryDatabase.findPublisher(publisherId) == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
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
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final series = _libraryDatabase
        .seriesForPublisher(publisherId, query: parameters['q'] ?? '')
        .toList()
      ..sort((left, right) => _compareSeries(left, right, sort, order));
    final offset = (page - 1) * pageSize;
    final items = offset >= series.length
        ? const <NasSeries>[]
        : series.skip(offset).take(pageSize).toList(growable: false);
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {'items': items.map(_seriesPayload).toList(growable: false)},
      'page': {
        'number': page,
        'size': pageSize,
        'total': series.length,
        'hasMore': offset + items.length < series.length,
      },
    });
  }

  Future<void> _publisherActors(HttpRequest request) async {
    final publisherId = request.uri.pathSegments[3];
    if (_libraryDatabase.findPublisher(publisherId) == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    return _relatedActors(
      request,
      _libraryDatabase.actorsForPublisher(publisherId),
    );
  }

  Future<void> _series(HttpRequest request) async {
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
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final series = _libraryDatabase
        .listSeries(
          query: parameters['q'] ?? '',
          publisherId: publisherId,
          includeArchived: parameters['includeArchived'] == 'true',
        )
        .toList()
      ..sort((left, right) => _compareSeries(left, right, sort, order));
    final offset = (page - 1) * pageSize;
    final items = offset >= series.length
        ? const <NasSeries>[]
        : series.skip(offset).take(pageSize).toList(growable: false);
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {'items': items.map(_seriesPayload).toList(growable: false)},
      'page': {
        'number': page,
        'size': pageSize,
        'total': series.length,
        'hasMore': offset + items.length < series.length,
      },
    });
  }

  Future<void> _seriesDetails(HttpRequest request) async {
    final series = _libraryDatabase.findSeries(request.uri.pathSegments.last);
    if (series == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _seriesPayload(series, includeTags: true),
    });
  }

  Future<void> _seriesMovies(HttpRequest request) async {
    final seriesId = request.uri.pathSegments[3];
    if (_libraryDatabase.findSeries(seriesId) == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    return _relatedMovies(
      request,
      _libraryDatabase.moviesForSeries(
        seriesId,
        query: request.uri.queryParameters['q'] ?? '',
      ),
    );
  }

  Future<void> _seriesActors(HttpRequest request) async {
    final seriesId = request.uri.pathSegments[3];
    if (_libraryDatabase.findSeries(seriesId) == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
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
    final resolutions = parameters['resolutions']
        ?.split(',')
        .where((value) => value.isNotEmpty)
        .toSet();
    if (page < 1 ||
        pageSize < 1 ||
        pageSize > 14 ||
        !const {'recent', 'createdAt', 'title', 'durationMs'}.contains(sort) ||
        !const {'asc', 'desc'}.contains(order) ||
        (categoryId != null &&
            _libraryDatabase.findCategory(categoryId) == null)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final movies = source
        .where((movie) =>
            (categoryId == null ||
                _categoryForMoviePayload(movie.id)?['id'] == categoryId) &&
            (resolutions == null ||
                resolutions.isEmpty ||
                (movie.resolutionLabel != null &&
                    resolutions.contains(movie.resolutionLabel))))
        .toList()
      ..sort((left, right) => _compareActorMovies(left, right, sort, order));
    final offset = (page - 1) * pageSize;
    final items = offset >= movies.length
        ? const <NasLibraryMovie>[]
        : movies.skip(offset).take(pageSize).toList(growable: false);
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {'items': items.map(_databaseSummary).toList(growable: false)},
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
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final offset = (page - 1) * pageSize;
    final items = offset >= source.length
        ? const <NasRelatedActor>[]
        : source.skip(offset).take(pageSize).toList(growable: false);
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items
            .map((item) => {
                  'actor': _actorPayload(item.actor),
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

  Future<void> _createAdminPublisher(HttpRequest request) async {
    final values =
        _publisherInputValues(await _readJsonBody(request), creating: true);
    if (values == null) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final logoAssetId = values['logo_asset_id'] as String?;
    if (logoAssetId != null &&
        _libraryDatabase.findManagedAsset(logoAssetId)?.purpose !=
            'publisher_logo') {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final publisher = _libraryDatabase.createPublisher(
      displayName: values['display_name'] as String,
      originalName: values['original_name'] as String?,
      countryRegion: values['country_region'] as String?,
      foundedDate: values['founded_date'] as String?,
      logoAssetId: logoAssetId,
    );
    await _writeJson(request.response, HttpStatus.created, {
      'data': _publisherPayload(publisher),
    });
  }

  Future<void> _updateAdminPublisher(HttpRequest request) async {
    final values =
        _publisherInputValues(await _readJsonBody(request), creating: false);
    if (values == null || values.isEmpty) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final logoAssetId = values['logo_asset_id'] as String?;
    if (values.containsKey('logo_asset_id') &&
        logoAssetId != null &&
        _libraryDatabase.findManagedAsset(logoAssetId)?.purpose !=
            'publisher_logo') {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final publisher = _libraryDatabase.updatePublisher(
      request.uri.pathSegments.last,
      values,
    );
    if (publisher == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _publisherPayload(publisher),
    });
  }

  Future<void> _archiveAdminPublisher(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body == null || body.isNotEmpty) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final publisher =
        _libraryDatabase.archivePublisher(request.uri.pathSegments[4]);
    if (publisher == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _publisherPayload(publisher),
    });
  }

  Future<void> _deleteAdminPublisher(HttpRequest request) async {
    final id = request.uri.pathSegments.last;
    final publisher = _libraryDatabase.findPublisher(id);
    if (publisher == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (_libraryDatabase.publisherHasReferences(id)) {
      return _error(request, HttpStatus.conflict, 'publisher_in_use');
    }
    final logo = publisher.logoAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(publisher.logoAssetId!);
    if (!_libraryDatabase.deletePublisher(id)) {
      return _error(request, HttpStatus.conflict, 'publisher_in_use');
    }
    await _deleteManagedAsset(logo);
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {'deleted': true},
    });
  }

  Future<void> _createAdminSeries(HttpRequest request) async {
    final values =
        _seriesInputValues(await _readJsonBody(request), creating: true);
    if (values == null) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
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
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final series = _libraryDatabase.createSeries(
      displayName: values['display_name'] as String,
      publisherId: publisherId,
      originalName: values['original_name'] as String?,
      translatedName: values['translated_name'] as String?,
      releaseDate: values['release_date'] as String?,
      posterAssetId: posterAssetId,
    );
    await _writeJson(request.response, HttpStatus.created, {
      'data': _seriesPayload(series),
    });
  }

  Future<void> _updateAdminSeries(HttpRequest request) async {
    final seriesId = request.uri.pathSegments.last;
    final existing = _libraryDatabase.findSeries(seriesId);
    if (existing == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    final values =
        _seriesInputValues(await _readJsonBody(request), creating: false);
    if (values == null || values.isEmpty) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
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
      return _error(request, HttpStatus.conflict, 'series_in_use');
    }
    final series = _libraryDatabase.updateSeries(seriesId, values);
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _seriesPayload(series!),
    });
  }

  Future<void> _archiveAdminSeries(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body == null || body.isNotEmpty) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final series = _libraryDatabase.archiveSeries(request.uri.pathSegments[4]);
    if (series == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _seriesPayload(series),
    });
  }

  Future<void> _deleteAdminSeries(HttpRequest request) async {
    final id = request.uri.pathSegments.last;
    final series = _libraryDatabase.findSeries(id);
    if (series == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (series.movieCount > 0) {
      return _error(request, HttpStatus.conflict, 'series_in_use');
    }
    final poster = series.posterAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(series.posterAssetId!);
    if (!_libraryDatabase.deleteSeries(id)) {
      return _error(request, HttpStatus.conflict, 'series_in_use');
    }
    await _deleteManagedAsset(poster);
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {'deleted': true},
    });
  }

  Future<void> _uploadAdminPublisherLogo(HttpRequest request) async {
    final publisher =
        _libraryDatabase.findPublisher(request.uri.pathSegments[4]);
    if (publisher == null) {
      await request.drain<void>();
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    final asset = await _saveManagedImage(request, 'publisher_logo');
    if (asset == null)
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    final previous = publisher.logoAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(publisher.logoAssetId!);
    final updated = _libraryDatabase.updatePublisher(
      publisher.id,
      {'logo_asset_id': asset.id},
    );
    if (updated == null)
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    await _deleteManagedAsset(previous);
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _publisherPayload(updated),
    });
  }

  Future<void> _uploadAdminSeriesPoster(HttpRequest request) async {
    final series = _libraryDatabase.findSeries(request.uri.pathSegments[4]);
    if (series == null) {
      await request.drain<void>();
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    final asset = await _saveManagedImage(request, 'series_poster');
    if (asset == null)
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    final previous = series.posterAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(series.posterAssetId!);
    final updated = _libraryDatabase.updateSeries(
      series.id,
      {'poster_asset_id': asset.id},
    );
    if (updated == null)
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    await _deleteManagedAsset(previous);
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _seriesPayload(updated),
    });
  }

  Future<NasManagedAsset?> _saveManagedImage(
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

  Future<void> _deleteManagedAsset(NasManagedAsset? asset) async {
    if (asset == null) return;
    _libraryDatabase.removeManagedAsset(asset.id);
    await _artworkService.deleteManagedAsset(asset.fileName);
  }

  Future<void> _uploadManagedImage(HttpRequest request) async {
    final purpose = request.uri.queryParameters['purpose'];
    final mimeType = request.headers.contentType?.mimeType;
    if (!const {
      'actor_photo',
      'movie_poster',
      'publisher_logo',
      'series_poster',
    }.contains(purpose)) {
      await request.drain<void>();
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final bytes = await _readArtworkBytes(request, mimeType);
    if (bytes == null || mimeType == null) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
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
      await _writeJson(request.response, HttpStatus.created, {
        'data': _managedAssetPayload(asset),
      });
    } on ArgumentError {
      if (fileName != null) await _artworkService.deleteManagedAsset(fileName);
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
  }

  Future<void> _aiSettings(HttpRequest request) => _writeJson(
        request.response,
        HttpStatus.ok,
        {'data': _aiSettingsPayload(_state!.aiSettings)},
      );

  Future<void> _updateAiSettings(HttpRequest request) async {
    final body = await _readJsonBody(request);
    const fields = {'provider', 'endpoint', 'model', 'apiKey'};
    if (body == null ||
        body.keys.any((key) => !fields.contains(key)) ||
        fields.any((key) =>
            body[key] is! String || (body[key] as String).trim().isEmpty)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final endpoint = Uri.tryParse((body['endpoint'] as String).trim());
    if (endpoint == null ||
        !endpoint.hasAuthority ||
        !const {'http', 'https'}.contains(endpoint.scheme)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final settings = NasAiSettings(
      provider: (body['provider'] as String).trim(),
      endpoint: endpoint.toString(),
      model: (body['model'] as String).trim(),
      apiKey: (body['apiKey'] as String).trim(),
    );
    _state = NasPersistentState(
      serverId: _state!.serverId,
      tokens: _state!.tokens,
      aiSettings: settings,
    );
    await _persistState();
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _aiSettingsPayload(settings),
    });
  }

  Future<void> _createAiTask(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final movieId = body?['movieId'];
    final instructions = body?['instructions'] ?? '';
    if (body == null ||
        body.keys.any((key) => key != 'movieId' && key != 'instructions') ||
        movieId is! String ||
        movieId.isEmpty ||
        instructions is! String ||
        instructions.length > 4000) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    if (!_state!.aiSettings.isConfigured) {
      return _error(request, HttpStatus.conflict, 'ai_not_configured');
    }
    final task = _libraryDatabase.createAiTask(
      movieId: movieId,
      instructions: instructions.trim(),
    );
    if (task == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    _logger.event('ai.task.create', fields: {
      'component': 'nas.ai',
      'taskIdShort': nasShortId(task.id),
      'movieIdShort': nasShortId(task.movieId),
      'outcome': 'queued',
    });
    await _writeJson(request.response, HttpStatus.accepted, {
      'data': _aiTaskPayload(task),
    });
    unawaited(_runAiTask(task.id));
  }

  Future<void> _aiTask(HttpRequest request) async {
    final task = _libraryDatabase.findAiTask(request.uri.pathSegments.last);
    if (task == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': _aiTaskPayload(task),
    });
  }

  Future<void> _applyAiTask(HttpRequest request) async {
    final task = _libraryDatabase.findAiTask(request.uri.pathSegments[5]);
    if (task == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (task.status != 'succeeded' || task.resultJson == null) {
      return _error(request, HttpStatus.conflict, 'ai_task_not_ready');
    }
    final result = _aiTaskResult(task.resultJson!);
    if (result == null) {
      return _error(request, HttpStatus.conflict, 'ai_response_invalid');
    }
    final title = _nonEmptyText(result['title']);
    final summary = result['summary'];
    final hasOriginalTitle = result.containsKey('originalTitle');
    final originalTitle = result['originalTitle'];
    final hasCatalogNumber = result.containsKey('catalogNumber');
    final catalogNumber = result['catalogNumber'];
    if ((summary != null && summary is! String) ||
        (hasOriginalTitle &&
            originalTitle != null &&
            originalTitle is! String) ||
        (hasCatalogNumber &&
            catalogNumber != null &&
            catalogNumber is! String) ||
        (title == null &&
            summary == null &&
            !hasOriginalTitle &&
            !hasCatalogNumber)) {
      return _error(request, HttpStatus.conflict, 'ai_response_invalid');
    }
    final movie = _libraryDatabase.updateMovieMetadata(
      movieId: task.movieId,
      title: title,
      originalTitle: originalTitle as String?,
      updateOriginalTitle: hasOriginalTitle,
      catalogNumber: catalogNumber as String?,
      updateCatalogNumber: hasCatalogNumber,
      summary: summary as String?,
    );
    if (movie == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    await _writeJson(request.response, HttpStatus.ok, {
      'data': await _databaseDetails(movie),
    });
  }

  Future<void> _runAiTask(String taskId) async {
    final task = _libraryDatabase.markAiTaskRunning(taskId);
    if (task == null) return;
    try {
      final movie = _libraryDatabase.findMovieForAdmin(task.movieId);
      if (movie == null) {
        _libraryDatabase.failAiTask(task.id, 'resource_not_found');
        return;
      }
      final result = await _aiMetadataClient.generate(
        settings: _state!.aiSettings,
        movie: movie,
        instructions: task.instructions,
      );
      final completed = _libraryDatabase.completeAiTask(task.id, result);
      _logger.event('ai.task.complete', fields: {
        'component': 'nas.ai',
        'taskIdShort': nasShortId(task.id),
        'outcome': completed == null ? 'discarded' : 'succeeded',
      });
    } on NasAiMetadataException catch (error) {
      _libraryDatabase.failAiTask(task.id, error.code);
      _logger.event('ai.task.complete', level: 'WARN', fields: {
        'component': 'nas.ai',
        'taskIdShort': nasShortId(task.id),
        'outcome': 'failed',
        'errorCode': error.code,
      });
    } catch (_) {
      _libraryDatabase.failAiTask(task.id, 'ai_request_failed');
      _logger.event('ai.task.complete', level: 'WARN', fields: {
        'component': 'nas.ai',
        'taskIdShort': nasShortId(task.id),
        'outcome': 'failed',
        'errorCode': 'ai_request_failed',
      });
    }
  }

  Map<String, Object?> _aiSettingsPayload(NasAiSettings settings) => {
        'provider': settings.provider,
        'endpoint': settings.endpoint,
        'model': settings.model,
        'apiKeyConfigured': settings.apiKey != null,
        'isConfigured': settings.isConfigured,
      };

  Map<String, Object?> _aiTaskPayload(NasAiTask task) => {
        'id': task.id,
        'movieId': task.movieId,
        'instructions': task.instructions,
        'status': task.status,
        'result':
            task.resultJson == null ? null : _aiTaskResult(task.resultJson!),
        'errorCode': task.errorCode,
        'createdAt': task.createdAt,
        'finishedAt': task.finishedAt,
      };

  Map<String, Object?>? _aiTaskResult(String resultJson) {
    try {
      final decoded = jsonDecode(resultJson);
      if (decoded is! Map) return null;
      final result = <String, Object?>{};
      decoded.forEach((key, value) {
        if (key is String) result[key] = value;
      });
      return result;
    } on FormatException {
      return null;
    }
  }

  String? _nonEmptyText(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return value.trim();
  }

  Future<void> _managedAsset(HttpRequest request) async {
    final asset =
        _libraryDatabase.findManagedAsset(request.uri.pathSegments.last);
    if (asset == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    final artwork = await _artworkService.managedAsset(asset.fileName);
    if (artwork == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.parse(artwork.mimeType);
    request.response.headers.contentLength = await artwork.file.length();
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (request.method == 'GET') {
      await request.response.addStream(artwork.file.openRead());
    }
    await request.response.close();
  }

  Map<String, Object?> _publisherReferencePayload(NasPublisher publisher) => {
        'id': publisher.id,
        'displayName': publisher.displayName,
      };

  Map<String, Object?> _seriesReferencePayload(NasSeries series) => {
        'id': series.id,
        'displayName': series.displayName,
        'publisherId': series.publisherId,
      };

  Map<String, Object?> _publisherPayload(
    NasPublisher publisher, {
    bool includeTags = false,
  }) {
    final logo = publisher.logoAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(publisher.logoAssetId!);
    return {
      ..._publisherReferencePayload(publisher),
      'originalName': publisher.originalName,
      'countryRegion': publisher.countryRegion,
      'foundedDate': publisher.foundedDate,
      'logoAsset': logo == null ? null : _managedAssetPayload(logo),
      'movieCount': publisher.movieCount,
      'seriesCount': publisher.seriesCount,
      'durationMs': publisher.durationMs,
      if (includeTags)
        'tags': _libraryDatabase
            .tagsForPublisher(publisher.id)
            .map(_tagPayload)
            .toList(growable: false),
      'createdAt': publisher.createdAt,
      'updatedAt': publisher.updatedAt,
      'archivedAt': publisher.archivedAt,
    };
  }

  Map<String, Object?> _seriesPayload(
    NasSeries series, {
    bool includeTags = false,
  }) {
    final publisher = series.publisherId == null
        ? null
        : _libraryDatabase.findPublisher(series.publisherId!);
    final poster = series.posterAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(series.posterAssetId!);
    return {
      ..._seriesReferencePayload(series),
      'originalName': series.originalName,
      'translatedName': series.translatedName,
      'publisher':
          publisher == null ? null : _publisherReferencePayload(publisher),
      'releaseDate': series.releaseDate,
      'posterAsset': poster == null ? null : _managedAssetPayload(poster),
      'movieCount': series.movieCount,
      'episodeCount': series.episodeCount,
      'durationMs': series.durationMs,
      if (includeTags)
        'tags': _libraryDatabase
            .tagsForSeries(series.id)
            .map(_tagPayload)
            .toList(growable: false),
      'createdAt': series.createdAt,
      'updatedAt': series.updatedAt,
      'archivedAt': series.archivedAt,
    };
  }

  Map<String, Object?> _actorPayload(NasActor actor) {
    final photoAsset = actor.photoAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(actor.photoAssetId!);
    return {
      'id': actor.id,
      'stageName': actor.stageName,
      'originalName': actor.originalName,
      'translatedName': actor.translatedName,
      'aliases': actor.aliases,
      'gender': actor.gender,
      'birthMonth': actor.birthMonth,
      'age': _actorAge(actor.birthMonth),
      'heightCm': actor.heightCm,
      'weightKg': actor.weightKg,
      'measurements': actor.measurements,
      'bodyType': actor.bodyType,
      'country': actor.country,
      'debutMonth': actor.debutMonth,
      'debutDescription': actor.debutDescription,
      'photoAsset':
          photoAsset == null ? null : _managedAssetPayload(photoAsset),
      'publishers': _libraryDatabase
          .publishersForActor(actor.id)
          .map(_publisherReferencePayload)
          .toList(growable: false),
      'movieCount': actor.movieCount,
      'createdAt': actor.createdAt,
      'updatedAt': actor.updatedAt,
      'archivedAt': actor.archivedAt,
    };
  }

  Map<String, Object?> _managedAssetPayload(NasManagedAsset asset) => {
        'id': asset.id,
        'purpose': asset.purpose,
        'url': '/api/v1/assets/${asset.id}',
        'mimeType': asset.mimeType,
        'createdAt': asset.createdAt,
      };

  int _compareActors(NasActor left, NasActor right, String sort, String order) {
    int compared;
    switch (sort) {
      case 'age':
        compared = _compareNullableInt(
            _actorAge(left.birthMonth), _actorAge(right.birthMonth));
      case 'movieCount':
        compared = left.movieCount.compareTo(right.movieCount);
      case 'debutMonth':
        compared = _compareNullableString(left.debutMonth, right.debutMonth);
      default:
        compared = left.createdAt.compareTo(right.createdAt);
    }
    if (compared == 0) compared = left.id.compareTo(right.id);
    return order == 'asc' ? compared : -compared;
  }

  int _compareActorMovies(
    NasLibraryMovie left,
    NasLibraryMovie right,
    String sort,
    String order,
  ) {
    final compared = switch (sort) {
      'title' => left.title.compareTo(right.title),
      'durationMs' => _compareNullableInt(left.durationMs, right.durationMs),
      'createdAt' => left.updatedAt.compareTo(right.updatedAt),
      _ => left.playCount.compareTo(right.playCount),
    };
    final stable = compared == 0 ? left.id.compareTo(right.id) : compared;
    return order == 'asc' ? stable : -stable;
  }

  int _comparePublishers(
    NasPublisher left,
    NasPublisher right,
    String sort,
    String order,
  ) {
    final compared = switch (sort) {
      'name' => left.displayName.compareTo(right.displayName),
      'movieCount' => left.movieCount.compareTo(right.movieCount),
      'seriesCount' => left.seriesCount.compareTo(right.seriesCount),
      _ => left.createdAt.compareTo(right.createdAt),
    };
    final stable = compared == 0 ? left.id.compareTo(right.id) : compared;
    return order == 'asc' ? stable : -stable;
  }

  int _compareSeries(
    NasSeries left,
    NasSeries right,
    String sort,
    String order,
  ) {
    final compared = switch (sort) {
      'name' => left.displayName.compareTo(right.displayName),
      'movieCount' => left.movieCount.compareTo(right.movieCount),
      'releaseDate' =>
        _compareNullableString(left.releaseDate, right.releaseDate),
      _ => left.createdAt.compareTo(right.createdAt),
    };
    final stable = compared == 0 ? left.id.compareTo(right.id) : compared;
    return order == 'asc' ? stable : -stable;
  }

  int _compareMovies(
    NasLibraryMovie left,
    NasLibraryMovie right,
    String sort,
    String order,
  ) {
    final compared = switch (sort) {
      'updatedAt' => left.updatedAt.compareTo(right.updatedAt),
      'durationMs' => _compareNullableInt(left.durationMs, right.durationMs),
      'recent' => left.playCount.compareTo(right.playCount),
      _ => left.title.compareTo(right.title),
    };
    final stable = compared == 0 ? left.id.compareTo(right.id) : compared;
    return order == 'asc' ? stable : -stable;
  }

  int? _actorAge(String? birthMonth) {
    if (birthMonth == null ||
        !RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(birthMonth)) {
      return null;
    }
    final parts = birthMonth.split('-');
    final now = DateTime.now();
    return now.year -
        int.parse(parts[0]) -
        (now.month < int.parse(parts[1]) ? 1 : 0);
  }

  int _compareNullableInt(int? left, int? right) {
    if (left == null) return right == null ? 0 : 1;
    if (right == null) return -1;
    return left.compareTo(right);
  }

  int _compareNullableString(String? left, String? right) {
    if (left == null) return right == null ? 0 : 1;
    if (right == null) return -1;
    return left.compareTo(right);
  }

  Map<String, Object?>? _publisherInputValues(
    Map<String, dynamic>? body, {
    required bool creating,
  }) {
    if (body == null) return null;
    const fields = {
      'displayName': 'display_name',
      'originalName': 'original_name',
      'countryRegion': 'country_region',
      'foundedDate': 'founded_date',
      'logoAssetId': 'logo_asset_id',
    };
    if (body.keys.any((key) => !fields.containsKey(key))) return null;
    final values = <String, Object?>{};
    for (final entry in body.entries) {
      final value = entry.value;
      if (value != null && value is! String) return null;
      final normalized = value is String ? _nullableTrimmed(value) : null;
      if (entry.key == 'displayName' && normalized == null) return null;
      if (entry.key == 'foundedDate' &&
          normalized != null &&
          !RegExp(r'^\d{4}(-\d{2}(-\d{2})?)?$').hasMatch(normalized)) {
        return null;
      }
      values[fields[entry.key]!] = normalized;
    }
    if (creating && (values['display_name'] as String?) == null) return null;
    return values;
  }

  Map<String, Object?>? _seriesInputValues(
    Map<String, dynamic>? body, {
    required bool creating,
  }) {
    if (body == null) return null;
    const fields = {
      'displayName': 'display_name',
      'originalName': 'original_name',
      'translatedName': 'translated_name',
      'publisherId': 'publisher_id',
      'releaseDate': 'release_date',
      'posterAssetId': 'poster_asset_id',
    };
    if (body.keys.any((key) => !fields.containsKey(key))) return null;
    final values = <String, Object?>{};
    for (final entry in body.entries) {
      final value = entry.value;
      if (value != null && value is! String) return null;
      final normalized = value is String ? _nullableTrimmed(value) : null;
      if (entry.key == 'displayName' && normalized == null) {
        return null;
      }
      if (entry.key == 'releaseDate' &&
          normalized != null &&
          !RegExp(r'^\d{4}(-\d{2}(-\d{2})?)?$').hasMatch(normalized)) {
        return null;
      }
      values[fields[entry.key]!] = normalized;
    }
    if (creating && (values['display_name'] as String?) == null) {
      return null;
    }
    return values;
  }

  Map<String, Object?>? _actorInputValues(
    Map<String, dynamic>? body, {
    required bool creating,
  }) {
    if (body == null) return null;
    const fields = {
      'stageName': 'stage_name',
      'originalName': 'original_name',
      'translatedName': 'translated_name',
      'aliases': 'aliases_json',
      'gender': 'gender',
      'birthMonth': 'birth_month',
      'heightCm': 'height_cm',
      'weightKg': 'weight_kg',
      'measurements': 'measurements',
      'bodyType': 'body_type',
      'country': 'country',
      'debutMonth': 'debut_month',
      'debutDescription': 'debut_description',
      'photoAssetId': 'photo_asset_id',
      'publisherIds': 'publisher_ids',
    };
    if (body.keys.any((key) => !fields.containsKey(key))) return null;
    final values = <String, Object?>{};
    for (final entry in body.entries) {
      final databaseKey = fields[entry.key]!;
      final value = entry.value;
      switch (entry.key) {
        case 'aliases':
          if (value is! List || value.any((item) => item is! String))
            return null;
          values[databaseKey] =
              jsonEncode(_cleanTextValues(value.cast<String>()));
        case 'publisherIds':
          if (value is! List || value.any((item) => item is! String))
            return null;
          final publisherIds = _cleanTextValues(value.cast<String>());
          if (publisherIds.length != value.length) return null;
          values[databaseKey] = publisherIds;
        case 'gender':
          if (value != null &&
              !const {'female', 'intersex', 'male'}.contains(value))
            return null;
          values[databaseKey] = value;
        case 'birthMonth':
        case 'debutMonth':
          if (value != null &&
              (value is! String ||
                  !RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(value))) {
            return null;
          }
          values[databaseKey] = value;
        case 'heightCm':
          if (value != null && (value is! int || value < 1 || value > 300))
            return null;
          values[databaseKey] = value;
        case 'weightKg':
          if (value != null && (value is! int || value < 1 || value > 500))
            return null;
          values[databaseKey] = value;
        default:
          if (value != null && value is! String) return null;
          values[databaseKey] =
              value is String && value.trim().isEmpty ? null : value?.trim();
      }
    }
    if (creating &&
        ![
          values['stage_name'],
          values['original_name'],
          values['translated_name'],
          ..._stringListFromJson(values['aliases_json'] as String?),
        ].any((value) => value is String && value.isNotEmpty)) {
      return null;
    }
    return values;
  }

  Map<String, Object?> _databaseSummary(NasLibraryMovie movie) => {
        'id': movie.id,
        'title': movie.title,
        'originalTitle': movie.originalTitle,
        'catalogNumber': movie.catalogNumber,
        'publisher': movie.publisherId == null
            ? null
            : {
                'id': movie.publisherId,
                'displayName': movie.publisherName,
              },
        'series': movie.seriesId == null
            ? null
            : {
                'id': movie.seriesId,
                'displayName': movie.seriesName,
                'publisherId': movie.publisherId,
              },
        'actors': nasMovieActorsToJson(movie.actors),
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
      'actors':
          movie.actors.map(_movieActorDetailsPayload).toList(growable: false),
      'summary': movie.summary,
      'lastPlayedAt': _libraryDatabase.lastPlaybackStartedAtForMovie(movie.id),
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

  Map<String, Object?> _movieActorDetailsPayload(NasMovieActor relation) {
    final actorId = relation.id;
    final actor = actorId == null ? null : _libraryDatabase.findActor(actorId);
    final photoAsset = actor?.photoAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(actor!.photoAssetId!);
    return {
      ...relation.toJson(),
      'originalName': actor?.originalName,
      'photoAsset':
          photoAsset == null ? null : _managedAssetPayload(photoAsset),
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
        (directoryKey != null &&
            !await _canBindCategoryDirectory(directoryKey))) {
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
    final scanJob =
        directoryChanged ? _scheduleCategoryScan(category.id) : null;
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {
        ..._categoryPayload(category),
        if (scanJob != null) 'scanJob': _scanJobPayload(scanJob),
      },
    });
  }

  Future<void> _deleteAdminCategory(HttpRequest request) async {
    if (!_libraryDatabase.deleteCategory(
      request.uri.pathSegments.last,
      deleteMovies: config.managedCategoryLibrary,
    )) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> _tagManagementOverview(HttpRequest request) async {
    final overview = _libraryDatabase.tagOverview();
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {
        'total': overview.total,
        'levelOne': overview.levelOne,
        'levelTwo': overview.levelTwo,
        'levelThree': overview.levelThree,
        'movieLinks': overview.movieLinks,
      },
    });
  }

  Future<void> _tagManagementDirectory(HttpRequest request) async {
    final roots = _libraryDatabase.tagDirectory(
      query: request.uri.queryParameters['q'] ?? '',
    );
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {
        'items': roots
            .map((root) => {
                  'tag': _tagPayload(root.tag),
                  'movieCount': root.movieCount,
                  'children': root.children
                      .map((child) => {
                            'tag': _tagPayload(child.tag),
                            'movieCount': child.movieCount,
                          })
                      .toList(growable: false),
                })
            .toList(growable: false),
      },
    });
  }

  Future<void> _tagManagementParentCandidates(HttpRequest request) async {
    final parameters = request.uri.queryParameters;
    final level = int.tryParse(parameters['level'] ?? '') ?? 0;
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '20') ?? 0;
    if (level < 2 || level > 3 || page < 1 || pageSize < 1 || pageSize > 50) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
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
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {'items': items.map(_tagPayload).toList(growable: false)},
      'page': {
        'number': page,
        'size': pageSize,
        'total': candidates.length,
        'hasMore': offset + items.length < candidates.length,
      },
    });
  }

  Future<void> _tagManagementSelectableTags(HttpRequest request) async {
    final parameters = request.uri.queryParameters;
    final level = int.tryParse(parameters['level'] ?? '') ?? 0;
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '20') ?? 0;
    if (level < 1 || level > 3 || page < 1 || pageSize < 1 || pageSize > 50) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
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
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {'items': items.map(_tagPayload).toList(growable: false)},
      'page': {
        'number': page,
        'size': pageSize,
        'total': tags.length,
        'hasMore': offset + items.length < tags.length,
      },
    });
  }

  Future<void> _tagManagementDetails(HttpRequest request) async {
    final details = _libraryDatabase.tagDetails(
      tagId: request.uri.pathSegments.last,
      contextParentId: request.uri.queryParameters['contextParentId'],
      contextRootId: request.uri.queryParameters['contextRootId'],
    );
    if (details == null)
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {
        'tag': _tagPayload(details.tag),
        'parents': details.parents.map(_tagPayload).toList(growable: false),
        'directChildCount': details.directChildCount,
        'movieCount': details.movieCount,
        'path': details.path.map(_tagPayload).toList(growable: false),
      },
    });
  }

  Future<void> _tagManagementChildren(HttpRequest request) async {
    final parameters = request.uri.queryParameters;
    final scope = parameters['scope'] ?? 'all';
    final associated = switch (scope) {
      'all' => null,
      'linked' => true,
      'unlinked' => false,
      _ => null,
    };
    if (!const {'all', 'linked', 'unlinked'}.contains(scope)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
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
      await _writeJson(request.response, HttpStatus.ok, {
        'data': {
          'items': page.items
              .map((item) => {
                    'tag': _tagPayload(item.tag),
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
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
  }

  Future<void> _tagManagementMovies(HttpRequest request) async {
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
          .map(_databaseSummary)
          .toList(growable: false);
      await _writeJson(request.response, HttpStatus.ok, {
        'data': {'items': movies},
        'page': {
          'number': page.number,
          'size': page.size,
          'total': page.total,
          'hasMore': page.hasMore,
        },
      });
    } on ArgumentError {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
  }

  Future<void> _tagManagementTemplate(HttpRequest request) => _writeJson(
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

  Future<void> _tagManagementExport(HttpRequest request) => _writeJson(
        request.response,
        HttpStatus.ok,
        {'data': _libraryDatabase.exportTagTaxonomy().toJson()},
      );

  Future<void> _importTagManagement(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body == null)
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    try {
      await _writeTaxonomyResult(
        request,
        _libraryDatabase.importTagTaxonomy(NasTagTaxonomyTransfer.decode(body)),
      );
    } on FormatException {
      await _error(request, HttpStatus.badRequest, 'invalid_taxonomy');
    }
  }

  Future<void> _createTagManagementTag(HttpRequest request) async {
    final input =
        _tagManagementInput(await _readJsonBody(request), creating: true);
    if (input == null)
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    try {
      final tag = _libraryDatabase.createTag(
        name: input.name,
        level: input.level!,
        description: input.description,
        color: input.color,
        parentIds: input.parentIds,
      );
      await _writeJson(
          request.response, HttpStatus.created, {'data': _tagPayload(tag)});
    } on ArgumentError {
      await _error(request, HttpStatus.badRequest, 'invalid_request');
    } on StateError {
      await _error(request, HttpStatus.conflict, 'tag_taxonomy_conflict');
    }
  }

  Future<void> _updateTagManagementTag(HttpRequest request) async {
    final tagId = request.uri.pathSegments.last;
    final current = _libraryDatabase.findTag(tagId);
    if (current == null)
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    final input =
        _tagManagementInput(await _readJsonBody(request), creating: false);
    if (input == null)
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    try {
      final tag = _libraryDatabase.updateTag(
        tagId: tagId,
        name: input.name,
        description: input.description,
        color: input.color,
        parentIds: input.parentIds,
      );
      if (tag == null) {
        await _error(request, HttpStatus.notFound, 'resource_not_found');
        return;
      }
      await _writeJson(
          request.response, HttpStatus.ok, {'data': _tagPayload(tag)});
    } on ArgumentError {
      await _error(request, HttpStatus.badRequest, 'invalid_request');
    } on StateError {
      await _error(request, HttpStatus.conflict, 'tag_taxonomy_conflict');
    }
  }

  Future<void> _archiveTagManagementTag(HttpRequest request) async {
    final tagId = request.uri.pathSegments[request.uri.pathSegments.length - 2];
    if (!_libraryDatabase.archiveTag(tagId)) {
      await _error(request, HttpStatus.notFound, 'resource_not_found');
      return;
    }
    final tag = _libraryDatabase.findTag(tagId)!;
    await _writeJson(
        request.response, HttpStatus.ok, {'data': _tagPayload(tag)});
  }

  Future<void> _deleteTagManagementTag(HttpRequest request) async {
    try {
      if (!_libraryDatabase.deleteTag(request.uri.pathSegments.last)) {
        await _error(request, HttpStatus.notFound, 'resource_not_found');
        return;
      }
    } on StateError {
      await _error(request, HttpStatus.conflict, 'tag_has_references');
      return;
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
            (await _mediaService.directoryForRelativePath(parentKey)) ==
                null)) {
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
            key != 'originalTitle' &&
            key != 'catalogNumber' &&
            key != 'publisherId' &&
            key != 'seriesId' &&
            key != 'summary' &&
            key != 'actorIds' &&
            key != 'categoryId' &&
            key != 'tagIds')) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
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
      return _error(request, HttpStatus.notFound, 'resource_not_found');
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
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final title = (rawTitle as String?)?.trim();
    if (title != null && title.isEmpty) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final originalTitle = (rawOriginalTitle as String?)?.trim();
    final catalogNumber = (rawCatalogNumber as String?)?.trim();
    final publisherId = (rawPublisherId as String?)?.trim();
    final seriesId = (rawSeriesId as String?)?.trim();
    List<String>? actorIds;
    if (hasActorIds) {
      final rawList = rawActorIds as List;
      if (rawList.length > 80 || rawList.any((value) => value is! String)) {
        return _error(request, HttpStatus.badRequest, 'invalid_request');
      }
      actorIds = rawList.cast<String>();
      if (actorIds.any((id) => id.isEmpty) ||
          actorIds.toSet().length != actorIds.length ||
          actorIds.any((id) {
            final actor = _libraryDatabase.findActor(id);
            return actor == null || actor.archivedAt != null;
          })) {
        return _error(request, HttpStatus.badRequest, 'invalid_request');
      }
    }
    final categoryId = rawCategoryId as String?;
    if (hasCategoryId &&
        (categoryId?.isEmpty == true ||
            (categoryId != null &&
                _libraryDatabase.findCategory(categoryId) == null))) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
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
      return _error(request, HttpStatus.badRequest, 'invalid_request');
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
      return _error(
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
      return _error(request, HttpStatus.notFound, 'resource_not_found');
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
      return _error(
          request, HttpStatus.conflict, 'movie_series_publisher_conflict');
    }
    if (actorIds != null &&
        !_libraryDatabase.setMovieActorIds(
          movieId: movie.id,
          actorIds: actorIds,
        )) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    _libraryDatabase.setMovieTaxonomy(
      movieId: movie.id,
      updateCategory: hasCategoryId,
      categoryId: categoryId,
      updateTagIds: hasTagIds,
      tagIds: tagIds.cast<String>(),
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
      if (updated == null)
        throw StateError('episode disappeared during rename');
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
      return _error(request, HttpStatus.internalServerError,
          'source_metadata_update_failed');
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
      mediaRootId:
          categoryScan ? _configuredMediaRoot!.id : mediaRootId as String,
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
        'level': tag.level,
        'description': tag.description,
        'color': tag.color,
        'createdAt': tag.createdAt,
        'updatedAt': tag.updatedAt,
        'archivedAt': tag.archivedAt,
      };

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
    final directory =
        await _mediaService.directoryForRelativePath(directoryKey);
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
                    'originalTitle': item.originalTitle,
                    'catalogNumber': item.catalogNumber,
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
    if (movie == null)
      return _error(request, HttpStatus.notFound, 'resource_not_found');
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
    if (image == null)
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    await _artworkService.deleteCarouselImage(image.fileName);
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> _carouselImage(HttpRequest request) async {
    final image =
        _libraryDatabase.findCarouselImage(request.uri.pathSegments.last);
    if (image == null)
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    final artwork = await _artworkService.carouselImage(image.fileName);
    if (artwork == null)
      return _error(request, HttpStatus.notFound, 'resource_not_found');
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
        !NasArtworkService.isValidPosterBytes(
            mimeType: mimeType, bytes: bytes)) {
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
      'ai_not_configured': 'AI settings have not been configured on this NAS.',
      'ai_task_not_ready':
          'The AI task does not have an applicable result yet.',
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

List<String> _stringListFromJson(String? value) {
  if (value == null || value.isEmpty) return const [];
  try {
    final decoded = jsonDecode(value);
    if (decoded is! List) return const [];
    return _cleanTextValues(decoded.whereType<String>());
  } on FormatException {
    return const [];
  }
}

List<String> _cleanTextValues(Iterable<String> values) => values
    .map((value) => value.trim())
    .where((value) => value.isNotEmpty)
    .toSet()
    .toList(growable: false);

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
