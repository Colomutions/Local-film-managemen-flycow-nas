import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

/// 目录只保存页码和字节范围，正文和图片在实际阅读时才加载。
class ReadingContent {
  final _indexes = <String, Future<List<Map<String, Object?>>>>{};
  Future<void> _renderTail = Future.value();

  Future<List<Map<String, Object?>>> index(
    File file,
    String digest,
    String format,
  ) {
    final key = '$format:$digest';
    final previous = _indexes.remove(key);
    if (previous != null) {
      _indexes[key] = previous;
      return previous;
    }
    while (_indexes.length >= 32) {
      _indexes.remove(_indexes.keys.first);
    }
    final result = _buildIndexInIsolate(file.path, format);
    _indexes[key] = result;
    unawaited(result.then<void>((_) {}, onError: (Object _, StackTrace __) {
      if (identical(_indexes[key], result)) _indexes.remove(key);
    }));
    return result;
  }

  Future<Uint8List> comicPage(
      File file, String format, Map<String, Object?> page, int number) async {
    if (format != 'pdf') {
      return _readZipInIsolate(file.path, page['entry'] as String);
    }
    // PDF 渲染串行执行，限制尺寸、输出和进程时长。
    final result = _renderTail.then((_) => _renderPdf(file.path, number));
    _renderTail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<String> chapter(File file, Map<String, Object?> chapter) async {
    final bytes = await file
        .openRead(chapter['start'] as int, chapter['end'] as int)
        .fold<BytesBuilder>(
            BytesBuilder(copy: false), (all, chunk) => all..add(chunk));
    return utf8
        .decode(bytes.takeBytes())
        .replaceFirst(RegExp(r'^\uFEFF'), '')
        .trim();
  }
}

// 独立函数限制 isolate 闭包只捕获路径与格式，不携带服务中的 Future。
Future<List<Map<String, Object?>>> _buildIndexInIsolate(
        String path, String format) =>
    Isolate.run(() => _index(path, format));

Future<Uint8List> _readZipInIsolate(String path, String entryName) =>
    Isolate.run(() {
      final input = InputFileStream(path);
      try {
        final entry = ZipDirectory.read(input)
            .fileHeaders
            .firstWhere((entry) => entry.filename == entryName);
        if ((entry.uncompressedSize ?? 0) > 50 * 1024 * 1024 ||
            (entry.uncompressedSize ?? 0) < 1) {
          throw const FormatException('漫画页面超过限制');
        }
        final content = entry.file!;
        if (!content.verifyCrc32()) throw const FormatException('漫画页面已损坏');
        return Uint8List.fromList(content.content);
      } finally {
        input.close();
      }
    });

Future<List<Map<String, Object?>>> _index(
    String filePath, String format) async {
  if (format == 'txt') return _textIndex(File(filePath));
  if (format == 'pdf') {
    final process = await Process.start('pdfinfo', [filePath]);
    final timer = Timer(const Duration(seconds: 30), () => process.kill());
    late String output;
    late int exitCode;
    try {
      final errors = process.stderr.drain<void>();
      output = await utf8.decoder.bind(process.stdout).join();
      exitCode = await process.exitCode;
      await errors;
    } finally {
      timer.cancel();
      process.kill();
    }
    final match =
        RegExp(r'^Pages:\s*(\d+)', multiLine: true).firstMatch(output);
    final count = int.tryParse(match?[1] ?? '') ?? 0;
    if (exitCode != 0 || count < 1 || count > 10000) {
      throw const FormatException('PDF 页数无效');
    }
    return List.generate(
        count,
        (index) => {
              'number': index,
              'title': '第 ${index + 1} 页',
              'chapter': '正文',
              'mimeType': 'image/png',
            });
  }
  final input = InputFileStream(filePath);
  try {
    final headers = ZipDirectory.read(input).fileHeaders;
    final pages = <Map<String, Object?>>[];
    for (final entry in headers) {
      final name = entry.filename;
      final parts = name.split('/');
      final extension = parts.last.split('.').last.toLowerCase();
      if (!const {'png', 'jpg', 'jpeg', 'webp'}.contains(extension) ||
          parts.any((part) =>
              part.isEmpty || part.startsWith('.') || part == '__MACOSX')) {
        continue;
      }
      if (parts.length > 2 || name.contains('\\')) {
        throw const FormatException('漫画目录无效');
      }
      pages.add({
        'entry': name,
        'title': parts.last,
        'chapter': parts.length == 2 ? parts.first : '正文',
        'mimeType': extension == 'jpg' ? 'image/jpeg' : 'image/$extension'
      });
    }
    pages.sort(
        (a, b) => _naturalCompare(a['entry'] as String, b['entry'] as String));
    if (pages.isEmpty || pages.length > 10000)
      throw const FormatException('漫画没有有效页面');
    for (var i = 0; i < pages.length; i++) {
      pages[i]['number'] = i;
    }
    return pages;
  } finally {
    input.close();
  }
}

int _naturalCompare(String a, String b) {
  final pattern = RegExp(r'\d+|\D+');
  final left = pattern.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final right = pattern.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = int.tryParse(left[i]), y = int.tryParse(right[i]);
    final order =
        x != null && y != null ? x.compareTo(y) : left[i].compareTo(right[i]);
    if (order != 0) return order;
  }
  final order = left.length.compareTo(right.length);
  return order == 0 ? a.compareTo(b) : order;
}

Future<List<Map<String, Object?>>> _textIndex(File file) async {
  final chapters = <Map<String, Object?>>[];
  final heading = RegExp(r'^(第.{1,25}[章回节卷部篇]|chapter\s+\d+|序章|序言|前言|后记|尾声)',
      caseSensitive: false);
  var position = 0, lineStart = 0, chapterStart = 0;
  var title = '正文';
  var line = <int>[];
  void flush() {
    final text = utf8.decode(line).replaceFirst(RegExp(r'^\uFEFF'), '').trim();
    if (lineStart > chapterStart &&
        (heading.hasMatch(text) || lineStart - chapterStart >= 256 * 1024)) {
      chapters.add({
        'number': chapters.length,
        'title': title,
        'start': chapterStart,
        'end': lineStart
      });
      chapterStart = lineStart;
      title = heading.hasMatch(text)
          ? String.fromCharCodes(text.runes.take(160))
          : '正文（${chapters.length + 1}）';
    } else if (lineStart == chapterStart && heading.hasMatch(text)) {
      title = String.fromCharCodes(text.runes.take(160));
    }
    line = <int>[];
    lineStart = position;
  }

  await for (final bytes in file.openRead()) {
    for (final byte in bytes) {
      position++;
      line.add(byte);
      if (byte == 10) {
        flush();
      } else if (line.length >= 65536) {
        // 无换行的长段落也可分段，边界必须落在完整 UTF-8 字符之后。
        var lead = line.length - 1;
        while (lead > 0 && (line[lead] & 0xc0) == 0x80) {
          lead--;
        }
        final first = line[lead];
        final count = first < 0x80
            ? 1
            : first < 0xe0
                ? 2
                : first < 0xf0
                    ? 3
                    : 4;
        if (line.length - lead == count) flush();
      }
    }
  }
  if (line.isNotEmpty) flush();
  if (position > chapterStart) {
    chapters.add({
      'number': chapters.length,
      'title': title,
      'start': chapterStart,
      'end': position
    });
  }
  if (chapters.isEmpty) throw const FormatException('小说没有正文');
  return chapters;
}

Future<Uint8List> _renderPdf(String filePath, int number) async {
  final process = await Process.start('pdftoppm', [
    '-f',
    '${number + 1}',
    '-l',
    '${number + 1}',
    '-singlefile',
    '-scale-to',
    '2000',
    '-png',
    filePath
  ]);
  final errors = process.stderr.drain<void>();
  final output = BytesBuilder(copy: false);
  final timer = Timer(const Duration(seconds: 45), () => process.kill());
  try {
    await for (final chunk in process.stdout) {
      output.add(chunk);
      if (output.length > 50 * 1024 * 1024) {
        process.kill();
        throw const FormatException('PDF 页面超过限制');
      }
    }
    final code = await process.exitCode;
    await errors;
    if (code != 0 || output.length == 0)
      throw const FormatException('PDF 页面读取失败');
    return output.takeBytes();
  } finally {
    timer.cancel();
    process.kill();
  }
}
