// Request handlers are dispatched independently so a long-lived media stream
// cannot block health checks or unrelated API requests.
import 'dart:async';
import 'dart:io';

import 'ai_metadata_service.dart';
import 'artwork_service.dart';
import 'auth.dart';
import 'backup_service.dart';
import 'backup_recovery_harness.dart';
import 'config.dart';
import 'disk_work_queue.dart';
import 'diagnostic_log.dart';
import 'fixture_library.dart';
import 'library/mdcng_actor_source.dart';
import 'library_database.dart';
import 'media_service.dart';
import 'novels/novel_backup.dart';
import 'novels/novel_http.dart';
import 'novels/novel_service.dart';
import 'novels/novel_storage.dart';
import 'novels/restore_activation.dart';
import 'comics/comic_http.dart';
import 'persistent_state.dart';
import 'scrape_service.dart';

import 'http/response.dart';
import 'http/api_router.dart';
import 'http/presenter.dart';
import 'http/media_resolver.dart';
import 'http/artwork.dart';
import 'http/movies.dart';
import 'http/profiles.dart';
import 'http/profile_packages.dart';
import 'http/ai.dart';
import 'http/scan.dart';
import 'http/taxonomy.dart';
import 'http/mdcng_movies.dart';
import 'http/mdcng_actors.dart';
import 'http/history.dart';
import 'http/playback.dart';
import 'http/pairing.dart';
import 'http/operations.dart';
import 'http/scraping.dart';

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
    NasMdcngActorSource? mdcngActorSource,
    NasScrapeWorker? scrapeWorker,
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
        _scrapeWorker = scrapeWorker ??
            NasProcessScrapeWorker(
                script: config.scraperScript,
                dataDir: '${config.dataDir}/scraper',
                node: config.scraperNode),
        _aiMetadataClient =
            aiMetadataClient ?? const NasDisabledAiMetadataClient(),
        _mdcngActorSource = mdcngActorSource ??
            (config.mdcngDataDir == null
                ? null
                : NasMdcngActorSource(config.mdcngDataDir!));

  final NasConfig config;

  final NasPersistentStateStore _stateStore;

  final NasFixtureLibrary _library;

  final NasMediaService _mediaService;

  final NasLibraryDatabase _libraryDatabase;

  final NasArtworkService _artworkService;

  final NasBackupService _backupService;

  final NasDiagnosticLogger _logger;

  final NasAiMetadataClient _aiMetadataClient;

  final NasMdcngActorSource? _mdcngActorSource;

  final NasScrapeWorker _scrapeWorker;

  NasScrapeService? _scraper;

  NasNovelHttpApi? _novelApi;

  NasNovelBackupCoordinator? _novelBackupCoordinator;

  ComicHttpApi? _comicApi;

  NasRestoreActivationService? _restoreActivation;

  bool _maintenance = false;

  HttpServer? _server;

  NasPersistentState? _state;

  NasMediaRoot? _configuredMediaRoot;

  int _activeRequests = 0;

  late final _diskWork = DiskWorkQueue(
    playbackActive: () => _playback.activeStreams > 0,
    backgroundBytesPerSecond: config.backgroundReadBytesPerSecond,
  );

  bool get isRunning => _server != null;

  int get port => _server?.port ?? config.port;

  Future<void> start() async {
    if (_server != null) {
      throw StateError('NAS health server is already running.');
    }
    _diskWork.accepting = true;
    _logger.event('service.start',
        fields: {'component': 'nas.service', 'phase': 'startup'});
    _state =
        await _stateStore.load() ?? NasPersistentState(serverId: newUuidV4());
    await _persistState();
    if (config.novelDir != null || config.comicDir != null) {
      _restoreActivation = NasRestoreActivationService(
        dataDir: config.dataDir,
        novelDir: config.novelDir,
      );
      await _restoreActivation!.recoverIncompleteActivation();
    }
    await _libraryDatabase.open();
    _scraper = NasScrapeService(
        _libraryDatabase, _artworkService, _scrapeWorker,
        cacheDir: '${config.dataDir}/scraper', logger: _logger)
      ..start();
    await _backupService.recoverIncomplete();
    await _initializeNovelServices();
    await _initializeComicServices();
    _configuredMediaRoot = _libraryDatabase.ensureConfiguredMediaRoot(
      rootName: config.mediaRootName,
      containerPath: config.mediaDir,
    );
    // 双盘覆盖以 /media/disk1、/media/disk2 作为物理来源盘；不存在时保留旧单根兼容。
    final topDirectories = await _mediaService.childDirectories(null);
    for (final directory in topDirectories) {
      final diskName = directory.relativePath.split('/').single;
      if (!RegExp(r'^disk\d+$', caseSensitive: false).hasMatch(diskName)) {
        continue;
      }
      _libraryDatabase.ensureConfiguredMediaRoot(
        rootName: diskName,
        containerPath: directory.directory.path,
      );
    }
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
      'activeStreams': _playback.activeStreams,
    });
    unawaited(_serve(server));
  }

  Future<void> _initializeNovelServices() async {
    _novelApi = null;
    _novelBackupCoordinator = null;
    if (config.novelDir case final novelDir?) {
      final novelService = NasNovelService(
        repository: _libraryDatabase.novels,
        storage: NasNovelStorage(
          rootPath: novelDir,
          maxUploadBytes: config.maxNovelUploadBytes,
        ),
        quotaBytes: config.novelQuotaBytes,
        uploadConcurrency: config.novelUploadConcurrency,
        uploadRequestsPerMinute: config.novelUploadRequestsPerMinute,
      );
      await novelService.initialize();
      _novelApi = NasNovelHttpApi(
        novelService,
        backgroundRead: _diskWork.read,
      );
      if (novelService.isReady) {
        _novelBackupCoordinator = NasNovelBackupCoordinator(
          repository: novelService.repository,
          storage: novelService.storage,
          writeBarrier: novelService.writeBarrier,
          backgroundRead: _diskWork.read,
        );
      }
    }
  }

  Future<void> _initializeComicServices() async {
    _comicApi?.close();
    _comicApi = null;
    if (config.comicDir case final comicDir?) {
      final api = ComicHttpApi(
        rootPath: comicDir,
        maxUploadBytes: config.maxComicUploadBytes,
        maxChunkBytes: config.maxComicChunkBytes,
        backgroundRead: _diskWork.read,
        quotaBytes: config.comicQuotaBytes,
        paceRead: _diskWork.pace,
      );
      await api.initialize();
      _comicApi = api;
    }
  }

  /// Local operational restore entry point. It is intentionally not exposed
  /// through HTTP because activating a database replaces all NAS state.
  Future<void> restoreBackup(String backupId) async {
    final activation = _restoreActivation;
    if (_server == null || activation == null) {
      throw StateError('Restore activation is unavailable.');
    }
    final parent = await Directory.systemTemp.createTemp('mujing-restore-');
    final isolated =
        Directory('${parent.path}${Platform.pathSeparator}validated');
    try {
      if (config.comicDir != null && (_comicApi == null || !_comicApi!.ready)) {
        throw StateError('Comic catalog is unavailable for restore.');
      }
      await NasBackupRecoveryHarness(_backupService).restore(
        backupId: backupId,
        target: isolated,
      );
      await activation.activate(
        restoredDirectory: isolated,
        enterMaintenance: () async {
          _maintenance = true;
          await _scraper?.close();
          _diskWork.accepting = false;
          await _mdcngMovies.activeTask;
          await _diskWork.drain();
          while (_activeRequests > 0) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        },
        leaveMaintenance: () async {
          _maintenance = false;
          _diskWork.accepting = true;
          _scraper?.start();
        },
        closeDatabase: () async {
          await _libraryDatabase.checkpointAndClose();
          _novelApi = null;
          _novelBackupCoordinator = null;
          _comicApi?.close();
          _comicApi = null;
        },
        openAndValidateDatabase: () async {
          await _libraryDatabase.open();
          if (!_libraryDatabase.validateIntegrity()) {
            throw StateError('Activated database failed integrity check.');
          }
          await _initializeNovelServices();
          await _initializeComicServices();
          await _comicApi?.invalidateSessionsForRestore();
        },
      );
    } finally {
      if (await parent.exists()) await parent.delete(recursive: true);
    }
  }

  Future<void> stop() async {
    _logger.event('service.stop', fields: {
      'component': 'nas.service',
      'activeRequests': _activeRequests,
      'activeStreams': _playback.activeStreams,
      'cancelReason': 'shutdown',
    });
    final server = _server;
    _server = null;
    _pairing.clear();
    _playback.clearSessions();
    _scans.clear();
    _mdcngMovies.cancelPending();
    await _mdcngMovies.activeTask;
    await _scraper?.close();
    _scraper = null;
    await _diskWork.drain();
    _mdcngMovies.clear();
    await server?.close(force: true);
    await _libraryDatabase.close();
    _novelApi = null;
    _novelBackupCoordinator = null;
    _comicApi?.close();
    _comicApi = null;
    _restoreActivation = null;
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
    request.response.headers.set('x-mujing-trace-id', traceId);
    request.response.headers.set('x-mujing-request-id', requestId);
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
      'activeStreams': _playback.activeStreams,
    });
    try {
      final path = request.uri.path;
      if (path == '/health') {
        return await _health(request);
      }
      if (_maintenance && path.startsWith('/api/v1/')) {
        return await writeApiError(
          request,
          HttpStatus.serviceUnavailable,
          'service_maintenance',
        );
      }
      if (request.method == 'GET' && path == '/api/v1/server-info') {
        return await _serverInfo(request);
      }
      if (request.method == 'POST' && path == '/api/v1/pairing/sessions') {
        return await _pairing.createPairingSession(request);
      }
      if (request.method == 'POST' &&
          RegExp(r'^/api/v1/pairing/sessions/[^/]+/confirm$').hasMatch(path)) {
        return await _pairing.confirmPairing(request);
      }
      if (!path.startsWith('/api/v1/')) {
        return await writeApiError(
            request, HttpStatus.notFound, 'resource_not_found');
      }

      final tokenHash = _pairing.authenticatedTokenHash(request);
      final device = tokenHash == null ? null : _state!.tokens[tokenHash];
      if (device == null || tokenHash == null) {
        return await writeApiError(
            request, HttpStatus.unauthorized, 'authentication_required');
      }
      if (path.startsWith('/api/v1/admin/') && device.scope != 'admin') {
        return await writeApiError(
            request, HttpStatus.forbidden, 'insufficient_scope');
      }
      await _apiRouter.handle(request, device: device, tokenHash: tokenHash);
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
        await writeApiError(
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
        'activeStreams': _playback.activeStreams,
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
      return writeApiError(
          request, HttpStatus.methodNotAllowed, 'method_not_allowed');
    }
    await writeApiJson(
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
    final mdcngActorAvailability = await _mdcngActors.cachedMdcngAvailability();
    final novelReady = _novelApi?.isReady ?? false;
    final comicReady = _comicApi?.ready ?? false;
    final data = <String, Object>{
      'serverId': _state!.serverId,
      'serverName': config.serverName,
      'apiVersion': '1.0',
      'minimumClientVersion': '1.0.0',
      'pairingRequired': true,
      'capabilities': {
        'cinemaHome': true,
        'playbackFinish': true,
        'movies': true,
        'playback': true,
        'watchHistory': true,
        'transcoding': false,
        'management': true,
        'categories': true,
        'actors': true,
        'publishers': true,
        'series': true,
        'tags': true,
        'mdcngNfo': true,
        'builtinScraping': _scraper?.available ?? false,
        'mdcngNfoBatch': true,
        'mdcngActors': mdcngActorAvailability.isAvailable,
        'profilePackages': true,
        'sourceRename': config.allowSourceRename,
        'novels': novelReady,
        'novelUpload': novelReady,
        'novelProgress': false,
        'novelUploadResume': false,
        'novelFormats': const ['txt'],
        if (novelReady) 'maxNovelUploadBytes': config.maxNovelUploadBytes,
        'comics': comicReady,
        'comicUpload': comicReady,
        'comicUploadResume': comicReady,
        'comicFormats':
            comicReady ? const ['zip', 'cbz', 'pdf'] : const <String>[],
        if (comicReady) 'maxComicUploadBytes': config.maxComicUploadBytes,
        if (comicReady) 'maxComicChunkBytes': config.maxComicChunkBytes,
      },
      'capabilityStatus': {
        'mdcngActors': mdcngActorAvailability.reason,
        if (!comicReady)
          'comics': _comicApi?.unavailableReason ?? 'storage_not_configured',
        if (!novelReady)
          'novels': _novelApi?.unavailableReason ??
              (config.novelDir == null
                  ? 'storage_not_configured'
                  : 'storage_unavailable'),
      },
      'pairingScopes': const ['viewer', 'admin'],
    };
    if (config.advertiseUrl case final advertiseUrl?) {
      data['connection'] = {'endpoint': advertiseUrl};
    }
    await writeApiJson(request.response, HttpStatus.ok, {'data': data});
  }

  Future<void> _persistState() => _stateStore.save(_state!);

  late final _presenter = NasLibraryPresenter(_libraryDatabase, config);
  late final _media = NasMediaResolver(_libraryDatabase, _mediaService, config);
  late final _assets = NasArtworkHttpApi(
    libraryDatabase: _libraryDatabase,
    artworkService: _artworkService,
    library: _library,
    config: config,
    presenter: _presenter,
  );
  late final _moviesApi = NasMoviesHttpApi(
    libraryDatabase: _libraryDatabase,
    library: _library,
    mediaService: _mediaService,
    config: config,
    presenter: _presenter,
    artworkService: _artworkService,
  );
  late final _profilesApi = NasProfilesHttpApi(
    libraryDatabase: _libraryDatabase,
    artworkService: _artworkService,
    presenter: _presenter,
    assets: _assets,
  );
  late final _packagesApi = NasProfilePackagesHttpApi(
    libraryDatabase: _libraryDatabase,
    artworkService: _artworkService,
    config: config,
    assets: _assets,
  );
  late final _aiApi = NasAiHttpApi(
    libraryDatabase: _libraryDatabase,
    aiMetadataClient: _aiMetadataClient,
    logger: _logger,
    state: () => _state,
    persistState: _persistState,
    presenter: _presenter,
    updateState: (value) => _state = value,
  );
  late final NasScanHttpApi _scans = NasScanHttpApi(
    libraryDatabase: _libraryDatabase,
    mediaService: _mediaService,
    artworkService: _artworkService,
    diskWork: _diskWork,
    config: config,
    logger: _logger,
    configuredRoot: () => _configuredMediaRoot,
    activeImport: () => _mdcngMovies.activeTask,
  );
  late final _taxonomyApi = NasTaxonomyHttpApi(
    libraryDatabase: _libraryDatabase,
    mediaService: _mediaService,
    artworkService: _artworkService,
    library: _library,
    config: config,
    scans: _scans,
    configuredRoot: () => _configuredMediaRoot,
    activeImport: () => _mdcngMovies.activeTask,
    presenter: _presenter,
  );
  late final NasMdcngMoviesHttpApi _mdcngMovies = NasMdcngMoviesHttpApi(
    libraryDatabase: _libraryDatabase,
    artworkService: _artworkService,
    media: _media,
    diskWork: _diskWork,
    scans: _scans,
    config: config,
    presenter: _presenter,
  );
  late final _mdcngActors = NasMdcngActorsHttpApi(
    libraryDatabase: _libraryDatabase,
    mdcngActorSource: _mdcngActorSource,
    logger: _logger,
    assets: _assets,
    presenter: _presenter,
    config: config,
  );
  late final _historyApi = NasHistoryHttpApi(_libraryDatabase);
  late final _playback = NasPlaybackHttpApi(
    libraryDatabase: _libraryDatabase,
    mediaService: _mediaService,
    media: _media,
    config: config,
    logger: _logger,
  );
  late final _pairing = NasPairingHttpApi(config, () => _state, _persistState);
  late final _operations = NasOperationsHttpApi(
    libraryDatabase: _libraryDatabase,
    mediaService: _mediaService,
    backupService: _backupService,
    diskWork: _diskWork,
    config: config,
    logger: _logger,
    state: () => _state,
    persistState: _persistState,
    backupCoordinator: () => _novelBackupCoordinator,
    presenter: _presenter,
  );
  late final _scrapingApi =
      NasScrapingHttpApi(_libraryDatabase, () => _scraper);

  late final _apiRouter = NasApiRouter(
    movies: _moviesApi,
    scraping: _scrapingApi,
    playback: _playback,
    operations: _operations,
    taxonomy: _taxonomyApi,
    artwork: _assets,
    mdcngMovies: _mdcngMovies,
    mdcngActors: _mdcngActors,
    scans: _scans,
    profilePackages: _packagesApi,
    ai: _aiApi,
    profiles: _profilesApi,
    history: _historyApi,
    novelApi: () => _novelApi,
    comicApi: () => _comicApi,
  );
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
