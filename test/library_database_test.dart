import 'dart:io';

import '../lib/src/library_database.dart';
import '../lib/src/media_service.dart';
import '../lib/src/metadata_probe.dart';
import '../lib/src/movie_actor.dart';

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
    runner: (command, arguments) async {
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
    final actorOne = database.createActor(
      translatedName: '演员甲',
      gender: 'female',
    );
    final actorTwo = database.createActor(
      translatedName: '演员乙',
      gender: 'male',
    );
    final publisher = database.createPublisher(
      displayName: '测试发行商',
      originalName: 'Test Publisher',
    );
    final draftSeries = database.createSeries(displayName: '未归属草稿系列');
    _expect(
      draftSeries.publisherId == null,
      'series draft may omit a publisher before it has films',
    );
    _expect(
      database.resolveMovieRelations(
            movieId: movie.id,
            publisherId: null,
            updatePublisherId: true,
            seriesId: draftSeries.id,
            updateSeriesId: true,
          ) ==
          null,
      'series draft cannot be linked to a movie before publisher is selected',
    );
    final series = database.createSeries(
      displayName: '测试系列',
      publisherId: publisher.id,
      releaseDate: '2026-09-10',
    );
    _expect(
      database.updateMovieMetadata(
            movieId: movie.id,
            originalTitle: 'Sample Original',
            updateOriginalTitle: true,
            catalogNumber: 'ABC-001',
            updateCatalogNumber: true,
          ) !=
          null,
      'database updates movie metadata',
    );
    _expect(
      database.updateMovieRelations(
            movieId: movie.id,
            publisherId: publisher.id,
            updatePublisherId: true,
            seriesId: series.id,
            updateSeriesId: true,
          ) !=
          null,
      'database stores movie publisher and series IDs',
    );
    _expect(
      database.setMovieActorIds(
          movieId: movie.id, actorIds: [actorOne.id, actorTwo.id]),
      'database stores native actor IDs only',
    );
    final linkedMovie = database.findMovieForAdmin(movie.id)!;
    _expect(linkedMovie.originalTitle == 'Sample Original',
        'database stores the original title');
    _expect(linkedMovie.catalogNumber == 'ABC-001',
        'database stores the catalog number');
    _expect(
      linkedMovie.publisherId == publisher.id &&
          linkedMovie.publisherName == '测试发行商',
      'database resolves the publisher through its stable ID',
    );
    _expect(
      linkedMovie.seriesId == series.id && linkedMovie.seriesName == '测试系列',
      'database resolves the series through its stable ID',
    );
    _expect(
      database.updateMovieRelations(
            movieId: movie.id,
            publisherId: null,
            updatePublisherId: true,
            seriesId: series.id,
            updateSeriesId: true,
          ) ==
          null,
      'database rejects a series and publisher conflict',
    );
    _expect(
      database.setActorPublisherIds(
        actorId: actorOne.id,
        publisherIds: [publisher.id],
      ),
      'actor publisher links use publisher entity IDs',
    );
    _expect(
      database.publishersForActor(actorOne.id).single.id == publisher.id,
      'actor publisher links resolve entity data',
    );
    _expect(
        linkedMovie.actors.length == 2 &&
            linkedMovie.actors.any((actor) =>
                actor.name == '演员甲' && actor.gender == NasActorGender.female),
        'database stores structured actors');
    _expect(database.listMovies(query: 'sample original').length == 1,
        'database searches the original title');
    _expect(database.listMovies(query: 'abc001').length == 1,
        'database searches normalized catalog numbers');
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
    database.recordPlaybackStarted(movieId: movie.id, episodeId: episode.id);
    _expect(database.lastPlaybackStartedAtForMovie(movie.id) != null,
        'database returns the latest playback timestamp for a movie');
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
    _expect(reopenedMovie.id == movie.id, 'SQLite data survives reopen');
    _expect(
        reopenedMovie.originalTitle == 'Sample Original' &&
            reopenedMovie.catalogNumber == 'ABC-001' &&
            reopenedMovie.publisherId == publisher.id &&
            reopenedMovie.seriesId == series.id,
        'movie identity metadata survives reopen');
    _expect(
      reopenedMovie.actors.any((actor) =>
          actor.name == '演员乙' && actor.gender == NasActorGender.male),
      'native actor links survive reopen',
    );
    final reopenedEpisode = database.episodesForMovie(movie.id).single;
    _expect(
        reopenedEpisode.durationMs == 12500 &&
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
