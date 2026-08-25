import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'auth.dart';
import 'config.dart';
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
  })  : _stateStore = stateStore ?? NasPersistentStateStore(config.dataDir),
        _library = library ?? NasFixtureLibrary(),
        _mediaService = mediaService ??
            NasMediaService(
              mediaDir: config.mediaDir,
              fixtureRelativePath: config.fixtureMediaRelativePath,
            ),
        _libraryDatabase =
            libraryDatabase ?? NasLibraryDatabase(config.dataDir);

  final NasConfig config;
  final NasPersistentStateStore _stateStore;
  final NasFixtureLibrary _library;
  final NasMediaService _mediaService;
  final NasLibraryDatabase _libraryDatabase;
  HttpServer? _server;
  NasPersistentState? _state;
  final Map<String, _PairingSession> _pairingSessions = {};
  final Map<String, _PlaybackSession> _playbackSessions = {};
  final Map<String, _ScanJob> _scanJobs = {};
  _FixturePlaybackState? _fixturePlaybackState;
  NasMediaRoot? _configuredMediaRoot;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? config.port;

  Future<void> start() async {
    if (_server != null) {
      throw StateError('NAS health server is already running.');
    }
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
    unawaited(_serve(server));
  }

  Future<void> stop() async {
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
        await _handle(request);
      }
    } on HttpException {
      // A client may disconnect while a health response is being sent.
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == '/health') {
        return _health(request);
      }
      if (request.method == 'GET' && path == '/api/v1/server-info') {
        return _serverInfo(request);
      }
      if (request.method == 'POST' && path == '/api/v1/pairing/sessions') {
        return _createPairingSession(request);
      }
      if (request.method == 'POST' &&
          RegExp(r'^/api/v1/pairing/sessions/[^/]+/confirm$').hasMatch(path)) {
        return _confirmPairing(request);
      }
      if (!path.startsWith('/api/v1/')) {
        return _error(request, HttpStatus.notFound, 'resource_not_found');
      }

      final tokenHash = _authenticatedTokenHash(request);
      final device = tokenHash == null ? null : _state!.tokens[tokenHash];
      if (device == null || tokenHash == null) {
        return _error(
            request, HttpStatus.unauthorized, 'authentication_required');
      }
      if (path.startsWith('/api/v1/admin/') && device.scope != 'admin') {
        return _error(request, HttpStatus.forbidden, 'insufficient_scope');
      }
      if (request.method == 'GET' && path == '/api/v1/admin/media-roots') {
        return _adminMediaRoots(request);
      }
      if (request.method == 'PATCH' &&
          RegExp(r'^/api/v1/admin/movies/[^/]+$').hasMatch(path)) {
        return _updateAdminMovie(request);
      }
      if (request.method == 'PATCH' &&
          RegExp(r'^/api/v1/admin/episodes/[^/]+$').hasMatch(path)) {
        return _updateAdminEpisode(request);
      }
      if (request.method == 'POST' && path == '/api/v1/admin/scan-jobs') {
        return _createScanJob(request);
      }
      if (request.method == 'GET' && path == '/api/v1/admin/scan-jobs') {
        return _listScanJobs(request);
      }
      if (request.method == 'GET' &&
          RegExp(r'^/api/v1/admin/scan-jobs/[^/]+$').hasMatch(path)) {
        return _scanJob(request);
      }
      if (request.method == 'GET' && path == '/api/v1/movies') {
        return _movies(request);
      }
      if (request.method == 'GET' &&
          RegExp(r'^/api/v1/movies/[^/]+$').hasMatch(path)) {
        return _movieDetails(request);
      }
      if (request.method == 'GET' && path == '/api/v1/tag-paths') {
        return _tagPaths(request);
      }
      if (request.method == 'GET' && path == '/api/v1/favorites') {
        return _emptyItems(request);
      }
      if (request.method == 'GET' && path == '/api/v1/history') {
        return _emptyItems(request);
      }
      if ((request.method == 'GET' || request.method == 'HEAD') &&
          RegExp(r'^/api/v1/assets/posters/[^/]+$').hasMatch(path)) {
        return _poster(request);
      }
      if (request.method == 'POST' && path == '/api/v1/playback/sessions') {
        return _createPlaybackSession(request, tokenHash);
      }
      if (request.method == 'PATCH' &&
          RegExp(r'^/api/v1/playback/sessions/[^/]+/progress$')
              .hasMatch(path)) {
        return _savePlaybackProgress(request, tokenHash);
      }
      if (request.method == 'DELETE' &&
          RegExp(r'^/api/v1/playback/sessions/[^/]+$').hasMatch(path)) {
        return _deletePlaybackSession(request, tokenHash);
      }
      if ((request.method == 'GET' || request.method == 'HEAD') &&
          RegExp(r'^/api/v1/playback/sessions/[^/]+/stream$').hasMatch(path)) {
        return _streamPlayback(request, tokenHash);
      }
      await _error(request, HttpStatus.notFound, 'resource_not_found');
    } catch (_) {
      try {
        await _error(
            request, HttpStatus.internalServerError, 'service_unavailable');
      } catch (_) {
        await request.response.close();
      }
    }
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
        'category': null,
        'tags': const [],
        'tagPaths': const [],
        'episodeCount': movie.episodeCount,
        'durationMs': movie.durationMs,
        'posterUrl': null,
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
                ? const <List<String>>[]
                : _library.tagPaths(),
          },
        },
      );

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

  Future<void> _updateAdminMovie(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body == null ||
        body.keys.any((key) => key != 'title' && key != 'summary')) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final rawTitle = body['title'];
    final rawSummary = body['summary'];
    if ((rawTitle != null && rawTitle is! String) ||
        (rawSummary != null && rawSummary is! String) ||
        (rawTitle == null && rawSummary == null)) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
    }
    final title = (rawTitle as String?)?.trim();
    if (title != null && title.isEmpty) {
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
    await _writeJson(request.response, HttpStatus.ok, {
      'data': await _databaseDetails(movie),
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
    try {
      final result = await _libraryDatabase.scanMediaRoot(
        mediaRootId: job.mediaRootId,
        mediaService: _mediaService,
      );
      job.status = 'succeeded';
      job.scannedFiles = result.scannedFiles;
      job.availableEpisodes = result.availableEpisodes;
    } catch (_) {
      job.status = 'failed';
      job.errorCode = 'service_unavailable';
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
    final bytes = _library.poster(request.uri.pathSegments.last);
    if (bytes == null) {
      return _error(request, HttpStatus.notFound, 'resource_not_found');
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType('image', 'png');
    request.response.headers.contentLength = bytes.length;
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (request.method == 'GET') request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _createPlaybackSession(
      HttpRequest request, String tokenHash) async {
    final body = await _readJsonBody(request);
    final requestedMovieId = body?['contentId'];
    final requestedEpisodeId = body?['episodeId'];
    if (requestedMovieId is! String) {
      return _error(request, HttpStatus.badRequest, 'invalid_request');
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
    final previous = _fixturePlaybackState;
    final durationMs = previous?.durationMs ?? 600000;
    final resumePositionMs = previous?.positionMs ?? 0;
    final sessionId = newUuidV4();
    _playbackSessions[sessionId] = _PlaybackSession(
      tokenHash: tokenHash,
      relativePath: file.relativePath,
    );
    await _writeJson(request.response, HttpStatus.ok, {
      'data': {
        'sessionId': sessionId,
        'episodeId': 'fixture-episode-1',
        'resumePositionMs': resumePositionMs,
        'durationMs': durationMs,
        'playbackVariants': [
          {
            'type': 'direct',
            'url': '/api/v1/playback/sessions/$sessionId/stream',
            'mimeType': mimeTypeForMediaPath(file.relativePath),
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
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> _streamPlayback(HttpRequest request, String tokenHash) async {
    final session = _playbackSession(request, tokenHash);
    final file = await _mediaService.fixtureFile();
    if (session == null ||
        file == null ||
        file.relativePath != session.relativePath) {
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
    if (request.method == 'GET') {
      await request.response.addStream(file.openRead(start, end + 1));
    }
    await request.response.close();
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
