import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../auth.dart';
import '../config.dart';
import '../diagnostic_log.dart';
import '../library/mdcng_actor_source.dart';
import '../library_database.dart';

import 'response.dart';
import 'presenter.dart';
import 'artwork.dart';

/// MDCNG actor source previews, decisions and imports.
class NasMdcngActorsHttpApi {
  NasMdcngActorsHttpApi({
    required NasLibraryDatabase libraryDatabase,
    required NasMdcngActorSource? mdcngActorSource,
    required NasDiagnosticLogger logger,
    required NasArtworkHttpApi assets,
    required NasLibraryPresenter presenter,
    required this.config,
  })  : _libraryDatabase = libraryDatabase,
        _mdcngActorSource = mdcngActorSource,
        _logger = logger,
        _assets = assets,
        _presenter = presenter;
  final NasLibraryDatabase _libraryDatabase;
  final NasDiagnosticLogger _logger;
  final NasArtworkHttpApi _assets;
  final NasLibraryPresenter _presenter;
  final NasMdcngActorSource? _mdcngActorSource;
  final NasConfig config;

  Future<NasMdcngActorSourceAvailability>? _mdcngAvailabilityProbe;

  DateTime? _mdcngAvailabilityCheckedAt;

  Future<NasMdcngActorSourceAvailability> cachedMdcngAvailability() {
    final source = _mdcngActorSource;
    if (source == null) {
      return Future.value(
        const NasMdcngActorSourceAvailability.unavailable(
          'mdcng_actor_source_not_configured',
        ),
      );
    }
    final now = DateTime.now().toUtc();
    final checkedAt = _mdcngAvailabilityCheckedAt;
    final probe = _mdcngAvailabilityProbe;
    if (probe != null &&
        checkedAt != null &&
        now.difference(checkedAt) < const Duration(seconds: 30)) {
      return probe;
    }
    _mdcngAvailabilityCheckedAt = now;
    return _mdcngAvailabilityProbe = source.checkAvailability();
  }

  /// Lists only completed MDCNG actor tasks.  The NAS returns safe summaries;
  /// host paths, source URLs, and MDCNG credentials never cross this API.
  Future<void> listMdcngActorImports(HttpRequest request) async {
    final records = await _readMdcngActorRecords(request);
    if (records == null) return;
    final deferred = _libraryDatabase.mdcngDeferredEmbyIdsForSource(
      config.mdcngSourceId,
    );
    final items = records.map((record) {
      final linked = _libraryDatabase.findActorByMdcngSource(
        sourceId: config.mdcngSourceId,
        embyId: record.embyId,
      );
      final isDeferred = deferred.contains(record.embyId);
      return {
        'taskId': record.taskId,
        'embyId': record.embyId,
        'sourceName': record.sourceName,
        'profileName': record.profile?.name,
        'profileResolution': record.profileResolution,
        'candidates': _mdcngActorCandidatePayloads(record),
        'completedAt': record.completedAt,
        'year': record.year,
        'imageCount': record.images.length,
        'sourceHasPhoto': record.hasPhoto,
        'sourceHasBackdrop': record.hasBackdrop,
        'hasPhoto': record.photo != null,
        'hasBackdrop': record.backdrop != null,
        'syncState': isDeferred
            ? 'deferred'
            : linked != null
                ? 'linked'
                : 'new',
        'similarActors': const <Map<String, Object?>>[],
      };
    }).toList(growable: false);
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'schemaVersion': 1,
        'mode': 'preview_only',
        'sourceId': config.mdcngSourceId,
        'items': items,
      },
    });
  }

  Future<void> setMdcngActorImportDecision(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    final taskId = body?['taskId'];
    final deferred = body?['deferred'];
    if (body == null ||
        body.length != 2 ||
        taskId is! String ||
        taskId.isEmpty ||
        deferred is! bool) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final records = await _readMdcngActorRecords(request);
    if (records == null) return;
    final record = records.where((item) => item.taskId == taskId).firstOrNull;
    if (record == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    _libraryDatabase.setMdcngActorDeferred(
      sourceId: config.mdcngSourceId,
      embyId: record.embyId,
      deferred: deferred,
    );
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {'taskId': taskId, 'deferred': deferred},
    });
  }

  Future<void> resetMdcngActors(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    if (body == null || body.isNotEmpty) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final reset = _libraryDatabase.clearAllMdcngActors();
    var deletedImages = 0;
    for (final asset in reset.assets) {
      await _assets.deleteManagedAsset(asset);
      deletedImages++;
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'deletedActors': reset.deletedActors,
        'unlinkedMovieLinks': reset.unlinkedMovieLinks,
        'deletedImages': deletedImages,
      },
    });
  }

  /// Previews completed MDCNG records against their existing source links.
  Future<void> previewMdcngActorBatchImport(HttpRequest request) async {
    final records = await _readMdcngActorRecords(request);
    if (records == null) return;
    final deferred = _libraryDatabase.mdcngDeferredEmbyIdsForSource(
      config.mdcngSourceId,
    );
    final plans = records
        .map((record) => _planMdcngActorBatchImport(
              record,
              deferredEmbyIds: deferred,
            ))
        .toList(growable: false);
    final counts = <String, int>{
      'eligibleCreate': 0,
      'eligibleUpdate': 0,
      'needsProfileResolution': 0,
      'needsTargetResolution': 0,
      'alreadyImported': 0,
      'noSafeChanges': 0,
      'deferred': 0,
    };
    for (final plan in plans) {
      final key = switch (plan.status) {
        'eligible_create' => 'eligibleCreate',
        'eligible_update' => 'eligibleUpdate',
        'needs_profile_resolution' => 'needsProfileResolution',
        'needs_target_resolution' => 'needsTargetResolution',
        'already_imported' => 'alreadyImported',
        'deferred' => 'deferred',
        _ => 'noSafeChanges',
      };
      counts[key] = counts[key]! + 1;
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'schemaVersion': 1,
        'mode': 'preview_only',
        'summary': {
          ...counts,
          'eligibleTotal':
              counts['eligibleCreate']! + counts['eligibleUpdate']!,
        },
        'items': plans.map(_mdcngActorBatchPlanPayload).toList(growable: false),
      },
    });
  }

  Future<void> applyMdcngActorBatchImport(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    final rawItems = body?['items'];
    if (body == null ||
        body.length != 1 ||
        rawItems is! List ||
        rawItems.isEmpty ||
        rawItems.length > 250) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final requested = <String, String>{};
    for (final rawItem in rawItems) {
      if (rawItem is! Map || rawItem.length != 2) {
        return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
      }
      final item = Map<String, dynamic>.from(rawItem);
      final taskId = item['taskId'];
      final fingerprint = item['fingerprint'];
      if (taskId is! String ||
          taskId.isEmpty ||
          fingerprint is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint) ||
          requested.putIfAbsent(taskId, () => fingerprint) != fingerprint) {
        return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
      }
    }
    if (requested.length != rawItems.length) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final records = await _readMdcngActorRecords(request, forceRefresh: true);
    if (records == null) return;
    final byTaskId = {for (final record in records) record.taskId: record};
    var created = 0;
    var updated = 0;
    var skipped = 0;
    final failures = <Map<String, Object?>>[];
    for (final entry in requested.entries) {
      final record = byTaskId[entry.key];
      if (record == null || record.fingerprint != entry.value) {
        failures
            .add({'taskId': entry.key, 'code': 'mdcng_actor_preview_stale'});
        continue;
      }
      final plan = _planMdcngActorBatchImport(record);
      if (!plan.isEligible) {
        skipped++;
        continue;
      }
      final outcome = await _applyMdcngActorBatchPlan(plan);
      if (outcome == 'created') {
        created++;
      } else if (outcome == 'updated') {
        updated++;
      } else if (outcome == 'skipped') {
        skipped++;
      } else {
        failures.add({'taskId': record.taskId, 'code': outcome});
      }
    }
    if (created + updated > 0) _libraryDatabase.reconcileScrapeActorMovies();
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'created': created,
        'updated': updated,
        'skipped': skipped,
        'failed': failures.length,
        'failures': failures,
      },
    });
  }

  _MdcngActorBatchPlan _planMdcngActorBatchImport(
      NasMdcngActorSourceRecord record,
      {Set<String>? deferredEmbyIds}) {
    if (deferredEmbyIds?.contains(record.embyId) ??
        _libraryDatabase.isMdcngActorDeferred(
          sourceId: config.mdcngSourceId,
          embyId: record.embyId,
        )) {
      return _MdcngActorBatchPlan(record: record, status: 'deferred');
    }
    if (record.profileResolution != 'matched' &&
        record.profileResolution != 'raw') {
      return _MdcngActorBatchPlan(
          record: record, status: 'needs_profile_resolution');
    }
    final linked = _libraryDatabase.findActorByMdcngSource(
      sourceId: config.mdcngSourceId,
      embyId: record.embyId,
    );
    final matches = linked == null ? _mdcngExactActors(record) : <NasActor>[];
    if (matches.length > 1 ||
        (matches.length == 1 &&
            _libraryDatabase.actorHasOtherMdcngIdentity(
                matches.single.id, config.mdcngSourceId, record.embyId))) {
      return _MdcngActorBatchPlan(
          record: record, status: 'needs_target_resolution');
    }
    final target = linked ?? matches.firstOrNull;
    if (target?.archivedAt != null) {
      return _MdcngActorBatchPlan(
          record: record, status: 'needs_target_resolution');
    }
    final fields = _mdcngActorFieldDiffs(record, target)
        .where(
            (diff) => diff['isAvailable'] == true && diff['status'] == 'fill')
        .map((diff) => diff['key'] as String)
        .toSet();
    if (fields.isEmpty && linked != null) {
      final imported = target != null &&
          _libraryDatabase.findMdcngActorImport(
                sourceId: config.mdcngSourceId,
                taskId: record.taskId,
                sourceFingerprint: record.fingerprint,
              ) !=
              null;
      return _MdcngActorBatchPlan(
        record: record,
        status: imported ? 'already_imported' : 'no_safe_changes',
        target: target,
      );
    }
    return _MdcngActorBatchPlan(
      record: record,
      status: target == null ? 'eligible_create' : 'eligible_update',
      fields: fields,
      target: target,
    );
  }

  Map<String, Object?> _mdcngActorBatchPlanPayload(
    _MdcngActorBatchPlan plan,
  ) =>
      {
        'taskId': plan.record.taskId,
        'embyId': plan.record.embyId,
        'sourceName': plan.record.sourceName,
        'profileName': plan.record.profile?.name,
        'profileResolution': plan.record.profileResolution,
        'status': plan.status,
        'fingerprint': plan.record.fingerprint,
        'fieldCount': plan.fields.length,
        'candidates': _mdcngActorCandidatePayloads(plan.record),
      };

  List<Map<String, Object?>> _mdcngActorCandidatePayloads(
    NasMdcngActorSourceRecord record,
  ) =>
      record.candidates
          .map(
            (candidate) => {
              'key': candidate.key,
              'name': candidate.name,
              'romanizedName': candidate.romanizedName,
              'hasPhoto': candidate.hasPhoto,
              'missingFieldCount': candidate.missingFieldCount,
            },
          )
          .toList(growable: false);

  /// 姓名和别名只用于首次唯一匹配，已有来源绑定始终优先。
  List<NasActor> _mdcngExactActors(NasMdcngActorSourceRecord record) =>
      _libraryDatabase.findActorsByExactNames([
        record.sourceName,
        if (record.profile != null) record.profile!.name,
        ...?record.profile?.aliases,
      ], includeArchived: true);

  Future<void> previewMdcngActorImport(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    final taskId = body?['taskId'];
    final selectedProfileKey = body?['selectedProfileKey'];
    final targetActorId = body?['targetActorId'];
    if (body == null ||
        body.keys.any(
          (key) =>
              key != 'taskId' &&
              key != 'selectedProfileKey' &&
              key != 'targetActorId',
        ) ||
        taskId is! String ||
        taskId.isEmpty ||
        (targetActorId != null &&
            (targetActorId is! String || targetActorId.isEmpty)) ||
        (selectedProfileKey != null &&
            (selectedProfileKey is! String || selectedProfileKey.isEmpty))) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final records = await _readMdcngActorRecords(
      request,
      selectedProfileKeys:
          selectedProfileKey == null ? const {} : {taskId: selectedProfileKey},
    );
    if (records == null) return;
    final record = records.where((item) => item.taskId == taskId).firstOrNull;
    if (record == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (_libraryDatabase.isMdcngActorDeferred(
      sourceId: config.mdcngSourceId,
      embyId: record.embyId,
    )) {
      return writeApiError(
          request, HttpStatus.conflict, 'mdcng_actor_deferred');
    }
    final selectedTarget = targetActorId == null
        ? null
        : _libraryDatabase.findActor(targetActorId);
    if (targetActorId != null &&
        (selectedTarget == null || selectedTarget.archivedAt != null)) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    final linked = _libraryDatabase.findActorByMdcngSource(
      sourceId: config.mdcngSourceId,
      embyId: record.embyId,
    );
    if (linked?.archivedAt != null ||
        (linked != null &&
            selectedTarget != null &&
            selectedTarget.id != linked.id)) {
      return writeApiError(request, HttpStatus.conflict,
          'mdcng_actor_target_resolution_required');
    }
    final matches = linked == null ? _mdcngExactActors(record) : <NasActor>[];
    final automaticTarget = matches.length == 1 &&
            matches.single.archivedAt == null &&
            !_libraryDatabase.actorHasOtherMdcngIdentity(
                matches.single.id, config.mdcngSourceId, record.embyId)
        ? matches.single
        : null;
    final comparisonActor = selectedTarget ?? linked ?? automaticTarget;
    if (comparisonActor == null &&
        matches.isNotEmpty &&
        matches.every((actor) => actor.archivedAt != null)) {
      return writeApiError(request, HttpStatus.conflict,
          'mdcng_actor_target_resolution_required');
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'schemaVersion': 1,
        'mode': 'preview_only',
        'source': {
          'sourceId': config.mdcngSourceId,
          'taskId': record.taskId,
          'embyId': record.embyId,
          'sourceName': record.sourceName,
          'completedAt': record.completedAt,
          'fingerprint': record.fingerprint,
          'selectedProfileKey': record.selectedProfileKey,
        },
        'profileResolution': record.profileResolution,
        'candidates': _mdcngActorCandidatePayloads(record),
        'proposed': _mdcngActorProposedPayload(record),
        'current': linked != null
            ? _presenter.actorPayload(linked)
            : selectedTarget == null && automaticTarget != null
                ? _presenter.actorPayload(automaticTarget)
                : null,
        'comparisonActorId': comparisonActor?.id,
        'similarActors': matches
            .where((actor) => actor.archivedAt == null)
            .map(_presenter.actorPayload)
            .toList(growable: false),
        'recommendedAction': comparisonActor != null
            ? 'update'
            : matches.isEmpty
                ? 'create'
                : 'resolve',
        'fieldDiffs': _mdcngActorFieldDiffs(record, comparisonActor),
      },
    });
  }

  Future<List<NasMdcngActorSourceRecord>?> _readMdcngActorRecords(
    HttpRequest request, {
    Map<String, String> selectedProfileKeys = const {},
    bool forceRefresh = false,
  }) async {
    final source = _mdcngActorSource;
    if (source == null) {
      await writeApiError(
        request,
        HttpStatus.conflict,
        'mdcng_actor_source_not_configured',
      );
      return null;
    }
    try {
      return await source.readCompletedActors(
        forceRefresh: forceRefresh,
        selectedProfileKeys: {
          ..._libraryDatabase.mdcngProfileKeysForSource(config.mdcngSourceId),
          ...selectedProfileKeys,
        },
      );
    } on NasMdcngActorSourceException catch (error) {
      _logger.event('mdcng.source.read_failed', level: 'WARN', fields: {
        'component': 'nas.mdcng',
        'outcome': error.code,
        if (error.sqliteExtendedResultCode != null)
          'sqliteExtendedResultCode': error.sqliteExtendedResultCode,
        if (error.sqliteOperation != null)
          'sqliteOperation': error.sqliteOperation,
      });
      await writeApiError(request, HttpStatus.serviceUnavailable, error.code);
      return null;
    } on Object {
      await writeApiError(
        request,
        HttpStatus.internalServerError,
        'mdcng_actor_source_unreadable',
      );
      return null;
    }
  }

  Map<String, Object?> _mdcngActorProposedPayload(
    NasMdcngActorSourceRecord record,
  ) {
    final profile = record.profile;
    return {
      'stageName': record.sourceName,
      'originalName': profile?.name,
      'translatedName': record.sourceName,
      'aliases': profile?.aliases ?? const <String>[],
      'gender': profile == null ? null : 'female',
      'romanizedName': profile?.roma,
      'birthDate': profile?.birthday,
      'birthMonth': profile?.birthMonth,
      'country': profile?.country,
      'heightCm': profile?.heightCm,
      'measurements': profile?.measurements,
      'debutMonth': profile?.debutMonth,
      'debutDescription': profile?.debutWork,
      'profileUpdatedAt': profile?.updatedAt,
      'profileCompleteness': profile?.completeness,
      'images': record.images
          .map(
            (image) => {
              'kind': image.kind,
              'fileName': image.fileName,
              'mimeType': image.mimeType,
              'byteLength': image.byteLength,
            },
          )
          .toList(growable: false),
    };
  }

  List<Map<String, Object?>> _mdcngActorFieldDiffs(
    NasMdcngActorSourceRecord record,
    NasActor? current,
  ) {
    final proposed = <String, Object?>{
      'stageName': record.sourceName,
      'originalName': record.profile?.name,
      'translatedName': record.sourceName,
      'aliases': record.profile?.aliases,
      'gender': record.profile == null ? null : 'female',
      'romanizedName': record.profile?.roma,
      'birthDate': record.profile?.birthday,
      'birthMonth': record.profile?.birthMonth,
      'heightCm': record.profile?.heightCm,
      'measurements': record.profile?.measurements,
      'country': record.profile?.country,
      'debutMonth': record.profile?.debutMonth,
      'debutDescription': record.profile?.debutWork,
      'photo': record.photo == null ? null : record.photo!.fileName,
      'backdrop': record.backdrop == null ? null : record.backdrop!.fileName,
    };
    final values = <String, Object?>{
      'stageName': current?.stageName,
      'originalName': current?.originalName,
      'translatedName': current?.translatedName,
      'aliases': current?.aliases,
      'gender': current?.gender,
      'romanizedName': current?.romanizedName,
      'birthDate': current?.birthDate,
      'birthMonth': current?.birthMonth,
      'heightCm': current?.heightCm,
      'measurements': current?.measurements,
      'country': current?.country,
      'debutMonth': current?.debutMonth,
      'debutDescription': current?.debutDescription,
      'photo': current?.photoAssetId,
      'backdrop': current?.backdropAssetId,
    };
    return proposed.entries.map(
      (entry) {
        final available = entry.value != null &&
            (entry.value is! List || (entry.value as List).isNotEmpty);
        final currentValue = _mdcngEffectiveCurrentValue(
          record,
          current,
          entry.key,
          values[entry.key],
        );
        final unchanged = available &&
            _mdcngActorValuesEqual(
              entry.key,
              currentValue,
              entry.value,
            );
        final needsConfirmation = available &&
            !unchanged &&
            _mdcngActorHasValue(currentValue) &&
            entry.key != 'aliases';
        return {
          'key': entry.key,
          'isAvailable': available,
          'status': !available
              ? 'unavailable'
              : unchanged
                  ? 'unchanged'
                  : needsConfirmation
                      ? 'replace_requires_confirmation'
                      : 'fill',
          'requiresConfirmation': needsConfirmation,
          'currentValue': _mdcngActorDiffDisplayValue(
            entry.key,
            currentValue,
            current: true,
          ),
          'proposedValue': _mdcngActorDiffDisplayValue(
            entry.key,
            entry.value,
            current: false,
          ),
        };
      },
    ).toList(growable: false);
  }

  /// Releases before MDCNG import schema 3 put the native actress name in
  /// `stage_name`.  These rows have a strict signature and are therefore safe
  /// to normalize in a later batch without replacing manually edited names.
  bool _isLegacyMdcngNameLayout(
    NasMdcngActorSourceRecord record,
    NasActor? actor,
  ) {
    final profile = record.profile;
    if (actor == null || profile == null) return false;
    final expectedIdentity =
        'mdcng:${config.mdcngSourceId}:emby:${record.embyId}';
    return actor.profileIdentity == expectedIdentity &&
        actor.stageName == profile.name &&
        (actor.originalName == null || actor.originalName == profile.name) &&
        (actor.translatedName == null ||
            actor.translatedName == record.sourceName);
  }

  Object? _mdcngEffectiveCurrentValue(
    NasMdcngActorSourceRecord record,
    NasActor? actor,
    String field,
    Object? value,
  ) {
    if (_isLegacyMdcngNameLayout(record, actor) &&
        (field == 'stageName' || field == 'translatedName')) {
      return null;
    }
    return value;
  }

  /// Re-reads the MDCNG source before writing and reuses a linked actor.
  Future<void> applyMdcngActorImport(HttpRequest request) async {
    final body = await readApiJsonBody(request);
    final taskId = body?['taskId'];
    final fingerprint = body?['fingerprint'];
    final rawFieldKeys = body?['fieldKeys'];
    final rawOverwriteFieldKeys = body?['overwriteFieldKeys'];
    final targetActorId = body?['targetActorId'];
    final createNew = body?['createNew'];
    final selectedProfileKey = body?['selectedProfileKey'];
    const allowedFields = {
      'stageName',
      'originalName',
      'translatedName',
      'aliases',
      'gender',
      'romanizedName',
      'birthDate',
      'birthMonth',
      'heightCm',
      'measurements',
      'country',
      'cup',
      'birthplace',
      'careerPeriod',
      'debutMonth',
      'debutDescription',
      'accountUrl',
      'officialSiteUrl',
      'photo',
      'backdrop',
    };
    if (body == null ||
        body.keys.any((key) =>
            key != 'taskId' &&
            key != 'fingerprint' &&
            key != 'fieldKeys' &&
            key != 'overwriteFieldKeys' &&
            key != 'targetActorId' &&
            key != 'createNew' &&
            key != 'selectedProfileKey') ||
        taskId is! String ||
        taskId.isEmpty ||
        fingerprint is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint) ||
        rawFieldKeys is! List ||
        rawFieldKeys.isEmpty ||
        rawFieldKeys.any((value) => value is! String) ||
        rawOverwriteFieldKeys is! List ||
        rawOverwriteFieldKeys.any((value) => value is! String) ||
        (targetActorId != null &&
            (targetActorId is! String || targetActorId.isEmpty)) ||
        (selectedProfileKey != null &&
            (selectedProfileKey is! String || selectedProfileKey.isEmpty)) ||
        createNew is! bool) {
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

    final records = await _readMdcngActorRecords(
      request,
      forceRefresh: true,
      selectedProfileKeys:
          selectedProfileKey == null ? const {} : {taskId: selectedProfileKey},
    );
    if (records == null) return;
    final record = records.where((item) => item.taskId == taskId).firstOrNull;
    if (record == null) {
      return writeApiError(request, HttpStatus.notFound, 'resource_not_found');
    }
    if (_libraryDatabase.isMdcngActorDeferred(
      sourceId: config.mdcngSourceId,
      embyId: record.embyId,
    )) {
      return writeApiError(
          request, HttpStatus.conflict, 'mdcng_actor_deferred');
    }
    if (record.fingerprint != fingerprint) {
      return writeApiError(
          request, HttpStatus.conflict, 'mdcng_actor_preview_stale');
    }
    if (record.profileResolution != 'matched' &&
        record.profileResolution != 'raw') {
      return writeApiError(
        request,
        HttpStatus.conflict,
        'mdcng_actor_profile_resolution_required',
      );
    }
    final profile = record.profile;
    final linked = _libraryDatabase.findActorByMdcngSource(
      sourceId: config.mdcngSourceId,
      embyId: record.embyId,
    );
    if (linked?.archivedAt != null ||
        (linked != null &&
            targetActorId != null &&
            targetActorId != linked.id)) {
      return writeApiError(request, HttpStatus.conflict,
          'mdcng_actor_target_resolution_required');
    }
    NasActor? target = linked;
    if (target == null && !createNew && targetActorId != null) {
      target = _libraryDatabase.findActor(targetActorId);
      if (target == null || target.archivedAt != null) {
        return writeApiError(
            request, HttpStatus.notFound, 'resource_not_found');
      }
    }
    if (target == null) {
      final matches = _mdcngExactActors(record);
      if (matches.isNotEmpty &&
          matches.every((actor) => actor.archivedAt != null)) {
        return writeApiError(request, HttpStatus.conflict,
            'mdcng_actor_target_resolution_required');
      }
      if (matches.length == 1 &&
          matches.single.archivedAt == null &&
          !_libraryDatabase.actorHasOtherMdcngIdentity(
              matches.single.id, config.mdcngSourceId, record.embyId)) {
        target = matches.single;
      } else if (matches.isNotEmpty && !createNew) {
        return writeApiError(request, HttpStatus.conflict,
            'mdcng_actor_target_resolution_required');
      }
    }
    if (target == null && !fields.contains('stageName')) {
      return writeApiError(
          request, HttpStatus.badRequest, 'invalid_mdcng_actor_selection');
    }
    final unavailable = _mdcngActorUnavailableFields(record, fields);
    if (unavailable.isNotEmpty) {
      return writeApiError(
          request, HttpStatus.badRequest, 'invalid_mdcng_actor_selection');
    }

    final proposed = _mdcngActorProposedValues(record);
    if (target != null) {
      for (final field in fields) {
        if (field == 'aliases') continue;
        final current = _mdcngEffectiveCurrentValue(
          record,
          target,
          field,
          _mdcngActorCurrentValue(target, field),
        );
        final next = proposed[field];
        if (_mdcngActorHasValue(current) &&
            !_mdcngActorValuesEqual(field, current, next) &&
            !overwriteFields.contains(field)) {
          return writeApiError(
            request,
            HttpStatus.conflict,
            'mdcng_actor_overwrite_confirmation_required',
          );
        }
      }
    }

    NasManagedAsset? newPhoto;
    NasManagedAsset? newBackdrop;
    NasActor? actor;
    final previousPhoto = target?.photoAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(target!.photoAssetId!);
    final previousBackdrop = target?.backdropAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(target!.backdropAssetId!);
    try {
      if (fields.contains('photo')) {
        newPhoto = await _saveMdcngActorImage(record.photo!, 'actor_photo');
        if (newPhoto == null) {
          await writeApiError(
              request, HttpStatus.badRequest, 'invalid_mdcng_actor_image');
          return;
        }
      }
      if (fields.contains('backdrop')) {
        newBackdrop =
            await _saveMdcngActorImage(record.backdrop!, 'actor_backdrop');
        if (newBackdrop == null) {
          await _assets.deleteManagedAsset(newPhoto);
          await writeApiError(
              request, HttpStatus.badRequest, 'invalid_mdcng_actor_image');
          return;
        }
      }
      if (_libraryDatabase.isMdcngActorDeferred(
        sourceId: config.mdcngSourceId,
        embyId: record.embyId,
      )) {
        await _assets.deleteManagedAsset(newPhoto);
        await _assets.deleteManagedAsset(newBackdrop);
        await writeApiError(
            request, HttpStatus.conflict, 'mdcng_actor_deferred');
        return;
      }
      final currentLink = _libraryDatabase.findActorByMdcngSource(
        sourceId: config.mdcngSourceId,
        embyId: record.embyId,
      );
      final latestTarget =
          target == null ? null : _libraryDatabase.findActor(target.id);
      final targetChanged = target != null &&
          (latestTarget == null ||
              latestTarget.archivedAt != null ||
              fields.any((field) => !_mdcngActorValuesEqual(
                  field,
                  _mdcngActorCurrentValue(target!, field),
                  _mdcngActorCurrentValue(latestTarget, field))));
      if (currentLink?.id != linked?.id ||
          targetChanged ||
          (target == null &&
              !createNew &&
              _mdcngExactActors(record).isNotEmpty)) {
        await _assets.deleteManagedAsset(newPhoto);
        await _assets.deleteManagedAsset(newBackdrop);
        await writeApiError(
            request, HttpStatus.conflict, 'mdcng_actor_preview_stale');
        return;
      }
      final aliases = fields.contains('aliases')
          ? [
              ...?target?.aliases,
              ...?profile?.aliases,
            ]
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toSet()
              .toList()
          : target?.aliases ?? const <String>[];
      final values = _mdcngActorDatabaseValues(
        record: record,
        fields: fields,
        aliases: aliases,
        photoAssetId: newPhoto?.id,
        backdropAssetId: newBackdrop?.id,
      );
      if (target == null) {
        actor = _libraryDatabase.createActor(
          profileIdentity:
              'mdcng:${config.mdcngSourceId}:task:${record.taskId}:${newUuidV4()}',
          stageName: values['stage_name'] as String?,
          originalName: values['original_name'] as String?,
          translatedName: values['translated_name'] as String?,
          aliases: aliases,
          gender: values['gender'] as String?,
          romanizedName: values['romanized_name'] as String?,
          birthDate: values['birth_date'] as String?,
          birthMonth: values['birth_month'] as String?,
          heightCm: values['height_cm'] as int?,
          country: values['country'] as String?,
          measurements: values['measurements'] as String?,
          cup: values['cup'] as String?,
          birthplace: values['birthplace'] as String?,
          careerPeriod: values['career_period'] as String?,
          debutMonth: values['debut_month'] as String?,
          debutDescription: values['debut_description'] as String?,
          accountUrl: values['account_url'] as String?,
          officialSiteUrl: values['official_site_url'] as String?,
          photoAssetId: newPhoto?.id,
          backdropAssetId: newBackdrop?.id,
        );
      } else {
        actor = _libraryDatabase.updateActor(target.id, values);
        if (actor == null) throw StateError('actor disappeared during import');
      }
      _libraryDatabase.linkActorToMdcngSource(
        sourceId: config.mdcngSourceId,
        embyId: record.embyId,
        actorId: actor.id,
        sourceName: record.sourceName,
        profileKey: profile?.key ?? '',
      );
      final audit = _libraryDatabase.addMdcngActorImport(
        actorId: actor.id,
        sourceId: config.mdcngSourceId,
        taskId: record.taskId,
        embyId: record.embyId,
        sourceFingerprint: record.fingerprint,
        appliedFields: fieldKeys,
      );
      if (fields.contains('photo'))
        await _assets.deleteManagedAsset(previousPhoto);
      if (fields.contains('backdrop'))
        await _assets.deleteManagedAsset(previousBackdrop);
      await writeApiJson(request.response, HttpStatus.ok, {
        'data': {
          'status': 'applied',
          'actor':
              _presenter.actorPayload(_libraryDatabase.findActor(actor.id)!),
          'appliedFields': fieldKeys,
          'importRecord': {
            'id': audit.id,
            'sourceId': audit.sourceId,
            'taskId': audit.taskId,
            'embyId': audit.embyId,
            'createdAt': audit.createdAt,
          },
        },
      });
    } on Object {
      if (target == null && actor != null) {
        _libraryDatabase.deleteActor(actor.id);
      }
      await _assets.deleteManagedAsset(newPhoto);
      await _assets.deleteManagedAsset(newBackdrop);
      return writeApiError(
        request,
        HttpStatus.internalServerError,
        'mdcng_actor_import_failed',
      );
    }
  }

  /// Batch creates new source records and fills blank fields on linked actors.
  Future<String> _applyMdcngActorBatchPlan(
    _MdcngActorBatchPlan plan,
  ) async {
    final record = plan.record;
    final profile = record.profile;
    final target = plan.target;
    if (!plan.isEligible) {
      return 'skipped';
    }
    if (_libraryDatabase.isMdcngActorDeferred(
      sourceId: config.mdcngSourceId,
      embyId: record.embyId,
    )) {
      return 'skipped';
    }
    NasManagedAsset? newPhoto;
    NasManagedAsset? newBackdrop;
    NasActor? actor;
    var committed = false;
    try {
      if (plan.fields.contains('photo')) {
        newPhoto = await _saveMdcngActorImage(record.photo!, 'actor_photo');
        if (newPhoto == null) return 'invalid_mdcng_actor_image';
      }
      if (plan.fields.contains('backdrop')) {
        newBackdrop =
            await _saveMdcngActorImage(record.backdrop!, 'actor_backdrop');
        if (newBackdrop == null) return 'invalid_mdcng_actor_image';
      }
      if (_libraryDatabase.isMdcngActorDeferred(
        sourceId: config.mdcngSourceId,
        embyId: record.embyId,
      )) {
        return 'skipped';
      }
      final currentPlan = _planMdcngActorBatchImport(record);
      if (!currentPlan.isEligible ||
          currentPlan.target?.id != target?.id ||
          !currentPlan.fields.containsAll(plan.fields)) {
        return 'skipped';
      }
      final aliases = plan.fields.contains('aliases')
          ? [
              ...?target?.aliases,
              ...?profile?.aliases,
            ]
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toSet()
              .toList()
          : target?.aliases ?? const <String>[];
      final values = _mdcngActorDatabaseValues(
        record: record,
        fields: plan.fields,
        aliases: aliases,
        photoAssetId: newPhoto?.id,
        backdropAssetId: newBackdrop?.id,
      );
      if (target == null) {
        actor = _libraryDatabase.createActor(
          profileIdentity:
              'mdcng:${config.mdcngSourceId}:task:${record.taskId}:${newUuidV4()}',
          stageName: values['stage_name'] as String?,
          originalName: values['original_name'] as String?,
          translatedName: values['translated_name'] as String?,
          aliases: aliases,
          gender: values['gender'] as String?,
          romanizedName: values['romanized_name'] as String?,
          birthDate: values['birth_date'] as String?,
          birthMonth: values['birth_month'] as String?,
          heightCm: values['height_cm'] as int?,
          country: values['country'] as String?,
          measurements: values['measurements'] as String?,
          cup: values['cup'] as String?,
          birthplace: values['birthplace'] as String?,
          careerPeriod: values['career_period'] as String?,
          debutMonth: values['debut_month'] as String?,
          debutDescription: values['debut_description'] as String?,
          accountUrl: values['account_url'] as String?,
          officialSiteUrl: values['official_site_url'] as String?,
          photoAssetId: newPhoto?.id,
          backdropAssetId: newBackdrop?.id,
        );
      } else {
        actor = _libraryDatabase.updateActor(target.id, values);
        if (actor == null) return 'resource_not_found';
      }
      _libraryDatabase.linkActorToMdcngSource(
        sourceId: config.mdcngSourceId,
        embyId: record.embyId,
        actorId: actor.id,
        sourceName: record.sourceName,
        profileKey: profile?.key ?? '',
        reconcileMovies: false,
      );
      _libraryDatabase.addMdcngActorImport(
        actorId: actor.id,
        sourceId: config.mdcngSourceId,
        taskId: record.taskId,
        embyId: record.embyId,
        sourceFingerprint: record.fingerprint,
        appliedFields: plan.fields.toList(growable: false),
      );
      committed = true;
      return target == null ? 'created' : 'updated';
    } on Object {
      if (target == null && actor != null) {
        _libraryDatabase.deleteActor(actor.id);
      }
      return 'mdcng_actor_import_failed';
    } finally {
      if (newPhoto != null && !committed) {
        await _assets.deleteManagedAsset(newPhoto);
      }
      if (newBackdrop != null && !committed) {
        await _assets.deleteManagedAsset(newBackdrop);
      }
    }
  }

  Set<String> _mdcngActorUnavailableFields(
    NasMdcngActorSourceRecord record,
    Set<String> fields,
  ) {
    final available = _mdcngActorProposedValues(record);
    return fields.where((field) {
      final value = available[field];
      return value == null || (value is List && value.isEmpty);
    }).toSet();
  }

  Map<String, Object?> _mdcngActorProposedValues(
    NasMdcngActorSourceRecord record,
  ) {
    final profile = record.profile;
    return {
      // Emby's task name is the Chinese name familiar to the local library;
      // Actress.db provides the native-language debut name and its romanization.
      'stageName': record.sourceName,
      'originalName': profile?.name,
      'translatedName': record.sourceName,
      'aliases': profile?.aliases ?? const <String>[],
      'gender': profile == null ? null : 'female',
      'romanizedName': profile?.roma,
      'birthDate': profile?.birthday,
      'birthMonth': profile?.birthMonth,
      'heightCm': profile?.heightCm,
      'measurements': profile?.measurements,
      'country': profile?.country,
      'debutMonth': profile?.debutMonth,
      'debutDescription': profile?.debutWork,
      'photo': record.photo?.fileName,
      'backdrop': record.backdrop?.fileName,
    };
  }

  Map<String, Object?> _mdcngActorDatabaseValues({
    required NasMdcngActorSourceRecord record,
    required Set<String> fields,
    required List<String> aliases,
    required String? photoAssetId,
    required String? backdropAssetId,
  }) {
    final proposed = _mdcngActorProposedValues(record);
    const databaseKeys = {
      'stageName': 'stage_name',
      'originalName': 'original_name',
      'translatedName': 'translated_name',
      'aliases': 'aliases_json',
      'gender': 'gender',
      'romanizedName': 'romanized_name',
      'birthDate': 'birth_date',
      'birthMonth': 'birth_month',
      'heightCm': 'height_cm',
      'measurements': 'measurements',
      'country': 'country',
      'debutMonth': 'debut_month',
      'debutDescription': 'debut_description',
      'accountUrl': 'account_url',
      'officialSiteUrl': 'official_site_url',
    };
    final values = <String, Object?>{};
    for (final field in fields) {
      final databaseKey = databaseKeys[field];
      if (databaseKey == null) continue;
      values[databaseKey] =
          field == 'aliases' ? jsonEncode(aliases) : proposed[field];
    }
    if (fields.contains('photo')) values['photo_asset_id'] = photoAssetId;
    if (fields.contains('backdrop')) {
      values['backdrop_asset_id'] = backdropAssetId;
    }
    return values;
  }

  Object? _mdcngActorCurrentValue(NasActor actor, String field) =>
      switch (field) {
        'stageName' => actor.stageName,
        'originalName' => actor.originalName,
        'translatedName' => actor.translatedName,
        'aliases' => actor.aliases,
        'gender' => actor.gender,
        'romanizedName' => actor.romanizedName,
        'birthDate' => actor.birthDate,
        'birthMonth' => actor.birthMonth,
        'heightCm' => actor.heightCm,
        'measurements' => actor.measurements,
        'country' => actor.country,
        'cup' => actor.cup,
        'birthplace' => actor.birthplace,
        'careerPeriod' => actor.careerPeriod,
        'debutMonth' => actor.debutMonth,
        'debutDescription' => actor.debutDescription,
        'accountUrl' => actor.accountUrl,
        'officialSiteUrl' => actor.officialSiteUrl,
        'photo' => actor.photoAssetId,
        'backdrop' => actor.backdropAssetId,
        _ => null,
      };

  Future<NasManagedAsset?> _saveMdcngActorImage(
    NasMdcngActorSourceImage image,
    String purpose,
  ) async {
    try {
      return await _assets.saveManagedImageBytes(
        purpose: purpose,
        bytes: await image.file.readAsBytes(),
        mimeType: image.mimeType,
      );
    } on FileSystemException {
      return null;
    }
  }
}

class _MdcngActorBatchPlan {
  const _MdcngActorBatchPlan({
    required this.record,
    required this.status,
    this.fields = const {},
    this.target,
  });

  final NasMdcngActorSourceRecord record;
  final String status;
  final Set<String> fields;
  final NasActor? target;

  bool get isEligible =>
      status == 'eligible_create' || status == 'eligible_update';
}

bool _mdcngActorHasValue(Object? value) => switch (value) {
      null => false,
      String text => text.trim().isNotEmpty,
      Iterable<dynamic> values => values.isNotEmpty,
      _ => true,
    };

String? _mdcngActorDiffDisplayValue(
  String field,
  Object? value, {
  required bool current,
}) {
  if (!_mdcngActorHasValue(value)) return null;
  if (current && (field == 'photo' || field == 'backdrop')) return '已有图片';
  if (value is Iterable) return value.join('、');
  return value.toString();
}

bool _mdcngActorValuesEqual(String field, Object? left, Object? right) {
  if (field == 'aliases' && left is Iterable && right is Iterable) {
    final normalize = (Iterable<dynamic> values) => values
        .whereType<String>()
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    final leftValues = normalize(left);
    final rightValues = normalize(right);
    return leftValues.length == rightValues.length &&
        leftValues.containsAll(rightValues);
  }
  return left == right;
}
