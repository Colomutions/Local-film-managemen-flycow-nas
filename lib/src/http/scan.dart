import 'dart:async';
import 'dart:io';

import '../artwork_service.dart';
import '../auth.dart';
import '../config.dart';
import '../disk_work_queue.dart';
import '../diagnostic_log.dart';
import '../library_database.dart';
import '../media_service.dart';

import 'response.dart';

/// Owns scan jobs and their existing shared disk-queue scheduling.
class NasScanHttpApi {
  NasScanHttpApi({
    required NasLibraryDatabase libraryDatabase,
    required NasMediaService mediaService,
    required NasArtworkService artworkService,
    required DiskWorkQueue diskWork,
    required this.config,
    required NasDiagnosticLogger logger,
    required this.configuredRoot,
    required this.activeImport,
  })  : _libraryDatabase = libraryDatabase,
        _mediaService = mediaService,
        _artworkService = artworkService,
        _diskWork = diskWork,
        _logger = logger;
  final NasLibraryDatabase _libraryDatabase;
  final NasConfig config;
  final NasDiagnosticLogger _logger;

  final NasMediaService _mediaService;
  final NasArtworkService _artworkService;
  final DiskWorkQueue _diskWork;
  final NasMediaRoot? Function() configuredRoot;
  NasMediaRoot? get _configuredMediaRoot => configuredRoot();
  final Future<void>? Function() activeImport;
  Future<void>? get _activeMdcngBatchTask => activeImport();
  Iterable<NasScanJob> get jobs => _scanJobs.values;
  void clear() => _scanJobs.clear();

  final Map<String, NasScanJob> _scanJobs = {};

  Future<void> createScanJob(HttpRequest request) async {
    if (_activeMdcngBatchTask != null) {
      return writeApiError(request, HttpStatus.conflict, 'mdcng_batch_running');
    }
    final body = await readApiJsonBody(request);
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
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final existing = _scanJobs.values
        .where((job) =>
            (job.status == 'queued' || job.status == 'running') &&
            job.categoryId == (categoryScan ? categoryId : null) &&
            (categoryScan || job.mediaRootId == mediaRootId))
        .firstOrNull;
    if (existing != null)
      return writeApiJson(
          request.response, 202, {'data': scanJobPayload(existing)});
    final job = NasScanJob(
      id: newUuidV4(),
      mediaRootId:
          categoryScan ? _configuredMediaRoot!.id : mediaRootId as String,
      categoryId: categoryScan ? categoryId as String : null,
      createdAt: DateTime.now().toUtc(),
    );
    _scanJobs[job.id] = job;
    unawaited(_diskWork.run(
        'scan:${job.categoryId ?? job.mediaRootId}', () => _runScanJob(job)));
    await writeApiJson(request.response, HttpStatus.accepted, {
      'data': scanJobPayload(job),
    });
  }

  NasScanJob? scheduleCategoryScan(String categoryId) {
    if (!config.managedCategoryLibrary || _configuredMediaRoot == null) {
      return null;
    }
    final existing = _scanJobs.values
        .where((job) =>
            job.categoryId == categoryId &&
            (job.status == 'queued' || job.status == 'running'))
        .firstOrNull;
    if (existing != null) return existing;
    final job = NasScanJob(
      id: newUuidV4(),
      mediaRootId: _configuredMediaRoot!.id,
      categoryId: categoryId,
      createdAt: DateTime.now().toUtc(),
    );
    _scanJobs[job.id] = job;
    unawaited(_diskWork.run(
        'scan:${job.categoryId ?? job.mediaRootId}', () => _runScanJob(job)));
    return job;
  }

  Future<void> listScanJobs(HttpRequest request) => writeApiJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {
            'items':
                _scanJobs.values.map(scanJobPayload).toList(growable: false),
          },
        },
      );

  Future<void> scanJob(HttpRequest request) {
    final job = _scanJobs[request.uri.pathSegments.last];
    if (job == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    return writeApiJson(request.response, HttpStatus.ok, {
      'data': scanJobPayload(job),
    });
  }

  Future<void> _runScanJob(NasScanJob job) async {
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
              beforeFile: _diskWork.yieldToPlayback,
              categoryId: job.categoryId!,
              mediaRootId: job.mediaRootId,
              mediaService: _mediaService,
            );
      for (final removed in result.removedMovieIndexes) {
        if (removed.posterFileName != null) {
          await _artworkService.deletePoster(removed.posterFileName!);
        }
        for (final fileName in removed.carouselFileNames) {
          await _artworkService.deleteCarouselImage(fileName);
        }
      }
      job.status = 'succeeded';
      job.scannedFiles = result.scannedFiles;
      job.availableEpisodes = result.availableEpisodes;
      job.removedEpisodes = result.removedEpisodes;
      job.removedMovies = result.removedMovieIndexes.length;
      job.conflicts = result.conflicts;
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

  Map<String, Object?> scanJobPayload(NasScanJob job) => {
        'id': job.id,
        'mediaRootId': job.mediaRootId,
        'categoryId': job.categoryId,
        'status': job.status,
        'scannedFiles': job.scannedFiles,
        'availableEpisodes': job.availableEpisodes,
        'removedEpisodes': job.removedEpisodes,
        'removedMovies': job.removedMovies,
        'conflicts': job.conflicts,
        'createdAt': job.createdAt.toIso8601String(),
        'startedAt': job.startedAt?.toIso8601String(),
        'finishedAt': job.finishedAt?.toIso8601String(),
        'errorCode': job.errorCode,
      };
}

class NasScanJob {
  NasScanJob({
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
  int? removedEpisodes;
  int? removedMovies;
  List<String> conflicts = const [];
  DateTime? startedAt;
  DateTime? finishedAt;
  String? errorCode;
}
