import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:xml/xml.dart';

import '../auth.dart';

/// Read-only view of MDCNG's actor files.  This deliberately reads only the
/// `config/data` mount and never opens MDCNG's config.json or writes back to
/// its databases or photo cache.
class NasMdcngActorSource {
  NasMdcngActorSource(this.dataDir);

  final String dataDir;
  static const _snapshotLifetime = Duration(minutes: 2);
  Future<_MdcngActorSnapshot>? _snapshotRead;
  _MdcngActorSnapshot? _snapshot;
  DateTime? _snapshotAt;

  /// A cheap readiness probe for server-info. It deliberately exposes only a
  /// stable reason code, never the administrator's source path or file names.
  Future<NasMdcngActorSourceAvailability> checkAvailability() async {
    final root = Directory(dataDir);
    if (!await root.exists()) {
      return const NasMdcngActorSourceAvailability.unavailable(
        'mdcng_actor_directory_unavailable',
      );
    }
    final taskFile = File(_path('mdc_ng.db'));
    if (!await taskFile.exists()) {
      return const NasMdcngActorSourceAvailability.unavailable(
        'mdcng_actor_database_files_missing',
      );
    }
    try {
      final taskHandle = await taskFile.open(mode: FileMode.read);
      await taskHandle.close();
    } on FileSystemException {
      return const NasMdcngActorSourceAvailability.unavailable(
        'mdcng_actor_database_files_unreadable',
      );
    }
    return const NasMdcngActorSourceAvailability.available();
  }

  Future<List<NasMdcngActorSourceRecord>> readCompletedActors({
    Map<String, String> selectedProfileKeys = const {},
    bool forceRefresh = false,
  }) async {
    final snapshot = await _loadSnapshot(forceRefresh: forceRefresh);
    return snapshot.tasks
        .map(
          (task) => _recordFor(
            task: task,
            lookup: snapshot.lookup,
            selectedProfileKey: selectedProfileKeys[task.id],
          ),
        )
        .toList(growable: false);
  }

  Future<_MdcngActorSnapshot> _loadSnapshot(
      {required bool forceRefresh}) async {
    final cached = _snapshot;
    final checkedAt = _snapshotAt;
    if (!forceRefresh &&
        cached != null &&
        checkedAt != null &&
        DateTime.now().difference(checkedAt) < _snapshotLifetime) {
      return cached;
    }
    final reading = _snapshotRead;
    if (reading != null) return reading;
    final next = _readSnapshot();
    _snapshotRead = next;
    try {
      final result = await next;
      _snapshot = result;
      _snapshotAt = DateTime.now();
      return result;
    } finally {
      _snapshotRead = null;
    }
  }

  Future<_MdcngActorSnapshot> _readSnapshot() async {
    final root = Directory(dataDir);
    if (!await root.exists()) {
      throw const NasMdcngActorSourceException('source_unavailable');
    }
    final taskFile = File(_path('mdc_ng.db'));
    final actressFile = File(_path('Actress.db'));
    if (!await taskFile.exists()) {
      throw const NasMdcngActorSourceException('source_incomplete');
    }

    final tasks = _readTasks(taskFile.path);
    final imageFiles = await _readImages();
    final mappings = await _readNameMappings();
    // Feiniu's bind-mounted ACL filesystem can allow raw reads while SQLite's
    // VFS still rejects a direct read-only database open (it probes journal and
    // lock side files next to the database).  Query a short-lived local copy
    // instead.  The source directory remains entirely read-only.
    final profiles = await actressFile.exists()
        ? await _readProfilesSnapshot(actressFile)
        : const <_MdcngProfile>[];
    return _MdcngActorSnapshot(
      tasks,
      _MdcngActorLookup(profiles, imageFiles, mappings),
    );
  }

  String _path(String name) => '$dataDir${Platform.pathSeparator}$name';

  List<_MdcngTask> _readTasks(String databasePath) {
    Database? database;
    try {
      database = sqlite3.open(databasePath, mode: OpenMode.readOnly);
      final columns = database
          .select('PRAGMA table_info(actress_task)')
          .map((row) => row['name'] as String)
          .toSet();
      final overviewColumn =
          columns.contains('overview') ? 'overview' : 'NULL AS overview';
      return database
          .select('''
            SELECT id, name, emby_id, year, has_pic, has_backdrop, end_at,
                   $overviewColumn
            FROM actress_task
            WHERE status = 2 AND stage >= 1000
            ORDER BY end_at DESC, id DESC
          ''')
          .map(
            (row) => _MdcngTask(
              id: (row['id'] as int).toString(),
              displayName: _text(row['name']) ?? '未命名演员',
              embyId: _text(row['emby_id']),
              year: row['year'] as int?,
              hasPhoto: (row['has_pic'] as int? ?? 0) != 0,
              hasBackdrop: (row['has_backdrop'] as int? ?? 0) != 0,
              completedAt: _text(row['end_at']),
              overview: _text(row['overview']),
            ),
          )
          .where((task) => task.embyId != null)
          .toList(growable: false);
    } on SqliteException catch (error) {
      throw NasMdcngActorSourceException(
        'source_unreadable',
        sqliteExtendedResultCode: error.extendedResultCode,
        sqliteOperation: error.operation,
      );
    } finally {
      database?.dispose();
    }
  }

  Future<List<_MdcngProfile>> _readProfilesSnapshot(File sourceFile) async {
    final directory = await Directory.systemTemp.createTemp(
      'mujing-mdcng-actress-',
    );
    final snapshot =
        File('${directory.path}${Platform.pathSeparator}Actress.db');
    try {
      // Do not use File.copy here: on Feiniu it preserves MDCNG's `000` POSIX
      // mode while dropping the source ACL.  A stream-created file inherits
      // the current process' normal umask and can therefore be opened by
      // SQLite under the same read-only service account.
      await sourceFile.openRead().pipe(snapshot.openWrite());
      return _readProfiles(snapshot.path);
    } on FileSystemException {
      throw const NasMdcngActorSourceException('profile_database_unreadable');
    } finally {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }

  List<_MdcngProfile> _readProfiles(String databasePath) {
    Database? database;
    try {
      database = sqlite3.open(databasePath, mode: OpenMode.readOnly);
      final aliasesByName = <String, List<String>>{};
      for (final row in database.select('SELECT Alias, Name FROM Names')) {
        final alias = _text(row['Alias']);
        final name = _text(row['Name']);
        if (alias == null || name == null) continue;
        aliasesByName.putIfAbsent(name, () => <String>[]).add(alias);
      }
      return database
          .select('''
            SELECT Name, Roma, Href, Birthday, Height, Bust, Waist, Hip, Cup,
                   Birthplace, CareerPeriod, DebutWork, Account, OfficialSite,
                   UpdateTime, Completeness
            FROM Info
          ''')
          .map(
            (row) => _MdcngProfile(
              name: _text(row['Name'])!,
              roma: _text(row['Roma']),
              href: _text(row['Href']) ?? '',
              birthday: _text(row['Birthday']),
              heightCm: row['Height'] as int?,
              bust: row['Bust'] as int?,
              waist: row['Waist'] as int?,
              hip: row['Hip'] as int?,
              cup: _text(row['Cup']),
              birthplace: _text(row['Birthplace']),
              careerPeriod: _text(row['CareerPeriod']),
              debutWork: _text(row['DebutWork']),
              accountUrl: _text(row['Account']),
              officialSiteUrl: _text(row['OfficialSite']),
              updatedAt: _text(row['UpdateTime']),
              completeness: row['Completeness'] as int?,
              aliases: aliasesByName[_text(row['Name'])!] ?? const <String>[],
            ),
          )
          .toList(growable: false);
    } on SqliteException catch (error) {
      throw NasMdcngActorSourceException(
        'profile_database_unreadable',
        sqliteExtendedResultCode: error.extendedResultCode,
        sqliteOperation: error.operation,
      );
    } finally {
      database?.dispose();
    }
  }

  Future<List<File>> _readImages() async {
    final directory = Directory(_path('photos'));
    if (!await directory.exists()) return const <File>[];
    final images = <File>[];
    await for (final entry
        in directory.list(recursive: true, followLinks: false)) {
      if (entry is! File || !_isImageFile(entry.path)) continue;
      images.add(entry);
    }
    images.sort((left, right) => left.path.compareTo(right.path));
    return images;
  }

  Future<List<_MdcngActorNameMapping>> _readNameMappings() async {
    final file = File(_path('mapping_actor.xml'));
    if (!await file.exists()) return const [];
    final document = XmlDocument.parse(await file.readAsString());
    return document
        .findAllElements('a')
        .map((element) {
          final names = <String>{
            ...['zh_cn', 'zh_tw', 'jp']
                .map(element.getAttribute)
                .whereType<String>(),
            ...?element.getAttribute('keyword')?.split(','),
          }
              .map((name) => name.trim())
              .where((name) => name.isNotEmpty)
              .toList();
          return _MdcngActorNameMapping(names, element.getAttribute('jp'));
        })
        .where((mapping) => mapping.names.isNotEmpty)
        .toList(growable: false);
  }

  NasMdcngActorSourceRecord _recordFor({
    required _MdcngTask task,
    required _MdcngActorLookup lookup,
    required String? selectedProfileKey,
  }) {
    final normalizedName = _normalizeName(task.displayName);
    final exactMatches =
        lookup.exactProfiles[normalizedName] ?? const <_MdcngProfile>[];
    final automaticMatches = exactMatches.isNotEmpty
        ? exactMatches
        : lookup.profilesForOverview(task.overview);
    final suggestions = automaticMatches.isNotEmpty
        ? automaticMatches
        : (normalizedName.runes.length < 2
                ? const <_MdcngProfile>[]
                : lookup.prefixProfiles[_namePrefix(normalizedName)] ??
                    const <_MdcngProfile>[])
            .take(12)
            .toList(growable: false);
    final selectedMatches = selectedProfileKey == null
        ? const <_MdcngProfile>[]
        : lookup.profilesByKey[selectedProfileKey] ?? const <_MdcngProfile>[];
    // A manual choice is never made by fuzzy matching: it must be the exact
    // canonical name from Actress.db and must identify one profile.
    final resolved = selectedMatches.length == 1
        ? selectedMatches.single
        : automaticMatches.length == 1
            ? automaticMatches.single
            : null;
    final mappedNames = lookup.namesForTask(task.displayName);
    final taskNames =
        {task.displayName, ...mappedNames}.map(_normalizeName).toSet();
    final manualProfileDiffers = selectedMatches.length == 1 &&
        ![selectedMatches.single.name, ...selectedMatches.single.aliases]
            .map(_normalizeName)
            .any(taskNames.contains);
    final imageNames = <String>[
      if (resolved != null) resolved.name,
      ...?resolved?.aliases,
      if (!manualProfileDiffers) ...mappedNames,
      if (!manualProfileDiffers) task.displayName,
    ];
    final images = _imagesForNames(
      imageNames,
      lookup,
    );
    final fingerprint = sha256Hex(
      jsonEncode({
        // Bump when the set of NAS-owned fields derived from one unchanged
        // MDCNG snapshot changes.  This lets already-imported actors receive
        // newly supported blank fields through the same safe update flow.
        'importSchema': 3,
        'taskId': task.id,
        'embyId': task.embyId,
        'name': task.displayName,
        'profileHref': resolved?.href,
        'profileUpdate': resolved?.updatedAt,
        'sourceHasPhoto': task.hasPhoto,
        'sourceHasBackdrop': task.hasBackdrop,
        'overview': task.overview,
        'mappedNames': mappedNames,
        'images': images
            .map((image) => '${image.fileName}:${image.byteLength}')
            .toList(growable: false),
      }),
    );
    return NasMdcngActorSourceRecord(
      taskId: task.id,
      embyId: task.embyId!,
      sourceName: task.displayName,
      year: task.year,
      completedAt: task.completedAt,
      hasPhoto: task.hasPhoto,
      hasBackdrop: task.hasBackdrop,
      selectedProfileKey:
          selectedMatches.length == 1 ? selectedProfileKey : null,
      profile: resolved == null
          ? null
          : NasMdcngActorProfile(
              key: resolved.key,
              name: resolved.name,
              roma: resolved.roma,
              birthday: resolved.birthday,
              heightCm: resolved.heightCm,
              bust: resolved.bust,
              waist: resolved.waist,
              hip: resolved.hip,
              cup: resolved.cup,
              birthplace: resolved.birthplace,
              careerPeriod: resolved.careerPeriod,
              debutWork: resolved.debutWork,
              accountUrl: resolved.accountUrl,
              officialSiteUrl: resolved.officialSiteUrl,
              updatedAt: resolved.updatedAt,
              completeness: resolved.completeness,
              aliases: _uniqueText(resolved.aliases),
              country: _countryForBirthplace(resolved.birthplace),
            ),
      // A profile match is optional. When it is absent, the task can still be
      // imported with its MDCNG name and locally indexed images.
      profileResolution: resolved != null ? 'matched' : 'raw',
      candidates: suggestions
          .map(
            (profile) => NasMdcngActorProfileCandidate(
              key: profile.key,
              name: profile.name,
              romanizedName: profile.roma,
              hasPhoto: _hasPhotoForName(
                profile.name,
                lookup.imageFilesByPrefix[
                        _namePrefix(_normalizeImageName(profile.name))] ??
                    const <File>[],
              ),
              missingFieldCount: _missingCandidateFieldCount(profile),
            ),
          )
          .toList(growable: false),
      images: images,
      fingerprint: fingerprint,
    );
  }

  List<NasMdcngActorSourceImage> _imagesForNames(
    Iterable<String> names,
    _MdcngActorLookup lookup,
  ) {
    final result = <NasMdcngActorSourceImage>[];
    final seen = <String>{};
    for (final name in names) {
      final normalizedName = _normalizeImageName(name);
      if (normalizedName.isEmpty) continue;
      final imageFiles =
          lookup.imageFilesByPrefix[_namePrefix(normalizedName)] ??
              const <File>[];
      for (final file in imageFiles) {
        final fileName = file.uri.pathSegments.last;
        if (!seen.add(file.path)) continue;
        final baseName = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
        if (!_imageNameMatches(baseName, normalizedName)) {
          seen.remove(file.path);
          continue;
        }
        final isBackdrop = _isBackdropImageName(baseName);
        result.add(
          NasMdcngActorSourceImage(
            file: file,
            fileName: fileName,
            kind: isBackdrop ? 'backdrop' : 'photo',
            mimeType: _mimeTypeForPath(file.path)!,
            byteLength: lookup.imageLength(file),
          ),
        );
      }
    }
    return result;
  }

  bool _hasPhotoForName(String name, List<File> imageFiles) {
    final normalizedName = _normalizeImageName(name);
    for (final file in imageFiles) {
      final fileName = file.uri.pathSegments.last;
      final baseName = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
      if (_imageNameMatches(baseName, normalizedName) &&
          !_isBackdropImageName(baseName)) {
        return true;
      }
    }
    return false;
  }

  int _missingCandidateFieldCount(_MdcngProfile profile) => <Object?>[
        profile.roma,
        profile.birthday,
        profile.heightCm,
        profile.bust,
        profile.waist,
        profile.hip,
        profile.cup,
        profile.birthplace,
        profile.careerPeriod,
        profile.debutWork,
        profile.accountUrl,
        profile.officialSiteUrl,
      ]
          .where((value) => value == null || value is String && value.isEmpty)
          .length;
}

class _MdcngActorSnapshot {
  const _MdcngActorSnapshot(this.tasks, this.lookup);

  final List<_MdcngTask> tasks;
  final _MdcngActorLookup lookup;
}

class _MdcngActorNameMapping {
  const _MdcngActorNameMapping(this.names, this.jpName);

  final List<String> names;
  final String? jpName;
}

class _MdcngActorLookup {
  _MdcngActorLookup(
    List<_MdcngProfile> profiles,
    List<File> imageFiles,
    List<_MdcngActorNameMapping> mappings,
  ) {
    for (final mapping in mappings) {
      final seen = <String>{};
      for (final name in mapping.names) {
        final normalized = _normalizeName(name);
        if (normalized.isEmpty || !seen.add(normalized)) continue;
        mappingsByName.putIfAbsent(normalized, () => []).add(mapping);
      }
    }
    for (final profile in profiles) {
      profilesByKey.putIfAbsent(profile.key, () => []).add(profile);
      for (final name in [profile.name, ...profile.aliases]) {
        final normalized = _normalizeName(name);
        if (normalized.isEmpty) continue;
        exactProfiles.putIfAbsent(normalized, () => []).add(profile);
        if (normalized.runes.length >= 2) {
          prefixProfiles
              .putIfAbsent(_namePrefix(normalized), () => [])
              .add(profile);
        }
      }
      for (final url in [profile.accountUrl, profile.officialSiteUrl]) {
        final key = _externalUrlKey(url);
        if (key == null) continue;
        profilesByExternalUrl.putIfAbsent(key, () => []).add(profile);
      }
    }
    for (final entry in exactProfiles.entries) {
      exactProfiles[entry.key] = _distinctProfiles(entry.value);
    }
    for (final entry in prefixProfiles.entries) {
      prefixProfiles[entry.key] = _distinctProfiles(entry.value);
    }
    for (final file in imageFiles) {
      final fileName = file.uri.pathSegments.last;
      final baseName = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
      final normalized = _normalizeImageName(baseName);
      if (normalized.isEmpty) continue;
      imageFilesByPrefix
          .putIfAbsent(_namePrefix(normalized), () => [])
          .add(file);
      if (normalized.runes.length >= 2) {
        imageFilesByPrefix
            .putIfAbsent(
              String.fromCharCodes(normalized.runes.take(1)),
              () => [],
            )
            .add(file);
      }
    }
  }

  final Map<String, List<_MdcngProfile>> exactProfiles = {};
  final Map<String, List<_MdcngProfile>> prefixProfiles = {};
  final Map<String, List<_MdcngProfile>> profilesByKey = {};
  final Map<String, List<_MdcngProfile>> profilesByExternalUrl = {};
  final Map<String, List<_MdcngActorNameMapping>> mappingsByName = {};
  final Map<String, List<File>> imageFilesByPrefix = {};
  final Map<String, int> _imageLengths = {};

  List<String> namesForTask(String name) {
    final matches = mappingsByName[_normalizeName(name)];
    if (matches == null || matches.length != 1) return const [];
    final mapping = matches.single;
    return mapping.names.where((candidate) {
      final normalized = _normalizeName(candidate);
      final owners = mappingsByName[normalized];
      if (owners == null) return false;
      if (owners.length == 1) return identical(owners.single, mapping);
      return owners.every((owner) =>
          owner.jpName != null && _normalizeName(owner.jpName!) == normalized);
    }).toList(growable: false);
  }

  int imageLength(File file) =>
      _imageLengths.putIfAbsent(file.path, file.lengthSync);

  List<_MdcngProfile> profilesForOverview(String? overview) {
    if (overview == null || overview.isEmpty) {
      return const <_MdcngProfile>[];
    }
    final matches = <String, _MdcngProfile>{};
    for (final url in _extractExternalUrls(overview)) {
      final key = _externalUrlKey(url);
      if (key == null) continue;
      for (final profile in profilesByExternalUrl[key] ?? const []) {
        matches[profile.href] = profile;
      }
    }
    return matches.values.toList(growable: false);
  }
}

class NasMdcngActorSourceAvailability {
  const NasMdcngActorSourceAvailability._(this.isAvailable, this.reason);

  const NasMdcngActorSourceAvailability.available() : this._(true, 'available');

  const NasMdcngActorSourceAvailability.unavailable(String reason)
      : this._(false, reason);

  final bool isAvailable;
  final String reason;
}

class NasMdcngActorSourceException implements Exception {
  const NasMdcngActorSourceException(
    this.code, {
    this.sqliteExtendedResultCode,
    this.sqliteOperation,
  });

  final String code;
  final int? sqliteExtendedResultCode;
  final String? sqliteOperation;
}

class NasMdcngActorSourceRecord {
  const NasMdcngActorSourceRecord({
    required this.taskId,
    required this.embyId,
    required this.sourceName,
    required this.year,
    required this.completedAt,
    required this.hasPhoto,
    required this.hasBackdrop,
    required this.selectedProfileKey,
    required this.profile,
    required this.profileResolution,
    required this.candidates,
    required this.images,
    required this.fingerprint,
  });

  final String taskId;
  final String embyId;
  final String sourceName;
  final int? year;
  final String? completedAt;
  final bool hasPhoto;
  final bool hasBackdrop;
  final String? selectedProfileKey;
  final NasMdcngActorProfile? profile;
  final String profileResolution;
  final List<NasMdcngActorProfileCandidate> candidates;
  final List<NasMdcngActorSourceImage> images;
  final String fingerprint;

  NasMdcngActorSourceImage? get photo =>
      images.where((image) => image.kind == 'photo').firstOrNull;
  NasMdcngActorSourceImage? get backdrop =>
      images.where((image) => image.kind == 'backdrop').firstOrNull;
}

class NasMdcngActorProfile {
  const NasMdcngActorProfile({
    required this.key,
    required this.name,
    required this.roma,
    required this.birthday,
    required this.heightCm,
    required this.bust,
    required this.waist,
    required this.hip,
    required this.cup,
    required this.birthplace,
    required this.country,
    required this.careerPeriod,
    required this.debutWork,
    required this.accountUrl,
    required this.officialSiteUrl,
    required this.updatedAt,
    required this.completeness,
    required this.aliases,
  });

  final String key;
  final String name;
  final String? roma;
  final String? birthday;
  final int? heightCm;
  final int? bust;
  final int? waist;
  final int? hip;
  final String? cup;
  final String? birthplace;
  final String? country;
  final String? careerPeriod;
  final String? debutWork;
  final String? accountUrl;
  final String? officialSiteUrl;
  final String? updatedAt;
  final int? completeness;
  final List<String> aliases;

  String? get birthMonth => birthday == null || birthday!.length < 7
      ? null
      : birthday!.substring(0, 7);

  String? get debutMonth {
    final value = debutWork;
    if (value == null) return null;
    final match = RegExp(r'(\d{4})年\s*(\d{1,2})月').firstMatch(value);
    if (match == null) return null;
    final month = int.tryParse(match.group(2) ?? '');
    if (month == null || month < 1 || month > 12) return null;
    return '${match.group(1)}-${month.toString().padLeft(2, '0')}';
  }

  String? get measurements {
    if (bust == null && waist == null && hip == null) return null;
    return [
      if (bust != null) 'B$bust',
      if (waist != null) 'W$waist',
      if (hip != null) 'H$hip',
    ].join(' / ');
  }
}

class NasMdcngActorProfileCandidate {
  const NasMdcngActorProfileCandidate({
    required this.key,
    required this.name,
    required this.romanizedName,
    required this.hasPhoto,
    required this.missingFieldCount,
  });

  final String key;
  final String name;
  final String? romanizedName;
  final bool hasPhoto;
  final int missingFieldCount;
}

class NasMdcngActorSourceImage {
  const NasMdcngActorSourceImage({
    required this.file,
    required this.fileName,
    required this.kind,
    required this.mimeType,
    required this.byteLength,
  });

  final File file;
  final String fileName;
  final String kind;
  final String mimeType;
  final int byteLength;
}

class _MdcngTask {
  const _MdcngTask({
    required this.id,
    required this.displayName,
    required this.embyId,
    required this.year,
    required this.hasPhoto,
    required this.hasBackdrop,
    required this.completedAt,
    required this.overview,
  });

  final String id;
  final String displayName;
  final String? embyId;
  final int? year;
  final bool hasPhoto;
  final bool hasBackdrop;
  final String? completedAt;
  final String? overview;
}

class _MdcngProfile {
  const _MdcngProfile({
    required this.name,
    required this.roma,
    required this.href,
    required this.birthday,
    required this.heightCm,
    required this.bust,
    required this.waist,
    required this.hip,
    required this.cup,
    required this.birthplace,
    required this.careerPeriod,
    required this.debutWork,
    required this.accountUrl,
    required this.officialSiteUrl,
    required this.updatedAt,
    required this.completeness,
    required this.aliases,
  });

  final String name;
  final String? roma;
  final String href;
  final String? birthday;
  final int? heightCm;
  final int? bust;
  final int? waist;
  final int? hip;
  final String? cup;
  final String? birthplace;
  final String? careerPeriod;
  final String? debutWork;
  final String? accountUrl;
  final String? officialSiteUrl;
  final String? updatedAt;
  final int? completeness;
  final List<String> aliases;

  String get key => sha256Hex('mdcng-actress:${href.isEmpty ? name : href}');
}

String? _text(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

bool _isImageFile(String path) => _mimeTypeForPath(path) != null;

Iterable<String> _extractExternalUrls(String value) sync* {
  final matches = RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false)
      .allMatches(value);
  for (final match in matches) {
    final url = match.group(0);
    if (url != null && url.isNotEmpty) yield url;
  }
}

String? _externalUrlKey(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  final uri = Uri.tryParse(text);
  final host = uri?.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  if (host == null || host.isEmpty) return null;
  final path = uri!.path.toLowerCase().replaceFirst(RegExp(r'/+$'), '');
  if (path.isEmpty) return null;
  final query = uri.queryParameters.entries
      .where((entry) => entry.key.toLowerCase() != 'utm_source')
      .map((entry) => '${entry.key.toLowerCase()}=${entry.value.toLowerCase()}')
      .toList()
    ..sort();
  return '$host$path${query.isEmpty ? '' : '?${query.join('&')}'}';
}

String? _mimeTypeForPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  return null;
}

String _normalizeName(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll('凉', '涼')
    .replaceAll(RegExp(r'[\s·・._-]'), '');

String _normalizeImageName(String value) {
  // MDCNG's optional AI repair cache prefixes the actor name with
  // `AI-Fix-`; that prefix is metadata, not part of the actor identity.
  final withoutGeneratedPrefix = value.replaceFirst(
    RegExp(r'^ai[-_ ]?fix[-_ ]?', caseSensitive: false),
    '',
  );
  return _normalizeName(withoutGeneratedPrefix);
}

bool _isBackdropImageName(String baseName) =>
    RegExp(r'[-_. ]big(?:[-_. ]old)?$', caseSensitive: false)
        .hasMatch(baseName);

bool _imageNameMatches(String baseName, String normalizedName) {
  if (normalizedName.isEmpty) return false;
  final normalizedBase = _normalizeImageName(baseName);
  if (normalizedBase == normalizedName) return true;
  final suffix = normalizedBase.startsWith(normalizedName)
      ? normalizedBase.substring(normalizedName.length)
      : '';
  return RegExp(r'^(?:old|big|bigold|\d+)$').hasMatch(suffix);
}

String _namePrefix(String normalized) =>
    String.fromCharCodes(normalized.runes.take(2));

/// Actress.db has no explicit country column.  Derive only the country we can
/// identify confidently from a Japanese prefecture-style birthplace; leave all
/// other entries empty rather than guessing.
String? _countryForBirthplace(String? birthplace) {
  final value = birthplace?.trim();
  if (value == null || value.isEmpty) return null;
  return RegExp(r'(?:東京都|北海道|(?:京都|大阪)府|.+県)$').hasMatch(value) ? '日本' : null;
}

List<_MdcngProfile> _distinctProfiles(List<_MdcngProfile> profiles) {
  final seen = <String>{};
  return profiles
      .where((profile) => seen.add(profile.href))
      .toList(growable: false);
}

List<String> _uniqueText(Iterable<String> values) {
  final seen = <String>{};
  return values
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty && seen.add(value))
      .toList(growable: false);
}
