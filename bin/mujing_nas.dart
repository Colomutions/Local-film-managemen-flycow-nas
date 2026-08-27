import 'dart:async';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main(List<String> arguments) async {
  final config = NasConfig.fromEnvironment(Platform.environment);
  if (arguments.contains('--healthcheck')) {
    exitCode = await checkLocalHealth(config) ? 0 : 1;
    return;
  }

  final logger = NasDiagnosticLogger.forConfig(
    config.dataDir,
    minimumLevel: config.logLevel,
    diagnosticMode: config.diagnosticMode,
    maxBytes: config.logMaxBytes,
    retentionFiles: config.logRetentionFiles,
  );
  await runZonedGuarded(() async {
    logger.event('process.start', fields: {
      'component': 'nas.process',
      'port': config.port,
    });
    final server = NasHealthServer(config, logger: logger);
    await server.start();
    logger.event('process.ready', fields: {
      'component': 'nas.process',
      'port': server.port,
    });
    await Future.any<void>([
      ProcessSignal.sigint.watch().first,
      ProcessSignal.sigterm.watch().first,
    ]);
    logger.event('process.stop', fields: {
      'component': 'nas.process',
      'cancelReason': 'signal',
    });
    await server.stop();
  }, (error, stackTrace) {
    logger.event('process.uncaught_error', level: 'ERROR', fields: {
      'component': 'nas.process',
      'outcome': 'error',
      'errorType': error.runtimeType.toString(),
      'stack': stackTrace.toString(),
    });
  });
}

