import 'dart:io';

import '../lib/src/library_database.dart';
import '../lib/src/media_service.dart';
import '../lib/src/metadata_probe.dart';

Future<void> main() async {
  final directory =
      await Directory.systemTemp.createTemp('mujing-nas-db-test-');
  final mediaRoot =
      Directory('${directory.path}${Platform.pathSeparator}media');
  final video = File(
      '${mediaRoot.path}${Platform.pathSeparator}真人${Platform.pathSeparator}sample.mp4');
  await video.parent.create(recursive: true);
  await video.writeAsBytes(List<int>.generate(32, (index) => index));
  final mediaService =
      NasMediaService(mediaDir: mediaRoot.path, fixtureRelativePath: null);
  final database =
      NasLibraryDatabase('${directory.path}${Platform.pathSeparator}data');
  var probeCalls = 0;
  final metadataProbe = NasMediaMetadataProbe(
    runner: (_, _) async {
      probeCalls++;
      return ProcessResult(
        1,
        0,
        '{"streams":[{"width":1920,"height":1080}],"format":{"duration":"12.5"}}',
        '',
      );
    },
  );

  try {
    await database.open();
    final scan = await database.scanConfiguredRoot(
      rootName: '测试媒体根',
      containerPath: mediaRoot.path,
      mediaService: mediaService,
      metadataProbe: metadataProbe,
    );
    _expect(scan.scannedFiles == 1, 'scanner imports supported video files');
    final movie = database.listMovies().single;
    _expect(movie.title == 'sample', 'scanner derives a display title');
    final episode = database.episodesForMovie(movie.id).single;
    _expect(episode.relativePath == '真人/sample.mp4',
        'database stores a relative path');
    _expect(episode.fileSize == 32, 'scanner stores file size');
    _expect(episode.isAvailable, 'scanner marks file available');
    _expect(episode.durationMs == 12500, 'scanner stores probed duration');
    _expect(episode.videoWidth == 1920 && episode.videoHeight == 1080,
        'scanner stores probed dimensions');
    _expect(episode.resolutionLabel == '1080P',
        'scanner stores normalized resolution label');
    final secondScan = await database.scanConfiguredRoot(
      rootName: '测试媒体根',
      containerPath: mediaRoot.path,
      mediaService: mediaService,
      metadataProbe: metadataProbe,
    );
    _expect(secondScan.scannedFiles == 1, 'unchanged media remains available');
    _expect(probeCalls == 1, 'unchanged media does not invoke ffprobe again');
    _expect(await mediaService.fileForRelativePath('../outside.mp4') == null,
        'media service rejects traversal');
    final configuredRoot = database.listMediaRoots().single;
    _expect(configuredRoot.readOnly, 'configured root remains read-only');
    _expect(configuredRoot.lastScannedAt != null,
        'scan records a persistent scan timestamp');

    await database.close();
    await database.open();
    final reopenedMovie = database.listMovies().single;
    _expect(reopenedMovie.id == movie.id,
        'SQLite data survives reopen');
    final reopenedEpisode = database.episodesForMovie(movie.id).single;
    _expect(reopenedEpisode.durationMs == 12500 &&
        reopenedEpisode.videoWidth == 1920 &&
        reopenedEpisode.videoHeight == 1080,
        'media metadata survives reopen');
    final reopenedRoot = database.listMediaRoots().single;
    _expect(
        reopenedRoot.id == configuredRoot.id, 'media root ID survives reopen');
    _expect(reopenedRoot.lastScannedAt == configuredRoot.lastScannedAt,
        'scan timestamp survives reopen');
  } finally {
    await database.close();
    await directory.delete(recursive: true);
  }

  stdout.writeln('library_database_test: PASS');
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('Assertion failed: $message');
}
