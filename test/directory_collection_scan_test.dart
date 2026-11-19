import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/mujing_nas.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final scenarios = <String, Future<void> Function(_Library)>{
    'directory grouping': _directoryGrouping,
    'single upgrade': _singleUpgrade,
    'composition ownership': _compositionOwnership,
    'legacy suffix rename': _suffixRename,
    'occupied suffix rename target': _occupiedSuffixRenameTarget,
    'occupied suffix target on later disk': (library) =>
        _occupiedSuffixRenameTarget(library, disk: 2, addEarlierSegment: true),
    'simultaneous suffix directories': _simultaneousSuffixDirectories,
    'changed suffix rename candidates': _changedSuffixRename,
    'legacy single migration': _legacySingleMigration,
    'hidden legacy key migration': _hiddenLegacyKeyMigration,
    'automatic and manual order': _episodeOrder,
    'legacy schema order migration': _schemaOrderMigration,
    'split directory conflict': _splitConflict,
  };
  final failures = <String>[];
  for (final scenario in scenarios.entries) {
    final library = await _Library.open();
    try {
      await scenario.value(library);
      check(library.db.validateIntegrity(),
          '${scenario.key}: database integrity');
      stdout.writeln('${scenario.key}: PASS');
    } on Object catch (error, stack) {
      failures.add('${scenario.key}: $error');
      stderr.writeln('${scenario.key}: FAIL\n$error\n$stack');
    } finally {
      await library.close();
    }
  }
  if (failures.isNotEmpty) {
    throw StateError(failures.join('\n'));
  }
  stdout.writeln('directory_collection_scan_test: PASS');
}

Future<void> _directoryGrouping(_Library library) async {
  for (final path in [
    'Single/part1.mkv',
    'Multiple/part1.mkv',
    'Multiple/part2.mkv',
    'Multiple/part10.mkv',
    'Parent/direct.mkv',
    'Parent/Child/part1.mkv',
    'Parent/Child/part2.mkv',
    'loose1.mp4',
    'loose2.mp4',
  ]) {
    await library.write(path);
  }
  await library.write('Multiple/part3.mkv', disk: 2);
  final result = await library.scan();
  final movies = library.db.listMovies();
  check(result.conflicts.isEmpty && result.scannedFiles == 10,
      'new directory layout enumerates every video without suffix markers');
  check(movies.length == 6,
      'one work per immediate video directory; root files remain separate');
  final single = movies.singleWhere((m) => m.title == 'part1');
  check(single.entryType == 'single' && single.episodeCount == 1,
      'one video in a work directory starts as a single');
  final multiple = movies.singleWhere((m) => m.title == 'Multiple');
  check(
      library.db.hasDefaultScannedTitle(single.id) &&
          library.db.hasDefaultScannedTitle(multiple.id),
      'new directory titles remain eligible for first NFO/scrape enrichment');
  check(multiple.entryType == 'series' && multiple.episodeCount == 4,
      'matching work directories on two disks share their collection');
  check(library.titles(multiple.id) == 'part1,part2,part3,part10',
      'new collection episodes use natural filename order across disks');
  check(
      movies.singleWhere((m) => m.title == 'direct').episodeCount == 1 &&
          movies.singleWhere((m) => m.title == 'Child').episodeCount == 2,
      'nested directories are independent and are not absorbed by their parent');
  check(
      movies
          .where((m) => m.title.startsWith('loose'))
          .every((m) => m.entryType == 'single'),
      'category root videos do not become one collection');
  final before = library.probes;
  final originalIds = movies.map((m) => m.id).toSet();
  await library.scan();
  check(
      library.probes == before &&
          library.db
              .listMovies()
              .map((m) => m.id)
              .toSet()
              .containsAll(originalIds),
      'unchanged rescan retains movie identities without new media probes');
}

Future<void> _singleUpgrade(_Library library) async {
  await library.write('Growing/第1集.mkv');
  await library.scan();
  final single = library.db.listMovies().single;
  final originalEpisode = library.db.episodesForMovie(single.id).single;
  library.db.updateMovieMetadata(
      movieId: single.id,
      title: 'Manual title',
      catalogNumber: 'KEEP-001',
      updateCatalogNumber: true,
      summary: 'Manual summary');
  check(!library.db.hasDefaultScannedTitle(single.id),
      'manual movie title is protected from automatic metadata enrichment');
  library.db.setMovieFavorite(movieId: single.id, isFavorite: true);
  final actor =
      library.db.createActor(stageName: 'Keep actor', gender: 'female');
  library.db.setMovieActorIds(movieId: single.id, actorIds: [actor.id]);
  final tag = library.db.createTag(name: 'Keep tag', level: 1);
  library.db.setMovieTaxonomy(
      movieId: single.id,
      updateCategory: false,
      categoryId: null,
      updateTagIds: true,
      tagIds: [tag.id]);
  library.recordPlayback(single.id, originalEpisode.id);
  final before = library.probes;
  await library.write('Growing/第2集.mkv');
  await library.scan();
  final upgraded = library.db.listMovies().single;
  check(
      upgraded.id == single.id &&
          upgraded.entryType == 'series' &&
          upgraded.episodeCount == 2,
      'a new segment upgrades the original single in place');
  check(
      upgraded.title == 'Manual title' &&
          upgraded.catalogNumber == 'KEEP-001' &&
          upgraded.summary == 'Manual summary' &&
          upgraded.isFavorite,
      'upgrading preserves edited metadata and favorite state');
  check(
      library.db.actorsForMovie(upgraded.id).single.id == actor.id &&
          library.db.tagsForMovie(upgraded.id).single.id == tag.id,
      'upgrading preserves actor and tag associations');
  check(library.db.episodesForMovie(upgraded.id).first.id == originalEpisode.id,
      'upgrading retains the original episode ID');
  library.checkPlayback(upgraded.id, originalEpisode.id);
  check(library.probes == before + 1, 'upgrading probes only the new segment');
}

Future<void> _compositionOwnership(_Library library) async {
  for (final path in ['Left/1.mkv', 'Right/2.mkv', 'Third/3.mkv']) {
    await library.write(path);
  }
  await library.scan();
  final sources = library.db.listMovies();
  final originalEpisodeIds = sources
      .expand((m) => library.db.episodesForMovie(m.id))
      .map((e) => e.id)
      .toSet();
  final firstTarget = await library.compose([sources[0].id, sources[1].id]);
  final finalTarget = await library.compose([firstTarget, sources[2].id]);
  final before = library.probes;
  await library.write('Left/4.mkv');
  await library.write('Right/5.mkv', disk: 2);
  await library.scan();
  final wall = library.db.listMovies();
  check(
      wall.length == 1 &&
          wall.single.id == finalTarget &&
          wall.single.episodeCount == 5,
      'rescan and new segments follow the final owner through repeated compositions');
  check(
      library.db
          .episodesForMovie(finalTarget)
          .map((e) => e.id)
          .toSet()
          .containsAll(originalEpisodeIds),
      'composition and rescan retain every original episode identity');
  check(
      [...sources.map((m) => m.id), firstTarget]
          .every((id) => library.db.findMovie(id) == null),
      'hidden source movies never reappear as loose entries');
  check(library.probes == before + 2,
      'rescan probes only two new segments after composition');
}

Future<void> _suffixRename(_Library library) async {
  await library.write('Legacy - 影集/第1集.mkv');
  await library.write('Legacy - 影集/第2集.mkv');
  await library.scan();
  final movie = library.db.listMovies().single;
  final episodes = library.db.episodesForMovie(movie.id);
  library.raw.execute('UPDATE movies SET collection_key=? WHERE id=?',
      ['legacy-collection-key', movie.id]);
  library.db.updateMovieMetadata(
      movieId: movie.id,
      title: 'Edited legacy',
      summary: 'Retained summary',
      catalogNumber: 'LEGACY-001',
      updateCatalogNumber: true);
  library.recordPlayback(movie.id, episodes.first.id);
  final before = library.probes;
  await Directory(library.path('Legacy - 影集')).rename(library.path('Legacy'));
  final result = await library.scan();
  final renamed = library.db.listMovies().single;
  final renamedEpisodes = library.db.episodesForMovie(renamed.id);
  check(
      result.conflicts.isEmpty &&
          renamed.id == movie.id &&
          renamed.episodeCount == 2,
      'removing the legacy suffix keeps the same collection');
  check(
      renamedEpisodes
              .map((e) => e.id)
              .toSet()
              .containsAll(episodes.map((e) => e.id)) &&
          renamedEpisodes.every((e) =>
              e.relativePath.startsWith('films/Legacy/') && e.isAvailable),
      'suffix removal updates paths without replacing episode IDs');
  check(
      renamed.title == 'Edited legacy' &&
          renamed.catalogNumber == 'LEGACY-001' &&
          renamed.summary == 'Retained summary',
      'suffix removal preserves the edited collection metadata');
  library.checkPlayback(movie.id, episodes.first.id);
  check(library.probes == before,
      'suffix-only directory rename reuses existing media probe results');
  check(
      library.raw.select('SELECT COUNT(*) AS n FROM episodes').single['n'] == 2,
      'suffix removal leaves no duplicate episode indexes');
}

Future<void> _simultaneousSuffixDirectories(_Library library) async {
  await library.write('Ambiguous - 影集/1.mp4');
  await library.write('Ambiguous - 影集/2.mp4');
  await library.scan();
  final original = library.db.listMovies().single;
  final episodes = library.db.episodesForMovie(original.id);
  final before = library.probes;
  await Directory(library.path('Ambiguous')).create();
  await File(library.path('Ambiguous - 影集/1.mp4'))
      .copy(library.path('Ambiguous/1.mp4'));
  await library.write('Ambiguous/3.mp4');
  final result = await library.scan();
  check(
      result.conflicts.isNotEmpty &&
          library.db.listMovies().single.id == original.id,
      'coexisting old and new directory names never guess a new movie');
  check(
      library.db
              .episodesForMovie(original.id)
              .map((e) => e.id)
              .toSet()
              .containsAll(episodes.map((e) => e.id)) &&
          library.raw.select('SELECT relative_path FROM episodes').every(
              (row) => (row['relative_path'] as String)
                  .startsWith('films/Ambiguous - 影集/')),
      'existing suffix paths stay untouched while conflicting new paths remain unindexed');
  check(
      library.raw.select('SELECT COUNT(*) AS n FROM episodes').single['n'] ==
              2 &&
          library.probes == before,
      'conflicting directories create no duplicate episode or extra media probe');
}

Future<void> _occupiedSuffixRenameTarget(_Library library,
    {int disk = 1, bool addEarlierSegment = false}) async {
  await library.write('Occupied - 影集/1.mp4', disk: disk);
  await library.scan();
  final original = library.db.listMovies().single;
  final oldEpisode = library.db.episodesForMovie(original.id).single;
  await Directory(library.path('Occupied - 影集', disk: disk))
      .rename(library.path('Occupied', disk: disk));
  final target = library.db.createEmptySeries(
      title: 'Existing target', categoryId: library.category.id);
  // 模拟旧库里新路径已独立入库、旧后缀记录尚未清理的状态。
  library.raw.execute('''UPDATE movies
    SET entry_type='single',collection_key=NULL,scan_grouping_mode='automatic'
    WHERE id IN (?,?)''', [original.id, target.id]);
  library.raw.execute('''INSERT INTO episodes(
    id,movie_id,media_root_id,title,relative_path,duration_ms,video_width,
    video_height,resolution_label,metadata_probed_at,media_modified_at,
    file_size,is_available,natural_sort_key,updated_at)
    SELECT ?,?,media_root_id,title,?,duration_ms,video_width,video_height,
      resolution_label,metadata_probed_at,media_modified_at,file_size,
      is_available,natural_sort_key,updated_at FROM episodes WHERE id=?''', [
    'occupied-target-episode',
    target.id,
    'films/Occupied/1.mp4',
    oldEpisode.id,
  ]);
  if (addEarlierSegment) {
    // 冲突盘尚未枚举时，也不能由先扫描的另一块盘触发自动归并。
    await library.write('Occupied/2.mp4');
  }
  final movieIds = {original.id, target.id};
  final episodeIds = {oldEpisode.id, 'occupied-target-episode'};
  final before = library.probes;
  for (var scan = 0; scan < 2; scan++) {
    final result = await library.scan();
    check(result.conflicts.any((message) => message.contains('去后缀目标已对应其他分集')),
        'an occupied suffix rename destination reports a collision');
    check(
        library.db.listMovies().length == 2 &&
            library.db
                .listMovies()
                .map((movie) => movie.id)
                .toSet()
                .containsAll(movieIds),
        'colliding old and exact-path singles never merge automatically');
    final rows = library.raw
        .select('SELECT id,movie_id,relative_path,is_available FROM episodes');
    check(
        rows.length == 2 &&
            rows.map((row) => row['id']).toSet().containsAll(episodeIds) &&
            rows.singleWhere((row) => row['id'] == oldEpisode.id)['movie_id'] ==
                original.id &&
            rows.singleWhere((row) => row['id'] == 'occupied-target-episode')[
                    'movie_id'] ==
                target.id,
        'collision handling retains episode IDs and owners without duplicate indexes');
    check(
        rows.singleWhere(
                    (row) => row['id'] == oldEpisode.id)['relative_path'] ==
                'films/Occupied - 影集/1.mp4' &&
            rows.singleWhere(
                    (row) => row['id'] == oldEpisode.id)['is_available'] ==
                0 &&
            rows.singleWhere((row) => row['id'] == 'occupied-target-episode')[
                    'is_available'] ==
                1 &&
            library.probes == before,
        'the exact existing file stays available while the missing old path remains offline without probing');
  }
}

Future<void> _changedSuffixRename(_Library library) async {
  await library.write('Changed size - 影集/1.mp4');
  await library.write('Changed time - 影集/1.mp4');
  await library.scan();
  final originalIds = library.db.listMovies().map((m) => m.id).toSet();
  final before = library.probes;
  for (final directory in ['Changed size', 'Changed time']) {
    await Directory(library.path('$directory - 影集'))
        .rename(library.path(directory));
  }
  await File(library.path('Changed size/1.mp4'))
      .writeAsBytes(List.filled(64, 2));
  final timeFile = File(library.path('Changed time/1.mp4'));
  final oldTime = (await timeFile.stat()).modified;
  await timeFile.setLastModified(oldTime.add(const Duration(seconds: 5)));
  final result = await library.scan();
  check(result.conflicts.length >= 2,
      'suffix rename candidates with changed size or modification time are reported separately');
  check(
      library.db.listMovies().length == 2 &&
          library.db
              .listMovies()
              .map((m) => m.id)
              .toSet()
              .containsAll(originalIds),
      'changed candidates preserve existing movies without creating replacement entries');
  check(
      library.raw.select('SELECT relative_path FROM episodes').every(
              (row) => (row['relative_path'] as String).contains(' - 影集/')) &&
          library.raw
                  .select('SELECT COUNT(*) AS n FROM episodes')
                  .single['n'] ==
              2 &&
          library.probes == before,
      'uncertain renamed files remain unassigned without extra probes or duplicate episode indexes');
}

Future<void> _legacySingleMigration(_Library library) async {
  await library.write('Legacy singles/1.mp4');
  await library.write('Legacy singles/2.mp4');
  await library.scan();
  final original = library.db.listMovies().single;
  final episodes = library.db.episodesForMovie(original.id);
  final second = library.db.createEmptySeries(
      title: 'Main legacy metadata', categoryId: library.category.id);
  library.raw.execute(
      "UPDATE movies SET entry_type='single',collection_key=NULL WHERE id IN (?,?)",
      [original.id, second.id]);
  library.raw.execute('UPDATE episodes SET movie_id=? WHERE id=?',
      [second.id, episodes.last.id]);
  library.db.updateMovieMetadata(
      movieId: second.id,
      summary: 'Selected legacy summary',
      catalogNumber: 'LEGACY-SINGLE-002',
      updateCatalogNumber: true);
  library.recordPlayback(second.id, episodes.last.id);
  final before = library.probes;
  final preview = library.db.collectionMigrationPreview().single;
  check(
      preview.sourceMovieIds.length == 2 &&
          preview.episodeIds.length == 2 &&
          preview.requiresMetadataChoice,
      'multiple legacy singles in one ordinary directory require an explicit metadata source');
  check(library.db.listMovies().length == 2,
      'migration preview leaves existing singles untouched');
  final migrated = (await library.db.applyCollectionMigration(
      key: preview.key, metadataSourceMovieId: second.id))!;
  check(
      migrated.id != original.id &&
          migrated.id != second.id &&
          migrated.entryType == 'series' &&
          migrated.episodeCount == 2,
      'confirmed legacy migration creates one collection and moves every source episode');
  check(
      migrated.title == 'Main legacy metadata' &&
          migrated.summary == 'Selected legacy summary' &&
          migrated.catalogNumber == 'LEGACY-SINGLE-002',
      'legacy migration uses the chosen main metadata');
  library.checkPlayback(migrated.id, episodes.last.id);
  await library.write('Legacy singles/3.mp4');
  await library.scan();
  check(
      library.db.listMovies().single.id == migrated.id &&
          library.db.findMovie(migrated.id)!.episodeCount == 3 &&
          library.db
              .episodesForMovie(migrated.id)
              .map((e) => e.id)
              .toSet()
              .containsAll(episodes.map((e) => e.id)),
      'new segments after migration join the confirmed collection and retain old episode IDs');
  check(
      library.probes == before + 1 &&
          library.db.collectionMigrationPreview().isEmpty,
      'completed migration stays out of subsequent previews and only probes the new segment');
}

Future<void> _hiddenLegacyKeyMigration(_Library library) async {
  await library.write('Hidden key - 影集/1.mp4');
  await library.write('Hidden key - 影集/2.mp4');
  await library.write('Other/3.mp4');
  await library.scan();
  final original =
      library.db.listMovies().singleWhere((m) => m.entryType == 'series');
  final other =
      library.db.listMovies().singleWhere((m) => m.entryType == 'single');
  final legacyKey = '${library.category.id}:Hidden key';
  library.raw.execute('UPDATE movies SET collection_key=? WHERE id=?',
      [legacyKey, original.id]);
  final composed = await library.compose([original.id, other.id]);
  check(library.db.findMovie(original.id) == null,
      'legacy collection is hidden after composition');
  check(
      library.db
              .splitEpisodesIntoSingles(
                  movieId: composed,
                  episodeIds: library.db
                      .episodesForMovie(composed)
                      .map((e) => e.id)
                      .toList())!
              .length ==
          3,
      'composed collection can be fully split without restoring hidden sources');
  var candidate = library.db
      .collectionMigrationPreview()
      .singleWhere((c) => c.key == legacyKey);
  var migrated = (await library.db.applyCollectionMigration(
      key: candidate.key,
      metadataSourceMovieId: candidate.sourceMovieIds.first))!;
  check(migrated.id != original.id && migrated.episodeCount == 2,
      'migration creates a fresh target while a hidden source owns the unique legacy key');
  check(
      library.raw.select(
                  'SELECT id,lifecycle_state FROM movies WHERE collection_key=?',
                  [legacyKey]).single['id'] ==
              original.id &&
          library.db.findMovie(original.id) == null,
      'migration preserves the hidden source alias without reactivating it');
  check(
      library.db
              .splitEpisodesIntoSingles(
                  movieId: migrated.id,
                  episodeIds: library.db
                      .episodesForMovie(migrated.id)
                      .map((e) => e.id)
                      .toList())!
              .length ==
          2,
      'new target can be split again while the hidden alias remains');
  candidate = library.db
      .collectionMigrationPreview()
      .singleWhere((c) => c.key == legacyKey);
  migrated = (await library.db.applyCollectionMigration(
      key: candidate.key,
      metadataSourceMovieId: candidate.sourceMovieIds.first))!;
  await library.write('Hidden key - 影集/4.mp4');
  await library.scan();
  check(
      library.db.findMovie(migrated.id)!.episodeCount == 3 &&
          library.db.listMovies().length == 2 &&
          library.db.findMovie(original.id) == null &&
          library.db.findMovie(composed) == null,
      'repeated split and migration never collide with unique aliases or resurrect old movie rows');
}

Future<void> _episodeOrder(_Library library) async {
  await library.write('Order/第1集.mp4');
  await library.write('Order/第10集.mp4');
  await library.scan();
  final movie = library.db.listMovies().single;
  check(library.titles(movie.id) == '第1集,第10集',
      'initial episodes use natural order');
  await library.write('Order/第2集.mp4');
  await library.scan();
  check(library.titles(movie.id) == '第1集,第2集,第10集',
      'automatic order places a new episode at its filename position');
  final episodes = library.db.episodesForMovie(movie.id);
  final manualIds = [episodes[2].id, episodes[0].id, episodes[1].id];
  check(
      library.db.setCollectionEpisodeOrder(
          movieId: movie.id, mode: 'manual', episodeIds: manualIds),
      'complete manual episode order can be saved');
  final before = library.probes;
  await library.scan();
  check(
      library.db.episodesForMovie(movie.id).map((e) => e.id).join(',') ==
              manualIds.join(',') &&
          library.probes == before,
      'unchanged rescan retains the manual sequence and skips media probes');
  await library.write('Order/第0集.mp4');
  await library.scan();
  check(library.titles(movie.id) == '第10集,第1集,第2集,第0集',
      'manual order appends a newly discovered segment');
  check(
      library.db.setCollectionEpisodeOrder(
              movieId: movie.id, mode: 'automatic') &&
          library.titles(movie.id) == '第0集,第1集,第2集,第10集',
      'switching back to automatic immediately restores natural filename order');
}

Future<void> _schemaOrderMigration(_Library library) async {
  for (final path in [
    'Automatic/第1集.mp4',
    'Automatic/第2集.mp4',
    'Automatic/第10集.mp4',
    'Manual/1.mp4',
    'Manual/2.mp4',
  ]) {
    await library.write(path);
  }
  await library.scan();
  final movies = library.db.listMovies();
  final automatic = movies.singleWhere((m) => m.title == 'Automatic');
  final manual = movies.singleWhere((m) => m.title == 'Manual');
  final manualIds =
      library.db.episodesForMovie(manual.id).reversed.map((e) => e.id).toList();
  check(
      library.db.setCollectionEpisodeOrder(
          movieId: manual.id, mode: 'manual', episodeIds: manualIds),
      'fixture starts with an existing saved manual order');
  final before = library.probes;
  await library.db.close();
  // Recreate the version 35 shape and old cached sort keys using only this
  // disposable fixture, then exercise the real database upgrade path.
  library.raw.execute('ALTER TABLE movies DROP COLUMN episode_sort_mode');
  library.raw.execute('ALTER TABLE movies DROP COLUMN scanned_title');
  library.raw.execute('ALTER TABLE movies DROP COLUMN scan_grouping_mode');
  library.raw.execute('DELETE FROM schema_migrations WHERE version>=36');
  library.raw.execute("UPDATE episodes SET natural_sort_key='' ");
  await library.db.open();
  check(
      library.db.collectionEpisodeSortMode(automatic.id) == 'automatic' &&
          library.titles(automatic.id) == '第1集,第2集,第10集',
      'upgrade backfills natural sort keys for existing automatic collections');
  check(
      library.db.collectionEpisodeSortMode(manual.id) == 'manual' &&
          library.db.episodesForMovie(manual.id).map((e) => e.id).join(',') ==
              manualIds.join(','),
      'upgrade detects and retains legacy manual ordering');
  await library.scan();
  check(library.probes == before,
      'sort migration and the following scan never repeat media probes');
}

Future<void> _splitConflict(_Library library) async {
  await library.write('Split/1.mkv');
  await library.write('Split/2.mkv');
  await library.scan();
  final movie = library.db.listMovies().single;
  final episode = library.db.episodesForMovie(movie.id).last;
  final split = library.db.splitEpisodesIntoSingles(
      movieId: movie.id, episodeIds: [episode.id])!.single;
  final before = library.probes;
  await library.write('Split/3.mkv');
  await library.write('Unaffected/4.mkv');
  final result = await library.scan();
  check(result.conflicts.isNotEmpty,
      'a new segment in a directory with multiple manual owners reports conflict');
  check(
      library.raw
          .select(
              "SELECT id FROM episodes WHERE relative_path='films/Split/3.mkv'")
          .isEmpty,
      'ambiguous new segments never create a duplicate movie or episode');
  check(
      library.db.listMovies().length == 3 &&
          library.db.findMovie(movie.id)!.episodeCount == 1 &&
          library.db.findMovie(split.id)!.episodeCount == 1,
      'existing manually split owners are retained and unaffected directories still scan');
  check(
      library.db.episodesForMovie(split.id).single.isAvailable &&
          library.probes == before + 1,
      'existing split episodes stay available; only the unambiguous new file is probed');
}

class _Library {
  _Library(
      this.temporary, this.media, this.db, this.raw, this.root, this.category);

  final Directory temporary;
  final Directory media;
  final NasLibraryDatabase db;
  final Database raw;
  final NasMediaRoot root;
  final NasLibraryCategory category;
  var probes = 0;

  static Future<_Library> open() async {
    final temporary =
        await Directory.systemTemp.createTemp('mujing-directory-scan-');
    final media = Directory('${temporary.path}${Platform.pathSeparator}media');
    for (final disk in [1, 2]) {
      await Directory(
              '${media.path}${Platform.pathSeparator}disk$disk${Platform.pathSeparator}films')
          .create(recursive: true);
    }
    final data = '${temporary.path}${Platform.pathSeparator}data';
    final db = NasLibraryDatabase(data);
    await db.open();
    final roots = [
      for (final disk in [1, 2])
        db.ensureConfiguredMediaRoot(
            rootName: 'disk$disk',
            containerPath: '${media.path}${Platform.pathSeparator}disk$disk')
    ];
    final category = db.createCategory('Films');
    check(
        db.replaceCategoryMediaSources(categoryId: category.id, sources: [
          for (final root in roots)
            NasCategoryMediaSourceInput(
                mediaRootId: root.id, relativePath: 'films'),
        ]),
        'fixture binds both source disks');
    return _Library(
        temporary,
        media,
        db,
        sqlite3.open(
            '$data${Platform.pathSeparator}db${Platform.pathSeparator}mujing.sqlite'),
        roots.first,
        category);
  }

  String path(String relative, {int disk = 1}) =>
      '${media.path}${Platform.pathSeparator}disk$disk${Platform.pathSeparator}films${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

  Future<void> write(String relative, {int disk = 1}) async {
    final file = File(path(relative, disk: disk));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(32, 1));
  }

  Future<NasScanResult> scan() => db.scanCategory(
        categoryId: category.id,
        mediaRootId: root.id,
        mediaService:
            NasMediaService(mediaDir: media.path, fixtureRelativePath: null),
        metadataProbe: NasMediaMetadataProbe(runner: (_, __) async {
          probes++;
          return ProcessResult(
              0,
              0,
              '{"streams":[{"width":1920,"height":1080}],"format":{"duration":"60"}}',
              '');
        }),
      );

  String titles(String movieId) =>
      db.episodesForMovie(movieId).map((e) => e.title).join(',');

  void recordPlayback(String movieId, String episodeId) {
    db.recordPlaybackStarted(movieId: movieId, episodeId: episodeId);
    db.savePlaybackProgress(
        movieId: movieId,
        episodeId: episodeId,
        positionMs: 15000,
        durationMs: 60000);
  }

  void checkPlayback(String movieId, String episodeId) {
    check(
        db
                    .playbackProgressForEpisode(
                        movieId: movieId, episodeId: episodeId)
                    ?.positionMs ==
                15000 &&
            raw.select(
                    'SELECT movie_id FROM playback_history WHERE episode_id=?',
                    [episodeId]).single['movie_id'] ==
                movieId,
        'progress and playback history retain their owner and episode IDs');
  }

  Future<String> compose(List<String> ids) async {
    final preview = await db.previewMovieComposition(
        movieIds: ids, metadataSourceMovieId: ids.first);
    return db.composeMovies(
        movieIds: ids,
        metadataSourceMovieId: ids.first,
        previewToken: preview['previewToken'] as String,
        episodeOrder: (preview['episodes'] as List)
            .map((e) => (e as Map)['id'] as String)
            .toList(),
        hasActivePlayback: (_) => false);
  }

  Future<void> close() async {
    raw.dispose();
    await db.close();
    await temporary.delete(recursive: true);
  }
}
