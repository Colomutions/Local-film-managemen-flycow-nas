import 'dart:io';
import '../lib/src/scrape_service.dart';

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('mujing-scrape-process-');
  final worker = NasProcessScrapeWorker(
      script: File('scraper/worker.mjs').absolute.path, dataDir: temp.path);
  try {
    if (!worker.available) throw StateError('内置脚本未打包');
    final result = await worker.execute({'type': 'resumeSource'});
    if (result['until'] != 0) throw StateError('初次冷却状态无效');
    var rejected = false;
    try {
      await worker.execute({'type': 'movie', 'code': 'invalid'});
    } on NasScrapeException {
      rejected = true;
    }
    if (!rejected) throw StateError('应拒绝无效番号而不启动浏览器');
    await worker.close();
    await worker.execute({'type': 'resumeSource'});
    stdout.writeln('scrape_process_test: PASS');
  } finally {
    await worker.close();
    await temp.delete(recursive: true);
  }
}
