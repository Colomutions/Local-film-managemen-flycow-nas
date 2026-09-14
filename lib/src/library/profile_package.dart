import 'dart:convert';

import 'package:archive/archive.dart';

enum NasProfilePackageKind {
  actor('actor', 'actors'),
  publisher('publisher', 'publishers'),
  series('series', 'series');

  const NasProfilePackageKind(this.wireValue, this.directoryName);

  final String wireValue;
  final String directoryName;

  static NasProfilePackageKind? tryParse(String value) {
    for (final kind in values) {
      if (kind.wireValue == value) return kind;
    }
    return null;
  }
}

class NasProfilePackageEntry {
  const NasProfilePackageEntry({
    required this.directoryName,
    required this.fields,
    this.validationError,
    this.imageBytes,
    this.imageMimeType,
  });

  final String directoryName;
  final Map<String, String> fields;
  final String? validationError;
  final List<int>? imageBytes;
  final String? imageMimeType;
}

class NasProfilePackage {
  const NasProfilePackage({required this.kind, required this.entries});

  final NasProfilePackageKind kind;
  final List<NasProfilePackageEntry> entries;
}

class NasProfilePackageExportEntry {
  const NasProfilePackageExportEntry({
    required this.directoryName,
    required this.fields,
    this.imageBytes,
    this.imageMimeType,
  });

  final String directoryName;
  final Map<String, String> fields;
  final List<int>? imageBytes;
  final String? imageMimeType;
}

class NasProfilePackageCodec {
  static const manifestFileName = 'mujing-profile-package.txt';
  static const maxPackageBytes = 64 * 1024 * 1024;
  static const maxExpandedBytes = 128 * 1024 * 1024;
  static const maxFileCount = 300;
  static const maxProfileBytes = 64 * 1024;

  static NasProfilePackage decode({
    required NasProfilePackageKind expectedKind,
    required List<int> bytes,
  }) {
    if (bytes.isEmpty || bytes.length > maxPackageBytes) {
      throw const FormatException('资料包大小不符合限制。');
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } on Object {
      throw const FormatException('资料包不是有效的 ZIP 文件。');
    }
    if (archive.length > maxFileCount) {
      throw const FormatException('资料包内文件数量超过限制。');
    }
    var expandedBytes = 0;
    final files = <String, ArchiveFile>{};
    final explicitDirectories = <String>{};
    for (final entry in archive) {
      final path = _normalizePath(entry.name, entry.isFile);
      if (entry.isFile) {
        if (files.putIfAbsent(path, () => entry) != entry) {
          throw const FormatException('资料包包含重复文件。');
        }
        expandedBytes += entry.size;
        if (expandedBytes > maxExpandedBytes) {
          throw const FormatException('资料包解压后的总大小超过限制。');
        }
      } else if (!explicitDirectories.add(path)) {
        throw const FormatException('资料包包含重复目录。');
      }
    }
    final manifest = files.remove(manifestFileName);
    if (manifest == null) {
      throw const FormatException('资料包缺少格式版本说明。');
    }
    final manifestFields = _parseFields(_fileBytes(manifest), maxBytes: 4096);
    if (manifestFields['format'] != '1' ||
        manifestFields['kind'] != expectedKind.wireValue ||
        manifestFields.keys.any((key) => key != 'format' && key != 'kind')) {
      throw const FormatException('资料包格式版本或资料类型不匹配。');
    }
    for (final directory in explicitDirectories) {
      final parts = directory.split('/');
      if (parts.first != expectedKind.directoryName || parts.length > 2) {
        throw const FormatException('资料包包含不允许的目录。');
      }
    }

    final records = <String, _MutablePackageEntry>{};
    for (final entry in files.entries) {
      final parts = entry.key.split('/');
      if (parts.length != 3 || parts.first != expectedKind.directoryName) {
        throw const FormatException('资料包包含不允许的文件。');
      }
      final directoryName = parts[1];
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')
          .hasMatch(directoryName)) {
        throw const FormatException('资料包目录名称不合法。');
      }
      final record = records.putIfAbsent(
        directoryName,
        () => _MutablePackageEntry(directoryName),
      );
      final fileName = parts.last;
      if (fileName == 'profile.txt') {
        if (record.profileFile != null) {
          throw const FormatException('资料包包含重复 profile.txt。');
        }
        record.profileFile = entry.value;
      } else if (_isImageFileName(fileName)) {
        if (record.imageFile != null) {
          throw const FormatException('每条资料最多包含一张图片。');
        }
        record.imageFile = entry.value;
        record.imageFileName = fileName;
      } else {
        throw const FormatException('资料包包含未知文件。');
      }
    }
    if (records.isEmpty || records.values.any((record) => record.profileFile == null)) {
      throw const FormatException('资料包中每条资料都必须包含 profile.txt。');
    }
    final declaredRecords = explicitDirectories
        .map((directory) => directory.split('/'))
        .where((parts) => parts.length == 2)
        .map((parts) => parts.last);
    if (declaredRecords.any((directory) => !records.containsKey(directory))) {
      throw const FormatException('资料包中每条资料都必须包含 profile.txt。');
    }

    final entries = <NasProfilePackageEntry>[];
    for (final record in records.values) {
      Map<String, String> fields = const {};
      String? validationError;
      try {
        fields = _parseFields(_fileBytes(record.profileFile!), maxBytes: maxProfileBytes);
        validationError = _validateProfile(expectedKind, fields);
      } on FormatException catch (error) {
        validationError = error.message.toString();
      }
      List<int>? imageBytes;
      String? imageMimeType;
      if (record.imageFile != null) {
        imageBytes = _fileBytes(record.imageFile!);
        imageMimeType = _mimeTypeForFileName(record.imageFileName!);
        if (imageMimeType == null ||
            imageBytes.length > 10 * 1024 * 1024 ||
            !_isValidImage(imageMimeType, imageBytes)) {
          throw const FormatException('资料包中的图片格式或大小不合法。');
        }
      }
      entries.add(
        NasProfilePackageEntry(
          directoryName: record.directoryName,
          fields: fields,
          validationError: validationError,
          imageBytes: imageBytes,
          imageMimeType: imageMimeType,
        ),
      );
    }
    return NasProfilePackage(kind: expectedKind, entries: entries);
  }

  static List<int> encode({
    required NasProfilePackageKind kind,
    required Iterable<NasProfilePackageExportEntry> entries,
  }) {
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          manifestFileName,
          utf8.encode('format=1\nkind=${kind.wireValue}\n').length,
          utf8.encode('format=1\nkind=${kind.wireValue}\n'),
        ),
      );
    final seenDirectories = <String>{};
    for (final entry in entries) {
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')
              .hasMatch(entry.directoryName) ||
          !seenDirectories.add(entry.directoryName)) {
        throw ArgumentError('导出资料目录不合法。');
      }
      final prefix = '${kind.directoryName}/${entry.directoryName}';
      final profile = _encodeFields(entry.fields);
      archive.addFile(
        ArchiveFile('$prefix/profile.txt', profile.length, profile),
      );
      final imageBytes = entry.imageBytes;
      final imageMimeType = entry.imageMimeType;
      if (imageBytes != null && imageMimeType != null) {
        final extension = switch (imageMimeType) {
          'image/png' => 'png',
          'image/jpeg' => 'jpg',
          'image/webp' => 'webp',
          _ => throw ArgumentError('导出图片类型不合法。'),
        };
        archive.addFile(
          ArchiveFile('$prefix/image.$extension', imageBytes.length, imageBytes),
        );
      }
    }
    final encoded = ZipEncoder().encode(archive);
    if (encoded == null) throw StateError('资料包生成失败。');
    return encoded;
  }

  static List<int> template(NasProfilePackageKind kind) {
    final fields = switch (kind) {
      NasProfilePackageKind.actor => const {
          'stageName': '示例艺名',
          'originalName': 'Example Actor',
          'translatedName': '',
          'aliases': '别名一|别名二',
          'gender': 'female',
          'birthMonth': '1990-01',
          'country': '国家或地区',
          'heightCm': '165',
          'weightKg': '50',
          'measurements': '',
          'bodyType': '',
          'debutMonth': '2010-01',
          'debutDescription': '',
          'publisherNames': '',
        },
      NasProfilePackageKind.publisher => const {
          'displayName': '示例发行商',
          'originalName': 'Example Publisher',
          'countryRegion': '国家或地区',
          'foundedDate': '2000-01-01',
        },
      NasProfilePackageKind.series => const {
          'displayName': '示例系列',
          'originalName': 'Example Series',
          'translatedName': '',
          'releaseDate': '2020-01-01',
          'publisherName': '',
        },
    };
    return encode(
      kind: kind,
      entries: [
        NasProfilePackageExportEntry(
          directoryName: 'example-${kind.wireValue}-001',
          fields: fields,
        ),
      ],
    );
  }

  static String _normalizePath(String value, bool isFile) {
    if (value.isEmpty || value.contains('\\') || value.startsWith('/')) {
      throw const FormatException('资料包路径不合法。');
    }
    final normalized = value.endsWith('/') ? value.substring(0, value.length - 1) : value;
    final parts = normalized.split('/');
    if (normalized.isEmpty ||
        parts.length > 3 ||
        parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const FormatException('资料包路径不合法。');
    }
    if (!isFile && value.endsWith('/') == false) {
      return '$normalized/';
    }
    return normalized;
  }

  static List<int> _fileBytes(ArchiveFile file) {
    final content = file.content;
    if (content is List<int>) return content;
    throw const FormatException('资料包文件无法读取。');
  }

  static Map<String, String> _parseFields(
    List<int> bytes, {
    required int maxBytes,
  }) {
    if (bytes.length > maxBytes) throw const FormatException('profile.txt 过大。');
    final text = utf8.decode(bytes, allowMalformed: false);
    final fields = <String, String>{};
    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final separator = line.indexOf('=');
      if (separator < 1) throw const FormatException('profile.txt 格式不正确。');
      final key = line.substring(0, separator).trim();
      final value = line.substring(separator + 1).trim();
      if (!RegExp(r'^[A-Za-z][A-Za-z0-9]{0,39}$').hasMatch(key) ||
          value.length > 1000 ||
          fields.containsKey(key)) {
        throw const FormatException('profile.txt 包含非法或重复字段。');
      }
      fields[key] = value;
    }
    return fields;
  }

  static List<int> _encodeFields(Map<String, String> fields) {
    final lines = fields.entries
        .where((entry) => entry.key.isNotEmpty)
        .map((entry) => '${entry.key}=${entry.value.replaceAll('\n', ' ').replaceAll('\r', ' ')}')
        .join('\n');
    return utf8.encode('$lines\n');
  }

  static String? _validateProfile(
    NasProfilePackageKind kind,
    Map<String, String> fields,
  ) {
    final allowed = switch (kind) {
      NasProfilePackageKind.actor => const {
          'stageName', 'originalName', 'translatedName', 'aliases',
          'gender', 'birthMonth', 'country', 'heightCm', 'weightKg',
          'measurements', 'bodyType', 'debutMonth', 'debutDescription',
          'publisherNames',
        },
      NasProfilePackageKind.publisher => const {
          'displayName', 'originalName', 'countryRegion', 'foundedDate',
        },
      NasProfilePackageKind.series => const {
          'displayName', 'originalName', 'translatedName', 'releaseDate',
          'publisherName',
        },
    };
    if (fields.keys.any((key) => !allowed.contains(key))) return 'profile.txt 包含未知字段。';
    if (kind == NasProfilePackageKind.actor) {
      final hasName = ['stageName', 'originalName', 'translatedName']
          .map((key) => fields[key])
          .any((value) => value != null && value.isNotEmpty);
      final aliases = _splitList(fields['aliases']);
      if (!hasName && aliases.isEmpty) return '演员至少需要填写一项名称。';
      if (!_validMonth(fields['birthMonth']) || !_validMonth(fields['debutMonth'])) {
        return '出生年月或出道年月格式不正确。';
      }
      if (fields['gender'] case final gender? when gender.isNotEmpty &&
          !const {'female', 'intersex', 'male'}.contains(gender)) {
        return '性别字段不合法。';
      }
      if (!_validInt(fields['heightCm'], min: 1, max: 300) ||
          !_validInt(fields['weightKg'], min: 1, max: 500)) {
        return '演员身高或体重不合法。';
      }
    } else if (kind == NasProfilePackageKind.publisher) {
      if ((fields['displayName'] ?? '').isEmpty || !_validDate(fields['foundedDate'])) {
        return '发行商名称或成立日期不合法。';
      }
    } else {
      if ((fields['displayName'] ?? '').isEmpty ||
          !_validDate(fields['releaseDate'])) {
        return '系列名称或上映日期不合法。';
      }
    }
    return null;
  }

  static bool _validMonth(String? value) => value == null ||
      value.isEmpty || RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(value);

  static bool _validDate(String? value) => value == null ||
      value.isEmpty || RegExp(r'^\d{4}(-\d{2}(-\d{2})?)?$').hasMatch(value);

  static bool _validInt(String? value, {required int min, required int max}) {
    if (value == null || value.isEmpty) return true;
    final parsed = int.tryParse(value);
    return parsed != null && parsed >= min && parsed <= max;
  }

  static List<String> _splitList(String? value) => (value ?? '')
      .split('|')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);

  static bool _isImageFileName(String value) =>
      RegExp(r'^image\.(png|jpe?g|webp)$', caseSensitive: false).hasMatch(value);

  static String? _mimeTypeForFileName(String value) {
    final lower = value.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    return null;
  }

  static bool _isValidImage(String mimeType, List<int> bytes) => switch (mimeType) {
        'image/png' => bytes.length >= 8 &&
            bytes.sublist(0, 8).toString() == [137, 80, 78, 71, 13, 10, 26, 10].toString(),
        'image/jpeg' => bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff,
        'image/webp' => bytes.length >= 12 &&
            bytes.sublist(0, 4).toString() == [82, 73, 70, 70].toString() &&
            bytes.sublist(8, 12).toString() == [87, 69, 66, 80].toString(),
        _ => false,
      };
}

class _MutablePackageEntry {
  _MutablePackageEntry(this.directoryName);

  final String directoryName;
  ArchiveFile? profileFile;
  ArchiveFile? imageFile;
  String? imageFileName;
}
