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
    'main and secondary unresolved cast': _unresolvedCast,
    'late MDCNG source name association': _mdcngAssociation,
    'supplement cast survives repeated compositions':
        _supplementAndRepeatedMerge,
    'explicit clearing blocks every reconciliation path': _manualClearing,
    'manual actors survive additive reconciliation': _manualActors,
    'hidden catalog aliases resolve to final collection': _hiddenCatalog,
    'hidden aliases cannot cross category boundaries': _categoryBoundary,
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
  stdout.writeln('collection_actor_reconciliation_test: PASS');
}

Future<void> _unresolvedCast(_Library library) async {
  final [first, second, third, _] = library.movies;
  library.db.saveScrapeMovieProfile(first.id, {
    'actors': [
      {'name': 'Late main cast'}
    ]
  });
  library.db.saveScrapeMovieProfile(second.id, {
    'actorSources': [
      {'name': 'Late secondary alias', 'provisional': true}
    ]
  });
  final target =
      await library.compose([first.id, second.id], automaticGrouping: true);
  final main = library.db.createActor(stageName: 'Late main cast');
  final secondary = library.db.createActor(
      stageName: 'Secondary canonical name', aliases: ['Late secondary alias']);
  library.db.reconcileScrapeActorMovies();
  library.expectActors(target, [main.id, secondary.id],
      'new actors resolve cast from both the main and non-main hidden sources');
  library.expectOnlyNewOwner(main.id, target);
  library.expectOnlyNewOwner(secondary.id, target);
  check(library.db.actorsForMovie(third.id).isEmpty,
      'unrelated active movies do not acquire the newly resolved actors');
  check(library.db.reconcileScrapeActorMovies() == 0,
      'repeated cast reconciliation creates no duplicate associations');
  check(
      library.db.findActor(main.id)!.movieCount == 1 &&
          library.db.findActor(secondary.id)!.movieCount == 1,
      'actor movie counts include the collection once');
}

Future<void> _mdcngAssociation(_Library library) async {
  final [first, second, _, _] = library.movies;
  library.db.saveScrapeMovieProfile(first.id, {
    'actors': [
      {'name': 'MDCNG source name'}
    ]
  });
  library.db.saveSupplementCast(second.id, [
    {'name': 'MDCNG supplemental alias', 'provisional': true}
  ]);
  final target =
      await library.compose([first.id, second.id], automaticGrouping: true);
  final actor = library.db.createActor(
      stageName: 'Imported translated name',
      aliases: ['MDCNG supplemental alias']);
  // MDCNG 导入保存身份后会触发相同的补关联入口，姓名可以与本库显示名不同。
  library.db.linkActorToMdcngSource(
      sourceId: 'mdcng-fixture',
      embyId: 'actor-1',
      actorId: actor.id,
      sourceName: 'MDCNG source name',
      profileKey: 'profile-1');
  library.expectActors(target, [actor.id],
      'MDCNG source names and aliases resolve both saved cast formats');
  library.expectOnlyNewOwner(actor.id, target);
  check(library.db.reconcileScrapeActorMovies(actor.id) == 0,
      'the MDCNG-triggered reconciliation is idempotent');
}

Future<void> _supplementAndRepeatedMerge(_Library library) async {
  final [first, second, third, _] = library.movies;
  for (final (movie, cast) in [
    (first, {'name': 'Late first supplement', 'provisional': true}),
    (
      second,
      {
        'id': 'stable-second-cast',
        'url': 'https://example.invalid/actor/second',
        'name': 'Late second supplement'
      }
    ),
    (third, {'name': 'Late third supplement', 'provisional': true})
  ]) {
    library.db.saveSupplementCast(movie.id, [cast]);
  }
  final intermediate =
      await library.compose([first.id, second.id], automaticGrouping: true);
  final target =
      await library.compose([intermediate, third.id], automaticGrouping: true);
  await library.db.close();
  await library.db.open();
  final actors = [
    for (final name in [
      'Late first supplement',
      'Late second supplement',
      'Late third supplement'
    ])
      library.db.createActor(stageName: name)
  ];
  library.db.reconcileSupplementCast(movieId: target);
  library.expectActors(target, actors.map((actor) => actor.id).toList(),
      'targeted reconciliation sees all supplement cast through repeated merges');
  for (final actor in actors) {
    library.expectOnlyNewOwner(actor.id, target);
  }
  check(
      [first.id, second.id, third.id, intermediate]
          .every((id) => library.db.findMovie(id) == null),
      'reconciliation never reactivates hidden source movies');
  check(library.db.reconcileSupplementCast(movieId: target) == 0,
      'repeated supplement reconciliation is idempotent after reopening');
}

Future<void> _manualClearing(_Library library) async {
  final [first, second, _, _] = library.movies;
  library.db.saveScrapeMovieProfile(first.id, {
    'actors': [
      {'name': 'Blocked by manual clearing'}
    ]
  });
  library.db.saveSupplementCast(second.id, [
    {'name': 'Blocked by manual clearing', 'provisional': true}
  ]);
  final target = await library.compose([first.id, second.id]);
  // 模拟用户在影集详情主动清空演员；与组成影集自动保留的名单保护区分。
  library.db.setMovieActorIds(movieId: target, actorIds: []);
  library.db
      .markMovieMetadataFieldsManual(movieId: target, fieldKeys: ['actors']);
  final actor = library.db.createActor(stageName: 'Blocked by manual clearing');
  library.db.reconcileScrapeActorMovies(actor.id);
  library.db.reconcileSupplementCast(movieId: target, actorId: actor.id);
  library.db.saveScrapeWorks(actor.id, [library.work('FIRST-001')]);
  check(library.db.actorsForMovie(target).isEmpty,
      'explicit clearing blocks profile, supplement and catalog-work association');
  check(library.db.findActor(actor.id)!.movieCount == 0,
      'manual clearing cannot leave associations on hidden source movies');
}

Future<void> _manualActors(_Library library) async {
  final [first, second, _, _] = library.movies;
  final manual = library.db.createActor(stageName: 'Existing manual actor');
  library.db.setMovieActorIds(movieId: first.id, actorIds: [manual.id]);
  library.db
      .markMovieMetadataFieldsManual(movieId: first.id, fieldKeys: ['actors']);
  library.db.saveScrapeMovieProfile(first.id, {
    'actors': [
      {'name': 'Rejected original manual cast'}
    ]
  });
  library.db.saveScrapeMovieProfile(second.id, {
    'actors': [
      {'name': 'Late additive actor'}
    ]
  });
  final target = await library.compose([first.id, second.id]);
  final late = library.db.createActor(stageName: 'Late additive actor');
  final rejected =
      library.db.createActor(stageName: 'Rejected original manual cast');
  library.db.reconcileScrapeActorMovies();
  // 手工组成的影集整体冻结；只有在最终影集上明确保存补充出演名单，
  // 才允许追加新演员。
  library.db.saveSupplementCast(target, [
    {'name': 'Late additive actor', 'provisional': true}
  ]);
  library.db.reconcileSupplementCast(movieId: target);
  library.expectActors(target, [manual.id, late.id],
      'late non-main cast appends without replacing an existing manual actor');
  check(
      !library.db
          .actorsForMovie(target)
          .any((actor) => actor.id == rejected.id),
      'a source movie explicitly protected by the user keeps its original actor selection');
  library.expectOnlyNewOwner(late.id, target);
}

Future<void> _hiddenCatalog(_Library library) async {
  final [first, second, third, _] = library.movies;
  final intermediate =
      await library.compose([first.id, second.id], automaticGrouping: true);
  final target =
      await library.compose([intermediate, third.id], automaticGrouping: true);
  final actor =
      library.db.createActor(stageName: 'Actor from old catalog work');
  library.db.saveScrapeWorks(actor.id, [library.work(' second_002 ')]);
  library.expectActors(target, [actor.id],
      'normalized old non-main catalog numbers resolve to the final collection');
  library.expectOnlyNewOwner(actor.id, target);
  library.db.saveScrapeWorks(actor.id, [library.work('SECOND-002')]);
  check(library.db.actorsForMovie(target).length == 1,
      'repeated work matching cannot duplicate the final collection relation');
}

Future<void> _categoryBoundary(_Library library) async {
  final [first, second, _, _] = library.movies;
  // 只在非主资料来源上保存出演名单；主资料被复制到最终影集后，
  // 影集自身换分类仍应保留自己的资料关联。
  library.db.saveScrapeMovieProfile(second.id, {
    'actors': [
      {'name': 'Category boundary actor'}
    ]
  });
  library.db.saveSupplementCast(second.id, [
    {'name': 'Category boundary actor', 'provisional': true}
  ]);
  final target =
      await library.compose([first.id, second.id], automaticGrouping: true);
  final otherCategory = library.db.createCategory('Other category');
  library.db.setMovieTaxonomy(
      movieId: target,
      updateCategory: true,
      categoryId: otherCategory.id,
      updateTagIds: false,
      tagIds: []);
  final actor = library.db.createActor(stageName: 'Category boundary actor');
  library.db.reconcileScrapeActorMovies(actor.id);
  library.db.reconcileSupplementCast(movieId: target, actorId: actor.id);
  library.db.saveScrapeWorks(actor.id, [library.work('SECOND-002')]);
  check(library.db.actorsForMovie(target).isEmpty,
      'hidden source aliases cannot associate actors across a changed category');
  check(library.db.findActor(actor.id)!.movieCount == 0,
      'a rejected category alias does not create hidden associations');
}

class _Library {
  _Library(this.temporary, this.db, this.raw, this.movies);

  final Directory temporary;
  final NasLibraryDatabase db;
  final Database raw;
  final List<NasLibraryMovie> movies;

  static Future<_Library> open() async {
    final temporary =
        await Directory.systemTemp.createTemp('mujing-collection-actor-');
    final media = Directory(_path(temporary.path, 'media'));
    final films = Directory(_path(media.path, 'films'));
    await films.create(recursive: true);
    for (final code in [
      'FIRST-001',
      'SECOND-002',
      'THIRD-003',
      'UNRELATED-004'
    ]) {
      await File(_path(films.path, '$code.mp4')).writeAsBytes([1, 2, 3]);
    }
    final data = _path(temporary.path, 'data');
    final db = NasLibraryDatabase(data);
    await db.open();
    final root = db.ensureConfiguredMediaRoot(
        rootName: 'Fixture disk', containerPath: media.path);
    final category = db.createCategory('Fixture category');
    check(
        db.replaceCategoryMediaSources(categoryId: category.id, sources: [
          NasCategoryMediaSourceInput(
              mediaRootId: root.id, relativePath: 'films')
        ]),
        'fixture category binding');
    await db.scanCategory(
        categoryId: category.id,
        mediaRootId: root.id,
        mediaService:
            NasMediaService(mediaDir: media.path, fixtureRelativePath: null),
        metadataProbe: NasMediaMetadataProbe(
            runner: (_, __) async =>
                ProcessResult(0, 0, '{"streams":[],"format":{}}', '')));
    final movies = db.listMovies()..sort((a, b) => a.title.compareTo(b.title));
    check(movies.length == 4, 'fixture has four independent movies');
    for (final movie in movies) {
      db.updateMovieMetadata(
          movieId: movie.id,
          catalogNumber: movie.title,
          updateCatalogNumber: true);
    }
    return _Library(
        temporary, db, sqlite3.open(_path(data, 'db/mujing.sqlite')), movies);
  }

  Future<String> compose(List<String> ids,
      {bool automaticGrouping = false}) async {
    final preview = await db.previewMovieComposition(
        movieIds: ids, metadataSourceMovieId: ids.first);
    return db.composeMovies(
        movieIds: ids,
        metadataSourceMovieId: ids.first,
        previewToken: preview['previewToken'] as String,
        episodeOrder: (preview['episodes'] as List)
            .map((episode) => (episode as Map)['id'] as String)
            .toList(),
        automaticGrouping: automaticGrouping,
        hasActivePlayback: (_) => false);
  }

  Map<String, Object?> work(String code) => {
        'sourceId': 'fixture-work',
        'code': code,
        'title': 'Fixture collected work',
        'url': 'https://example.invalid/work/fixture'
      };

  void expectActors(String movieId, List<String> expected, String message) {
    final actual = db.actorsForMovie(movieId).map((actor) => actor.id).toList()
      ..sort();
    final wanted = [...expected]..sort();
    check(actual.join(',') == wanted.join(','), message);
  }

  void expectOnlyNewOwner(String actorId, String target) {
    final links = raw.select(
        'SELECT movie_id FROM movie_actor_links WHERE actor_id=?', [actorId]);
    check(links.length == 1 && links.single['movie_id'] == target,
        'late associations point only to the final active collection');
  }

  Future<void> close() async {
    raw.dispose();
    await db.close();
    await temporary.delete(recursive: true);
  }
}
