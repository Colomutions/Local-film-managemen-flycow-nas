import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/src/library_database.dart';
import '../lib/src/library/library_values.dart';
import '../lib/src/media_service.dart';
import '../lib/src/metadata_probe.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final temp =
      await Directory.systemTemp.createTemp('episode-order-migration-');
  final db = NasLibraryDatabase('${temp.path}/data');
  try {
    final media = Directory('${temp.path}/media');
    for (final path in [
      'av/automatic/10.mkv',
      'av/automatic/2.mkv',
      'av/manual/B.mkv',
      'av/manual/a.mkv'
    ]) {
      final file = File('${media.path}/$path');
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);
    }
    await db.open();
    final root = db.ensureConfiguredMediaRoot(
        rootName: 'disk', containerPath: media.path);
    final category = db.createCategory('av');
    db.replaceCategoryMediaSources(categoryId: category.id, sources: [
      NasCategoryMediaSourceInput(mediaRootId: root.id, relativePath: 'av')
    ]);
    await db.scanCategory(
        categoryId: category.id,
        mediaRootId: root.id,
        mediaService:
            NasMediaService(mediaDir: media.path, fixtureRelativePath: null),
        metadataProbe: NasMediaMetadataProbe(
            runner: (_, __) async =>
                ProcessResult(0, 0, '{"streams":[],"format":{}}', '')));
    final automatic =
        db.listMovies().singleWhere((m) => m.title == 'automatic');
    final manual = db.listMovies().singleWhere((m) => m.title == 'manual');
    final originalIds = db.episodesForMovie(manual.id).map((e) => e.id).toSet();
    await db.close();
    final raw = sqlite3.open('${db.dataDir}/db/mujing.sqlite');
    try {
      raw.execute('ALTER TABLE movies DROP COLUMN episode_sort_mode');
      raw.execute('ALTER TABLE movies DROP COLUMN scanned_title');
      raw.execute('ALTER TABLE movies DROP COLUMN scan_grouping_mode');
      raw.execute('DELETE FROM schema_migrations WHERE version>=36');
      raw.execute('UPDATE episodes SET natural_sort_key=relative_path');
      raw.execute(
          "UPDATE episodes SET manual_order=CASE title WHEN 'B' THEN 10 ELSE NULL END WHERE movie_id=?",
          [manual.id]);
    } finally {
      raw.dispose();
    }
    await db.open();
    check(db.collectionEpisodeSortMode(automatic.id) == 'automatic',
        'old default stays automatic');
    check(db.collectionEpisodeSortMode(manual.id) == 'manual',
        'old explicit positions stay manual');
    check(
        db.episodesForMovie(automatic.id).map((e) => e.title).join(',') ==
            '2,10',
        'legacy keys upgraded to numeric order');
    check(db.episodesForMovie(manual.id).map((e) => e.title).join(',') == 'B,a',
        'manual positions survive migration');
    check(
        db.episodesForMovie(manual.id).every((e) => originalIds.contains(e.id)),
        'episode identity survives migration');
    final stable = db.episodesForMovie(manual.id).map((e) => e.id).join(',');
    await db.close();
    await db.open();
    check(db.episodesForMovie(manual.id).map((e) => e.id).join(',') == stable,
        'reopening is idempotent');
    await File('${media.path}/av/manual/0.mkv').writeAsBytes([4, 5, 6]);
    await db.scanCategory(
        categoryId: category.id,
        mediaRootId: root.id,
        mediaService:
            NasMediaService(mediaDir: media.path, fixtureRelativePath: null),
        metadataProbe: NasMediaMetadataProbe(
            runner: (_, __) async =>
                ProcessResult(0, 0, '{"streams":[],"format":{}}', '')));
    check(
        db.episodesForMovie(manual.id).map((e) => e.title).join(',') == 'B,a,0',
        'new segments append after the migrated NULL-order tail');
    final samples = [
      'ABF-001-10.mkv',
      'ABF-001-02.mkv',
      'ABF-001-1.mkv',
      'ABF-001-b.mkv',
      'ABF-001-A.mkv'
    ]..sort((a, b) => naturalSortKey(a).compareTo(naturalSortKey(b)));
    check(
        samples.join(',') ==
            'ABF-001-1.mkv,ABF-001-02.mkv,ABF-001-10.mkv,ABF-001-A.mkv,ABF-001-b.mkv',
        'numeric and case insensitive letter segments');
    check(
        naturalSortKey('dir-z/ABF_001_a.mkv') ==
            naturalSortKey('dir-a/abf-1-A.mp4'),
        'directory, extension and separator do not determine episode order');
    print('episode_order_migration_test: PASS');
  } finally {
    await db.close();
    await temp.delete(recursive: true);
  }
}
