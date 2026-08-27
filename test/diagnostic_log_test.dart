import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/src/diagnostic_log.dart';

Future<void> main() async {
  final memory = _MemorySink();
  final logger = NasDiagnosticLogger(
    stdoutSink: memory,
    diagnosticMode: true,
  );
  logger.event('http.request.start', fields: {
    'traceId': logger.newId('t'),
    'requestId': logger.newId('r'),
    'authorization': 'Bearer secret-value',
    'route': nasRouteTemplate('/api/v1/movies/12345678-1234-1234-1234-123456789abc'),
    'error': 'C:\\media\\private.mp4\nBearer another-secret',
  });
  await Future<void>.delayed(Duration.zero);
  _expect(memory.lines.length == 1, 'logger writes one JSONL record');
  final record = jsonDecode(memory.lines.single) as Map<String, dynamic>;
  _expect(record['schemaVersion'] == 1, 'schema version is present');
  _expect(record['ts'].toString().endsWith('Z'), 'timestamp is UTC');
  _expect(record['authorization'] == '[redacted]', 'authorization is redacted');
  _expect(record['route'] == '/api/v1/movies/:id', 'normalized routes remain readable');
  _expect(!memory.lines.single.contains('secret'), 'secrets never reach a sink');
  _expect(!memory.lines.single.contains('private.mp4'), 'absolute paths are redacted');
  _expect(!memory.lines.single.contains('\n'), 'JSONL has no literal newlines');

  final failing = NasDiagnosticLogger(stdoutSink: _FailingSink());
  failing.event('service.ready');
  await Future<void>.delayed(Duration.zero);
  _expect(failing.failures == 1, 'sink errors are contained and counted');

  final blocked = _BlockedSink();
  final bounded = NasDiagnosticLogger(
    stdoutSink: blocked,
    diagnosticMode: true,
    maxPendingWrites: 1,
  );
  bounded.event('first', level: 'INFO');
  bounded.event('second', level: 'DEBUG');
  _expect(bounded.droppedDebugEvents == 1, 'full queue drops DEBUG only');
  blocked.release();

  final directory = await Directory.systemTemp.createTemp('mujing-nas-log-test-');
  try {
    final sink = NasRotatingFileLogSink(directory, maxBytes: 10, retentionFiles: 1);
    await sink.write('{"a":1}');
    await sink.write('{"b":2}');
    _expect(await File('${directory.path}${Platform.pathSeparator}mujing-nas.jsonl.1').exists(), 'file sink rotates');
  } finally {
    await directory.delete(recursive: true);
  }
  stdout.writeln('diagnostic_log_test: PASS');
}

class _MemorySink implements NasLogSink {
  final lines = <String>[];
  @override
  Future<void> write(String line) async => lines.add(line);
}

class _FailingSink implements NasLogSink {
  @override
  Future<void> write(String line) => Future<void>.error(StateError('sink unavailable'));
}

class _BlockedSink implements NasLogSink {
  final _completer = Completer<void>();
  @override
  Future<void> write(String line) => _completer.future;
  void release() => _completer.complete();
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('Expectation failed: $message');
}
