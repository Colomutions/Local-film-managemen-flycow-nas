import 'dart:async';
import 'dart:io';

import '../backup_service.dart';
import '../config.dart';
import '../disk_work_queue.dart';
import '../diagnostic_log.dart';
import '../library_database.dart';
import '../media_service.dart';
import '../novels/novel_backup.dart';
import '../persistent_state.dart';

import 'response.dart';
import 'presenter.dart';

/// Device, media-root and backup administration.
class NasOperationsHttpApi {
  NasOperationsHttpApi({
    required NasLibraryDatabase libraryDatabase,
    required NasMediaService mediaService,
    required NasBackupService backupService,
    required DiskWorkQueue diskWork,
    required this.config,
    required NasDiagnosticLogger logger,
    required this.state,
    required Future<void> Function() persistState,
    required this.backupCoordinator,
    required NasLibraryPresenter presenter,
  })  : _libraryDatabase = libraryDatabase,
        _mediaService = mediaService,
        _backupService = backupService,
        _diskWork = diskWork,
        _logger = logger,
        _persistState = persistState,
        _presenter = presenter;
  final NasLibraryDatabase _libraryDatabase;
  final NasConfig config;
  final NasDiagnosticLogger _logger;
  final NasLibraryPresenter _presenter;
  final NasMediaService _mediaService;
  final NasBackupService _backupService;
  final DiskWorkQueue _diskWork;
  final NasPersistentState? Function() state;
  NasPersistentState? get _state => state();
  final Future<void> Function() _persistState;
  final NasNovelBackupCoordinator? Function() backupCoordinator;
  NasNovelBackupCoordinator? get _novelBackupCoordinator => backupCoordinator();

  Future<NasBackupRecord>? _pendingBackup;

  Future<void> adminMediaRoots(HttpRequest request) => writeApiJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {
            'items': _libraryDatabase
                .listMediaRoots()
                .map(_presenter.mediaRootPayload)
                .toList(growable: false),
          },
        },
      );

  Future<void> adminMediaDirectories(HttpRequest request) async {
    final parentKey = request.uri.queryParameters['parentKey'];
    if (parentKey != null &&
        (parentKey.isEmpty ||
            (await _mediaService.directoryForRelativePath(parentKey)) ==
                null)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final directories = await _mediaService.childDirectories(parentKey);
    await writeApiJson(request.response, HttpStatus.ok, {
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

  Future<void> adminDevices(HttpRequest request) => writeApiJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {
            'items': _state!.tokens.values
                .map(_presenter.devicePayload)
                .toList(growable: false)
              ..sort((left, right) => (left['deviceId']! as String)
                  .compareTo(right['deviceId']! as String)),
          },
        },
      );

  Future<void> revokeAdminDevice(HttpRequest request) async {
    final deviceId = request.uri.pathSegments.last;
    final removedTokenHashes = _state!.tokens.entries
        .where((entry) => entry.value.deviceId == deviceId)
        .map((entry) => entry.key)
        .toList(growable: false);
    if (removedTokenHashes.isEmpty) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    for (final tokenHash in removedTokenHashes) {
      _state!.tokens.remove(tokenHash);
    }
    await _persistState();
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> createAdminBackup(HttpRequest request) async {
    final watch = Stopwatch()..start();
    _logger.event('backup.start', fields: {'component': 'nas.backup'});
    try {
      if (_novelBackupCoordinator == null &&
          _libraryDatabase.novels.hasNovels) {
        await writeApiError(
          request,
          HttpStatus.serviceUnavailable,
          'novel_storage_unavailable',
        );
        return;
      }
      final pending = _pendingBackup ??= _diskWork.run(
          'backup',
          () => _backupService.create(
                databaseSnapshot: _libraryDatabase.createBackupSnapshot,
                prepareContribution: _novelBackupCoordinator?.prepare,
                backgroundRead: _diskWork.read,
              ));
      final NasBackupRecord backup;
      try {
        backup = await pending;
      } finally {
        if (identical(pending, _pendingBackup)) _pendingBackup = null;
      }
      _logger.event('backup.end', fields: {
        'component': 'nas.backup',
        'outcome': 'success',
        'durationMs': watch.elapsedMilliseconds,
        'bytes': backup.sizeBytes,
      });
      await writeApiJson(request.response, HttpStatus.created, {
        'data': _presenter.backupPayload(backup),
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

  Future<void> adminBackups(HttpRequest request) async {
    final backups = await _backupService.list();
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': backups.map(_presenter.backupPayload).toList(growable: false),
      },
    });
  }

  Future<void> adminBackup(HttpRequest request) async {
    final backup = await _backupService.find(request.uri.pathSegments.last);
    if (backup == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _presenter.backupPayload(backup),
    });
  }
}
