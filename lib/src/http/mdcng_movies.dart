import 'dart:async';
import 'dart:io';

import '../artwork_service.dart';
import '../auth.dart';
import '../config.dart';
import '../disk_work_queue.dart';

import '../library/mdcng_sidecar.dart';
import '../library_database.dart';
import '../media_service.dart';

import 'response.dart';
import 'validation.dart';
import 'presenter.dart';
import 'media_resolver.dart';
import 'scan.dart';

/// MDCNG movie sidecar previews and queued batch imports.
class NasMdcngMoviesHttpApi {
  NasMdcngMoviesHttpApi({
    required NasLibraryDatabase libraryDatabase,
    required NasArtworkService artworkService,
    required NasMediaResolver media,
    required DiskWorkQueue diskWork,
    required NasScanHttpApi scans,
    required this.config,
    required NasLibraryPresenter presenter,
  })  : _libraryDatabase = libraryDatabase,
        _artworkService = artworkService,
        _media = media,
        _diskWork = diskWork,
        _scans = scans,
        _presenter = presenter;
  final NasLibraryDatabase _libraryDatabase;
  final NasConfig config;

  final NasLibraryPresenter _presenter;
  final NasArtworkService _artworkService;
  final NasMediaResolver _media;
  final DiskWorkQueue _diskWork;
  final NasScanHttpApi _scans;
  Future<void>? get activeTask => _activeMdcngBatchTask;
  void cancelPending() {
    for (final job in _mdcngBatchJobs.values) {
      if (job.status == 'running' || job.status == 'queued')
        job.cancelled = true;
    }
  }

  void clear() => _mdcngBatchJobs.clear();

  final Map<String, _MdcngBatchJob> _mdcngBatchJobs = {};

  Future<void>? _activeMdcngBatchTask;

  /// 只读取 MDCNG 放在视频同目录的 NFO 和本地图片，绝不写库或触及源文件。
  Future<void> previewMdcngImport(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    final movieId = body?['movieId'];
    final requestedEpisodeId = body?['episodeId'];
    if (body == null ||
        body.keys.any((key) => key != 'movieId' && key != 'episodeId') ||
        movieId is! String ||
        movieId.isEmpty ||
        (requestedEpisodeId != null &&
            (requestedEpisodeId is! String || requestedEpisodeId.isEmpty))) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final movie = _libraryDatabase.findMovieForAdmin(movieId);
    if (movie == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final sources = await _mdcngSourcesForMovie(movie.id);
    if (sources.isEmpty) {
      return writeApiError(
          request, HttpStatus.notFound, 'mdcng_sidecar_not_found');
    }
    final preferredEpisodeId =
        _libraryDatabase.preferredMdcngEpisodeIdForMovie(movie.id);
    final selected = requestedEpisodeId == null
        ? sources
                .where((source) => source.episode.id == preferredEpisodeId)
                .firstOrNull ??
            sources.first
        : sources
            .where((source) => source.episode.id == requestedEpisodeId)
            .firstOrNull;
    if (selected == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final episode = selected.episode;
    final video = selected.video;

    final MdcngNfoSidecar sidecar;
    try {
      sidecar = await const MdcngNfoSidecarReader().readForVideo(video);
    } on MdcngNfoSidecarException catch (error) {
      return writeApiError(
        request,
        error.code == 'sidecar_not_found'
            ? HttpStatus.notFound
            : HttpStatus.badRequest,
        error.code == 'sidecar_not_found'
            ? 'mdcng_sidecar_not_found'
            : 'invalid_mdcng_sidecar',
      );
    }
    final summary = sidecar.movie.plot ?? sidecar.movie.outline;
    final originalTitle = nasMdcngOriginalTitle(sidecar.movie);
    final proposedActorNames = sidecar.movie.actors
        .map((actor) => actor.name)
        .toSet()
        .toList(growable: false);
    final proposedTags = sidecar.movie.tagsAndGenres;
    final fieldSources =
        _libraryDatabase.metadataFieldSourcesForMovie(movie.id);
    final actorResolutions = proposedActorNames.map(
      (name) {
        final actor = _libraryDatabase.findActiveActorByExactName(name);
        return {
          'name': name,
          'status': actor == null ? 'unresolved' : 'matched',
          if (actor != null) 'actorId': actor.id,
        };
      },
    ).toList(growable: false);
    final tagResolutions = proposedTags.map(
      (name) {
        final tag = _libraryDatabase.findActiveTagByName(name);
        return {
          'name': name,
          'status': tag == null ? 'unresolved' : 'matched',
          if (tag != null) 'tagId': tag.id,
        };
      },
    ).toList(growable: false);

    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'schemaVersion': 1,
        'mode': 'preview_only',
        'movie': {
          'id': movie.id,
          'episodeId': episode.id,
          'sourceFileName': nasSourceFileName(episode.relativePath),
          'nfoFileName': sidecar.nfoFileName,
          'nfoContentHash': sidecar.nfoContentHash,
        },
        'sources': sources
            .map((source) => {
                  'episodeId': source.episode.id,
                  'sourceFileName':
                      nasSourceFileName(source.episode.relativePath),
                  'nfoFileName': source.nfoFileName,
                })
            .toList(growable: false),
        'current': {
          'title': movie.title,
          'originalTitle': movie.originalTitle,
          'catalogNumber': movie.catalogNumber,
          'summary': movie.summary,
          'actors': movie.actors.map((actor) => actor.name).toList(),
          'tags': _libraryDatabase
              .tagsForMovie(movie.id)
              .map((tag) => tag.name)
              .toList(growable: false),
        },
        'proposed': {
          'title': sidecar.movie.title,
          'originalTitle': originalTitle,
          'catalogNumber': sidecar.movie.catalogNumber,
          'summary': summary,
          'actors': proposedActorNames,
          'tags': proposedTags,
          'actorResolutions': actorResolutions,
          'tagResolutions': tagResolutions,
          'setName': sidecar.movie.setName,
          'series': sidecar.movie.series,
          'publisherCandidates': {
            'studio': sidecar.movie.studio,
            'maker': sidecar.movie.maker,
            'publisher': sidecar.movie.publisher,
            'label': sidecar.movie.label,
          },
          'artwork': sidecar.artwork
              .map(
                (image) => {
                  'kind': image.kind.wireName,
                  'fileName': image.fileName,
                  'mimeType': image.mimeType,
                  'byteLength': image.byteLength,
                },
              )
              .toList(growable: false),
        },
        'fieldDiffs': [
          nasMdcngScalarFieldDiff(
            key: 'title',
            currentValue: movie.title,
            proposedValue: sidecar.movie.title,
            source: fieldSources['title'],
          ),
          nasMdcngScalarFieldDiff(
            key: 'originalTitle',
            currentValue: movie.originalTitle,
            proposedValue: originalTitle,
            source: fieldSources['originalTitle'],
          ),
          nasMdcngScalarFieldDiff(
            key: 'catalogNumber',
            currentValue: movie.catalogNumber,
            proposedValue: sidecar.movie.catalogNumber,
            source: fieldSources['catalogNumber'],
          ),
          nasMdcngScalarFieldDiff(
            key: 'summary',
            currentValue: movie.summary,
            proposedValue: summary,
            source: fieldSources['summary'],
          ),
        ],
        'notImported': {
          'externalCoverUrlPresent': sidecar.movie.coverUrl != null,
          'externalWebsitePresent': sidecar.movie.website != null,
          'runtimeMinutes': sidecar.movie.runtimeMinutes,
          'releaseDate': sidecar.movie.releaseDate ??
              sidecar.movie.premiered ??
              sidecar.movie.release,
        },
        'issues': sidecar.issues
            .map((issue) => {'code': issue.code, 'field': issue.field})
            .toList(growable: false),
      },
    });
  }

  /// 写入前重新读取 sidecar；客户端必须提交预览返回的内容摘要和字段选择。
  Future<void> applyMdcngImport(HttpRequest request) async {
    if (_activeMdcngBatchTask != null) {
      return writeApiError(request, HttpStatus.conflict, 'mdcng_batch_running');
    }
    final body = await readApiJsonBody(request);
    final movieId = body?['movieId'];
    final episodeId = body?['episodeId'];
    final nfoContentHash = body?['nfoContentHash'];
    final rawFieldKeys = body?['fieldKeys'];
    final rawOverwriteFieldKeys = body?['overwriteFieldKeys'];
    const allowedFields = {
      'title',
      'originalTitle',
      'catalogNumber',
      'summary',
      'actors',
      'tags',
      'poster',
      'fanart',
    };
    if (body == null ||
        body.keys.any((key) =>
            key != 'movieId' &&
            key != 'episodeId' &&
            key != 'nfoContentHash' &&
            key != 'fieldKeys' &&
            key != 'overwriteFieldKeys') ||
        movieId is! String ||
        movieId.isEmpty ||
        episodeId is! String ||
        episodeId.isEmpty ||
        nfoContentHash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(nfoContentHash) ||
        rawFieldKeys is! List ||
        rawOverwriteFieldKeys is! List ||
        rawFieldKeys.isEmpty ||
        rawFieldKeys.length > allowedFields.length ||
        rawFieldKeys.any((field) => field is! String) ||
        rawOverwriteFieldKeys.any((field) => field is! String)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final fieldKeys = rawFieldKeys.cast<String>();
    final overwriteFieldKeys = rawOverwriteFieldKeys.cast<String>();
    final fields = fieldKeys.toSet();
    final overwriteFields = overwriteFieldKeys.toSet();
    if (fields.length != fieldKeys.length ||
        overwriteFields.length != overwriteFieldKeys.length ||
        fields.any((field) => !allowedFields.contains(field)) ||
        overwriteFields.any((field) => !fields.contains(field))) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }

    final movie = _libraryDatabase.findMovieForAdmin(movieId);
    final episode = _libraryDatabase.findEpisode(episodeId);
    if (movie == null ||
        episode == null ||
        episode.movieId != movie.id ||
        !episode.isAvailable) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final video = await _media.fileForEpisode(episode);
    if (video == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final MdcngNfoSidecar sidecar;
    try {
      sidecar = await const MdcngNfoSidecarReader().readForVideo(video);
    } on MdcngNfoSidecarException {
      return writeApiError(
          request, HttpStatus.badRequest, 'invalid_mdcng_sidecar');
    }
    if (sidecar.nfoContentHash != nfoContentHash) {
      return writeApiError(request, HttpStatus.conflict, 'mdcng_preview_stale');
    }

    final sources = _libraryDatabase.metadataFieldSourcesForMovie(movie.id);
    final effectiveFieldKeys = fieldKeys.where((field) {
      final source = sources[field];
      return source?.sourceKind != 'mdcng' ||
          source?.sourceContentHash != sidecar.nfoContentHash;
    }).toList(growable: false);
    if (effectiveFieldKeys.isEmpty) {
      return writeApiJson(request.response, HttpStatus.ok, {
        'data': {
          'status': 'no_changes',
          'appliedFields': const <String>[],
          'skippedAlreadyImported': fieldKeys,
        },
      });
    }
    final effectiveFields = effectiveFieldKeys.toSet();
    final title = nasNullableTrimmed(sidecar.movie.title);
    final originalTitle = nasMdcngOriginalTitle(sidecar.movie);
    final catalogNumber = nasNullableTrimmed(sidecar.movie.catalogNumber);
    final summary = nasNullableTrimmed(sidecar.movie.plot) ??
        nasNullableTrimmed(sidecar.movie.outline);
    if ((effectiveFields.contains('title') && title == null) ||
        (effectiveFields.contains('originalTitle') && originalTitle == null) ||
        (effectiveFields.contains('catalogNumber') && catalogNumber == null) ||
        (effectiveFields.contains('summary') && summary == null)) {
      return writeApiError(
          request, HttpStatus.badRequest, 'invalid_mdcng_selection');
    }
    final scalarValues = <String, String?>{
      'title': title,
      'originalTitle': originalTitle,
      'catalogNumber': catalogNumber,
      'summary': summary,
    };
    final currentValues = <String, String?>{
      'title': movie.title,
      'originalTitle': movie.originalTitle,
      'catalogNumber': movie.catalogNumber,
      'summary': movie.summary,
    };
    for (final field in scalarValues.keys) {
      if (!effectiveFields.contains(field)) continue;
      final current = nasNullableTrimmed(currentValues[field]);
      final proposed = scalarValues[field];
      if (current != null &&
          current != proposed &&
          !overwriteFields.contains(field)) {
        return writeApiError(
          request,
          HttpStatus.conflict,
          'mdcng_overwrite_confirmation_required',
        );
      }
    }

    List<String>? actorIds;
    if (effectiveFields.contains('actors')) {
      final resolved = <String>[];
      for (final candidate
          in sidecar.movie.actors.map((actor) => actor.name).toSet()) {
        final actor = _libraryDatabase.findActiveActorByExactName(candidate);
        if (actor == null) {
          return writeApiError(
            request,
            HttpStatus.conflict,
            'mdcng_actor_resolution_required',
          );
        }
        resolved.add(actor.id);
      }
      actorIds = [
        ..._libraryDatabase.actorsForMovie(movie.id).map((actor) => actor.id),
        ...resolved,
      ].toSet().toList(growable: false);
    }

    List<String>? tagIds;
    if (effectiveFields.contains('tags')) {
      final resolved = <String>[];
      for (final candidate in sidecar.movie.tagsAndGenres) {
        final tag = _libraryDatabase.findActiveTagByName(candidate);
        if (tag == null) {
          return writeApiError(
            request,
            HttpStatus.conflict,
            'mdcng_tag_resolution_required',
          );
        }
        resolved.add(tag.id);
      }
      tagIds = [
        ..._libraryDatabase.tagsForMovie(movie.id).map((tag) => tag.id),
        ...resolved,
      ].toSet().toList(growable: false);
    }

    MdcngNfoArtwork? poster;
    MdcngNfoArtwork? fanart;
    for (final artwork in sidecar.artwork) {
      if (artwork.kind == MdcngNfoArtworkKind.poster) poster = artwork;
      if (artwork.kind == MdcngNfoArtworkKind.fanart) fanart = artwork;
    }
    if (effectiveFields.contains('poster') &&
        (poster == null || movie.posterFileName != null)) {
      return writeApiError(
        request,
        HttpStatus.conflict,
        'mdcng_poster_overwrite_not_supported',
      );
    }
    if (effectiveFields.contains('fanart') && fanart == null) {
      return writeApiError(
          request, HttpStatus.badRequest, 'invalid_mdcng_selection');
    }

    String? posterFileName;
    String? fanartFileName;
    var committed = false;
    try {
      const reader = MdcngNfoSidecarReader();
      if (poster != null && effectiveFields.contains('poster')) {
        final bytes = await reader.readArtworkBytes(
          video: video,
          artwork: poster,
        );
        posterFileName = await _artworkService.savePoster(
          movieId: movie.id,
          mimeType: poster.mimeType,
          bytes: bytes,
        );
      }
      if (fanart != null && effectiveFields.contains('fanart')) {
        final bytes = await reader.readArtworkBytes(
          video: video,
          artwork: fanart,
        );
        fanartFileName = await _artworkService.saveCarouselImage(
          movieId: movie.id,
          mimeType: fanart.mimeType,
          bytes: bytes,
        );
      }
      final record = _libraryDatabase.applyMdcngMetadata(
        NasMdcngMetadataApply(
          movieId: movie.id,
          episodeId: episode.id,
          nfoFileName: sidecar.nfoFileName,
          nfoContentHash: sidecar.nfoContentHash,
          fieldKeys: effectiveFieldKeys,
          title: effectiveFields.contains('title') ? title : null,
          originalTitle:
              effectiveFields.contains('originalTitle') ? originalTitle : null,
          catalogNumber:
              effectiveFields.contains('catalogNumber') ? catalogNumber : null,
          summary: effectiveFields.contains('summary') ? summary : null,
          actorIds: effectiveFields.contains('actors') ? actorIds : null,
          tagIds: effectiveFields.contains('tags') ? tagIds : null,
          posterFileName:
              effectiveFields.contains('poster') ? posterFileName : null,
          fanartFileName:
              effectiveFields.contains('fanart') ? fanartFileName : null,
        ),
      );
      committed = true;
      final updatedMovie = _libraryDatabase.findMovieForAdmin(movie.id)!;
      await writeApiJson(request.response, HttpStatus.ok, {
        'data': {
          'status': 'applied',
          'appliedFields': effectiveFieldKeys,
          'skippedAlreadyImported': fieldKeys
              .where((field) => !effectiveFields.contains(field))
              .toList(growable: false),
          'importRecord': {
            'id': record.id,
            'nfoFileName': record.nfoFileName,
            'nfoContentHash': record.nfoContentHash,
            'createdAt': record.createdAt,
          },
          'movie': await _presenter.databaseDetails(updatedMovie),
        },
      });
    } on MdcngNfoSidecarException {
      if (!committed) {
        await _deleteMdcngImportedArtwork(
          posterFileName: posterFileName,
          fanartFileName: fanartFileName,
        );
      }
      return writeApiError(
          request, HttpStatus.badRequest, 'invalid_mdcng_sidecar');
    } on ArgumentError {
      if (!committed) {
        await _deleteMdcngImportedArtwork(
          posterFileName: posterFileName,
          fanartFileName: fanartFileName,
        );
      }
      return writeApiError(
          request, HttpStatus.badRequest, 'invalid_mdcng_selection');
    } on Object {
      if (!committed) {
        await _deleteMdcngImportedArtwork(
          posterFileName: posterFileName,
          fanartFileName: fanartFileName,
        );
      }
      return writeApiError(
          request, HttpStatus.internalServerError, 'mdcng_import_failed');
    }
  }

  Future<List<_MdcngSource>> _mdcngSourcesForMovie(
    String movieId, {
    bool firstOnly = false,
  }) async {
    final sources = <_MdcngSource>[];
    const reader = MdcngNfoSidecarReader();
    final episodes = _libraryDatabase.episodesForMovie(movieId);
    final preferredId = firstOnly
        ? _libraryDatabase.preferredMdcngEpisodeIdForMovie(movieId)
        : null;
    final ordered = firstOnly && preferredId != null
        ? [
            ...episodes.where((episode) => episode.id == preferredId),
            ...episodes.where((episode) => episode.id != preferredId),
          ]
        : episodes;
    for (final episode in ordered) {
      if (!episode.isAvailable) continue;
      final video = await _media.fileForEpisode(episode);
      if (video == null) continue;
      try {
        if (!await reader.hasNfoForVideo(video)) continue;
      } on FileSystemException {
        continue;
      } on MdcngNfoSidecarException {
        continue;
      }
      final name = nasSourceFileName(episode.relativePath);
      sources.add(_MdcngSource(
        episode: episode,
        video: video,
        nfoFileName: '${name.substring(0, name.lastIndexOf('.'))}.nfo',
      ));
      if (firstOnly) break;
    }
    return sources;
  }

  Future<void> createMdcngBatchJob(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    final categoryId = body?['categoryId'];
    if (body == null ||
        body.length != 1 ||
        categoryId is! String ||
        _libraryDatabase.findCategory(categoryId) == null) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    if (_activeMdcngBatchTask != null) {
      return writeApiError(request, HttpStatus.conflict, 'mdcng_batch_running');
    }
    if (_scans.jobs
        .any((job) => job.status == 'queued' || job.status == 'running')) {
      return writeApiError(request, HttpStatus.conflict, 'scan_running');
    }
    final job = _MdcngBatchJob(
      id: newUuidV4(),
      categoryId: categoryId,
      movieIds: _libraryDatabase.activeMovieIdsForCategory(categoryId),
    );
    _rememberMdcngBatchJob(job);
    _activeMdcngBatchTask = Future<void>.delayed(Duration.zero).then(
        (_) => _diskWork.run('mdcng:${job.id}', () => _runMdcngBatchJob(job)));
    await writeApiJson(request.response, HttpStatus.accepted, {
      'data': _mdcngBatchJobPayload(job),
    });
  }

  Future<void> listMdcngBatchJobs(HttpRequest request) async {
    final categoryId = request.uri.queryParameters['categoryId'];
    if (categoryId == null ||
        _libraryDatabase.findCategory(categoryId) == null) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final jobs = _mdcngBatchJobs.values
        .where((job) => job.categoryId == categoryId)
        .toList(growable: false);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {'job': jobs.isEmpty ? null : _mdcngBatchJobPayload(jobs.last)},
    });
  }

  Future<void> previewMdcngBatchJob(HttpRequest request) async {
    final categoryId = request.uri.queryParameters['categoryId'];
    if (categoryId == null ||
        _libraryDatabase.findCategory(categoryId) == null) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'categoryId': categoryId,
        'movieCount':
            _libraryDatabase.activeMovieIdsForCategory(categoryId).length,
      },
    });
  }

  Future<void> getMdcngBatchJob(HttpRequest request) async {
    final job = _mdcngBatchJobs[request.uri.pathSegments.last];
    if (job == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _mdcngBatchJobPayload(job),
    });
  }

  Future<void> changeMdcngBatchJob(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    final job = _mdcngBatchJobs[segments[segments.length - 2]];
    if (job == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (segments.last == 'cancel') {
      if (job.status == 'running' || job.status == 'queued')
        job.cancelled = true;
      return writeApiJson(request.response, HttpStatus.ok, {
        'data': _mdcngBatchJobPayload(job),
      });
    }
    if (_activeMdcngBatchTask != null || job.status != 'succeeded') {
      return writeApiError(request, HttpStatus.conflict, 'mdcng_batch_running');
    }
    final retryIds = job.failures.keys.toList(growable: false);
    if (retryIds.isEmpty) {
      return writeApiError(
          request, HttpStatus.conflict, 'mdcng_no_failed_items');
    }
    final retry = _MdcngBatchJob(
      id: newUuidV4(),
      categoryId: job.categoryId,
      movieIds: retryIds,
    );
    _rememberMdcngBatchJob(retry);
    _activeMdcngBatchTask = Future<void>.delayed(Duration.zero).then((_) =>
        _diskWork.run('mdcng:${retry.id}', () => _runMdcngBatchJob(retry)));
    await writeApiJson(request.response, HttpStatus.accepted, {
      'data': _mdcngBatchJobPayload(retry),
    });
  }

  Map<String, Object?> _mdcngBatchJobPayload(_MdcngBatchJob job) => {
        'id': job.id,
        'categoryId': job.categoryId,
        'status': job.status,
        'errorCode': job.errorCode,
        'total': job.movieIds.length,
        'processed': job.processed,
        'applied': job.applied,
        'skipped': job.skipped,
        'failed': job.failures.length,
        'warningCount': job.warnings.length,
        'warnings': job.status == 'running'
            ? const <Object>[]
            : job.warnings.entries
                .map((entry) => {
                      'movieId': entry.key,
                      'title': entry.value.title,
                      'fields': entry.value.fields,
                    })
                .toList(growable: false),
        'failures': job.status == 'running'
            ? const <Object>[]
            : job.failures.entries
                .map((entry) => {
                      'movieId': entry.key,
                      'title': entry.value.title,
                      'reason': entry.value.reason,
                    })
                .toList(growable: false),
      };

  void _rememberMdcngBatchJob(_MdcngBatchJob job) {
    _mdcngBatchJobs[job.id] = job;
    while (_mdcngBatchJobs.length > 10) {
      _mdcngBatchJobs.remove(_mdcngBatchJobs.keys.first);
    }
  }

  Future<void> _runMdcngBatchJob(_MdcngBatchJob job) async {
    job.status = 'running';
    try {
      for (final movieId in job.movieIds) {
        if (job.cancelled) break;
        final movie = _libraryDatabase.findMovieForAdmin(movieId);
        try {
          final result = await _importMdcngBatchMovie(movieId, job.categoryId);
          if (result.warnings.isNotEmpty) {
            job.warnings[movieId] = (
              title: movie?.title ?? '未知影片',
              fields: result.warnings,
            );
          }
          if (result.status == 'applied') {
            job.applied++;
          } else {
            job.skipped++;
          }
        } on Object catch (error) {
          job.failures[movieId] = (
            title: movie?.title ?? '未知影片',
            reason: error is MdcngNfoSidecarException
                ? error.code
                : error is FileSystemException
                    ? 'sidecar_read_failed'
                    : 'mdcng_import_failed',
          );
        }
        job.processed++;
        await Future<void>.delayed(Duration.zero);
      }
      job.status = job.cancelled ? 'cancelled' : 'succeeded';
    } on Object {
      job.status = 'failed';
      job.errorCode = 'mdcng_import_failed';
    } finally {
      _activeMdcngBatchTask = null;
    }
  }

  Future<({String status, List<String> warnings})> _importMdcngBatchMovie(
      String movieId, String categoryId) async {
    final movie = _libraryDatabase.findMovieForAdmin(movieId);
    if (movie == null || movie.categoryId != categoryId) {
      return (status: 'skipped', warnings: const <String>[]);
    }
    final sources = await _mdcngSourcesForMovie(movieId, firstOnly: true);
    if (sources.isEmpty) {
      throw const MdcngNfoSidecarException('sidecar_not_found');
    }
    final source = sources.first;
    const reader = MdcngNfoSidecarReader();
    final sidecar = await reader.readForVideo(source.video);
    final provenance = _libraryDatabase.metadataFieldSourcesForMovie(movieId);
    final fields = <String>[];
    final warnings = <String>[];
    bool canUpdate(String key, {required bool empty}) {
      final previous = provenance[key];
      if (previous?.sourceKind == 'manual' ||
          previous?.sourceContentHash == sidecar.nfoContentHash) {
        return false;
      }
      return previous?.sourceKind == 'mdcng' || empty;
    }

    final title = nasNullableTrimmed(sidecar.movie.title);
    final originalTitle = nasMdcngOriginalTitle(sidecar.movie);
    final catalogNumber = nasNullableTrimmed(sidecar.movie.catalogNumber);
    final summary = nasNullableTrimmed(sidecar.movie.plot) ??
        nasNullableTrimmed(sidecar.movie.outline);
    if (title != null &&
        title != movie.title &&
        canUpdate('title',
            empty: _libraryDatabase.hasDefaultScannedTitle(movieId))) {
      fields.add('title');
    }
    if (originalTitle != null &&
        originalTitle != movie.originalTitle &&
        canUpdate('originalTitle',
            empty: nasNullableTrimmed(movie.originalTitle) == null)) {
      fields.add('originalTitle');
    }
    if (catalogNumber != null &&
        catalogNumber != movie.catalogNumber &&
        canUpdate('catalogNumber',
            empty: nasNullableTrimmed(movie.catalogNumber) == null)) {
      fields.add('catalogNumber');
    }
    if (summary != null &&
        summary != movie.summary &&
        canUpdate('summary',
            empty: nasNullableTrimmed(movie.summary) == null)) {
      fields.add('summary');
    }

    List<String>? actorIds;
    if (sidecar.movie.actors.isNotEmpty &&
        canUpdate('actors',
            empty: _libraryDatabase.actorsForMovie(movieId).isEmpty)) {
      final ids = <String>[];
      for (final name
          in sidecar.movie.actors.map((actor) => actor.name).toSet()) {
        final actor = _libraryDatabase.findActiveActorByExactName(name);
        if (actor == null) {
          ids.clear();
          break;
        }
        ids.add(actor.id);
      }
      if (ids.isNotEmpty) {
        actorIds = ids;
        fields.add('actors');
      } else {
        warnings.add('actors_unresolved');
      }
    }
    List<String>? tagIds;
    if (sidecar.movie.tagsAndGenres.isNotEmpty &&
        canUpdate('tags',
            empty: _libraryDatabase.tagsForMovie(movieId).isEmpty)) {
      final ids = <String>[];
      for (final name in sidecar.movie.tagsAndGenres) {
        final tag = _libraryDatabase.findActiveTagByName(name);
        if (tag == null) {
          ids.clear();
          break;
        }
        ids.add(tag.id);
      }
      if (ids.isNotEmpty) {
        tagIds = ids.toSet().toList(growable: false);
        fields.add('tags');
      } else {
        warnings.add('tags_unresolved');
      }
    }
    final poster = sidecar.artwork
        .where((item) => item.kind == MdcngNfoArtworkKind.poster)
        .firstOrNull;
    final fanart = sidecar.artwork
        .where((item) => item.kind == MdcngNfoArtworkKind.fanart)
        .firstOrNull;
    if (poster != null &&
        movie.posterFileName == null &&
        canUpdate('poster', empty: true)) fields.add('poster');
    if (fanart != null &&
        canUpdate('fanart',
            empty: _libraryDatabase.carouselImagesForMovie(movieId).isEmpty) &&
        _libraryDatabase.carouselImagesForMovie(movieId).isEmpty) {
      fields.add('fanart');
    }
    if (fields.isEmpty) return (status: 'skipped', warnings: warnings);

    String? posterFileName;
    String? fanartFileName;
    try {
      if (fields.contains('poster')) {
        final bytes = await reader.readArtworkBytes(
            video: source.video, artwork: poster!);
        posterFileName = await _artworkService.savePoster(
            movieId: movieId, mimeType: poster.mimeType, bytes: bytes);
      }
      if (fields.contains('fanart')) {
        final bytes = await reader.readArtworkBytes(
            video: source.video, artwork: fanart!);
        fanartFileName = await _artworkService.saveCarouselImage(
            movieId: movieId, mimeType: fanart.mimeType, bytes: bytes);
      }
      _libraryDatabase.applyMdcngMetadata(NasMdcngMetadataApply(
        movieId: movieId,
        episodeId: source.episode.id,
        nfoFileName: sidecar.nfoFileName,
        nfoContentHash: sidecar.nfoContentHash,
        fieldKeys: fields,
        title: fields.contains('title') ? title : null,
        originalTitle: fields.contains('originalTitle') ? originalTitle : null,
        catalogNumber: fields.contains('catalogNumber') ? catalogNumber : null,
        summary: fields.contains('summary') ? summary : null,
        actorIds: actorIds,
        tagIds: tagIds,
        posterFileName: posterFileName,
        fanartFileName: fanartFileName,
      ));
      return (status: 'applied', warnings: warnings);
    } on Object {
      await _deleteMdcngImportedArtwork(
        posterFileName: posterFileName,
        fanartFileName: fanartFileName,
      );
      rethrow;
    }
  }

  Future<void> _deleteMdcngImportedArtwork({
    String? posterFileName,
    String? fanartFileName,
  }) async {
    if (posterFileName != null) {
      await _artworkService.deletePoster(posterFileName);
    }
    if (fanartFileName != null) {
      await _artworkService.deleteCarouselImage(fanartFileName);
    }
  }
}

class _MdcngSource {
  const _MdcngSource({
    required this.episode,
    required this.video,
    required this.nfoFileName,
  });

  final NasLibraryEpisode episode;
  final NasMediaFile video;
  final String nfoFileName;
}

class _MdcngBatchJob {
  _MdcngBatchJob({
    required this.id,
    required this.categoryId,
    required this.movieIds,
  });

  final String id;
  final String categoryId;
  final List<String> movieIds;
  final Map<String, ({String title, String reason})> failures = {};
  final Map<String, ({String title, List<String> fields})> warnings = {};
  String status = 'queued';
  String? errorCode;
  int processed = 0;
  int applied = 0;
  int skipped = 0;
  bool cancelled = false;
}
