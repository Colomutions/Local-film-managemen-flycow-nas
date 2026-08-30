import 'dart:io';

import 'auth.dart';

class NasArtworkFile {
  const NasArtworkFile({
    required this.file,
    required this.mimeType,
  });

  final File file;
  final String mimeType;
}

class NasArtworkService {
  NasArtworkService(this.dataDir);

  static const maxPosterBytes = 10 * 1024 * 1024;

  final String dataDir;

  Directory get _posterDirectory => Directory(
      '$dataDir${Platform.pathSeparator}artwork${Platform.pathSeparator}posters');
  Directory get _carouselDirectory => Directory(
      '$dataDir${Platform.pathSeparator}artwork${Platform.pathSeparator}carousel');

  Future<String> savePoster({
    required String movieId,
    required String mimeType,
    required List<int> bytes,
  }) async {
    final extension = _extensionForMimeType(mimeType);
    if (extension == null ||
        !isValidPosterBytes(mimeType: mimeType, bytes: bytes)) {
      throw ArgumentError('Unsupported or invalid poster payload.');
    }
    final directory = _posterDirectory;
    await directory.create(recursive: true);
    final fileName = '$movieId.$extension';
    final target = File('${directory.path}${Platform.pathSeparator}$fileName');
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(target.path);
    return fileName;
  }

  Future<NasArtworkFile?> poster(String? fileName) async {
    if (fileName == null ||
        !RegExp(r'^[A-Za-z0-9-]+\.(png|jpe?g|webp)$').hasMatch(fileName)) {
      return null;
    }
    final mimeType = _mimeTypeForFileName(fileName);
    if (mimeType == null) return null;
    final file =
        File('${_posterDirectory.path}${Platform.pathSeparator}$fileName');
    return await file.exists()
        ? NasArtworkFile(file: file, mimeType: mimeType)
        : null;
  }

  Future<void> deletePoster(String? fileName) async {
    final artwork = await poster(fileName);
    if (artwork != null) await artwork.file.delete();
  }

  Future<String> saveCarouselImage({
    required String movieId,
    required String mimeType,
    required List<int> bytes,
  }) async {
    final extension = _extensionForMimeType(mimeType);
    if (extension == null || !isValidPosterBytes(mimeType: mimeType, bytes: bytes)) {
      throw ArgumentError('Unsupported or invalid carousel payload.');
    }
    final directory = _carouselDirectory;
    await directory.create(recursive: true);
    final fileName = '${movieId}-${newUuidV4()}.$extension';
    final target = File('${directory.path}${Platform.pathSeparator}$fileName');
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(target.path);
    return fileName;
  }

  Future<NasArtworkFile?> carouselImage(String? fileName) async {
    if (fileName == null ||
        !RegExp(r'^movie-[A-Za-z0-9-]+-[A-Za-z0-9-]+\.(png|jpe?g|webp)$')
            .hasMatch(fileName)) {
      return null;
    }
    final mimeType = _mimeTypeForFileName(fileName);
    if (mimeType == null) return null;
    final file = File('${_carouselDirectory.path}${Platform.pathSeparator}$fileName');
    return await file.exists()
        ? NasArtworkFile(file: file, mimeType: mimeType)
        : null;
  }

  Future<void> deleteCarouselImage(String? fileName) async {
    final artwork = await carouselImage(fileName);
    if (artwork != null) await artwork.file.delete();
  }

  static String? _extensionForMimeType(String mimeType) => switch (mimeType) {
        'image/png' => 'png',
        'image/jpeg' => 'jpg',
        'image/webp' => 'webp',
        _ => null,
      };

  static bool isValidPosterBytes({
    required String mimeType,
    required List<int> bytes,
  }) {
    if (bytes.isEmpty || bytes.length > maxPosterBytes) return false;
    return switch (mimeType) {
      'image/png' => bytes.length >= 8 &&
          bytes.sublist(0, 8).toString() ==
              [137, 80, 78, 71, 13, 10, 26, 10].toString(),
      'image/jpeg' => bytes.length >= 3 &&
          bytes[0] == 0xff &&
          bytes[1] == 0xd8 &&
          bytes[2] == 0xff,
      'image/webp' => bytes.length >= 12 &&
          bytes.sublist(0, 4).toString() == [82, 73, 70, 70].toString() &&
          bytes.sublist(8, 12).toString() == [87, 69, 66, 80].toString(),
      _ => false,
    };
  }

  static String? _mimeTypeForFileName(String fileName) {
    if (fileName.endsWith('.png')) return 'image/png';
    if (fileName.endsWith('.jpg') || fileName.endsWith('.jpeg'))
      return 'image/jpeg';
    if (fileName.endsWith('.webp')) return 'image/webp';
    return null;
  }
}
