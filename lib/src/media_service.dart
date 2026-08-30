import 'dart:io';

class NasMediaFile {
  const NasMediaFile(this.file, this.relativePath);

  final File file;
  final String relativePath;

  Future<int> length() => file.length();
  Stream<List<int>> openRead(int start, int endExclusive) =>
      file.openRead(start, endExclusive);
}

class NasMediaDirectory {
  const NasMediaDirectory(this.directory, this.relativePath);

  final Directory directory;
  final String relativePath;
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

  /// Resolves only a directory below the configured read-only media mount.
  /// The key is relative to that mount; callers never receive its container
  /// path, and symlinks cannot escape it.
  Future<NasMediaDirectory?> directoryForRelativePath(String relativePath) async {
    try {
      final normalized = relativePath.replaceAll('\\', '/');
      if (normalized.isEmpty ||
          normalized.startsWith('/') ||
          normalized.split('/').any(
            (segment) => segment.isEmpty || segment == '.' || segment == '..',
          )) {
        return null;
      }
      final root = Directory(mediaDir);
      if (!await root.exists()) return null;
      final resolvedRoot = await root.resolveSymbolicLinks();
      final candidate = Directory([
        root.path,
        ...normalized.split('/'),
      ].join(Platform.pathSeparator));
      if (!await candidate.exists()) return null;
      final resolvedDirectory = await candidate.resolveSymbolicLinks();
      final prefix = resolvedRoot.endsWith(Platform.pathSeparator)
          ? resolvedRoot
          : '$resolvedRoot${Platform.pathSeparator}';
      if (!resolvedDirectory.startsWith(prefix)) return null;
      final canonicalRelative = resolvedDirectory
          .substring(prefix.length)
          .replaceAll(Platform.pathSeparator, '/');
      if (canonicalRelative.isEmpty) return null;
      return NasMediaDirectory(Directory(resolvedDirectory), canonicalRelative);
    } on FileSystemException {
      return null;
    }
  }

  Future<List<NasMediaDirectory>> childDirectories(String? parentRelativePath) async {
    try {
      final root = Directory(mediaDir);
      if (!await root.exists()) return const [];
      final resolvedRoot = await root.resolveSymbolicLinks();
      final parent = parentRelativePath == null
          ? NasMediaDirectory(Directory(resolvedRoot), '')
          : await directoryForRelativePath(parentRelativePath);
      if (parent == null) return const [];
      final prefix = resolvedRoot.endsWith(Platform.pathSeparator)
          ? resolvedRoot
          : '$resolvedRoot${Platform.pathSeparator}';
      final results = <NasMediaDirectory>[];
      await for (final entity in parent.directory.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final resolved = await entity.resolveSymbolicLinks();
        if (!resolved.startsWith(prefix)) continue;
        final relative = resolved.substring(prefix.length).replaceAll(
              Platform.pathSeparator,
              '/',
            );
        if (relative.isEmpty) continue;
        results.add(NasMediaDirectory(Directory(resolved), relative));
      }
      results.sort((a, b) => a.relativePath.compareTo(b.relativePath));
      return results;
    } on FileSystemException {
      return const [];
    }
  }
}
