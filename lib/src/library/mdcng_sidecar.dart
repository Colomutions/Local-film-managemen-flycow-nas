import 'dart:convert';
import 'dart:io';

import '../auth.dart';
import '../artwork_service.dart';
import '../media_service.dart';
import 'mdcng_nfo.dart';

/// 已验证的 MDCNG 同目录元数据文件。
///
/// 读取器刻意不访问网络，也不写入媒体目录；它只接受与视频同目录的
/// 同名 NFO 和 NFO 明确引用的本地图片文件。
class MdcngNfoSidecar {
  const MdcngNfoSidecar({
    required this.nfoFileName,
    required this.nfoContentHash,
    required this.movie,
    required this.artwork,
    required this.issues,
  });

  final String nfoFileName;
  final String nfoContentHash;
  final MdcngNfoMovie movie;
  final List<MdcngNfoArtwork> artwork;
  final List<MdcngNfoSidecarIssue> issues;
}

class MdcngNfoArtwork {
  const MdcngNfoArtwork({
    required this.kind,
    required this.fileName,
    required this.mimeType,
    required this.byteLength,
  });

  final MdcngNfoArtworkKind kind;
  final String fileName;
  final String mimeType;
  final int byteLength;
}

enum MdcngNfoArtworkKind {
  poster('poster'),
  fanart('fanart'),
  thumb('thumb');

  const MdcngNfoArtworkKind(this.wireName);

  final String wireName;
}

class MdcngNfoSidecarIssue {
  const MdcngNfoSidecarIssue({
    required this.code,
    required this.field,
  });

  final String code;
  final String field;
}

class MdcngNfoSidecarException implements Exception {
  const MdcngNfoSidecarException(this.code);

  final String code;

  @override
  String toString() => 'MdcngNfoSidecarException: $code';
}

class MdcngNfoSidecarReader {
  const MdcngNfoSidecarReader({this.parser = const MdcngNfoParser()});

  static const maxNfoBytes = 1024 * 1024;

  final MdcngNfoParser parser;

  Future<bool> hasNfoForVideo(NasMediaFile video) async {
    final name = _fileName(video.file.path);
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex <= 0) return false;
    final nfo =
        await _sibling(video.file, '${name.substring(0, dotIndex)}.nfo');
    return nfo.exists();
  }

  Future<MdcngNfoSidecar> readForVideo(NasMediaFile video) async {
    final videoName = _fileName(video.file.path);
    final dotIndex = videoName.lastIndexOf('.');
    if (dotIndex <= 0 || dotIndex == videoName.length - 1) {
      throw const MdcngNfoSidecarException('invalid_video_name');
    }
    final nfoFileName = videoName.substring(0, dotIndex) + '.nfo';
    final nfoFile = await _sibling(video.file, nfoFileName);
    if (!await nfoFile.exists()) {
      throw const MdcngNfoSidecarException('sidecar_not_found');
    }

    final int nfoLength;
    try {
      nfoLength = await nfoFile.length();
    } on FileSystemException {
      throw const MdcngNfoSidecarException('sidecar_read_failed');
    }
    if (nfoLength <= 0 || nfoLength > maxNfoBytes) {
      throw const MdcngNfoSidecarException('invalid_nfo_size');
    }

    final MdcngNfoMovie movie;
    late final String nfoContentHash;
    try {
      final bytes = await nfoFile.readAsBytes();
      movie = parser.parse(utf8.decode(bytes));
      // 使用 Base64 的确定性文本表示计算摘要，避免将原始内容暴露到 API。
      nfoContentHash = sha256Hex(base64Encode(bytes));
    } on FormatException {
      throw const MdcngNfoSidecarException('invalid_nfo');
    } on FileSystemException {
      throw const MdcngNfoSidecarException('sidecar_read_failed');
    }

    final artwork = <MdcngNfoArtwork>[];
    final issues = <MdcngNfoSidecarIssue>[];
    await _inspectArtwork(
      video: video.file,
      kind: MdcngNfoArtworkKind.poster,
      fileName: movie.poster ?? 'poster.jpg',
      reportMissing: movie.poster != null,
      artwork: artwork,
      issues: issues,
    );
    await _inspectArtwork(
      video: video.file,
      kind: MdcngNfoArtworkKind.fanart,
      fileName: movie.fanart ?? 'fanart.jpg',
      reportMissing: movie.fanart != null,
      artwork: artwork,
      issues: issues,
    );
    await _inspectArtwork(
      video: video.file,
      kind: MdcngNfoArtworkKind.thumb,
      fileName: movie.thumb ?? 'thumb.jpg',
      reportMissing: movie.thumb != null,
      artwork: artwork,
      issues: issues,
    );

    return MdcngNfoSidecar(
      nfoFileName: nfoFileName,
      nfoContentHash: nfoContentHash,
      movie: movie,
      artwork: artwork,
      issues: issues,
    );
  }

  /// 在确认导入前重新读取并校验已预览的本地图片。
  Future<List<int>> readArtworkBytes({
    required NasMediaFile video,
    required MdcngNfoArtwork artwork,
  }) async {
    if (!_isSafeSiblingFileName(artwork.fileName)) {
      throw const MdcngNfoSidecarException('invalid_artwork_path');
    }
    final image = await _sibling(video.file, artwork.fileName);
    try {
      final bytes = await image.readAsBytes();
      if (bytes.length > NasArtworkService.maxPosterBytes ||
          !NasArtworkService.isValidPosterBytes(
            mimeType: artwork.mimeType,
            bytes: bytes,
          )) {
        throw const MdcngNfoSidecarException('invalid_artwork');
      }
      return bytes;
    } on FileSystemException {
      throw const MdcngNfoSidecarException('artwork_read_failed');
    }
  }

  Future<void> _inspectArtwork({
    required File video,
    required MdcngNfoArtworkKind kind,
    required String? fileName,
    required bool reportMissing,
    required List<MdcngNfoArtwork> artwork,
    required List<MdcngNfoSidecarIssue> issues,
  }) async {
    if (fileName == null) return;
    if (!_isSafeSiblingFileName(fileName)) {
      issues.add(
        MdcngNfoSidecarIssue(
          code: 'invalid_artwork_path',
          field: kind.wireName,
        ),
      );
      return;
    }

    final File image;
    try {
      image = await _sibling(video, fileName);
    } on MdcngNfoSidecarException {
      issues.add(
        MdcngNfoSidecarIssue(
          code: 'invalid_artwork_path',
          field: kind.wireName,
        ),
      );
      return;
    }
    if (!await image.exists()) {
      if (reportMissing) {
        issues.add(
          MdcngNfoSidecarIssue(
            code: 'artwork_not_found',
            field: kind.wireName,
          ),
        );
      }
      return;
    }

    try {
      final length = await image.length();
      if (length <= 0 || length > NasArtworkService.maxPosterBytes) {
        issues.add(
          MdcngNfoSidecarIssue(
            code: 'invalid_artwork_size',
            field: kind.wireName,
          ),
        );
        return;
      }
      final header = await image.openRead(0, 12).fold<List<int>>(
        <int>[],
        (bytes, chunk) => bytes..addAll(chunk),
      );
      final mimeType = _mimeTypeForHeader(header);
      if (mimeType == null) {
        issues.add(
          MdcngNfoSidecarIssue(
            code: 'invalid_artwork_type',
            field: kind.wireName,
          ),
        );
        return;
      }
      artwork.add(
        MdcngNfoArtwork(
          kind: kind,
          fileName: fileName,
          mimeType: mimeType,
          byteLength: length,
        ),
      );
    } on FileSystemException {
      issues.add(
        MdcngNfoSidecarIssue(
          code: 'artwork_read_failed',
          field: kind.wireName,
        ),
      );
    }
  }

  Future<File> _sibling(File video, String fileName) async {
    final parent = await video.parent.resolveSymbolicLinks();
    final candidate = File(parent + Platform.pathSeparator + fileName);
    if (!await candidate.exists()) return candidate;
    final resolved = await candidate.resolveSymbolicLinks();
    final prefix = parent.endsWith(Platform.pathSeparator)
        ? parent
        : parent + Platform.pathSeparator;
    if (!resolved.startsWith(prefix)) {
      throw const MdcngNfoSidecarException('invalid_sidecar_path');
    }
    return File(resolved);
  }
}

String _fileName(String path) =>
    path.split(Platform.pathSeparator).where((part) => part.isNotEmpty).last;

bool _isSafeSiblingFileName(String fileName) =>
    fileName.isNotEmpty &&
    fileName != '.' &&
    fileName != '..' &&
    !fileName.contains('/') &&
    !fileName.contains('\\');

String? _mimeTypeForHeader(List<int> bytes) {
  if (_matches(bytes, const [0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (_matches(bytes, const [137, 80, 78, 71, 13, 10, 26, 10])) {
    return 'image/png';
  }
  if (_matches(bytes, const [82, 73, 70, 70]) &&
      bytes.length >= 12 &&
      _matchesAt(bytes, const [87, 69, 66, 80], 8)) {
    return 'image/webp';
  }
  return null;
}

bool _matches(List<int> bytes, List<int> expected) =>
    _matchesAt(bytes, expected, 0);

bool _matchesAt(List<int> bytes, List<int> expected, int offset) {
  if (bytes.length < offset + expected.length) return false;
  for (var index = 0; index < expected.length; index++) {
    if (bytes[offset + index] != expected[index]) return false;
  }
  return true;
}
