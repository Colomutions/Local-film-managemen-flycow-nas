import 'dart:io';

class NasMediaFile {
  const NasMediaFile(this.file, this.relativePath);

  final File file;
  final String relativePath;

  Future<int> length() => file.length();
  Stream<List<int>> openRead(int start, int endExclusive) =>
      file.openRead(start, endExclusive);
}

class NasMediaService {
  NasMediaService({required this.mediaDir, required this.fixtureRelativePath});

  final String mediaDir;
  final String? fixtureRelativePath;

  Future<NasMediaFile?> fixtureFile() async {
    final relativePath = fixtureRelativePath;
    if (relativePath == null) return null;
    return fileForRelativePath(relativePath);
  }

  Future<NasMediaFile?> fileForRelativePath(String relativePath) async {
    try {
      final root = Directory(mediaDir);
      if (!await root.exists()) return null;
      final resolvedRoot = await root.resolveSymbolicLinks();
      if (relativePath.split('/').any((segment) =>
          segment.isEmpty || segment == '.' || segment == '..')) {
        return null;
      }
      final segments = relativePath.split('/');
      final candidate = File([
        root.path,
        ...segments,
      ].join(Platform.pathSeparator));
      if (!await candidate.exists()) return null;
      final resolvedFile = await candidate.resolveSymbolicLinks();
      final prefix = resolvedRoot.endsWith(Platform.pathSeparator)
          ? resolvedRoot
          : '$resolvedRoot${Platform.pathSeparator}';
      if (!resolvedFile.startsWith(prefix)) return null;
      return NasMediaFile(File(resolvedFile), relativePath);
    } on FileSystemException {
      return null;
    }
  }
}
