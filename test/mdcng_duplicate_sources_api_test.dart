import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../lib/mujing_nas.dart';
import 'scrape_api_test.dart' show request;

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final temp =
      await Directory.systemTemp.createTemp('mujing-mdcng-duplicates-');
  final media = Directory('${temp.path}${Platform.pathSeparator}media');
  String mediaPath(String path) =>
      '${media.path}${Platform.pathSeparator}${path.replaceAll('/', Platform.pathSeparator)}';
  final oldVideo = File(mediaPath('disk1/av/PGD/PGD-889/PGD-889.avi'));
  final newVideo = File(mediaPath('disk2/AV/PGD/PGD-889/pgd-889.avi'));
  await oldVideo.parent.create(recursive: true);
  await oldVideo.writeAsBytes([1, 2, 3]);
  await newVideo.parent.create(recursive: true);
  final db = NasLibraryDatabase('${temp.path}/data');
  final server = NasHealthServer(
    NasConfig(
      bindHost: '127.0.0.1',
      port: 0,
      serverName: 'Test',
      advertiseUrl: null,
      pairingCode: 'test-pairing-code',
      fixtureMediaRelativePath: null,
      mediaRootName: '媒体库',
      scanOnStart: false,
      managedCategoryLibrary: true,
      dataDir: db.dataDir,
      mediaDir: media.path,
      timezone: 'Asia/Shanghai',
    ),
    libraryDatabase: db,
  );
  sqlite.Database? raw;
  try {
    await server.start();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final info = await request(base, 'GET', '/api/v1/server-info');
    final session =
        await request(base, 'POST', '/api/v1/pairing/sessions', body: {
      'serverId': info.$2['data']['serverId'],
      'requestedScope': 'admin',
    });
    final paired = await request(base, 'POST',
        '/api/v1/pairing/sessions/${session.$2['data']['pairingSessionId']}/confirm',
        body: {'pairingPassword': 'test-pairing-code'});
    final token = paired.$2['data']['accessToken'] as String;
    Future<Map> waitForJob(String path) async {
      for (var i = 0; i < 200; i++) {
        final response = await request(base, 'GET', path, token: token);
        check(response.$1 == 200, '任务查询成功');
        final job = response.$2['data'] as Map;
        if (job['status'] == 'succeeded') return job;
        check(job['status'] != 'failed', '任务不应中断');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      throw StateError('任务超时');
    }

    final created = await request(base, 'POST', '/api/v1/admin/categories',
        token: token,
        body: {
          'name': 'AV',
          'directoryKeys': ['disk1/av', 'disk2/AV'],
        });
    check(created.$1 == 201, '创建跨盘分类成功');
    final categoryId = created.$2['data']['id'] as String;
    await waitForJob(
        '/api/v1/admin/scan-jobs/${created.$2['data']['scanJob']['id']}');
    final oldMovie = db.listMovies().single;
    await oldVideo.delete();
    await newVideo.writeAsBytes([1, 2, 3]);
    await File('${newVideo.parent.path}/pgd-889.nfo').writeAsString(
        '<movie><title>PGD-889大失禁！</title><num>PGD-889</num><plot>disk2 的简介</plot></movie>');
    final scan = await request(base, 'POST', '/api/v1/admin/scan-jobs',
        token: token, body: {'categoryId': categoryId});
    await waitForJob('/api/v1/admin/scan-jobs/${scan.$2['data']['id']}');
    final newMovie =
        db.listMovies().singleWhere((movie) => movie.id != oldMovie.id);
    final oldEpisode = db.episodesForMovie(oldMovie.id).single;
    final newEpisode = db.episodesForMovie(newMovie.id).single;
    check(!oldEpisode.isAvailable && newEpisode.isAvailable,
        '跨盘移动会保留不可用旧记录，并创建不同 ID 的可用记录');
    Future<Map> preview() async {
      final response = await request(base, 'GET',
          '/api/v1/admin/mdcng-import-jobs/preview?categoryId=$categoryId',
          token: token);
      check(response.$1 == 200, '批量预览成功');
      return response.$2['data'] as Map;
    }

    final before = await preview();
    check(before['categoryMovieCount'] == 2 && before['movieCount'] == 1,
        '分类包含两条记录，只有 disk2 记录进入导入范围');
    final unavailable = (before['unavailableMovies'] as List).single as Map;
    final matching =
        (unavailable['matchingAvailableSources'] as List).single as Map;
    check(
        unavailable['movieId'] == oldMovie.id &&
            matching['movieId'] == newMovie.id &&
            matching['sourceName'] == 'disk2' &&
            matching['relativePath'] == 'AV/PGD/PGD-889/pgd-889.avi',
        '问题旧记录列出同分类同文件名的 disk2 记录，忽略文件名大小写');
    final batch = await request(base, 'POST', '/api/v1/admin/mdcng-import-jobs',
        token: token, body: {'categoryId': categoryId});
    final done = await waitForJob(
        '/api/v1/admin/mdcng-import-jobs/${batch.$2['data']['id']}');
    check(
        done['total'] == 1 &&
            done['applied'] == 1 &&
            done['failed'] == 0 &&
            db.findMovieForAdmin(newMovie.id)!.summary == 'disk2 的简介' &&
            db.findMovieForAdmin(oldMovie.id)!.summary.isEmpty,
        '导入 disk2 NFO 到 disk2 记录，不借用到同名旧记录');

    // 相同片名不足以关联来源；其他分类和影集也不参与单片重复提示。
    final otherVideo = File(mediaPath('disk3/AV/PGD-889.avi'));
    await otherVideo.parent.create(recursive: true);
    await otherVideo.writeAsBytes([1, 2, 3]);
    final otherCategory = await request(
        base, 'POST', '/api/v1/admin/categories',
        token: token, body: {'name': '其他', 'directoryKey': 'disk3/AV'});
    await waitForJob(
        '/api/v1/admin/scan-jobs/${otherCategory.$2['data']['scanJob']['id']}');
    raw = sqlite.sqlite3.open('${db.dataDir}/db/mujing.sqlite');
    raw.execute(
        "UPDATE movies SET entry_type='series' WHERE id=?", [newMovie.id]);
    final seriesPreview = await preview();
    check(
        ((seriesPreview['unavailableMovies'] as List)
                .single['matchingAvailableSources'] as List)
            .isEmpty,
        '不同分类和影集的同名分集不列为单片重复候选');
    raw.execute("UPDATE movies SET entry_type='single',title=? WHERE id=?",
        [oldMovie.title, newMovie.id]);
    raw.execute('UPDATE episodes SET relative_path=? WHERE id=?',
        ['AV/Other.avi', newEpisode.id]);
    final titleOnly = await preview();
    check(
        ((titleOnly['unavailableMovies'] as List)
                .single['matchingAvailableSources'] as List)
            .isEmpty,
        '同片名但文件名不同的记录不提示为同文件名记录');
    raw.execute('UPDATE episodes SET relative_path=? WHERE id=?',
        [newEpisode.relativePath, newEpisode.id]);

    raw.execute('UPDATE media_roots SET is_online=0 WHERE id=?',
        [newEpisode.mediaRootId]);
    final offlinePreview = await preview();
    final oldOffline = (offlinePreview['unavailableMovies'] as List)
        .singleWhere((movie) => movie['movieId'] == oldMovie.id);
    check((oldOffline['matchingAvailableSources'] as List).isEmpty,
        '来源盘离线的同文件名记录不列为可用候选');
    raw.execute('UPDATE media_roots SET is_online=1 WHERE id=?',
        [newEpisode.mediaRootId]);

    // 同一影片 ID 有旧盘不可用来源和新盘可用来源时，不应再进入问题清单。
    raw.execute('UPDATE episodes SET movie_id=? WHERE id=?',
        [newMovie.id, oldEpisode.id]);
    await File('${newVideo.parent.path}/pgd-889.nfo').writeAsString(
        '<movie><title>PGD-889大失禁！</title><num>PGD-889</num><plot>disk2 更新的简介</plot></movie>');
    final joinedPreview = await preview();
    check(
        joinedPreview['categoryMovieCount'] == 1 &&
            joinedPreview['movieCount'] == 1 &&
            (joinedPreview['unavailableMovies'] as List).isEmpty,
        '同 ID 的可用 disk2 来源足以使影片记录参与导入');
    final joinedBatch = await request(
        base, 'POST', '/api/v1/admin/mdcng-import-jobs',
        token: token, body: {'categoryId': categoryId});
    final joinedDone = await waitForJob(
        '/api/v1/admin/mdcng-import-jobs/${joinedBatch.$2['data']['id']}');
    check(
        joinedDone['failed'] == 0 &&
            joinedDone['applied'] == 1 &&
            db.findMovieForAdmin(newMovie.id)!.summary == 'disk2 更新的简介',
        '同 ID 下跳过不可用旧盘，继续读取 disk2 NFO');
    stdout.writeln('mdcng_duplicate_sources_api_test: PASS');
  } finally {
    raw?.dispose();
    await server.stop();
    if (!temp.absolute.path.startsWith(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}')) {
      throw StateError('临时目录边界无效');
    }
    await temp.delete(recursive: true);
  }
}
