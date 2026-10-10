import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/src/library/playback_repository.dart';
import '../lib/src/library/schema_repository.dart';
import '../lib/src/library_database.dart';

Future<void> main() async {
  _standalonePlaybackRepository();
  await _facadeReopenAndTransaction();
  stdout.writeln('library_repository_boundaries_test: PASS');
}

void _standalonePlaybackRepository() {
  final connection = sqlite3.openInMemory();
  try {
    connection.execute('PRAGMA foreign_keys = ON');
    NasSchemaRepository(() => connection).migrate();
    connection.execute('''
      INSERT INTO media_roots(
        id, name, container_path, read_only, enabled, created_at, updated_at
      ) VALUES ('root', 'Memory fixture', '/unused', 1, 1, '2026-01-01', '2026-01-01');
      INSERT INTO movies(id, title, created_at, updated_at)
        VALUES ('movie', 'Fixture', '2026-01-01', '2026-01-01');
      INSERT INTO episodes(
        id, movie_id, media_root_id, title, relative_path, file_size, is_available, updated_at
      ) VALUES ('episode', 'movie', 'root', 'Episode', 'unused.mp4', 0, 1, '2026-01-01');
    ''');
    final playback = NasPlaybackRepository(() => connection);
    final historyId = playback.recordPlaybackStarted(
      movieId: 'movie',
      episodeId: 'episode',
      deviceId: 'android',
      devicePlatform: 'android',
      durationMs: 120000,
    );
    playback.savePlaybackProgress(
      movieId: 'movie',
      episodeId: 'episode',
      positionMs: 30000,
      durationMs: 120000,
    );
    playback.reportPlaybackHistory(
      historyId: historyId,
      lastReportedAt: '2026-10-10T12:00:00Z',
      watchDurationMs: 30000,
      lastPositionMs: 30000,
      durationMs: 120000,
      playbackStatus: 'paused',
    );
    final resume = playback.resumeTargetForMovie('movie');
    _expect(resume?.episodeId == 'episode' && resume?.positionMs == 30000,
        'playback repository operates without a service or media filesystem');
    final page = playback.watchHistoryPage(const NasWatchHistoryQuery(
      query: '',
      startedOnOrAfter: null,
      startedBefore: null,
      devicePlatform: null,
      sort: 'startedAt',
      order: 'desc',
      page: 1,
      pageSize: 20,
    ));
    _expect(
        page.items.single.recordId == historyId &&
            page.items.single.watchDurationMs == 30000 &&
            page.items.single.status == 'paused',
        'history and resume share the injected SQLite connection');
  } finally {
    connection.dispose();
  }
}

Future<void> _facadeReopenAndTransaction() async {
  final root =
      await Directory.systemTemp.createTemp('mujing-repository-boundary-');
  final database = NasLibraryDatabase(root.path);
  try {
    await database.open();
    final category = database.createCategory('Keep');
    final movie =
        database.createEmptySeries(title: 'Keep', categoryId: category.id);
    final publisher = database.createPublisher(displayName: 'Keep');
    final before = database.revisions;
    try {
      database.transaction(() {
        database.createCategory('Rollback');
        database.createPublisher(displayName: 'Rollback');
        database.createEmptySeries(title: 'Rollback', categoryId: category.id);
        throw const FormatException('rollback boundary');
      });
    } on FormatException {
      _expect(
          database.listCategories().length == 1 &&
              database.listPublishers().length == 1 &&
              database.listMovies().length == 1,
          'one facade transaction rolls back writes made by different repositories');
      final after = database.revisions;
      _expect(before.keys.every((key) => before[key] == after[key]),
          'rolled back repository writes do not advance resource revisions');
    }

    await database.close();
    await database.open();
    _expect(
        database.findCategory(category.id)?.name == 'Keep' &&
            database.findMovieForAdmin(movie.id)?.title == 'Keep' &&
            database.findPublisher(publisher.id)?.displayName == 'Keep',
        'repositories reuse the current connection after the same facade reopens');
    database.updateMovieMetadata(movieId: movie.id, title: 'After reopen');
    _expect(database.findMovieForAdmin(movie.id)?.title == 'After reopen',
        'cross-repository callbacks do not retain a disposed connection');
    _expect(
        database.validateIntegrity(), 'reopened database remains consistent');
  } finally {
    await database.close();
    await root.delete(recursive: true);
  }
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
