import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

import '../auth.dart';
import '../content_file_names.dart';
import '../novels/novel_metadata.dart';
import 'comic_catalog.dart';

final _shaPattern = RegExp(r'^[0-9a-f]{64}$');
final _badFileName = RegExp(r'[\\/:*?"<>|\u0000-\u001f\u007f]');

Map<String, Object?> parseComicMetadata(Object? decoded,
    {required bool admin, required bool replace}) {
  if (decoded is! Map<String, dynamic>)
    throw const ComicFailure('invalid_metadata');
  const common = {
    'title',
    'author',
    'format',
    'relativePath',
    'fileName',
    'sizeBytes',
    'contentSha256'
  };
  final allowed = {...common, if (!replace) 'conflictPolicy'};
  if (decoded.keys.any((key) => !allowed.contains(key)))
    throw const ComicFailure('invalid_metadata');
  final rawTitle = decoded['title'];
  final rawAuthor = decoded['author'];
  final rawFormat = decoded['format'];
  final rawPath = decoded['relativePath'] ?? '';
  final rawSize = decoded['sizeBytes'];
  final rawSha = decoded['contentSha256'];
  if (rawTitle is! String ||
      (rawAuthor != null && rawAuthor is! String) ||
      rawFormat is! String ||
      rawPath is! String ||
      rawSize is! int ||
      rawSize < 1 ||
      rawSha is! String ||
      !_shaPattern.hasMatch(rawSha)) {
    throw const ComicFailure('invalid_metadata');
  }
  final title = normalizeNovelText(rawTitle);
  final author = rawAuthor == null ? null : normalizeNovelText(rawAuthor);
  if (title.isEmpty ||
      title.runes.length > 256 ||
      (author?.runes.length ?? 0) > 128) {
    throw const ComicFailure('invalid_metadata');
  }
  String path;
  try {
    path = normalizeNovelRelativePath(rawPath);
  } catch (_) {
    throw const ComicFailure('invalid_metadata');
  }
  final format = rawFormat.toLowerCase();
  if (!const {'zip', 'cbz', 'pdf'}.contains(format))
    throw const ComicFailure('unsupported_comic_format');
  final rawName = decoded['fileName'];
  if (rawName != null && rawName is! String)
    throw const ComicFailure('invalid_metadata');
  final fileName = rawName == null
      ? comicFileName(title, format)
      : normalizeNovelText(rawName);
  if (fileName.isEmpty ||
      fileName.runes.length > 256 ||
      _badFileName.hasMatch(fileName) ||
      fileName.endsWith(' ') ||
      fileName.endsWith('.') ||
      !fileName.endsWith('.$format')) {
    throw const ComicFailure('invalid_metadata');
  }
  final policy = replace ? 'reject' : decoded['conflictPolicy'] ?? 'reject';
  if (policy != 'reject' && policy != 'keep_both')
    throw const ComicFailure('invalid_metadata');
  return {
    'title': title,
    'author': author == null || author.isEmpty ? null : author,
    'format': format,
    'relativePath': path,
    'fileName': fileName,
    'sizeBytes': rawSize,
    'contentSha256': rawSha,
    'conflictPolicy': policy
  };
}

String comicFileName(String title, String format) {
  var base = normalizeNovelText(title)
      .replaceAll(_badFileName, '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (base.isEmpty) base = '漫画';
  base = String.fromCharCodes(base.runes.take(252))
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (base.isEmpty) base = '漫画';
  return '$base.$format';
}

class ComicTemporaryFile {
  const ComicTemporaryFile(this.file, this.sizeBytes, this.digest);
  final File file;
  final int sizeBytes;
  final String digest;
}

class ComicFiles {
  ComicFiles(this.rootPath, this.maxUploadBytes);
  final String rootPath;
  final int maxUploadBytes;
  ContentFileNames? fileNames;
  Directory get objects =>
      Directory('$rootPath${Platform.pathSeparator}objects');
  Directory get temporary =>
      Directory('$rootPath${Platform.pathSeparator}.tmp');
  File object(String digest) {
    if (!_shaPattern.hasMatch(digest))
      throw const ComicFailure('invalid_request');
    final name = fileNames?.resolve(digest) ?? digest;
    return File('${objects.path}${Platform.pathSeparator}$name');
  }

  File sessionFile(String id) =>
      File('${temporary.path}${Platform.pathSeparator}$id.part');

  Future<void> initialize() async {
    if (!Directory(rootPath).isAbsolute)
      throw const ComicFailure('comic_storage_unavailable');
    try {
      await objects.create(recursive: true);
      await temporary.create(recursive: true);
      final probe = File(
          '${temporary.path}${Platform.pathSeparator}.probe-${newUuidV4()}');
      await probe.writeAsBytes([1], flush: true);
      await probe.delete();
      final pdf = await Process.run('pdfinfo', ['-v']);
      final zip = await Process.run(Platform.isWindows ? 'tar' : 'unzip',
          [Platform.isWindows ? '--version' : '-v']);
      if (pdf.exitCode != 0 || zip.exitCode != 0)
        throw const ComicFailure('comic_storage_unavailable');
    } catch (_) {
      throw const ComicFailure('comic_storage_unavailable');
    }
  }

  Future<ComicTemporaryFile> receive(
      Stream<List<int>> input, int declaredSize, String declaredDigest) async {
    if (declaredSize > maxUploadBytes)
      throw const ComicFailure('payload_too_large');
    final file =
        File('${temporary.path}${Platform.pathSeparator}${newUuidV4()}.upload');
    final digestSink = _DigestSink();
    final digestInput = sha256.startChunkedConversion(digestSink);
    IOSink? sink;
    var size = 0;
    var done = false;
    try {
      sink = file.openWrite();
      await for (final chunk in input) {
        size += chunk.length;
        if (size > maxUploadBytes)
          throw const ComicFailure('payload_too_large');
        if (size > declaredSize)
          throw const ComicFailure('content_length_mismatch');
        sink.add(chunk);
        digestInput.add(chunk);
      }
      digestInput.close();
      await sink.flush();
      await sink.close();
      sink = null;
      final durable = await file.open(mode: FileMode.append);
      await durable.flush();
      await durable.close();
      if (size != declaredSize)
        throw const ComicFailure('content_length_mismatch');
      final digest = digestSink.value?.toString();
      if (digest != declaredDigest)
        throw const ComicFailure('content_hash_mismatch');
      done = true;
      return ComicTemporaryFile(file, size, digest!);
    } finally {
      await sink?.close();
      if (!done && await file.exists()) await file.delete();
    }
  }

  Future<void> verify(ComicTemporaryFile content, String format) async {
    if (format == 'pdf') {
      await _verifyPdf(content.file);
      return;
    }
    await _verifyZip(content.file);
  }

  Future<void> publish(ComicTemporaryFile content, {String? fileName}) async {
    if (fileName != null) {
      await fileNames!.reserve(content.digest, fileName, objects);
    }
    final dest = object(content.digest);
    if (await dest.exists()) {
      if (await dest.length() != content.sizeBytes)
        throw const ComicFailure('comic_existing_content_unavailable');
      return;
    }
    await content.file.rename(dest.path);
    try {
      if (Platform.isLinux) {
        await _syncPath(dest.path);
        await _syncPath(objects.path);
      }
    } catch (_) {
      try {
        await dest.rename(content.file.path);
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> restoreUncommitted(ComicTemporaryFile content) async {
    if (await content.file.exists()) return;
    final published = object(content.digest);
    if (await published.exists()) await published.rename(content.file.path);
  }

  Future<void> _syncPath(String path) async {
    final result = await Process.run('sync', [path]);
    if (result.exitCode != 0)
      throw const ComicFailure('comic_storage_unavailable');
  }

  Future<void> retire(String digest) async {
    final file = object(digest);
    if (await file.exists()) await file.delete();
  }

  Future<String> state(String digest, int expectedSize) async {
    try {
      final stat = await object(digest).stat();
      if (stat.type != FileSystemEntityType.file) return 'missing';
      return stat.size == expectedSize ? 'healthy' : 'corrupt';
    } catch (_) {
      return 'missing';
    }
  }

  Future<void> _verifyZip(File file) async {
    final signature = await file
        .openRead(0, 4)
        .fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    if (signature.length != 4 ||
        signature[0] != 0x50 ||
        signature[1] != 0x4b ||
        signature[2] != 0x03 ||
        signature[3] != 0x04) {
      throw const ComicFailure('unsupported_comic_format');
    }
    await _checkZipDirectoryBounds(file);
    InputFileStream? input;
    try {
      input = InputFileStream(file.path);
      final directory = ZipDirectory.read(input);
      if (directory.fileHeaders.isEmpty || directory.fileHeaders.length > 10000)
        throw const ComicFailure('invalid_comic_content');
      var total = 0;
      var images = 0;
      var rootImages = false;
      var chapterImages = false;
      final names = <String>{};
      for (final entry in directory.fileHeaders) {
        final name = entry.filename;
        final parts = name.split('/');
        final isFile = !name.endsWith('/');
        final size = entry.uncompressedSize ?? -1;
        final packed = entry.compressedSize ?? -1;
        final mode = (entry.externalFileAttributes ?? 0) >> 16;
        final isLink =
            entry.versionMadeBy >> 8 == 3 && (mode & 0xF000) == 0xA000;
        if (name.startsWith('/') ||
            name.contains('\\') ||
            RegExp(r'^[A-Za-z]:').hasMatch(name) ||
            parts.any((part) => part == '..' || part == '.') ||
            !names.add(name.toLowerCase()) ||
            isLink ||
            ((entry.generalPurposeBitFlag | (entry.file?.flags ?? 0)) & 0x1) !=
                0 ||
            size > 512 * 1024 * 1024 ||
            size < 0 ||
            packed < 0 ||
            (entry.compressionMethod != 0 && entry.compressionMethod != 8)) {
          throw const ComicFailure('invalid_comic_content');
        }
        if (!isFile) continue;
        total += size;
        if (total > 4 * 1024 * 1024 * 1024)
          throw const ComicFailure('invalid_comic_content');
        if (size > 0 && (packed == 0 || size > packed * 200))
          throw const ComicFailure('invalid_comic_content');
        final extension = name.split('.').last.toLowerCase();
        if (const {'jpg', 'jpeg', 'png', 'webp'}.contains(extension) &&
            parts.every((part) =>
                part.isNotEmpty &&
                !part.startsWith('.') &&
                part != '__MACOSX')) {
          if (parts.length == 1) {
            rootImages = true;
          } else if (parts.length == 2) {
            chapterImages = true;
          } else {
            throw const ComicFailure('invalid_comic_content');
          }
          images++;
        }
      }
      if (images == 0 || (rootImages && chapterImages))
        throw const ComicFailure('invalid_comic_content');
    } catch (error) {
      if (error is ComicFailure) rethrow;
      throw const ComicFailure('invalid_comic_content');
    } finally {
      await input?.close();
    }
    final executable = Platform.isWindows ? 'tar' : 'unzip';
    final args = Platform.isWindows ? ['-xOf', file.path] : ['-tqq', file.path];
    try {
      final process = await Process.start(executable, args);
      final output = process.stdout.drain<void>();
      final errors = process.stderr.drain<void>();
      final code = await process.exitCode.timeout(const Duration(minutes: 10),
          onTimeout: () {
        process.kill();
        return -1;
      });
      await Future.wait([output, errors]);
      if (code != 0) throw const ComicFailure('invalid_comic_content');
    } catch (error) {
      if (error is ComicFailure) rethrow;
      throw const ComicFailure('invalid_comic_content');
    }
  }

  Future<void> _checkZipDirectoryBounds(File file) async {
    final handle = await file.open(mode: FileMode.read);
    try {
      final length = await handle.length();
      final tailLength = length < 65557 ? length : 65557;
      await handle.setPosition(length - tailLength);
      final tail = await handle.read(tailLength);
      int u16(int at) => tail[at] | (tail[at + 1] << 8);
      int u32(int at) =>
          tail[at] |
          (tail[at + 1] << 8) |
          (tail[at + 2] << 16) |
          (tail[at + 3] << 24);
      for (var at = tail.length - 22; at >= 0; at--) {
        if (u32(at) != 0x06054b50 || at + 22 + u16(at + 20) != tail.length)
          continue;
        final entries = u16(at + 10);
        final directoryBytes = u32(at + 12);
        if (entries < 1 ||
            entries > 10000 ||
            directoryBytes > 16 * 1024 * 1024 ||
            directoryBytes < entries * 46) {
          throw const ComicFailure('invalid_comic_content');
        }
        return;
      }
      throw const ComicFailure('invalid_comic_content');
    } finally {
      await handle.close();
    }
  }

  Future<void> _verifyPdf(File file) async {
    final header =
        await file.openRead(0, 8).fold<List<int>>([], (a, b) => a..addAll(b));
    if (!ascii.decode(header, allowInvalid: true).startsWith('%PDF-'))
      throw const ComicFailure('unsupported_comic_format');
    Process? process;
    try {
      process = await Process.start(
          Platform.isLinux ? 'prlimit' : 'pdfinfo',
          Platform.isLinux
              ? ['--as=268435456', '--', 'pdfinfo', file.path]
              : [file.path]);
      final out = process.stdout.transform(utf8.decoder).join();
      final err = process.stderr.transform(utf8.decoder).join();
      var timedOut = false;
      final code = await process.exitCode.timeout(const Duration(seconds: 30),
          onTimeout: () {
        timedOut = true;
        process?.kill();
        return -1;
      });
      final text = await out;
      final errorText = await err;
      if (timedOut)
        throw const ComicFailure(
            'invalid_comic_content', {'reason': 'pdf_validation_timeout'});
      if (code != 0) {
        final reason =
            RegExp(r'memory|bad_alloc|cannot allocate', caseSensitive: false)
                    .hasMatch(errorText)
                ? 'pdf_memory_limit'
                : null;
        throw ComicFailure('invalid_comic_content',
            reason == null ? null : {'reason': reason});
      }
      final pages = int.tryParse(RegExp(r'^Pages:\s+(\d+)', multiLine: true)
              .firstMatch(text)
              ?.group(1) ??
          '');
      if (pages != null && pages > 10000)
        throw const ComicFailure(
            'invalid_comic_content', {'reason': 'pdf_page_limit'});
      if (pages == null ||
          pages < 1 ||
          RegExp(r'^Encrypted:\s+yes', multiLine: true).hasMatch(text)) {
        throw const ComicFailure('invalid_comic_content');
      }
    } catch (error) {
      if (error is ComicFailure) rethrow;
      throw const ComicFailure('invalid_comic_content');
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
