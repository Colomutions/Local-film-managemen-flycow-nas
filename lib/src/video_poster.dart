import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'artwork_service.dart';

typedef VideoPosterCrop = ({int x, int y, int width, int height});

class NasVideoPoster {
  NasVideoPoster({this.executable = 'ffmpeg'});

  final String executable;
  bool _busy = false;
  bool get busy => _busy;

  Future<Uint8List?> render(
    File input, {
    required int startMs,
    required int durationMs,
    required VideoPosterCrop? crop,
  }) async {
    _busy = true;
    Process? process;
    try {
      final active = process = await Process.start(executable, [
        '-nostdin',
        '-v',
        'error',
        '-protocol_whitelist',
        'file',
        '-format_whitelist',
        'mov,matroska,avi,mpegts,mpeg,asf,flv,rm,ogg',
        '-ss',
        (startMs / 1000).toStringAsFixed(3),
        '-threads',
        '2',
        '-i',
        input.path,
        '-map',
        '0:V:0',
        '-an',
        '-sn',
        '-dn',
        '-filter_threads',
        '2',
        if (crop == null) ...[
          '-frames:v',
          '1',
          '-threads',
          '2',
          '-c:v',
          'png',
          '-f',
          'image2pipe',
        ] else ...[
          '-t',
          (durationMs / 1000).toStringAsFixed(3),
          '-vf',
          'fps=10,crop=${crop.width}:${crop.height}:${crop.x}:${crop.y}:exact=1,'
              'scale=600:900:flags=lanczos,setsar=1',
          '-c:v',
          'libwebp_anim',
          '-quality',
          '75',
          '-loop',
          '0',
          '-f',
          'webp',
        ],
        'pipe:1',
      ]);
      final bytes = BytesBuilder(copy: false);
      await Future.wait<void>([
        active.exitCode,
        active.stderr.drain<void>(),
        active.stdout.forEach((chunk) {
          if (bytes.length + chunk.length > NasArtworkService.maxPosterBytes) {
            throw const FormatException('Video poster exceeds the asset limit');
          }
          bytes.add(chunk);
        }),
      ], eagerError: true)
          .timeout(const Duration(seconds: 22));
      if (await active.exitCode != 0) return null;
      final image = bytes.takeBytes();
      final valid = crop == null
          ? NasArtworkService.isValidPosterBytes(
              mimeType: 'image/png', bytes: image)
          : _isAnimatedWebp(image);
      return valid ? image : null;
    } on TimeoutException {
      return null;
    } on FormatException {
      return null;
    } on ProcessException {
      return null;
    } finally {
      if (process != null) {
        process.kill();
        await process.exitCode;
      }
      _busy = false;
    }
  }

  bool _isAnimatedWebp(Uint8List bytes) {
    if (!NasArtworkService.isValidPosterBytes(
        mimeType: 'image/webp', bytes: bytes)) {
      return false;
    }
    final data = ByteData.sublistView(bytes);
    var frames = 0;
    for (var offset = 12; offset + 8 <= bytes.length;) {
      final type = data.getUint32(offset);
      final size = data.getUint32(offset + 4, Endian.little);
      offset += 8 + size + (size & 1);
      if (offset > bytes.length) return false;
      if (type == 0x414E4D46) frames++; // ANMF
    }
    return frames > 1;
  }
}
