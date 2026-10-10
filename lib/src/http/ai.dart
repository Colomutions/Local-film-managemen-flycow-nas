import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../ai_metadata_service.dart';
import '../diagnostic_log.dart';
import '../library_database.dart';
import '../persistent_state.dart';

import 'response.dart';
import 'presenter.dart';

/// AI settings and metadata task operations.
class NasAiHttpApi {
  NasAiHttpApi({
    required NasLibraryDatabase libraryDatabase,
    required NasAiMetadataClient aiMetadataClient,
    required NasDiagnosticLogger logger,
    required this.state,
    required Future<void> Function() persistState,
    required NasLibraryPresenter presenter,
    required this.updateState,
  })  : _libraryDatabase = libraryDatabase,
        _aiMetadataClient = aiMetadataClient,
        _logger = logger,
        _persistState = persistState,
        _presenter = presenter;
  final NasLibraryDatabase _libraryDatabase;
  final NasDiagnosticLogger _logger;
  final NasLibraryPresenter _presenter;
  final NasAiMetadataClient _aiMetadataClient;
  final NasPersistentState? Function() state;
  NasPersistentState? get _state => state();
  final Future<void> Function() _persistState;
  final void Function(NasPersistentState) updateState;
  set _state(NasPersistentState? value) => updateState(value!);

  Future<void> aiSettings(HttpRequest request) => writeApiJson(
        request.response,
        HttpStatus.ok,
        {'data': _aiSettingsPayload(_state!.aiSettings)},
      );

  Future<void> updateAiSettings(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    const fields = {'provider', 'endpoint', 'model', 'apiKey'};
    if (body == null ||
        body.keys.any((key) => !fields.contains(key)) ||
        fields.any((key) =>
            body[key] is! String || (body[key] as String).trim().isEmpty)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final endpoint = Uri.tryParse((body['endpoint'] as String).trim());
    if (endpoint == null ||
        !endpoint.hasAuthority ||
        !const {'http', 'https'}.contains(endpoint.scheme)) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
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
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _aiSettingsPayload(settings),
    });
  }

  Future<void> createAiTask(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    final movieId = body?['movieId'];
    final instructions = body?['instructions'] ?? '';
    if (body == null ||
        body.keys.any((key) => key != 'movieId' && key != 'instructions') ||
        movieId is! String ||
        movieId.isEmpty ||
        instructions is! String ||
        instructions.length > 4000) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    if (!_state!.aiSettings.isConfigured) {
      return writeApiError(request, HttpStatus.conflict, 'ai_not_configured');
    }
    final task = _libraryDatabase.createAiTask(
      movieId: movieId,
      instructions: instructions.trim(),
    );
    if (task == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    _logger.event('ai.task.create', fields: {
      'component': 'nas.ai',
      'taskIdShort': nasShortId(task.id),
      'movieIdShort': nasShortId(task.movieId),
      'outcome': 'queued',
    });
    await writeApiJson(request.response, HttpStatus.accepted, {
      'data': _aiTaskPayload(task),
    });
    unawaited(_runAiTask(task.id));
  }

  Future<void> aiTask(HttpRequest request) async {
    final task = _libraryDatabase.findAiTask(request.uri.pathSegments.last);
    if (task == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': _aiTaskPayload(task),
    });
  }

  Future<void> applyAiTask(HttpRequest request) async {
    final task = _libraryDatabase.findAiTask(request.uri.pathSegments[5]);
    if (task == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (task.status != 'succeeded' || task.resultJson == null) {
      return writeApiError(request, HttpStatus.conflict, 'ai_task_not_ready');
    }
    final result = _aiTaskResult(task.resultJson!);
    if (result == null) {
      return writeApiError(request, HttpStatus.conflict, 'ai_response_invalid');
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
      return writeApiError(request, HttpStatus.conflict, 'ai_response_invalid');
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
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': await _presenter.databaseDetails(movie),
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
}
