import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../lib/mujing_nas.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

String _path(String base, String relative) =>
    '$base${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

Future<void> main() async {
  final scenarios = <String, Future<void> Function(_Library)>{
    'legacy singles preserve composition data': _preserveCompositionData,
    'default scan titles remain enrichable': _defaultTitle,
    'imported provenance remains updateable': _importedProvenance,
    'manual values and explicit clearing remain protected': _manualProvenance,
    'same work across disks': _crossDisk,
    'manual composition survives rescan': _manualComposition,
    'explicit full split survives rescan': _fullSplit,
    'explicit partial split protects new segments': _partialSplit,
    'categories remain separate': _crossCategory,
    'mixed series and single remain ambiguous': _mixedOwners,
    'category root files remain separate': _rootFiles,
    'active playback prevents automatic composition': _activePlayback,
    'active scraping skips only the affected directory': _activeScraping,
  };
  final failures = <String>[];
  for (final scenario in scenarios.entries) {
    final library = await _Library.open();
    try {
      await scenario.value(library);
      check(library.db.validateIntegrity(), '${scenario.key}: integrity');
      check(library.raw.select('PRAGMA foreign_key_check').isEmpty,
          '${scenario.key}: foreign keys');
      stdout.writeln('${scenario.key}: PASS');
    } on Object catch (error, stack) {
      failures.add('${scenario.key}: $error');
      stderr.writeln('${scenario.key}: FAIL\n$error\n$stack');
    } finally {
      await library.close();
    }
  }
  if (failures.isNotEmpty) throw StateError(failures.join('\n'));
  stdout.writeln('automatic_legacy_collection_scan_test: PASS');
}

Future<void> _preserveCompositionData(_Library library) async {
  // 先创建 B 并让其创建时间更早，确保主资料选择不依赖写入时间、
  // 文件枚举顺序或影片创建时间。
  await library.write('PPT-001/PPT-001-B.mp4');
  await library.write('PPT-001/PPT-001-A.mp4');
  final legacy = await library.legacySingles();
  final first = legacy.first;
  final second = legacy.last;
  library.raw.execute('UPDATE movies SET created_at=? WHERE id=?',
      ['2030-01-01T00:00:00Z', first.id]);
  library.raw.execute('UPDATE movies SET created_at=? WHERE id=?',
      ['2000-01-01T00:00:00Z', second.id]);
  library.db.updateMovieMetadata(
      movieId: first.id,
      title: 'Natural first metadata',
      summary: 'Preserved primary summary',
      catalogNumber: 'PPT-001',
      updateCatalogNumber: true);
  library.db.updateMovieMetadata(
      movieId: second.id, title: 'Other metadata', summary: 'Other summary');
  library.db.setMovieFavorite(movieId: second.id, isFavorite: true);
  library.raw.execute('UPDATE movies SET poster_file_name=? WHERE id=?',
      ['primary-poster.png', first.id]);
  library.db.saveScrapeMovieProfile(first.id, {'source': 'primary source'});
  final publisher = library.db.createPublisher(displayName: 'Primary maker');
  library.raw.execute(
      'INSERT INTO movie_company_links(movie_id,company_id,role) VALUES (?,?,?)',
      [first.id, publisher.id, 'maker']);
  final actors = [
    for (final name in ['Actor A', 'Actor B'])
      library.db.createActor(stageName: name, gender: 'female')
  ];
  library.db.setMovieActorIds(movieId: first.id, actorIds: [actors.first.id]);
  library.db.setMovieActorIds(
      movieId: second.id, actorIds: actors.map((actor) => actor.id).toList());
  final tags = [
    for (final name in ['Tag A', 'Tag B'])
      library.db.createTag(name: name, level: 1)
  ];
  for (final (movieId, tagIds) in [
    (first.id, [tags.first.id]),
    (second.id, tags.map((tag) => tag.id).toList())
  ]) {
    library.db.setMovieTaxonomy(
        movieId: movieId,
        updateCategory: false,
        categoryId: null,
        updateTagIds: true,
        tagIds: tagIds);
  }
  for (final (fileName, movieId, bytes) in [
    ('duplicate-a.png', first.id, [1, 2, 3]),
    ('duplicate-b.png', second.id, [1, 2, 3]),
    ('unique.png', second.id, [4, 5, 6]),
  ]) {
    await File('${library.data}/artwork/carousel/$fileName')
        .writeAsBytes(bytes);
    library.db.addCarouselImage(movieId: movieId, fileName: fileName);
  }
  final originalEpisodes = [
    library.db.episodesForMovie(first.id).single,
    library.db.episodesForMovie(second.id).single
  ];
  for (var i = 0; i < originalEpisodes.length; i++) {
    library.db.recordPlaybackStarted(
        movieId: legacy[i].id, episodeId: originalEpisodes[i].id);
    library.db.savePlaybackProgress(
        movieId: legacy[i].id,
        episodeId: originalEpisodes[i].id,
        positionMs: 15000 + i * 10000,
        durationMs: 60000);
  }
  final probes = library.probes;
  final scan = await library.scan();
  final target = library.db.listMovies().single;
  check(scan.conflicts.isEmpty, 'automatic migration should be unambiguous');
  check(target.entryType == 'series' && target.episodeCount == 2,
      'ordinary old work directory automatically becomes one collection');
  check(legacy.every((movie) => library.db.findMovie(movie.id) == null),
      'all original single movies are hidden');
  check(
      target.title == 'Natural first metadata' &&
          target.summary == 'Preserved primary summary' &&
          target.catalogNumber == 'PPT-001' &&
          target.posterFileName == 'primary-poster.png',
      'natural first episode chooses stable main metadata');
  check(
      !library.db.hasDefaultScannedTitle(target.id) &&
          !library.db.scrapeFieldAllowed('movie', target.id, 'title',
              target.title, 'Unrequested overwrite'),
      'a meaningful source title keeps its manual enrichment protection');
  check(
      target.isFavorite &&
          library.db.actorsForMovie(target.id).length == 2 &&
          library.db.tagsForMovie(target.id).length == 2,
      'favorites and deduplicated actor/tag unions survive');
  final combinedSources = library.db.metadataFieldSourcesForMovie(target.id);
  for (final field in ['actors', 'tags', 'fanart']) {
    check(
        combinedSources[field]?.sourceKind == 'manual' &&
            combinedSources[field]?.importRecordId == null &&
            combinedSources[field]?.sourceContentHash == null &&
            !library.db.scrapeFieldAllowed(
                'movie', target.id, field, '[]', '["replacement"]'),
        'nonempty $field union is protected against later partial imports');
  }
  check(
      library.db.movieCompanies(target.id).single['id'] == publisher.id &&
          library.db.scrapeMovieProfile(target.id)?['source'] ==
              'primary source',
      'main company and source details survive');
  final images = library.db.carouselImagesForMovie(target.id);
  check(images.length == 2, 'screenshots are deduplicated by content');
  check(
      images.every((image) =>
          File('${library.data}/artwork/carousel/${image.fileName}')
              .existsSync()),
      'retained screenshots remain on disk');
  final transferred = library.db.episodesForMovie(target.id);
  check(
      transferred.map((episode) => episode.id).join(',') ==
          originalEpisodes.map((episode) => episode.id).join(','),
      'both original episode IDs survive in natural order');
  check(target.playCount == 2, 'play counts are summed');
  for (var i = 0; i < originalEpisodes.length; i++) {
    final episode = originalEpisodes[i];
    check(
        library.db
                .playbackProgressForEpisode(
                    movieId: target.id, episodeId: episode.id)
                ?.positionMs ==
            15000 + i * 10000,
        'each source resume position transfers to collection');
  }
  check(
      library.raw
          .select('SELECT movie_id FROM playback_history')
          .every((row) => row['movie_id'] == target.id),
      'playback history points to the collection');
  check(library.db.compositionSourcesForMovie(target.id).length == 2,
      'source titles and catalog numbers remain in composition provenance');
  check(library.probes == probes, 'old episodes reuse their metadata probes');

  final before = library.businessSnapshot();
  library.countBusinessWrites();
  await library.scan();
  check(library.businessSnapshot() == before,
      'second scan preserves every movie, episode and transferred relation');
  check(library.businessWrites == 0 && library.probes == probes,
      'unchanged second scan performs no movie/episode/relation writes or probes');
}

Future<void> _defaultTitle(_Library library) async {
  await library.write('Default work/PPT-001-A.mp4');
  await library.write('Default work/PPT-001-B.mp4');
  final legacy = await library.legacySingles();
  for (final movie in legacy) {
    final episode = library.db.episodesForMovie(movie.id).single;
    library.raw.execute(
        'UPDATE movies SET title=?,scanned_title=NULL WHERE id=?',
        [episode.title, movie.id]);
  }
  check(legacy.every((movie) => library.db.hasDefaultScannedTitle(movie.id)),
      'fixture uses legacy filename titles without scanned_title markers');
  await library.scan();
  final target = library.db.listMovies().single;
  check(
      target.title == 'Default work' &&
          library.db.hasDefaultScannedTitle(target.id),
      'automatic collection replaces a default filename with its work directory');
  check(
      library.db.metadataFieldSourcesForMovie(target.id)['title']?.sourceKind !=
              'manual' &&
          library.db.scrapeFieldAllowed(
              'movie', target.id, 'title', target.title, 'Enriched NFO title',
              scannedTitle: library.db.hasDefaultScannedTitle(target.id)),
      'neither metadata nor scrape manual guards block default title enrichment');
  final emptyFields = {
    'originalTitle': 'original_title',
    'catalogNumber': 'catalog_number',
    'summary': 'summary',
    'actors': 'actors',
    'tags': 'tags',
    'poster': 'poster_file_name',
    'fanart': 'fanart'
  };
  final sources = library.db.metadataFieldSourcesForMovie(target.id);
  for (final field in emptyFields.entries) {
    check(
        sources[field.key]?.sourceKind != 'manual' &&
            library.db.scrapeFieldAllowed(
                'movie', target.id, field.value, '', 'enriched value'),
        'empty ${field.key} receives no artificial manual protection');
  }
  final actor =
      library.db.createActor(stageName: 'Enriched actor', gender: 'female');
  final tag = library.db.createTag(name: 'Enriched tag', level: 1);
  final episode = library.db.episodesForMovie(target.id).first;
  library.db.applyMdcngMetadata(NasMdcngMetadataApply(
      movieId: target.id,
      episodeId: episode.id,
      nfoFileName: 'PPT-001-A.nfo',
      nfoContentHash: 'default-title-fixture',
      fieldKeys: ['title', ...emptyFields.keys],
      title: 'Enriched NFO title',
      originalTitle: 'Enriched original title',
      catalogNumber: 'NFO-001',
      summary: 'Enriched summary',
      actorIds: [actor.id],
      tagIds: [tag.id],
      posterFileName: 'enriched-poster.png',
      fanartFileName: 'enriched-fanart.png'));
  final enriched = library.db.findMovie(target.id)!;
  check(
      enriched.title == 'Enriched NFO title' &&
          enriched.originalTitle == 'Enriched original title' &&
          enriched.catalogNumber == 'NFO-001' &&
          enriched.summary == 'Enriched summary' &&
          enriched.posterFileName == 'enriched-poster.png' &&
          library.db.actorsForMovie(target.id).single.id == actor.id &&
          library.db.tagsForMovie(target.id).single.id == tag.id &&
          library.db.carouselImagesForMovie(target.id).single.fileName ==
              'enriched-fanart.png' &&
          !library.db.hasDefaultScannedTitle(target.id) &&
          library.db
                  .metadataFieldSourcesForMovie(target.id)['title']
                  ?.sourceKind ==
              'mdcng',
      'first NFO enrichment fills the default title and all missing metadata');
}

Future<void> _importedProvenance(_Library library) async {
  await library.write('Imported/PPT-001-A.mp4');
  await library.write('Imported/PPT-001-B.mp4');
  final legacy = await library.legacySingles();
  final main = legacy.first;
  final episode = library.db.episodesForMovie(main.id).single;
  final originalImport = library.db.applyMdcngMetadata(NasMdcngMetadataApply(
      movieId: main.id,
      episodeId: episode.id,
      nfoFileName: 'PPT-001-A.nfo',
      nfoContentHash: 'original-nfo-hash',
      fieldKeys: ['title', 'summary', 'catalogNumber'],
      title: 'Imported title',
      summary: 'Imported summary',
      catalogNumber: 'IMPORTED-001'));
  // 同时保留正常采集的值记录，验证后续按原值识别更新的规则不被自动归并打断。
  for (final entry in {
    'title': 'Imported title',
    'summary': 'Imported summary',
    'catalog_number': 'IMPORTED-001'
  }.entries) {
    library.db.recordScrapeField('movie', main.id, entry.key, entry.value);
  }
  final beforeSources = library.db.metadataFieldSourcesForMovie(main.id);
  final beforeScrape = jsonEncode(library.raw.select(
      "SELECT field,value,manual,updated_at FROM scrape_fields WHERE kind='movie' AND entity_id=? ORDER BY field",
      [main.id]));
  await library.scan();
  final target = library.db.listMovies().single;
  final afterSources = library.db.metadataFieldSourcesForMovie(target.id);
  for (final field in ['title', 'summary', 'catalogNumber']) {
    final source = afterSources[field];
    check(
        source?.sourceKind == 'mdcng' &&
            source?.importRecordId == originalImport.id &&
            source?.sourceContentHash == 'original-nfo-hash' &&
            source?.updatedAt == beforeSources[field]?.updatedAt,
        'automatic grouping preserves the exact imported $field provenance');
  }
  check(
      jsonEncode(library.raw.select(
              "SELECT field,value,manual,updated_at FROM scrape_fields WHERE kind='movie' AND entity_id=? ORDER BY field",
              [target.id])) ==
          beforeScrape,
      'scrape field values and manual flags are copied without modification');
  check(
      library.db.applyScrapeFields('movie', target.id, {
        'title': 'Updated scraped title',
        'summary': 'Updated scraped summary',
        'catalog_number': 'UPDATED-001'
      }).isEmpty,
      'previously imported scalar fields stay eligible for normal scrape updates');
  final updated = library.db.findMovie(target.id)!;
  check(
      updated.title == 'Updated scraped title' &&
          updated.summary == 'Updated scraped summary' &&
          updated.catalogNumber == 'UPDATED-001',
      'normal scrape updates are actually applied after automatic grouping');
  final nextImport = library.db.applyMdcngMetadata(NasMdcngMetadataApply(
      movieId: target.id,
      episodeId: episode.id,
      nfoFileName: 'PPT-001-A.nfo',
      nfoContentHash: 'new-nfo-hash',
      fieldKeys: ['title', 'summary'],
      title: 'Updated NFO title',
      summary: 'Updated NFO summary'));
  final nextSources = library.db.metadataFieldSourcesForMovie(target.id);
  check(
      library.db.findMovie(target.id)?.title == 'Updated NFO title' &&
          library.db.findMovie(target.id)?.summary == 'Updated NFO summary' &&
          ['title', 'summary'].every((field) =>
              nextSources[field]?.sourceKind == 'mdcng' &&
              nextSources[field]?.importRecordId == nextImport.id &&
              nextSources[field]?.sourceContentHash == 'new-nfo-hash'),
      'a later confirmed NFO import can update data and its provenance');
}

Future<void> _manualProvenance(_Library library) async {
  await library.write('Manual sources/PPT-001-A.mp4');
  await library.write('Manual sources/PPT-001-B.mp4');
  final legacy = await library.legacySingles();
  final main = legacy.first;
  library.db.updateMovieMetadata(
      movieId: main.id,
      title: 'Explicit manual title',
      summary: '',
      catalogNumber: null,
      updateCatalogNumber: true);
  const manualFields = [
    'title',
    'summary',
    'catalogNumber',
    'actors',
    'tags',
    'poster',
    'fanart'
  ];
  library.db
      .markMovieMetadataFieldsManual(movieId: main.id, fieldKeys: manualFields);
  library.db.markScrapeManual('movie', main.id,
      ['title', 'summary', 'catalog_number', 'poster_file_name']);
  final beforeSources = library.db.metadataFieldSourcesForMovie(main.id);
  final beforeScrape = jsonEncode(library.raw.select(
      "SELECT field,value,manual,updated_at FROM scrape_fields WHERE kind='movie' AND entity_id=? ORDER BY field",
      [main.id]));
  await library.scan();
  final target = library.db.listMovies().single;
  final afterSources = library.db.metadataFieldSourcesForMovie(target.id);
  for (final field in manualFields) {
    check(
        afterSources[field]?.sourceKind == 'manual' &&
            afterSources[field]?.updatedAt == beforeSources[field]?.updatedAt,
        'explicit manual $field provenance survives even when its value is empty');
  }
  check(
      jsonEncode(library.raw.select(
              "SELECT field,value,manual,updated_at FROM scrape_fields WHERE kind='movie' AND entity_id=? ORDER BY field",
              [target.id])) ==
          beforeScrape,
      'existing manual scrape flags survive automatic grouping unchanged');
  check(
      library.db.applyScrapeFields('movie', target.id, {
            'title': 'Unrequested title',
            'summary': 'Unrequested summary',
            'catalog_number': 'UNREQUESTED-001',
            'poster_file_name': 'unrequested.png'
          }).length ==
          4,
      'normal scraping cannot replace a manual value or fill explicitly cleared fields');
  final unchanged = library.db.findMovie(target.id)!;
  check(
      unchanged.title == 'Explicit manual title' &&
          unchanged.summary.isEmpty &&
          unchanged.catalogNumber == null &&
          unchanged.posterFileName == null,
      'explicit manual values and scalar clearing remain effective');
  for (final field in ['actors', 'tags', 'fanart']) {
    check(
        !library.db.scrapeFieldAllowed(
            'movie', target.id, field, '[]', '["unrequested"]'),
        'explicitly cleared $field remains protected against refilling');
  }
}

Future<void> _crossDisk(_Library library) async {
  check(
      library.db.replaceCategoryMediaSources(
          categoryId: library.category.id,
          sources: [
            NasCategoryMediaSourceInput(
                mediaRootId: library.roots.first.id, relativePath: 'films'),
            NasCategoryMediaSourceInput(
                mediaRootId: library.roots.last.id, relativePath: 'videos')
          ]),
      'cross-disk fixture binds different physical source-directory names');
  await library.write('Same/PPT-001-B.mp4');
  final a = File(_path(library.media.path, 'disk2/videos/Same/PPT-001-A.mp4'));
  await a.parent.create(recursive: true);
  await a.writeAsBytes(List.filled(32, 1));
  final legacy = await library.legacySingles();
  final episodeIds = legacy
      .expand((movie) => library.db.episodesForMovie(movie.id))
      .map((episode) => episode.id)
      .toSet();
  library.db.updateMovieMetadata(
      movieId: legacy.first.id, title: 'Disk two natural first');
  final scan = await library.scan();
  final target = library.db.listMovies().single;
  check(scan.conflicts.isEmpty && target.episodeCount == 2,
      'same relative work directory merges across source disks');
  check(target.title == 'Disk two natural first',
      'metadata choice is independent of source disk scan order');
  check(
      library.db
          .episodesForMovie(target.id)
          .map((episode) => episode.id)
          .toSet()
          .containsAll(episodeIds),
      'cross-disk automatic composition retains episode identities');
}

Future<void> _manualComposition(_Library library) async {
  await library.write('Left/1.mp4');
  await library.write('Right/2.mp4');
  await library.scan();
  final sources = library.db.listMovies();
  final target =
      await library.compose(sources.map((movie) => movie.id).toList());
  final originalIds =
      library.db.episodesForMovie(target).map((episode) => episode.id).toSet();
  await library.write('Left/3.mp4');
  await library.write('Right/4.mp4', disk: 2);
  await library.scan();
  check(
      library.db.listMovies().single.id == target &&
          library.db.findMovie(target)!.episodeCount == 4 &&
          sources.every((movie) => library.db.findMovie(movie.id) == null),
      'manual cross-directory composition and added segments never revive sources');
  check(
      library.db
          .episodesForMovie(target)
          .map((episode) => episode.id)
          .toSet()
          .containsAll(originalIds),
      'manual composition retains original episodes after scan');
}

Future<void> _fullSplit(_Library library) async {
  await library.write('Split/1.mp4');
  await library.write('Split/2.mp4');
  await library.scan();
  final series = library.db.listMovies().single;
  final episodes = library.db.episodesForMovie(series.id);
  final singles = library.db.splitEpisodesIntoSingles(
      movieId: series.id,
      episodeIds: episodes.map((episode) => episode.id).toList())!;
  check(singles.length == 2, 'fixture explicitly splits both episodes');
  check(singles.every((movie) => library.groupingMode(movie.id) == 'manual'),
      'explicitly split singles receive manual scan grouping protection');
  final probes = library.probes;
  for (var i = 0; i < 2; i++) {
    await library.scan();
    check(
        library.db
                .listMovies()
                .map((movie) => movie.id)
                .toSet()
                .containsAll(singles.map((movie) => movie.id)) &&
            library.db.listMovies().length == 2,
        'repeated scans cannot recombine explicitly split singles');
  }
  check(library.probes == probes, 'protected split needs no repeat probes');
}

Future<void> _partialSplit(_Library library) async {
  await library.write('Partial/1.mp4');
  await library.write('Partial/2.mp4');
  await library.scan();
  final series = library.db.listMovies().single;
  final separated = library.db.splitEpisodesIntoSingles(
      movieId: series.id,
      episodeIds: [library.db.episodesForMovie(series.id).last.id])!.single;
  check(
      library.groupingMode(separated.id) == 'manual' &&
          library.groupingMode(series.id) == 'manual',
      'both owners from a partial split are marked manual');
  await library.write('Partial/3.mp4');
  final scan = await library.scan();
  check(scan.conflicts.isNotEmpty,
      'new part with split owners reports ambiguity');
  check(
      library.db.listMovies().length == 2 &&
          library.db.findMovie(series.id)!.episodeCount == 1 &&
          library.db.findMovie(separated.id)!.episodeCount == 1,
      'partial split preserves both manually chosen owners');
  check(
      library.raw
          .select(
              "SELECT id FROM episodes WHERE relative_path='films/Partial/3.mp4'")
          .isEmpty,
      'ambiguous new part is not silently assigned');
}

Future<void> _crossCategory(_Library library) async {
  await library.write('Same/part-A.mp4');
  await library.scan();
  final first = library.db.listMovies().single;
  final other = library.db.createCategory('Other category');
  final file = File(_path(library.media.path, 'disk2/other/Same/part-B.mp4'));
  await file.parent.create(recursive: true);
  await file.writeAsBytes(List.filled(32, 1));
  check(
      library.db.replaceCategoryMediaSources(categoryId: other.id, sources: [
        NasCategoryMediaSourceInput(
            mediaRootId: library.roots.last.id, relativePath: 'other')
      ]),
      'second category uses an independent directory binding');
  await library.scan(categoryId: other.id);
  await library.scan();
  final movies = library.db.listMovies();
  check(
      movies.length == 2 &&
          movies.every((movie) => movie.entryType == 'single') &&
          library.db.findMovie(first.id)?.categoryId == library.category.id &&
          movies.singleWhere((movie) => movie.id != first.id).categoryId ==
              other.id,
      'identical work-directory names cannot merge across categories');
}

Future<void> _mixedOwners(_Library library) async {
  for (final name in ['1', '2', '3']) {
    await library.write('Mixed/$name.mp4');
  }
  await library.scan();
  final series = library.db.listMovies().single;
  final episodes = library.db.episodesForMovie(series.id);
  final single = library.db.createEmptySeries(
      title: 'Legacy unrelated single', categoryId: library.category.id);
  library.raw.execute(
      "UPDATE movies SET entry_type='single',collection_key=NULL,scan_grouping_mode='automatic' WHERE id=?",
      [single.id]);
  library.raw.execute('UPDATE episodes SET movie_id=? WHERE id=?',
      [single.id, episodes.last.id]);
  final scan = await library.scan();
  check(scan.conflicts.isNotEmpty, 'mixed series/single ownership is reported');
  check(
      library.db.listMovies().length == 2 &&
          library.db.findMovie(series.id)!.episodeCount == 2 &&
          library.db.findMovie(single.id)!.episodeCount == 1,
      'ambiguous mixed owners are not automatically merged');
}

Future<void> _rootFiles(_Library library) async {
  await library.write('PPT-001-A.mp4');
  await library.write('PPT-001-B.mp4');
  await library.scan();
  final ids = library.db.listMovies().map((movie) => movie.id).toSet();
  await library.scan();
  check(
      library.db.listMovies().length == 2 &&
          library.db.listMovies().every((movie) =>
              movie.entryType == 'single' &&
              ids.contains(movie.id) &&
              library.groupingMode(movie.id) == 'automatic'),
      'root loose files remain separate even with matching catalog prefixes');
}

Future<void> _activePlayback(_Library library) async {
  await library.write('Playing/1.mp4');
  await library.write('Playing/2.mp4');
  final legacy = await library.legacySingles();
  library.playingMovieIds.add(legacy.first.id);
  final scan = await library.scan();
  check(scan.conflicts.isNotEmpty && library.db.listMovies().length == 2,
      'active playback preserves both old singles and reports a conflict');
  library.playingMovieIds.clear();
  await library.scan();
  check(library.db.listMovies().single.episodeCount == 2,
      'a later scan can group the work after playback ends');
}

Future<void> _activeScraping(_Library library) async {
  await library.write('Scraping/1.mp4');
  await library.write('Scraping/2.mp4');
  final legacy = await library.legacySingles();
  final job = library.db.createScrapeJob('automatic composition fixture');
  final task = library.db.enqueueScrapeTask(
      [job], 'movie', 'fixture', {'movieId': legacy.first.id});
  await library.write('Unaffected/3.mp4');
  final scan = await library.scan();
  check(
      scan.conflicts.isNotEmpty &&
          legacy.every((movie) => library.db.findMovie(movie.id) != null) &&
          library.db.listMovies().length == 3,
      'pending source scraping blocks grouping while other work directories scan');
  library.raw
      .execute("UPDATE scrape_tasks SET status='done' WHERE id=?", [task]);
  await library.scan();
  check(
      library.db.listMovies().length == 2 &&
          library.db
                  .listMovies()
                  .singleWhere((movie) => movie.entryType == 'series')
                  .episodeCount ==
              2,
      'automatic grouping resumes when the source scraping task completes');
}

class _Library {
  _Library(this.temporary, this.media, this.data, this.db, this.raw, this.roots,
      this.category, this.playingMovieIds);

  final Directory temporary;
  final Directory media;
  final String data;
  final NasLibraryDatabase db;
  final Database raw;
  final List<NasMediaRoot> roots;
  final NasLibraryCategory category;
  final Set<String> playingMovieIds;
  var probes = 0;

  static Future<_Library> open() async {
    final temporary =
        await Directory.systemTemp.createTemp('mujing-auto-legacy-scan-');
    final media = Directory(_path(temporary.path, 'media'));
    for (final disk in [1, 2]) {
      await Directory(_path(media.path, 'disk$disk/films'))
          .create(recursive: true);
    }
    final data = _path(temporary.path, 'data');
    final playing = <String>{};
    final db = NasLibraryDatabase(data,
        hasActivePlayback: (ids) => ids.any(playing.contains));
    await db.open();
    final roots = [
      for (final disk in [1, 2])
        db.ensureConfiguredMediaRoot(
            rootName: 'disk$disk',
            containerPath: _path(media.path, 'disk$disk'))
    ];
    final category = db.createCategory('Films');
    check(
        db.replaceCategoryMediaSources(categoryId: category.id, sources: [
          for (final root in roots)
            NasCategoryMediaSourceInput(
                mediaRootId: root.id, relativePath: 'films')
        ]),
        'fixture binds two disks');
    return _Library(
        temporary,
        media,
        data,
        db,
        sqlite3.open(_path(data, 'db/mujing.sqlite')),
        roots,
        category,
        playing);
  }

  Future<void> write(String relative, {int disk = 1}) async {
    final file = File(_path(media.path, 'disk$disk/films/$relative'));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(32, 1));
  }

  Future<NasScanResult> scan({String? categoryId}) => db.scanCategory(
      categoryId: categoryId ?? category.id,
      mediaRootId: roots.first.id,
      mediaService:
          NasMediaService(mediaDir: media.path, fixtureRelativePath: null),
      metadataProbe: NasMediaMetadataProbe(runner: (_, __) async {
        probes++;
        return ProcessResult(
            0,
            0,
            '{"streams":[{"width":1920,"height":1080}],"format":{"duration":"60"}}',
            '');
      }));

  // 保留真实扫描得到的元数据与分集 ID，仅还原按目录自动归组上线前的
  // 旧 single 归属结构，随后用真实分类重扫验证迁移。
  Future<List<NasLibraryMovie>> legacySingles() async {
    await scan();
    final original = db.listMovies().single;
    final episodes = db.episodesForMovie(original.id);
    check(episodes.length == 2, 'legacy fixture has two real scanned segments');
    final second =
        db.createEmptySeries(title: 'Legacy second', categoryId: category.id);
    raw.execute(
        "UPDATE movies SET entry_type='single',collection_key=NULL,scan_grouping_mode='automatic' WHERE id IN (?,?)",
        [original.id, second.id]);
    raw.execute('UPDATE episodes SET movie_id=? WHERE id=?',
        [second.id, episodes.last.id]);
    return [db.findMovie(original.id)!, db.findMovie(second.id)!];
  }

  String groupingMode(String movieId) => raw.select(
      'SELECT scan_grouping_mode FROM movies WHERE id=?',
      [movieId]).single['scan_grouping_mode'] as String;

  Future<String> compose(List<String> ids) async {
    final preview = await db.previewMovieComposition(
        movieIds: ids, metadataSourceMovieId: ids.first);
    return db.composeMovies(
        movieIds: ids,
        metadataSourceMovieId: ids.first,
        previewToken: preview['previewToken'] as String,
        episodeOrder: (preview['episodes'] as List)
            .map((episode) => (episode as Map)['id'] as String)
            .toList(),
        hasActivePlayback: (_) => false);
  }

  static const _businessTables = [
    'movies',
    'episodes',
    'movie_actor_links',
    'movie_tag_links',
    'movie_metadata_field_sources',
    'movie_company_links',
    'scrape_movie_profiles',
    'scrape_fields',
    'movie_carousel_images',
    'episode_playback_progress',
    'playback_history'
  ];

  List<String> get businessTables {
    final existing = raw
        .select("SELECT name FROM sqlite_master WHERE type='table'")
        .map((row) => row['name'] as String)
        .toSet();
    return _businessTables.where(existing.contains).toList();
  }

  String businessSnapshot() => jsonEncode({
        for (final table in businessTables)
          table: raw
              .select('SELECT * FROM $table')
              .map((row) => jsonEncode(row))
              .toList()
            ..sort()
      });

  void countBusinessWrites() {
    raw.execute('CREATE TABLE test_scan_writes(n INTEGER NOT NULL)');
    raw.execute('INSERT INTO test_scan_writes VALUES(0)');
    for (final table in businessTables) {
      for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
        raw.execute(
            'CREATE TRIGGER test_scan_${table}_$operation AFTER $operation ON $table '
            'BEGIN UPDATE test_scan_writes SET n=n+1; END');
      }
    }
  }

  int get businessWrites =>
      raw.select('SELECT n FROM test_scan_writes').single['n'] as int;

  Future<void> close() async {
    raw.dispose();
    await db.close();
    await temporary.delete(recursive: true);
  }
}
