import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Best-effort structured diagnostics.  Logging failures are deliberately
/// contained: this class must never affect an HTTP response or a media stream.
abstract interface class NasLogSink {
  Future<void> write(String line);
}

class NasStdoutLogSink implements NasLogSink {
  const NasStdoutLogSink();

  @override
  Future<void> write(String line) async {
    stdout.writeln(line);
  }
}

class NasRotatingFileLogSink implements NasLogSink {
  NasRotatingFileLogSink(this.directory, {this.maxBytes = 2 * 1024 * 1024, this.retentionFiles = 3});

  final Directory directory;
  final int maxBytes;
  final int retentionFiles;
  Future<void> _tail = Future<void>.value();

  @override
  Future<void> write(String line) {
    _tail = _tail.then((_) => _write(line)).catchError((_) {});
    return _tail;
  }

  Future<void> _write(String line) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}${Platform.pathSeparator}mujing-nas.jsonl');
    final bytes = utf8.encode('$line\n');
    if (await file.exists() && await file.length() + bytes.length > maxBytes) {
      for (var index = retentionFiles - 1; index >= 1; index--) {
        final source = File('${file.path}.$index');
        final target = File('${file.path}.${index + 1}');
        if (await source.exists()) await source.rename(target.path);
      }
      if (await file.exists()) await file.rename('${file.path}.1');
    }
    await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
    final expired = File('${file.path}.${retentionFiles + 1}');
    if (await expired.exists()) await expired.delete();
  }
}

class NasDiagnosticLogger {
  NasDiagnosticLogger({
    NasLogSink? stdoutSink,
    NasLogSink? fileSink,
    this.minimumLevel = 'INFO',
    this.diagnosticMode = false,
    this.maxPendingWrites = 256,
    DateTime Function()? now,
    Random? random,
  })  : _stdoutSink = stdoutSink ?? const NasStdoutLogSink(),
        _fileSink = fileSink,
        _now = now ?? (() => DateTime.now().toUtc()),
        _random = random ?? Random.secure();

  final NasLogSink _stdoutSink;
  final NasLogSink? _fileSink;
  final String minimumLevel;
  final bool diagnosticMode;
  final int maxPendingWrites;
  final DateTime Function() _now;
  final Random _random;
  int droppedDebugEvents = 0;
  int failures = 0;
  int _pendingWrites = 0;

  factory NasDiagnosticLogger.forConfig(String dataDir, {
    required String minimumLevel,
    required bool diagnosticMode,
    required int maxBytes,
    required int retentionFiles,
  }) => NasDiagnosticLogger(
    minimumLevel: minimumLevel,
    diagnosticMode: diagnosticMode,
    fileSink: NasRotatingFileLogSink(
      Directory('$dataDir${Platform.pathSeparator}logs'),
      maxBytes: maxBytes,
      retentionFiles: retentionFiles,
    ),
  );

  String newId(String prefix) => '$prefix-${List<String>.generate(12, (_) => _alphabet[_random.nextInt(_alphabet.length)]).join()}';

  void event(
    String event, {
    String level = 'INFO',
    String component = 'nas',
    Map<String, Object?> fields = const {},
  }) {
    if (!_shouldWrite(level)) {
      if (level == 'DEBUG') droppedDebugEvents++;
      return;
    }
    try {
      final record = <String, Object?>{
        'schemaVersion': 1,
        'ts': _now().toUtc().toIso8601String(),
        'level': level,
        'component': component,
        'event': event,
        ...fields,
      };
      final line = jsonEncode(_sanitize(record));
      // Do not await from request handlers: logging is observational only.
      _writeSafely(_stdoutSink, line, level);
      final fileSink = _fileSink;
      if (fileSink != null) _writeSafely(fileSink, line, level);
    } catch (_) {
      failures++;
    }
  }

  void _writeSafely(NasLogSink sink, String line, String level) {
    if (_pendingWrites >= maxPendingWrites && level == 'DEBUG') {
      droppedDebugEvents++;
      return;
    }
    _pendingWrites++;
    sink.write(line).catchError((_) {
      failures++;
    }).whenComplete(() {
      _pendingWrites--;
    });
  }

  bool _shouldWrite(String level) {
    if (level == 'DEBUG' && !diagnosticMode) return false;
    const ranks = {'DEBUG': 0, 'INFO': 1, 'WARN': 2, 'ERROR': 3};
    return (ranks[level] ?? 1) >= (ranks[minimumLevel] ?? 1);
  }

  Object? _sanitize(Object? value) {
    if (value is String) return _sanitizeText(value);
    if (value is Map) {
      return value.map((key, child) {
        final name = key.toString();
        final lowered = name.toLowerCase();
        final sensitive = lowered.contains('authorization') ||
            lowered.contains('token') ||
            lowered.contains('password') ||
            lowered.contains('pairing') ||
            lowered.contains('proof') ||
            lowered == 'query' ||
            lowered.contains('path') ||
            lowered.contains('title') ||
            lowered.contains('actor');
        return MapEntry(name, sensitive ? '[redacted]' : _sanitize(child));
      });
    }
    if (value is Iterable) return value.map(_sanitize).toList(growable: false);
    return value;
  }

  String _sanitizeText(String value) {
    var result = value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ');
    result = result.replaceAll(
      RegExp(r'(bearer\s+)[^\s,;]+', caseSensitive: false),
      r'$1[redacted]',
    );
    result = result.replaceAll(RegExp(r'\?.*'), '?[redacted]');
    // Absolute paths are not useful for the first diagnostic cut. Keep API
    // routes such as /api/v1/movies readable.
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(result) ||
        RegExp(r'^/(?:data|media|mnt|var|home|tmp)(?:/|$)').hasMatch(result)) {
      return '[redacted-path]';
    }
    return result.length > 512 ? '${result.substring(0, 512)}…' : result;
  }

  static const _alphabet = 'abcdefghijkmnopqrstuvwxyz23456789';
}

String nasShortId(String? value) {
  if (value == null || value.isEmpty) return 'none';
  var hash = 2166136261;
  for (final unit in value.codeUnits) {
    hash = (hash ^ unit) * 16777619;
  }
  return hash.toUnsigned(32).toRadixString(16).padLeft(8, '0');
}

String nasRouteTemplate(String path) {
  final segments = path.split('/');
  return segments
      .map((segment) => RegExp(r'^[0-9a-fA-F-]{8,}$').hasMatch(segment) ? ':id' : segment)
      .join('/');
}
