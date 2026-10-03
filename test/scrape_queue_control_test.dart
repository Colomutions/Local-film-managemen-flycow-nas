import 'dart:async';
import 'dart:io';
import '../lib/mujing_nas.dart';
import 'scrape_service_test.dart' show FakeWorker, expect, waitJob;

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('mujing-scrape-control-');
  final db = NasLibraryDatabase(temp.path);
  final worker = ControlledWorker();
  final service = NasScrapeService(db, NasArtworkService(temp.path), worker,
      cacheDir: '${temp.path}/scraper');
  try {
    await db.open();
    service.start();
    final job = service.create({'kind': 'actors', 'limit': 1});
    await worker.started.future;
    await service.control(job['id'] as String, 'pause');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final paused = db.scrapeJob(job['id'] as String)!;
    expect(paused['paused'] == 1 && (paused['counts'] as Map)['pending'] == 1,
        '暂停取消当前请求并保留任务');
    worker.hold = false;
    await service.control(job['id'] as String, 'resume');
    await waitJob(db, job['id'] as String);
    expect(db.listActors().length == 1, '继续相同范围');
    final before = worker.calls.length;
    final again = service.create({'kind': 'actors', 'limit': 1});
    await waitJob(db, again['id'] as String);
    expect(worker.calls.length == before + 1, '排名刷新但档案默认复用');

    worker.block = true;
    final blocked =
        service.create({'kind': 'actors', 'limit': 1, 'refresh': true});
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (db.scrapeSettings['blockedReason'] == null &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(db.scrapeSettings['blockedReason'] != null, '验证页暂停来源');
    final count = worker.calls.length;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(worker.calls.length == count, '来源暂停时不继续请求');
    await service.control(blocked['id'] as String, 'pause');
    worker.block = false;
    await service.resumeSource();
    expect(db.scrapeSettings['blockedReason'] == null, '显式恢复来源');
    stdout.writeln('scrape_queue_control_test: PASS');
  } finally {
    await service.close();
    await db.close();
    await temp.delete(recursive: true);
  }
}

class ControlledWorker extends FakeWorker {
  bool hold = true, block = false;
  final started = Completer<void>();
  Completer<Map<String, dynamic>>? pending;
  @override
  Future<Map<String, dynamic>> execute(Map<String, dynamic> input) async {
    if (hold) {
      pending = Completer<Map<String, dynamic>>();
      if (!started.isCompleted) started.complete();
      return pending!.future;
    }
    if (block) throw NasScrapeException('blocked', '网站要求验证');
    return super.execute(input);
  }

  @override
  void cancel() {
    if (pending != null && !pending!.isCompleted)
      pending!.completeError(NasScrapeException('cancelled', '暂停'));
  }
}
