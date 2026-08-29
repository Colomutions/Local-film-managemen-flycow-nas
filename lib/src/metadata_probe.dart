import 'dart:convert';
import 'dart:io';

import 'media_service.dart';

typedef NasProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class NasMediaMetadata {
  NasMediaMetadata({this.durationMs, this.width, this.height})
    : resolutionLabel = width == null || height == null
          ? null
          : _label(width, height);

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
    this.timeout = const Duration(seconds: 20),
    this.runner,
  });

  final String executable;
  final Duration timeout;
  final NasProcessRunner? runner;

  Future<NasMediaMetadata?> probe(NasMediaFile media) async {
    try {
      final arguments = [
          '-v', 'error',
          '-select_streams', 'v:0',
          '-show_entries', 'stream=width,height:format=duration',
          '-of', 'json',
          media.file.path,
        ];
      final result = await (runner?.call(executable, arguments) ??
              Process.run(executable, arguments, runInShell: false))
          .timeout(timeout);
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
}
