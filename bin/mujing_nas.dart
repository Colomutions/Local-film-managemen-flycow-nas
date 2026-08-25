import 'dart:async';
import 'dart:io';

import '../lib/mujing_nas.dart';

Future<void> main(List<String> arguments) async {
  final config = NasConfig.fromEnvironment(Platform.environment);
  if (arguments.contains('--healthcheck')) {
    exitCode = await checkLocalHealth(config) ? 0 : 1;
    return;
  }

  final server = NasHealthServer(config);
  await server.start();
  stdout.writeln(
    'Mujing NAS health service listening on ${config.bindHost}:${server.port}.',
  );

  await Future.any<void>([
    ProcessSignal.sigint.watch.first,
    ProcessSignal.sigterm.watch.first,
  ]);
  await server.stop();
}

