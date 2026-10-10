import 'dart:async';
import 'dart:io';

import '../auth.dart';
import '../config.dart';
import '../diagnostic_log.dart';
import '../fixture_library.dart';
import '../library_database.dart';
import '../media_service.dart';
import '../persistent_state.dart';
import '../range.dart';

import 'response.dart';
import 'media_resolver.dart';

/// Owns playback sessions, progress accounting and byte-range streaming.
class NasPlaybackHttpApi {
  NasPlaybackHttpApi({
    required NasLibraryDatabase libraryDatabase,
    required NasMediaService mediaService,
    required NasMediaResolver media,
    required this.config,
    required NasDiagnosticLogger logger,
  })  : _libraryDatabase = libraryDatabase,
        _mediaService = mediaService,
        _media = media,
        _logger = logger;
  final NasLibraryDatabase _libraryDatabase;
  final NasConfig config;
  final NasDiagnosticLogger _logger;
  final NasMediaService _mediaService;
  final NasMediaResolver _media;
  int get activeStreams => _activeStreams;
  void clearSessions() => _playbackSessions.clear();

  final Map<String, _PlaybackSession> _playbackSessions = {};

  _FixturePlaybackState? _fixturePlaybackState;

  final Map<String, String> _closedPlayback = {};

  int _activeStreams = 0;

  Future<void> createPlaybackSession(
    HttpRequest request,
    String tokenHash,
    NasDeviceToken device,
  ) async {
    final body = await readApiJsonBody(request);
    final requestedMovieId = body?['contentId'];
    final requestedEpisodeId = body?['episodeId'];
    final purpose = body?['purpose'] ?? 'playback';
    if (requestedMovieId is! String ||
        purpose is! String ||
        !const {'playback', 'preview'}.contains(purpose)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
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
        return writeApiError(
            request, HttpStatus.notFound, 'resource_not_found');
      }
      final file = await _media.fileForEpisode(episode);
      if (file == null) {
        return writeApiError(
            request, HttpStatus.notFound, 'resource_not_found');
      }
      return _writePlaybackSession(
        request,
        tokenHash: tokenHash,
        device: device,
        movieId: databaseMovie.id,
        episodeId: episode.id,
        mediaRootId: episode.mediaRootId,
        relativePath: file.relativePath,
        durationMs: episode.durationMs ?? 600000,
        purpose: purpose,
      );
    }
    if (requestedMovieId != NasFixtureLibrary.movieId ||
        (requestedEpisodeId != null &&
            requestedEpisodeId != 'fixture-episode-1')) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final file = await _mediaService.fixtureFile();
    if (file == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    return _writePlaybackSession(
      request,
      tokenHash: tokenHash,
      device: device,
      movieId: requestedMovieId,
      episodeId: 'fixture-episode-1',
      mediaRootId: null,
      relativePath: file.relativePath,
      durationMs: _fixturePlaybackState?.durationMs ?? 600000,
      purpose: purpose,
    );
  }

  Future<void> _writePlaybackSession(
    HttpRequest request, {
    required String tokenHash,
    required NasDeviceToken device,
    required String movieId,
    required String episodeId,
    required String? mediaRootId,
    required String relativePath,
    required int durationMs,
    required String purpose,
  }) async {
    final persistedProgress = purpose == 'preview'
        ? null
        : _libraryDatabase.playbackProgressForEpisode(
            movieId: movieId,
            episodeId: episodeId,
          );
    final resumePositionMs = (persistedProgress?.positionMs ?? 0) > 0
        ? persistedProgress!.positionMs
        : purpose == 'playback'
            ? _fixturePlaybackState?.positionMs ?? 0
            : 0;
    final persistedDurationMs = persistedProgress?.durationMs;
    final sessionDurationMs =
        persistedDurationMs != null && persistedDurationMs > 0
            ? persistedDurationMs
            : durationMs;
    final sessionId = newUuidV4();
    _playbackSessions[sessionId] = _PlaybackSession(
      tokenHash: tokenHash,
      deviceId: device.deviceId,
      devicePlatform: device.platform,
      relativePath: relativePath,
      movieId: movieId,
      episodeId: episodeId,
      mediaRootId: mediaRootId,
      purpose: purpose,
      durationMs: sessionDurationMs,
    );
    _logger.event('playback.session.create', fields: {
      'component': 'nas.playback',
      'playbackSessionId': nasShortId(sessionId),
      'movieIdShort': nasShortId(movieId),
      'purpose': purpose,
      'outcome': 'success',
    });
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'sessionId': sessionId,
        'episodeId': episodeId,
        'resumePositionMs': resumePositionMs,
        'durationMs': sessionDurationMs,
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

  Future<void> savePlaybackProgress(
      HttpRequest request, String tokenHash) async {
    final session = _playbackSession(request, tokenHash);
    final body = await readApiJsonBody(request);
    final positionMs = (body?['positionMs'] as num?)?.toInt();
    final durationMs = (body?['durationMs'] as num?)?.toInt();
    final state = body?['state'] ?? 'playing';
    if (session == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (positionMs == null ||
        durationMs == null ||
        positionMs < 0 ||
        durationMs < 0 ||
        state is! String ||
        !const {'playing', 'paused'}.contains(state)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    if (session.purpose == 'playback' &&
        session.started &&
        !(state == 'paused' &&
            session.playbackStatus == state &&
            session.endPositionMs == positionMs &&
            session.durationMs == durationMs)) {
      _libraryDatabase.transaction(() {
        session.endPositionMs =
            positionMs > durationMs ? durationMs : positionMs;
        session.durationMs = durationMs;
        _reportPlaybackHistory(
          session,
          reportedAt: DateTime.now().toUtc(),
          nextStatus: state,
        );
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
      });
    }
    _logger.event('playback.progress', level: 'DEBUG', fields: {
      'component': 'nas.playback',
      'playbackSessionId': nasShortId(request.uri.pathSegments[4]),
      'outcome': 'success',
    });
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {'updatedAt': DateTime.now().toUtc().toIso8601String()},
    });
  }

  Future<void> markPlaybackStarted(
      HttpRequest request, String tokenHash) async {
    final session = _playbackSession(request, tokenHash);
    if (session == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (session.purpose == 'playback' && !session.streamRequested) {
      return writeApiError(request, HttpStatus.conflict, 'playback_not_ready');
    }
    if (session.purpose == 'playback' && !session.started) {
      final startedAt = DateTime.now().toUtc();
      session.started = true;
      session.lastReportedAt = startedAt;
      session.playbackStatus = 'playing';
      if (_libraryDatabase.findMovie(session.movieId) != null) {
        session.historyId = _libraryDatabase.recordPlaybackStarted(
          movieId: session.movieId,
          episodeId: session.episodeId,
          deviceId: session.deviceId,
          devicePlatform: session.devicePlatform,
          startedAt: startedAt.toIso8601String(),
          durationMs: session.durationMs,
        );
      }
      _logger.event('playback.started', fields: {
        'component': 'nas.playback',
        'playbackSessionId': nasShortId(request.uri.pathSegments[4]),
        'movieIdShort': nasShortId(session.movieId),
        'outcome': 'success',
      });
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {'started': session.started},
    });
  }

  Future<void> finishPlayback(HttpRequest request, String tokenHash) async {
    final id = request.uri.pathSegments[4];
    if (_closedPlayback[id] == tokenHash) {
      request.response.statusCode = HttpStatus.noContent;
      return request.response.close();
    }
    final session = _playbackSession(request, tokenHash);
    if (session == null)
      return writeApiError(request, 404, 'resource_not_found');
    final body = await readApiJsonBody(request);
    final position = body?['positionMs'];
    final duration = body?['durationMs'];
    if (position is! int || duration is! int || position < 0 || duration < 0) {
      return writeApiError(request, 400, 'invalid_request');
    }
    _libraryDatabase.transaction(() {
      if (session.started && session.purpose == 'playback') {
        session.endPositionMs = position.clamp(0, duration);
        session.durationMs = duration;
        _libraryDatabase.savePlaybackProgress(
            movieId: session.movieId,
            episodeId: session.episodeId,
            positionMs: position,
            durationMs: duration);
        final now = DateTime.now().toUtc();
        _reportPlaybackHistory(session, reportedAt: now, nextStatus: 'ended');
        if (session.historyId != null) {
          _libraryDatabase.finishPlaybackHistory(
              historyId: session.historyId!,
              endPositionMs: session.endPositionMs,
              durationMs: duration,
              lastReportedAt: now.toIso8601String(),
              watchDurationMs: session.watchDurationMs);
        }
      }
    });
    _playbackSessions.remove(id);
    _closedPlayback[id] = tokenHash;
    if (_closedPlayback.length > 256)
      _closedPlayback.remove(_closedPlayback.keys.first);
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> deletePlaybackSession(
      HttpRequest request, String tokenHash) async {
    final sessionId = request.uri.pathSegments[4];
    final session = _playbackSessions[sessionId];
    if (session == null || session.tokenHash != tokenHash) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    _playbackSessions.remove(sessionId);
    final historyId = session.historyId;
    if (historyId != null) {
      final reportedAt = DateTime.now().toUtc();
      _reportPlaybackHistory(
        session,
        reportedAt: reportedAt,
        nextStatus: 'ended',
      );
      _libraryDatabase.finishPlaybackHistory(
        historyId: historyId,
        endPositionMs: session.endPositionMs,
        durationMs: session.durationMs,
        lastReportedAt: reportedAt.toIso8601String(),
        watchDurationMs: session.watchDurationMs,
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

  /// 以会话为边界累积实际播放时长；暂停期间只更新时间，不叠加时长。
  void _reportPlaybackHistory(
    _PlaybackSession session, {
    required DateTime reportedAt,
    required String nextStatus,
  }) {
    final previousReport = session.lastReportedAt ?? reportedAt;
    if (session.playbackStatus == 'playing') {
      final elapsed = reportedAt.difference(previousReport).inMilliseconds;
      if (elapsed > 0) session.watchDurationMs += elapsed;
    }
    session.lastReportedAt = reportedAt;
    session.playbackStatus = nextStatus;
    final historyId = session.historyId;
    if (historyId == null) return;
    _libraryDatabase.reportPlaybackHistory(
      historyId: historyId,
      lastReportedAt: reportedAt.toIso8601String(),
      watchDurationMs: session.watchDurationMs,
      lastPositionMs: session.endPositionMs ?? 0,
      durationMs: session.durationMs,
      playbackStatus: nextStatus,
    );
  }

  Future<NasMediaFile?> _fileForPlaybackSession(
    _PlaybackSession session,
  ) async {
    final mediaRootId = session.mediaRootId;
    if (mediaRootId == null) {
      return _mediaService.fileForRelativePath(session.relativePath);
    }
    final root = _libraryDatabase.findMediaRoot(mediaRootId);
    if (root == null || !root.isOnline) return null;
    return root.containerPath == config.mediaDir
        ? _mediaService.fileForRelativePath(session.relativePath)
        : _mediaService.fileForRootRelativePath(
            rootPath: root.containerPath,
            relativePath: session.relativePath,
          );
  }

  Future<void> streamPlayback(HttpRequest request, String tokenHash) async {
    final session = _playbackSession(request, tokenHash);
    if (session == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final file = await _fileForPlaybackSession(session);
    if (file == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
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

  _PlaybackSession? _playbackSession(HttpRequest request, String tokenHash) {
    final session = _playbackSessions[request.uri.pathSegments[4]];
    return session?.tokenHash == tokenHash ? session : null;
  }
}

class _PlaybackSession {
  _PlaybackSession({
    required this.tokenHash,
    required this.deviceId,
    required this.devicePlatform,
    required this.relativePath,
    required this.movieId,
    required this.episodeId,
    required this.mediaRootId,
    required this.purpose,
    required this.durationMs,
  });

  final String tokenHash;
  final String deviceId;
  final String devicePlatform;
  final String relativePath;
  final String movieId;
  final String episodeId;
  final String? mediaRootId;
  final String purpose;
  bool started = false;
  bool streamRequested = false;
  String? historyId;
  int? endPositionMs;
  int? durationMs;
  DateTime? lastReportedAt;
  int watchDurationMs = 0;
  String playbackStatus = 'playing';
}

class _FixturePlaybackState {
  const _FixturePlaybackState(
      {required this.positionMs, required this.durationMs});

  final int positionMs;
  final int durationMs;
}
