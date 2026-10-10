import 'dart:async';
import 'dart:io';

import '../artwork_service.dart';
import '../config.dart';
import '../library/profile_package.dart';
import '../library_database.dart';

import 'response.dart';
import 'validation.dart';
import 'artwork.dart';

/// Profile-package export and import workflows.
class NasProfilePackagesHttpApi {
  NasProfilePackagesHttpApi({
    required NasLibraryDatabase libraryDatabase,
    required NasArtworkService artworkService,
    required this.config,
    required NasArtworkHttpApi assets,
  })  : _libraryDatabase = libraryDatabase,
        _artworkService = artworkService,
        _assets = assets;
  final NasLibraryDatabase _libraryDatabase;
  final NasConfig config;
  final NasArtworkHttpApi _assets;
  final NasArtworkService _artworkService;

  Future<void> downloadProfilePackageTemplate(HttpRequest request) async {
    final kind = _profilePackageKind(request);
    if (kind == null)
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    await writeApiBinary(
      request.response,
      NasProfilePackageCodec.template(kind),
      fileName: 'mujing-${kind.wireValue}-template.zip',
    );
  }

  Future<void> exportProfilePackage(HttpRequest request) async {
    final kind = _profilePackageKind(request);
    if (kind == null)
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    try {
      final entries = switch (kind) {
        NasProfilePackageKind.actor => await _actorProfilePackageEntries(),
        NasProfilePackageKind.publisher =>
          await _publisherProfilePackageEntries(),
        NasProfilePackageKind.series => await _seriesProfilePackageEntries(),
      };
      await writeApiBinary(
        request.response,
        NasProfilePackageCodec.encode(kind: kind, entries: entries),
        fileName: 'mujing-${kind.wireValue}-profiles.zip',
      );
    } on Object {
      await writeApiError(
          request, HttpStatus.internalServerError, 'profile_package_failed');
    }
  }

  Future<void> importProfilePackage(HttpRequest request) async {
    final kind = _profilePackageKind(request);
    final bytes = await _readProfilePackageBytes(request);
    if (kind == null || bytes == null) {
      return writeApiError(
          request, HttpStatus.badRequest, 'invalid_profile_package');
    }
    final NasProfilePackage package;
    try {
      package = NasProfilePackageCodec.decode(expectedKind: kind, bytes: bytes);
    } on FormatException {
      return writeApiError(
          request, HttpStatus.badRequest, 'invalid_profile_package');
    }
    final items = <_ProfilePackageImportResult>[];
    for (final entry in package.entries) {
      final item = switch (kind) {
        NasProfilePackageKind.actor => await _importActorProfile(entry),
        NasProfilePackageKind.publisher => await _importPublisherProfile(entry),
        NasProfilePackageKind.series => await _importSeriesProfile(entry),
      };
      items.add(item);
    }
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': items.map((item) => item.toJson()).toList(growable: false)
      },
    });
  }

  Future<List<NasProfilePackageExportEntry>>
      _actorProfilePackageEntries() async {
    final entries = <NasProfilePackageExportEntry>[];
    for (final actor in _libraryDatabase.listActors(includeArchived: true)) {
      final image = await _profilePackageImage(actor.photoAssetId);
      final publisherNames = _libraryDatabase
          .publisherIdsForActor(actor.id)
          .map(_libraryDatabase.findPublisher)
          .whereType<NasPublisher>()
          .map((publisher) => publisher.displayName)
          .join('|');
      entries.add(
        NasProfilePackageExportEntry(
          directoryName: actor.profileIdentity,
          fields: {
            'stageName': actor.stageName ?? '',
            'originalName': actor.originalName ?? '',
            'translatedName': actor.translatedName ?? '',
            'aliases': actor.aliases.join('|'),
            'gender': actor.gender ?? '',
            'birthMonth': actor.birthMonth ?? '',
            'country': actor.country ?? '',
            'heightCm': actor.heightCm?.toString() ?? '',
            'weightKg': actor.weightKg?.toString() ?? '',
            'measurements': actor.measurements ?? '',
            'bodyType': actor.bodyType ?? '',
            'debutMonth': actor.debutMonth ?? '',
            'debutDescription': actor.debutDescription ?? '',
            'publisherNames': publisherNames,
          },
          imageBytes: image.bytes,
          imageMimeType: image.mimeType,
        ),
      );
    }
    return entries;
  }

  Future<List<NasProfilePackageExportEntry>>
      _publisherProfilePackageEntries() async {
    final entries = <NasProfilePackageExportEntry>[];
    for (final publisher
        in _libraryDatabase.listPublishers(includeArchived: true)) {
      final image = await _profilePackageImage(publisher.logoAssetId);
      entries.add(
        NasProfilePackageExportEntry(
          directoryName: publisher.profileIdentity,
          fields: {
            'displayName': publisher.displayName,
            'originalName': publisher.originalName ?? '',
            'countryRegion': publisher.countryRegion ?? '',
            'foundedDate': publisher.foundedDate ?? '',
          },
          imageBytes: image.bytes,
          imageMimeType: image.mimeType,
        ),
      );
    }
    return entries;
  }

  Future<List<NasProfilePackageExportEntry>>
      _seriesProfilePackageEntries() async {
    final entries = <NasProfilePackageExportEntry>[];
    for (final series in _libraryDatabase.listSeries(includeArchived: true)) {
      final image = await _profilePackageImage(series.posterAssetId);
      final publisher = series.publisherId == null
          ? null
          : _libraryDatabase.findPublisher(series.publisherId!);
      entries.add(
        NasProfilePackageExportEntry(
          directoryName: series.profileIdentity,
          fields: {
            'displayName': series.displayName,
            'originalName': series.originalName ?? '',
            'translatedName': series.translatedName ?? '',
            'releaseDate': series.releaseDate ?? '',
            'publisherName': publisher?.displayName ?? '',
          },
          imageBytes: image.bytes,
          imageMimeType: image.mimeType,
        ),
      );
    }
    return entries;
  }

  Future<_ProfilePackageImage> _profilePackageImage(String? assetId) async {
    if (assetId == null) return const _ProfilePackageImage();
    final asset = _libraryDatabase.findManagedAsset(assetId);
    final artwork = asset == null
        ? null
        : await _artworkService.managedAsset(asset.fileName);
    if (artwork == null) return const _ProfilePackageImage();
    return _ProfilePackageImage(
      bytes: await artwork.file.readAsBytes(),
      mimeType: artwork.mimeType,
    );
  }

  Future<_ProfilePackageImportResult> _importActorProfile(
    NasProfilePackageEntry entry,
  ) async {
    if (entry.validationError != null)
      return _profileFailure(entry, entry.validationError!);
    final fields = entry.fields;
    final aliases = nasProfileList(fields['aliases']);
    final displayName = nasFirstProfileText([
      fields['stageName'],
      fields['originalName'],
      fields['translatedName'],
      ...aliases,
    ]);
    if (displayName == null) return _profileFailure(entry, '演员缺少可用名称。');
    if (_libraryDatabase.actorDisplayNameExists(displayName)) {
      return _profileSkipped(entry, displayName, '同名演员已存在，已跳过。');
    }
    final publisherIds = <String>[];
    for (final publisherName in nasProfileList(fields['publisherNames'])) {
      final publisher =
          _libraryDatabase.findPublisherByDisplayName(publisherName);
      if (publisher == null || publisher.archivedAt != null) {
        return _profileFailure(entry, '引用的发行商名称不存在。');
      }
      publisherIds.add(publisher.id);
    }
    if (publisherIds.length != publisherIds.toSet().length) {
      return _profileFailure(entry, '发行商名称重复。');
    }
    NasManagedAsset? asset;
    NasActor? actor;
    try {
      asset = await _assets.saveManagedImageBytes(
        purpose: 'actor_photo',
        bytes: entry.imageBytes,
        mimeType: entry.imageMimeType,
      );
      if (entry.imageBytes != null && asset == null) {
        return _profileFailure(entry, '演员海报保存失败。');
      }
      actor = _libraryDatabase.createActor(
        stageName: nasNullableTrimmed(fields['stageName']),
        originalName: nasNullableTrimmed(fields['originalName']),
        translatedName: nasNullableTrimmed(fields['translatedName']),
        aliases: aliases,
        gender: nasNullableTrimmed(fields['gender']),
        birthMonth: nasNullableTrimmed(fields['birthMonth']),
        country: nasNullableTrimmed(fields['country']),
        heightCm: int.tryParse(fields['heightCm'] ?? ''),
        weightKg: int.tryParse(fields['weightKg'] ?? ''),
        measurements: nasNullableTrimmed(fields['measurements']),
        bodyType: nasNullableTrimmed(fields['bodyType']),
        debutMonth: nasNullableTrimmed(fields['debutMonth']),
        debutDescription: nasNullableTrimmed(fields['debutDescription']),
        photoAssetId: asset?.id,
      );
      if (!_libraryDatabase.setActorPublisherIds(
        actorId: actor.id,
        publisherIds: publisherIds,
      )) {
        _libraryDatabase.deleteActor(actor.id);
        await _assets.deleteManagedAsset(asset);
        return _profileFailure(entry, '演员与发行商关系保存失败。');
      }
      return _profileAdded(entry, displayName);
    } on Object {
      if (actor != null) _libraryDatabase.deleteActor(actor.id);
      await _assets.deleteManagedAsset(asset);
      return _profileFailure(entry, '演员资料写入失败。');
    }
  }

  Future<_ProfilePackageImportResult> _importPublisherProfile(
    NasProfilePackageEntry entry,
  ) async {
    if (entry.validationError != null)
      return _profileFailure(entry, entry.validationError!);
    final fields = entry.fields;
    final displayName = fields['displayName']!.trim();
    if (_libraryDatabase.publisherDisplayNameExists(displayName)) {
      return _profileSkipped(entry, displayName, '同名发行商已存在，已跳过。');
    }
    NasManagedAsset? asset;
    try {
      asset = await _assets.saveManagedImageBytes(
        purpose: 'publisher_logo',
        bytes: entry.imageBytes,
        mimeType: entry.imageMimeType,
      );
      if (entry.imageBytes != null && asset == null) {
        return _profileFailure(entry, '发行商 Logo 保存失败。');
      }
      _libraryDatabase.createPublisher(
        displayName: displayName,
        originalName: nasNullableTrimmed(fields['originalName']),
        countryRegion: nasNullableTrimmed(fields['countryRegion']),
        foundedDate: nasNullableTrimmed(fields['foundedDate']),
        logoAssetId: asset?.id,
      );
      return _profileAdded(entry, displayName);
    } on Object {
      await _assets.deleteManagedAsset(asset);
      return _profileFailure(entry, '发行商资料写入失败。');
    }
  }

  Future<_ProfilePackageImportResult> _importSeriesProfile(
    NasProfilePackageEntry entry,
  ) async {
    if (entry.validationError != null)
      return _profileFailure(entry, entry.validationError!);
    final fields = entry.fields;
    final displayName = fields['displayName']!.trim();
    if (_libraryDatabase.seriesDisplayNameExists(displayName)) {
      return _profileSkipped(entry, displayName, '同名系列已存在，已跳过。');
    }
    final publisherName = nasNullableTrimmed(fields['publisherName']);
    final publisher = publisherName == null
        ? null
        : _libraryDatabase.findPublisherByDisplayName(publisherName);
    if (publisherName != null &&
        (publisher == null || publisher.archivedAt != null)) {
      return _profileFailure(entry, '引用的发行商名称不存在。');
    }
    NasManagedAsset? asset;
    try {
      asset = await _assets.saveManagedImageBytes(
        purpose: 'series_poster',
        bytes: entry.imageBytes,
        mimeType: entry.imageMimeType,
      );
      if (entry.imageBytes != null && asset == null) {
        return _profileFailure(entry, '系列海报保存失败。');
      }
      _libraryDatabase.createSeries(
        displayName: displayName,
        originalName: nasNullableTrimmed(fields['originalName']),
        translatedName: nasNullableTrimmed(fields['translatedName']),
        releaseDate: nasNullableTrimmed(fields['releaseDate']),
        publisherId: publisher?.id,
        posterAssetId: asset?.id,
      );
      return _profileAdded(entry, displayName);
    } on Object {
      await _assets.deleteManagedAsset(asset);
      return _profileFailure(entry, '系列资料写入失败。');
    }
  }

  NasProfilePackageKind? _profilePackageKind(HttpRequest request) =>
      request.uri.pathSegments.length > 4
          ? NasProfilePackageKind.tryParse(request.uri.pathSegments[4])
          : null;

  Future<List<int>?> _readProfilePackageBytes(HttpRequest request) async {
    if (request.headers.contentType?.mimeType != 'application/zip' ||
        request.headers.contentLength >
            NasProfilePackageCodec.maxPackageBytes) {
      await request.drain<void>();
      return null;
    }
    final bytes = <int>[];
    var oversized = false;
    await for (final chunk in request) {
      if (oversized) continue;
      if (bytes.length + chunk.length >
          NasProfilePackageCodec.maxPackageBytes) {
        oversized = true;
      } else {
        bytes.addAll(chunk);
      }
    }
    return oversized ? null : bytes;
  }

  _ProfilePackageImportResult _profileAdded(
    NasProfilePackageEntry entry,
    String name,
  ) =>
      _ProfilePackageImportResult(entry.directoryName, name, 'added', '已新增。');

  _ProfilePackageImportResult _profileSkipped(
    NasProfilePackageEntry entry,
    String name,
    String reason,
  ) =>
      _ProfilePackageImportResult(entry.directoryName, name, 'skipped', reason);

  _ProfilePackageImportResult _profileFailure(
    NasProfilePackageEntry entry,
    String reason,
  ) =>
      _ProfilePackageImportResult(
          entry.directoryName, entry.directoryName, 'failed', reason);
}

class _ProfilePackageImage {
  const _ProfilePackageImage({this.bytes, this.mimeType});

  final List<int>? bytes;
  final String? mimeType;
}

class _ProfilePackageImportResult {
  const _ProfilePackageImportResult(
    this.directoryName,
    this.name,
    this.status,
    this.reason,
  );

  final String directoryName;
  final String name;
  final String status;
  final String reason;

  Map<String, Object?> toJson() => {
        'directoryName': directoryName,
        'name': name,
        'status': status,
        'reason': reason,
      };
}
