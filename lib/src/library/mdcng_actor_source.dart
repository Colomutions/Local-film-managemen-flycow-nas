import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';

/// Read-only view of MDCNG's actor files.  This deliberately reads only the
/// `config/data` mount and never opens MDCNG's config.json or writes back to
/// its databases or photo cache.
class NasMdcngActorSource {
  NasMdcngActorSource(this.dataDir);

  final String dataDir;
  static const _snapshotLifetime = Duration(seconds: 30);
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
    final actressFile = File(_path('Actress.db'));
    if (!await taskFile.exists() || !await actressFile.exists()) {
      return const NasMdcngActorSourceAvailability.unavailable(
        'mdcng_actor_database_files_missing',
      );
    }
    try {
      final taskHandle = await taskFile.open(mode: FileMode.read);
      await taskHandle.close();
      final actressHandle = await actressFile.open(mode: FileMode.read);
      await actressHandle.close();
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
    if (!await taskFile.exists() || !await actressFile.exists()) {
      throw const NasMdcngActorSourceException('source_incomplete');
    }

    final tasks = _readTasks(taskFile.path);
    final imageFiles = await _readImages();
    // Feiniu's bind-mounted ACL filesystem can allow raw reads while SQLite's
    // VFS still rejects a direct read-only database open (it probes journal and
    // lock side files next to the database).  Query a short-lived local copy
    // instead.  The source directory remains entirely read-only.
    final profiles = await _readProfilesSnapshot(actressFile);
    return _MdcngActorSnapshot(tasks, _MdcngActorLookup(profiles, imageFiles));
  }

  String _path(String name) => '$dataDir${Platform.pathSeparator}$name';

  List<_MdcngTask> _readTasks(String databasePath) {
    Database? database;
    try {
      database = sqlite3.open(databasePath, mode: OpenMode.readOnly);
      return database
          .select('''
            SELECT id, name, emby_id, year, has_pic, has_backdrop, end_at
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

  NasMdcngActorSourceRecord _recordFor({
    required _MdcngTask task,
    required _MdcngActorLookup lookup,
    required String? selectedProfileKey,
  }) {
    final normalizedName = _normalizeName(task.displayName);
    final automaticMatches =
        lookup.exactProfiles[normalizedName] ?? const <_MdcngProfile>[];
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
    final images = resolved == null
        ? const <NasMdcngActorSourceImage>[]
        : _imagesFor(
            resolved.name,
            lookup.imageFilesByPrefix[
                    _namePrefix(_normalizeName(resolved.name))] ??
                const <File>[],
            lookup.imageLength,
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
      profileResolution: resolved != null
          ? 'matched'
          : automaticMatches.isEmpty
              ? 'unresolved'
              : 'ambiguous',
      candidates: suggestions
          .map(
            (profile) => NasMdcngActorProfileCandidate(
              key: profile.key,
              name: profile.name,
              romanizedName: profile.roma,
              hasPhoto: _hasPhotoForName(
                profile.name,
                lookup.imageFilesByPrefix[
                        _namePrefix(_normalizeName(profile.name))] ??
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

  List<NasMdcngActorSourceImage> _imagesFor(
    String name,
    List<File> imageFiles,
    int Function(File) imageLength,
  ) {
    final normalizedName = _normalizeName(name);
    final result = <NasMdcngActorSourceImage>[];
    for (final file in imageFiles) {
      final fileName = file.uri.pathSegments.last;
      final baseName = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
      if (!_normalizeName(baseName).startsWith(normalizedName)) continue;
      final isBackdrop = baseName.toLowerCase().contains('big');
      result.add(
        NasMdcngActorSourceImage(
          file: file,
          fileName: fileName,
          kind: isBackdrop ? 'backdrop' : 'photo',
          mimeType: _mimeTypeForPath(file.path)!,
          byteLength: imageLength(file),
        ),
      );
    }
    return result;
  }

  bool _hasPhotoForName(String name, List<File> imageFiles) {
    final normalizedName = _normalizeName(name);
    return imageFiles.any((file) {
      final fileName = file.uri.pathSegments.last;
      final baseName = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
      return _normalizeName(baseName).startsWith(normalizedName) &&
          !baseName.toLowerCase().contains('big');
    });
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

class _MdcngActorLookup {
  _MdcngActorLookup(List<_MdcngProfile> profiles, List<File> imageFiles) {
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
      final normalized = _normalizeName(baseName);
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
  final Map<String, List<File>> imageFilesByPrefix = {};
  final Map<String, int> _imageLengths = {};

  int imageLength(File file) =>
      _imageLengths.putIfAbsent(file.path, file.lengthSync);
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
  });

  final String id;
  final String displayName;
  final String? embyId;
  final int? year;
  final bool hasPhoto;
  final bool hasBackdrop;
  final String? completedAt;
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
