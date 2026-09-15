import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'media_service.dart';

typedef NasProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class NasMediaMetadata {
  NasMediaMetadata({this.durationMs, this.width, this.height})
      : resolutionLabel =
            width == null || height == null ? null : _label(width, height);

  final int? durationMs;
  final int? width;
  final int? height;
  final String? resolutionLabel;

  static String _label(int width, int height) {
    final shortEdge = width < height ? width : height;
    if (shortEdge <= 576) return 'SD';
    if (shortEdge <= 720) return '720P';
    if (shortEdge <= 1080) return '1080P';
    if (shortEdge <= 1440) return '2K';
    if (shortEdge <= 2160) return '4K';
    return '8K';
  }
}

/// Runs a bounded ffprobe process and parses only whitelisted media fields.
/// Paths and raw stderr are never returned or logged by this class.
class NasMediaMetadataProbe {
  const NasMediaMetadataProbe({
    this.executable = 'ffprobe',
    this.timeout = const Duration(seconds: 5),
    this.runner,
  });

  final String executable;
  final Duration timeout;
  final NasProcessRunner? runner;

  Future<NasMediaMetadata?> probe(NasMediaFile media) async {
    try {
      final arguments = [
        '-v',
        'error',
        // NAS 扫描只需要首个视频流的基本信息。限制探测预算，避免损坏、
        // 网络盘或尾部索引异常的文件让一次扫描长期阻塞。
        '-probesize',
        '1048576',
        '-analyzeduration',
        '1000000',
        '-select_streams',
        'v:0',
        '-show_entries',
        'stream=width,height:format=duration',
        '-of',
        'json',
        media.file.path,
      ];
      final result = runner == null
          ? await _runBounded(arguments)
          : await runner!(executable, arguments).timeout(timeout);
      if (result == null) return null;
      if (result.exitCode != 0) return null;
      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final streams = json['streams'] as List<dynamic>? ?? const [];
      final streamValues = streams.whereType<Map<String, dynamic>>();
      final stream = streamValues.isEmpty ? null : streamValues.first;
      final width = (stream?['width'] as num?)?.toInt();
      final height = (stream?['height'] as num?)?.toInt();
      final formats = json['format'] as Map<String, dynamic>?;
      final seconds = double.tryParse('${formats?['duration'] ?? ''}');
      final durationMs = seconds == null || !seconds.isFinite || seconds < 0
          ? null
          : (seconds * 1000).round();
      if ((width == null || width <= 0) &&
          (height == null || height <= 0) &&
          durationMs == null) {
        return null;
      }
      return NasMediaMetadata(
        durationMs: durationMs,
        width: width != null && width > 0 ? width : null,
        height: height != null && height > 0 ? height : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Unlike [Process.run], actively terminates ffprobe when the deadline is
  /// reached. A timed-out probe must not remain in the background and compete
  /// with the rest of a NAS scan for disk I/O.
  Future<ProcessResult?> _runBounded(List<String> arguments) async {
    final process =
        await Process.start(executable, arguments, runInShell: false);
    final output = Future.wait<dynamic>([
      process.exitCode,
      process.stdout.transform(utf8.decoder).join(),
      process.stderr.transform(utf8.decoder).join(),
    ]);
    try {
      final values = await output.timeout(timeout);
      return ProcessResult(
        process.pid,
        values[0] as int,
        values[1] as String,
        values[2] as String,
      );
    } on TimeoutException {
      process.kill();
      return null;
    }
  }
}
