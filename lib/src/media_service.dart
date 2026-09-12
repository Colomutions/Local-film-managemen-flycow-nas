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

  /// 在指定物理来源盘内解析路径。返回值仍只保留该来源盘内的相对路径。
  Future<NasMediaFile?> fileForRootRelativePath({
    required String rootPath,
    required String relativePath,
  }) async {
    final rootRelative = _rootRelativePath(rootPath);
    if (rootRelative == null || !_isSafeRelativePath(relativePath)) {
      return null;
    }
    final file = await fileForRelativePath('$rootRelative/$relativePath');
    return file == null ? null : NasMediaFile(file.file, relativePath);
  }

  /// 在不离开所属目录的前提下重命名单个来源文件，并始终在媒体根目录内校验路径。
  Future<NasMediaFile> renameFileInPlace({
    required String relativePath,
    required String sourceName,
    String? rootPath,
  }) async {
    if (!_isSafeRelativePath(relativePath) || !_isSafeSourceName(sourceName)) {
      throw const NasMediaRenameException('invalid_source_name');
    }
    final effectiveRootPath = rootPath ?? mediaDir;
    final source = rootPath == null
        ? await fileForRelativePath(relativePath)
        : await fileForRootRelativePath(
            rootPath: effectiveRootPath,
            relativePath: relativePath,
          );
    if (source == null) throw const NasMediaRenameException('resource_not_found');
    final currentName = source.relativePath.split('/').last;
    final currentDot = currentName.lastIndexOf('.');
    final requestedDot = sourceName.lastIndexOf('.');
    if (currentDot <= 0 || requestedDot <= 0 ||
        currentName.substring(currentDot).toLowerCase() !=
            sourceName.substring(requestedDot).toLowerCase()) {
      throw const NasMediaRenameException('invalid_source_name');
    }
    final parentSegments = source.relativePath.split('/')..removeLast();
    final renamedRelativePath = [...parentSegments, sourceName].join('/');
    final root = Directory(effectiveRootPath);
    final resolvedRootPath = await root.resolveSymbolicLinks();
    final candidate = File([
      root.path,
      ...parentSegments,
      sourceName,
    ].join(Platform.pathSeparator));
    try {
      if (await candidate.exists()) {
        throw const NasMediaRenameException('source_name_conflict');
      }
      final resolvedParent = await source.file.parent.resolveSymbolicLinks();
      final prefix = resolvedRootPath.endsWith(Platform.pathSeparator)
          ? resolvedRootPath
          : '$resolvedRootPath${Platform.pathSeparator}';
      if (!resolvedParent.startsWith(prefix)) {
        throw const NasMediaRenameException('invalid_source_name');
      }
      final renamed = await source.file.rename(candidate.path);
      final checked = rootPath == null
          ? await fileForRelativePath(renamedRelativePath)
          : await fileForRootRelativePath(
              rootPath: effectiveRootPath,
              relativePath: renamedRelativePath,
            );
      if (checked == null) {
        // 路径校验后不应到达这里；优先尽力回滚，避免文件停留在受管边界外。
        try {
          if (await renamed.exists() && !(await source.file.exists())) {
            await renamed.rename(source.file.path);
          }
        } on FileSystemException {}
        throw const NasMediaRenameException('source_rename_failed');
      }
      return checked;
    } on NasMediaRenameException {
      rethrow;
    } on FileSystemException {
      throw const NasMediaRenameException('source_rename_failed');
    }
  }

  Future<void> restoreRenamedFile({
    required NasMediaFile renamedFile,
    required String originalRelativePath,
    String? rootPath,
  }) async {
    if (!_isSafeRelativePath(originalRelativePath)) return;
    final original = File([
      rootPath ?? mediaDir,
      ...originalRelativePath.split('/'),
    ].join(Platform.pathSeparator));
    try {
      if (await renamedFile.file.exists() && !(await original.exists())) {
        await renamedFile.file.rename(original.path);
      }
    } on FileSystemException {
      // A failed rollback must not conceal the database failure from callers.
    }
  }

  static bool _isSafeRelativePath(String value) {
    final normalized = value.replaceAll('\\', '/');
    return normalized.isNotEmpty &&
        !normalized.startsWith('/') &&
        !RegExp(r'^[A-Za-z]:').hasMatch(normalized) &&
        !normalized.split('/').any(
          (segment) => segment.isEmpty || segment == '.' || segment == '..',
        );
  }

  static bool _isSafeSourceName(String value) =>
      value.isNotEmpty &&
      value == value.trim() &&
      value.length <= 240 &&
      !value.contains('/') &&
      !value.contains('\\') &&
      value != '.' &&
      value != '..';

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

  /// 以物理来源盘为边界解析分类来源目录，避免跨盘或符号链接逃逸。
  Future<NasMediaDirectory?> directoryForRootRelativePath({
    required String rootPath,
    required String relativePath,
  }) async {
    final rootRelative = _rootRelativePath(rootPath);
    if (rootRelative == null || !_isSafeRelativePath(relativePath)) {
      return null;
    }
    final directory = await directoryForRelativePath('$rootRelative/$relativePath');
    return directory == null
        ? null
        : NasMediaDirectory(directory.directory, relativePath.replaceAll('\\', '/'));
  }

  String? _rootRelativePath(String rootPath) {
    try {
      final base = Directory(mediaDir).absolute.path;
      final root = Directory(rootPath).absolute.path;
      final prefix = base.endsWith(Platform.pathSeparator)
          ? base
          : '$base${Platform.pathSeparator}';
      if (!root.startsWith(prefix)) return null;
      final relative = root
          .substring(prefix.length)
          .replaceAll(Platform.pathSeparator, '/');
      return _isSafeRelativePath(relative) ? relative : null;
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

class NasMediaRenameException implements Exception {
  const NasMediaRenameException(this.code);

  final String code;
}
