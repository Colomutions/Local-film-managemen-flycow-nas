import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';
import '../library_models.dart';
import 'library_values.dart';

/// Owns actor, publisher and series records and their associations.
class NasProfilesRepository {
  NasProfilesRepository(
    this._connection, {
    required this.tagsForRelation,
    required this.findManagedAsset,
    required this.findMovieForAdmin,
    required this.listMovies,
    required this.markScrapeManual,
    required this.movieCompanies,
    required this.reconcileScrapeActorMovies,
  });

  final Database Function() _connection;
  Database get _db => _connection();
  final List<NasLibraryTag> Function(
    String condition,
    List<Object?> parameters,
  ) tagsForRelation;
  final NasManagedAsset? Function(String assetId) findManagedAsset;
  final NasLibraryMovie? Function(String movieId) findMovieForAdmin;
  final List<NasLibraryMovie> Function({String query}) listMovies;
  final void Function(String kind, String id, Iterable<String> fields)
      markScrapeManual;
  final List<Map<String, dynamic>> Function(String movieId) movieCompanies;
  final int Function([String? actorId]) reconcileScrapeActorMovies;

  List<NasPublisher> listPublishers({
    String query = '',
    bool includeArchived = false,
  }) {
    final queryLike = '%${query.trim()}%';
    final rows = _db.select('''
      SELECT p.id, p.profile_identity, p.display_name, p.original_name, p.country_region,
             p.founded_date, p.logo_asset_id, p.created_at, p.updated_at,
             p.archived_at,
              (SELECT COUNT(*) FROM movies m
                WHERE (m.publisher_id = p.id OR EXISTS(SELECT 1 FROM movie_company_links cl WHERE cl.movie_id=m.id AND cl.company_id=p.id)) AND m.lifecycle_state = 'active') AS movie_count,
             (SELECT COUNT(*) FROM series s WHERE s.publisher_id = p.id) AS series_count,
             (SELECT SUM(COALESCE(e.duration_ms, 0))
                FROM movies m JOIN episodes e ON e.movie_id = m.id
                WHERE (m.publisher_id = p.id OR EXISTS(SELECT 1 FROM movie_company_links cl WHERE cl.movie_id=m.id AND cl.company_id=p.id)) AND m.lifecycle_state = 'active'
                  AND e.is_available = 1) AS duration_ms
      FROM publishers p
      WHERE (? = 1 OR p.archived_at IS NULL)
        AND (? = '%%' OR lower(p.display_name) LIKE lower(?)
             OR lower(COALESCE(p.original_name, '')) LIKE lower(?))
      ORDER BY p.created_at DESC, p.id DESC
    ''', [includeArchived ? 1 : 0, queryLike, queryLike, queryLike]);
    return rows.map(_mapPublisher).toList(growable: false);
  }

  NasPublisher? findPublisher(String publisherId) {
    final rows = _db.select('''
      SELECT p.id, p.profile_identity, p.display_name, p.original_name, p.country_region,
             p.founded_date, p.logo_asset_id, p.created_at, p.updated_at,
             p.archived_at,
              (SELECT COUNT(*) FROM movies m
                WHERE (m.publisher_id = p.id OR EXISTS(SELECT 1 FROM movie_company_links cl WHERE cl.movie_id=m.id AND cl.company_id=p.id)) AND m.lifecycle_state = 'active') AS movie_count,
             (SELECT COUNT(*) FROM series s WHERE s.publisher_id = p.id) AS series_count,
             (SELECT SUM(COALESCE(e.duration_ms, 0))
                FROM movies m JOIN episodes e ON e.movie_id = m.id
                WHERE (m.publisher_id = p.id OR EXISTS(SELECT 1 FROM movie_company_links cl WHERE cl.movie_id=m.id AND cl.company_id=p.id)) AND m.lifecycle_state = 'active'
                  AND e.is_available = 1) AS duration_ms
      FROM publishers p WHERE p.id = ?
    ''', [publisherId]);
    return rows.isEmpty ? null : _mapPublisher(rows.single);
  }

  NasPublisher? findPublisherByProfileIdentity(String profileIdentity) {
    final rows = _db.select(
      'SELECT id FROM publishers WHERE profile_identity = ?',
      [profileIdentity],
    );
    return rows.isEmpty ? null : findPublisher(rows.single['id'] as String);
  }

  bool publisherDisplayNameExists(String displayName) => _db.select(
        'SELECT 1 FROM publishers WHERE lower(display_name) = lower(?) LIMIT 1',
        [displayName.trim()],
      ).isNotEmpty;

  NasPublisher? findPublisherByDisplayName(String displayName) {
    final rows = _db.select(
      'SELECT id FROM publishers WHERE lower(display_name) = lower(?) LIMIT 1',
      [displayName.trim()],
    );
    return rows.isEmpty ? null : findPublisher(rows.single['id'] as String);
  }

  NasPublisher createPublisher({
    required String displayName,
    String? profileIdentity,
    String? originalName,
    String? countryRegion,
    String? foundedDate,
    String? logoAssetId,
  }) {
    final id = newUuidV4();
    final timestamp = now();
    _db.execute('''
      INSERT INTO publishers(
        id, profile_identity, display_name, original_name, country_region, founded_date,
        logo_asset_id, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      id,
      nullableTrimmed(profileIdentity) ?? newUuidV4(),
      displayName.trim(),
      nullableTrimmed(originalName),
      nullableTrimmed(countryRegion),
      nullableTrimmed(foundedDate),
      logoAssetId,
      timestamp,
      timestamp,
    ]);
    return findPublisher(id)!;
  }

  NasPublisher? updatePublisher(
      String publisherId, Map<String, Object?> values) {
    if (findPublisher(publisherId) == null) return null;
    if (values.isEmpty) return findPublisher(publisherId);
    markScrapeManual('company', publisherId, values.keys);
    final assignments = <String>[];
    final parameters = <Object?>[];
    values.forEach((key, value) {
      assignments.add('$key = ?');
      parameters.add(value);
    });
    assignments.add('updated_at = ?');
    parameters
      ..add(now())
      ..add(publisherId);
    _db.execute(
      'UPDATE publishers SET ${assignments.join(', ')} WHERE id = ?',
      parameters,
    );
    return findPublisher(publisherId);
  }

  NasPublisher? archivePublisher(String publisherId) => updatePublisher(
        publisherId,
        {'archived_at': now()},
      );

  bool publisherHasReferences(String publisherId) => _db.select('''
    SELECT 1
    WHERE EXISTS(SELECT 1 FROM movies
      WHERE publisher_id = ? AND lifecycle_state = 'active')
       OR EXISTS(SELECT 1 FROM series WHERE publisher_id = ?)
       OR EXISTS(SELECT 1 FROM actor_publisher_links WHERE publisher_id = ?)
       OR EXISTS(SELECT 1 FROM movie_company_links WHERE company_id = ?)
  ''', [publisherId, publisherId, publisherId, publisherId]).isNotEmpty;

  bool deletePublisher(String publisherId) {
    if (findPublisher(publisherId) == null ||
        publisherHasReferences(publisherId)) {
      return false;
    }
    _db.execute('DELETE FROM publishers WHERE id = ?', [publisherId]);
    return true;
  }

  List<NasSeries> listSeries({
    String query = '',
    String? publisherId,
    bool includeArchived = false,
  }) {
    final queryLike = '%${query.trim()}%';
    final rows = _db.select('''
      SELECT s.id, s.profile_identity, s.display_name, s.original_name, s.translated_name,
             s.publisher_id, s.release_date, s.poster_asset_id, s.created_at,
             s.updated_at, s.archived_at,
              (SELECT COUNT(*) FROM movies m
                WHERE m.series_id = s.id AND m.lifecycle_state = 'active') AS movie_count,
             (SELECT COUNT(e.id) FROM movies m JOIN episodes e ON e.movie_id = m.id
                WHERE m.series_id = s.id AND m.lifecycle_state = 'active'
                  AND e.is_available = 1) AS episode_count,
             (SELECT SUM(COALESCE(e.duration_ms, 0))
                FROM movies m JOIN episodes e ON e.movie_id = m.id
                WHERE m.series_id = s.id AND m.lifecycle_state = 'active'
                  AND e.is_available = 1) AS duration_ms
      FROM series s
      WHERE (? = 1 OR s.archived_at IS NULL)
        AND (? IS NULL OR s.publisher_id = ?)
        AND (? = '%%' OR lower(s.display_name) LIKE lower(?)
             OR lower(COALESCE(s.original_name, '')) LIKE lower(?)
             OR lower(COALESCE(s.translated_name, '')) LIKE lower(?))
      ORDER BY s.created_at DESC, s.id DESC
    ''', [
      includeArchived ? 1 : 0,
      publisherId,
      publisherId,
      queryLike,
      queryLike,
      queryLike,
      queryLike,
    ]);
    return rows.map(_mapSeries).toList(growable: false);
  }

  NasSeries? findSeries(String seriesId) {
    final rows = _db.select('''
      SELECT s.id, s.profile_identity, s.display_name, s.original_name, s.translated_name,
             s.publisher_id, s.release_date, s.poster_asset_id, s.created_at,
             s.updated_at, s.archived_at,
              (SELECT COUNT(*) FROM movies m
                WHERE m.series_id = s.id AND m.lifecycle_state = 'active') AS movie_count,
             (SELECT COUNT(e.id) FROM movies m JOIN episodes e ON e.movie_id = m.id
                WHERE m.series_id = s.id AND m.lifecycle_state = 'active'
                  AND e.is_available = 1) AS episode_count,
             (SELECT SUM(COALESCE(e.duration_ms, 0))
                FROM movies m JOIN episodes e ON e.movie_id = m.id
                WHERE m.series_id = s.id AND m.lifecycle_state = 'active'
                  AND e.is_available = 1) AS duration_ms
      FROM series s WHERE s.id = ?
    ''', [seriesId]);
    return rows.isEmpty ? null : _mapSeries(rows.single);
  }

  NasSeries? findSeriesByProfileIdentity(String profileIdentity) {
    final rows = _db.select(
      'SELECT id FROM series WHERE profile_identity = ?',
      [profileIdentity],
    );
    return rows.isEmpty ? null : findSeries(rows.single['id'] as String);
  }

  bool seriesDisplayNameExists(String displayName) => _db.select(
        'SELECT 1 FROM series WHERE lower(display_name) = lower(?) LIMIT 1',
        [displayName.trim()],
      ).isNotEmpty;

  NasSeries createSeries({
    required String displayName,
    String? profileIdentity,
    String? publisherId,
    String? originalName,
    String? translatedName,
    String? releaseDate,
    String? posterAssetId,
  }) {
    final id = newUuidV4();
    final timestamp = now();
    _db.execute('''
      INSERT INTO series(
        id, profile_identity, display_name, original_name, translated_name, publisher_id,
        release_date, poster_asset_id, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      id,
      nullableTrimmed(profileIdentity) ?? newUuidV4(),
      displayName.trim(),
      nullableTrimmed(originalName),
      nullableTrimmed(translatedName),
      nullableTrimmed(publisherId),
      nullableTrimmed(releaseDate),
      posterAssetId,
      timestamp,
      timestamp,
    ]);
    return findSeries(id)!;
  }

  NasSeries? updateSeries(String seriesId, Map<String, Object?> values) {
    if (findSeries(seriesId) == null) return null;
    if (values.isEmpty) return findSeries(seriesId);
    final assignments = <String>[];
    final parameters = <Object?>[];
    values.forEach((key, value) {
      assignments.add('$key = ?');
      parameters.add(value);
    });
    assignments.add('updated_at = ?');
    parameters
      ..add(now())
      ..add(seriesId);
    _db.execute(
      'UPDATE series SET ${assignments.join(', ')} WHERE id = ?',
      parameters,
    );
    return findSeries(seriesId);
  }

  NasSeries? archiveSeries(String seriesId) => updateSeries(
        seriesId,
        {'archived_at': now()},
      );

  bool deleteSeries(String seriesId) {
    final series = findSeries(seriesId);
    if (series == null || series.movieCount > 0) return false;
    _db.execute('DELETE FROM series WHERE id = ?', [seriesId]);
    return true;
  }

  List<NasLibraryMovie> moviesForPublisher(String publisherId,
          {String query = ''}) =>
      listMovies(query: query)
          .where((movie) =>
              movie.publisherId == publisherId ||
              movieCompanies(movie.id)
                  .any((company) => company['id'] == publisherId))
          .toList(growable: false);

  List<NasLibraryMovie> moviesForSeries(String seriesId, {String query = ''}) =>
      listMovies(query: query)
          .where((movie) => movie.seriesId == seriesId)
          .toList(growable: false);

  List<NasSeries> seriesForPublisher(String publisherId, {String query = ''}) =>
      listSeries(query: query, publisherId: publisherId)
          .toList(growable: false);

  List<NasLibraryTag> tagsForPublisher(String publisherId) => tagsForRelation(
        '(m.publisher_id = ? OR EXISTS(SELECT 1 FROM movie_company_links cl WHERE cl.movie_id=m.id AND cl.company_id=?))',
        [publisherId, publisherId],
      );

  List<NasLibraryTag> tagsForSeries(String seriesId) => tagsForRelation(
        'm.series_id = ?',
        [seriesId],
      );

  List<NasRelatedActor> actorsForPublisher(String publisherId) =>
      _relatedActorsForMovies(
          '(m.publisher_id = ? OR EXISTS(SELECT 1 FROM movie_company_links cl WHERE cl.movie_id=m.id AND cl.company_id=?))',
          [publisherId, publisherId]);

  List<NasRelatedActor> actorsForSeries(String seriesId) =>
      _relatedActorsForMovies('m.series_id = ?', [seriesId]);

  List<String> publisherIdsForActor(String actorId) => _db
      .select('''
        SELECT publisher_id FROM actor_publisher_links
        WHERE actor_id = ? ORDER BY publisher_id
      ''', [actorId])
      .map((row) => row['publisher_id'] as String)
      .toList(growable: false);

  List<NasPublisher> publishersForActor(String actorId) =>
      publisherIdsForActor(actorId)
          .map(findPublisher)
          .whereType<NasPublisher>()
          .toList(growable: false);

  bool setActorPublisherIds({
    required String actorId,
    required List<String> publisherIds,
  }) {
    if (findActor(actorId) == null ||
        publisherIds.length != publisherIds.toSet().length ||
        publisherIds.any((id) {
          final publisher = findPublisher(id);
          return publisher == null || publisher.archivedAt != null;
        })) {
      return false;
    }
    _db.execute('BEGIN');
    try {
      _db.execute(
          'DELETE FROM actor_publisher_links WHERE actor_id = ?', [actorId]);
      for (final publisherId in publisherIds) {
        _db.execute(
          'INSERT INTO actor_publisher_links(actor_id, publisher_id) VALUES (?, ?)',
          [actorId, publisherId],
        );
      }
      _db.execute('COMMIT');
      return true;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 统一解析影片关系，系列存在时始终以系列所属发行商为准。
  ({String? publisherId, String? seriesId})? resolveMovieRelations({
    required String movieId,
    String? publisherId,
    required bool updatePublisherId,
    String? seriesId,
    required bool updateSeriesId,
  }) {
    final movie = findMovieForAdmin(movieId);
    if (movie == null) return null;
    final resolvedSeriesId =
        updateSeriesId ? nullableTrimmed(seriesId) : movie.seriesId;
    var resolvedPublisherId =
        updatePublisherId ? nullableTrimmed(publisherId) : movie.publisherId;
    if (resolvedSeriesId != null) {
      final series = findSeries(resolvedSeriesId);
      final seriesPublisherId = series?.publisherId;
      if (series == null ||
          series.archivedAt != null ||
          seriesPublisherId == null) {
        return null;
      }
      if (updatePublisherId && resolvedPublisherId != seriesPublisherId)
        return null;
      resolvedPublisherId = seriesPublisherId;
    }
    if (resolvedPublisherId != null) {
      final publisher = findPublisher(resolvedPublisherId);
      if (publisher == null || publisher.archivedAt != null) return null;
    }
    return (publisherId: resolvedPublisherId, seriesId: resolvedSeriesId);
  }

  NasLibraryMovie? updateMovieRelations({
    required String movieId,
    required String? publisherId,
    required bool updatePublisherId,
    required String? seriesId,
    required bool updateSeriesId,
  }) {
    final relations = resolveMovieRelations(
      movieId: movieId,
      publisherId: publisherId,
      updatePublisherId: updatePublisherId,
      seriesId: seriesId,
      updateSeriesId: updateSeriesId,
    );
    if (relations == null) return null;
    if (!updatePublisherId && !updateSeriesId)
      return findMovieForAdmin(movieId);
    _db.execute(
      'UPDATE movies SET publisher_id = ?, series_id = ?, updated_at = ? WHERE id = ?',
      [relations.publisherId, relations.seriesId, now(), movieId],
    );
    return findMovieForAdmin(movieId);
  }

  List<NasActor> listActors({
    String query = '',
    String? gender,
    bool includeArchived = false,
  }) {
    final rows = _db.select('''
      SELECT a.id, a.profile_identity, a.stage_name, a.original_name, a.translated_name,
             a.aliases_json, a.gender, a.romanized_name, a.birth_date, a.birth_month,
             a.height_cm, a.weight_kg, a.measurements, a.body_type, a.country,
             a.birthplace, a.cup, a.career_period, a.debut_month, a.debut_description,
             a.account_url, a.official_site_url, a.photo_asset_id, a.backdrop_asset_id,
             a.publisher_names_json,
             a.created_at, a.updated_at, a.archived_at,
              COUNT(CASE WHEN linked_movie.lifecycle_state = 'active' THEN l.movie_id END) AS movie_count
       FROM actors a
       LEFT JOIN movie_actor_links l ON l.actor_id = a.id
       LEFT JOIN movies linked_movie ON linked_movie.id = l.movie_id
      WHERE (? = 1 OR a.archived_at IS NULL)
        AND (? IS NULL OR a.gender = ?)
      GROUP BY a.id
      ORDER BY a.created_at DESC, a.id DESC
    ''', [includeArchived ? 1 : 0, gender, gender]);
    final normalizedQuery = normalizeActorSearch(query);
    return rows
        .map(_mapActor)
        .where((actor) =>
            normalizedQuery.isEmpty ||
            actorSearchText(actor).contains(normalizedQuery))
        .toList(growable: false);
  }

  NasActor? findActor(String actorId) {
    final rows = _db.select('''
      SELECT a.id, a.profile_identity, a.stage_name, a.original_name, a.translated_name,
             a.aliases_json, a.gender, a.romanized_name, a.birth_date, a.birth_month,
             a.height_cm, a.weight_kg, a.measurements, a.body_type, a.country,
             a.birthplace, a.cup, a.career_period, a.debut_month, a.debut_description,
             a.account_url, a.official_site_url, a.photo_asset_id, a.backdrop_asset_id,
             a.publisher_names_json,
             a.created_at, a.updated_at, a.archived_at,
              COUNT(CASE WHEN linked_movie.lifecycle_state = 'active' THEN l.movie_id END) AS movie_count
       FROM actors a
       LEFT JOIN movie_actor_links l ON l.actor_id = a.id
       LEFT JOIN movies linked_movie ON linked_movie.id = l.movie_id
      WHERE a.id = ?
      GROUP BY a.id
    ''', [actorId]);
    return rows.isEmpty ? null : _mapActor(rows.single);
  }

  NasActor? findActorByProfileIdentity(String profileIdentity) {
    final rows = _db.select(
      'SELECT id FROM actors WHERE profile_identity = ?',
      [profileIdentity],
    );
    return rows.isEmpty ? null : findActor(rows.single['id'] as String);
  }

  bool actorDisplayNameExists(String displayName) => _db.select('''
    SELECT 1 FROM actors
    WHERE lower(COALESCE(NULLIF(stage_name, ''), NULLIF(original_name, ''),
      NULLIF(translated_name, ''))) = lower(?)
    LIMIT 1
  ''', [displayName.trim()]).isNotEmpty;

  /// 仅接受与任一已保存演员名称完全相等的活动演员，模糊候选必须人工处理。
  NasActor? findActiveActorByExactName(String name) {
    final matches = findActorsByExactNames([name]);
    return matches.length == 1 ? matches.single : null;
  }

  /// 同时核对所有姓名和别名；不同名字指向多位演员时必须人工选择。
  List<NasActor> findActorsByExactNames(Iterable<String> names,
      {bool includeArchived = false}) {
    final normalized = names
        .map((name) => name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet();
    if (normalized.isEmpty) return const [];
    final sourceNames = <String, List<String>>{};
    for (final row in _db
        .select('SELECT actor_id,source_name FROM mdcng_actor_source_links')) {
      sourceNames
          .putIfAbsent(row['actor_id'] as String, () => [])
          .add(row['source_name'] as String);
    }
    return listActors(includeArchived: includeArchived).where((actor) {
      final names = <String?>[
        actor.stageName,
        actor.originalName,
        actor.translatedName,
        ...actor.aliases,
        ...?sourceNames[actor.id],
      ];
      return names.any(
          (candidate) => normalized.contains(candidate?.trim().toLowerCase()));
    }).toList(growable: false);
  }

  List<NasActor> actorsForMovie(String movieId) {
    final ids = _db.select('''
      SELECT actor_id FROM movie_actor_links
      WHERE movie_id = ? ORDER BY actor_id
    ''', [movieId]);
    return ids
        .map((row) => findActor(row['actor_id'] as String))
        .whereType<NasActor>()
        .toList(growable: false);
  }

  List<NasLibraryMovie> moviesForActor(String actorId, {String query = ''}) {
    final movieIds = _db.select('''
      SELECT links.movie_id FROM movie_actor_links links
      JOIN movies m ON m.id = links.movie_id
      WHERE links.actor_id = ? AND m.lifecycle_state = 'active'
    ''', [actorId]).map((row) => row['movie_id'] as String).toSet();
    if (movieIds.isEmpty) return const [];
    return listMovies(query: query)
        .where((movie) => movieIds.contains(movie.id))
        .toList(growable: false);
  }

  List<NasActorCoactor> coactorsForActor(String actorId) {
    final rows = _db.select('''
      SELECT l2.actor_id, COUNT(*) AS movie_count
      FROM movie_actor_links l1
      JOIN movie_actor_links l2 ON l2.movie_id = l1.movie_id
      JOIN movies m ON m.id = l1.movie_id
      WHERE l1.actor_id = ? AND l2.actor_id != ? AND m.lifecycle_state = 'active'
      GROUP BY l2.actor_id
      ORDER BY movie_count DESC, l2.actor_id ASC
    ''', [actorId, actorId]);
    return rows
        .map((row) {
          final actor = findActor(row['actor_id'] as String);
          return actor == null
              ? null
              : NasActorCoactor(
                  actor: actor,
                  movieCount: row['movie_count'] as int,
                );
        })
        .whereType<NasActorCoactor>()
        .toList(growable: false);
  }

  List<NasActor> findSimilarActors({
    String? stageName,
    String? originalName,
    String? translatedName,
    List<String> aliases = const [],
    List<NasActor>? candidates,
  }) {
    final names = <String?>[
      stageName,
      originalName,
      translatedName,
      ...aliases,
    ];
    final queries = names
        .map(nullableTrimmed)
        .whereType<String>()
        .map(normalizeActorSearch)
        .where((value) => value.isNotEmpty)
        .toSet();
    if (queries.isEmpty) return const [];
    return (candidates ?? listActors(includeArchived: true))
        .where((actor) => queries.any(actorSearchText(actor).contains))
        .toList(growable: false);
  }

  NasActor createActor({
    String? profileIdentity,
    String? stageName,
    String? originalName,
    String? translatedName,
    List<String> aliases = const [],
    String? gender,
    String? romanizedName,
    String? birthDate,
    String? birthMonth,
    int? heightCm,
    int? weightKg,
    String? measurements,
    String? bodyType,
    String? country,
    String? birthplace,
    String? cup,
    String? careerPeriod,
    String? debutMonth,
    String? debutDescription,
    String? accountUrl,
    String? officialSiteUrl,
    String? photoAssetId,
    String? backdropAssetId,
    List<String> publisherNames = const [],
  }) {
    final timestamp = now();
    final id = newUuidV4();
    _db.execute('''
      INSERT INTO actors(
        id, profile_identity, stage_name, original_name, translated_name, aliases_json, gender,
        romanized_name, birth_date, birth_month, height_cm, weight_kg, measurements, body_type,
        country, birthplace, cup, career_period, debut_month, debut_description,
        account_url, official_site_url, photo_asset_id, backdrop_asset_id, publisher_names_json,
        created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      id,
      nullableTrimmed(profileIdentity) ?? newUuidV4(),
      nullableTrimmed(stageName),
      nullableTrimmed(originalName),
      nullableTrimmed(translatedName),
      jsonEncode(cleanTextList(aliases)),
      gender,
      nullableTrimmed(romanizedName),
      nullableTrimmed(birthDate),
      nullableTrimmed(birthMonth),
      heightCm,
      weightKg,
      nullableTrimmed(measurements),
      nullableTrimmed(bodyType),
      nullableTrimmed(country),
      nullableTrimmed(birthplace),
      nullableTrimmed(cup),
      nullableTrimmed(careerPeriod),
      nullableTrimmed(debutMonth),
      nullableTrimmed(debutDescription),
      nullableTrimmed(accountUrl),
      nullableTrimmed(officialSiteUrl),
      photoAssetId,
      backdropAssetId,
      jsonEncode(cleanTextList(publisherNames)),
      timestamp,
      timestamp,
    ]);
    return findActor(id)!;
  }

  NasActor? updateActor(String actorId, Map<String, Object?> values) {
    if (findActor(actorId) == null) return null;
    if (values.isEmpty) return findActor(actorId);
    markScrapeManual('actor', actorId, values.keys);
    final assignments = <String>[];
    final parameters = <Object?>[];
    values.forEach((key, value) {
      assignments.add('$key = ?');
      parameters.add(value);
    });
    assignments.add('updated_at = ?');
    parameters
      ..add(now())
      ..add(actorId);
    _db.execute(
      'UPDATE actors SET ${assignments.join(', ')} WHERE id = ?',
      parameters,
    );
    return findActor(actorId);
  }

  NasMdcngActorImportRecord? findMdcngActorImport({
    required String sourceId,
    required String taskId,
    required String sourceFingerprint,
  }) {
    final rows = _db.select('''
      SELECT id, actor_id, source_id, task_id, emby_id, source_fingerprint,
             applied_fields_json, created_at
      FROM mdcng_actor_import_records
      WHERE source_id = ? AND task_id = ? AND source_fingerprint = ?
      LIMIT 1
    ''', [sourceId, taskId, sourceFingerprint]);
    return rows.isEmpty ? null : _mapMdcngActorImportRecord(rows.single);
  }

  NasActor? findActorByMdcngSource({
    required String sourceId,
    required String embyId,
  }) {
    final rows = _db.select('''
      SELECT actor_id FROM mdcng_actor_source_links
      WHERE source_id = ? AND emby_id = ?
      LIMIT 1
    ''', [sourceId, embyId]);
    return rows.isEmpty ? null : findActor(rows.single['actor_id'] as String);
  }

  Set<String> mdcngDeferredEmbyIdsForSource(String sourceId) => _db
      .select('SELECT emby_id FROM mdcng_actor_deferred WHERE source_id = ?',
          [sourceId])
      .map((row) => row['emby_id'] as String)
      .toSet();

  bool isMdcngActorDeferred(
          {required String sourceId, required String embyId}) =>
      _db.select('''
        SELECT 1 FROM mdcng_actor_deferred
        WHERE source_id = ? AND emby_id = ? LIMIT 1
      ''', [sourceId, embyId]).isNotEmpty;

  void setMdcngActorDeferred({
    required String sourceId,
    required String embyId,
    required bool deferred,
  }) {
    if (isMdcngActorDeferred(sourceId: sourceId, embyId: embyId) == deferred) {
      return;
    }
    if (deferred) {
      _db.execute('''
        INSERT INTO mdcng_actor_deferred(source_id, emby_id, created_at)
        VALUES (?, ?, ?)
      ''', [sourceId, embyId, now()]);
    } else {
      _db.execute('''
        DELETE FROM mdcng_actor_deferred
        WHERE source_id = ? AND emby_id = ?
      ''', [sourceId, embyId]);
    }
  }

  Map<String, String> mdcngProfileKeysForSource(String sourceId) {
    final rows = _db.select('''
      SELECT emby_id, profile_key FROM mdcng_actor_source_links
      WHERE source_id = ? AND profile_key IS NOT NULL AND profile_key != ''
    ''', [sourceId]);
    return {
      for (final row in rows)
        row['emby_id'] as String: row['profile_key'] as String,
    };
  }

  void linkActorToMdcngSource({
    required String sourceId,
    required String embyId,
    required String actorId,
    required String sourceName,
    required String profileKey,
    bool reconcileMovies = true,
  }) {
    _db.execute('''
      INSERT INTO mdcng_actor_source_links(
        source_id, emby_id, actor_id, source_name, profile_key, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(source_id, emby_id) DO UPDATE SET
        actor_id = excluded.actor_id,
        source_name = excluded.source_name,
        profile_key = excluded.profile_key,
        updated_at = excluded.updated_at
    ''', [sourceId, embyId, actorId, sourceName.trim(), profileKey, now()]);
    if (reconcileMovies) reconcileScrapeActorMovies(actorId);
  }

  bool actorHasOtherMdcngIdentity(
          String actorId, String sourceId, String embyId) =>
      _db.select('''SELECT 1 FROM mdcng_actor_source_links
        WHERE actor_id=? AND source_id=? AND emby_id!=? LIMIT 1''',
          [actorId, sourceId, embyId]).isNotEmpty;

  NasMdcngActorImportRecord addMdcngActorImport({
    required String actorId,
    required String sourceId,
    required String taskId,
    required String embyId,
    required String sourceFingerprint,
    required List<String> appliedFields,
  }) {
    final record = NasMdcngActorImportRecord(
      id: newUuidV4(),
      actorId: actorId,
      sourceId: sourceId,
      taskId: taskId,
      embyId: embyId,
      sourceFingerprint: sourceFingerprint,
      appliedFields: cleanTextList(appliedFields),
      createdAt: now(),
    );
    _db.execute('''
      INSERT INTO mdcng_actor_import_records(
        id, actor_id, source_id, task_id, emby_id, source_fingerprint,
        applied_fields_json, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      record.id,
      record.actorId,
      record.sourceId,
      record.taskId,
      record.embyId,
      record.sourceFingerprint,
      jsonEncode(record.appliedFields),
      record.createdAt,
    ]);
    return record;
  }

  NasActor? archiveActor(String actorId) => updateActor(actorId, {
        'archived_at': now(),
      });

  /// 删除无活跃影片关联的演员；归并审计关系不再阻止资料清理。
  bool deleteActor(String actorId) {
    if (findActor(actorId) == null) return false;
    final hasActiveReferences = _db.select('''
      SELECT 1 FROM movie_actor_links links
      JOIN movies m ON m.id = links.movie_id
      WHERE links.actor_id = ? AND m.lifecycle_state = 'active'
      LIMIT 1
    ''', [actorId]).isNotEmpty;
    if (hasActiveReferences) return false;
    _db.execute('''
      DELETE FROM movie_actor_links
      WHERE actor_id = ? AND movie_id IN (
        SELECT id FROM movies WHERE lifecycle_state = 'merged'
      )
    ''', [actorId]);
    _db.execute('DELETE FROM actors WHERE id = ?', [actorId]);
    return true;
  }

  /// Removes the current MDCNG actor import state in one transaction. All
  /// actor-to-movie links are removed first so every actor can be deleted,
  /// including actors that are currently used by active movies.
  NasMdcngActorReset clearAllMdcngActors() {
    final actorRows = _db.select('''
      SELECT photo_asset_id, backdrop_asset_id FROM actors
    ''');
    final assetIds = actorRows
        .expand((row) => [row['photo_asset_id'], row['backdrop_asset_id']])
        .whereType<String>()
        .toSet();
    final assets = assetIds
        .map(findManagedAsset)
        .whereType<NasManagedAsset>()
        .toList(growable: false);
    final actorCount = (_db
            .select('SELECT COUNT(*) AS count FROM actors')
            .single['count'] as int? ??
        0);
    final movieLinkCount = (_db
            .select('SELECT COUNT(*) AS count FROM movie_actor_links')
            .single['count'] as int? ??
        0);
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute('DELETE FROM movie_actor_links');
      _db.execute('DELETE FROM mdcng_actor_source_links');
      _db.execute('DELETE FROM mdcng_actor_import_records');
      _db.execute('DELETE FROM mdcng_actor_deferred');
      _db.execute('DELETE FROM actors');
      _db.execute('COMMIT');
    } on Object {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return NasMdcngActorReset(
      deletedActors: actorCount,
      unlinkedMovieLinks: movieLinkCount,
      assets: assets,
    );
  }

  bool setMovieActorIds({
    required String movieId,
    required List<String> actorIds,
  }) {
    if (findMovieForAdmin(movieId) == null ||
        actorIds.toSet().length != actorIds.length ||
        actorIds.any((id) => findActor(id) == null)) {
      return false;
    }
    _db.execute('BEGIN');
    try {
      _db.execute(
          'DELETE FROM movie_actor_links WHERE movie_id = ?', [movieId]);
      for (final actorId in actorIds) {
        _db.execute(
          'INSERT INTO movie_actor_links(movie_id, actor_id) VALUES (?, ?)',
          [movieId, actorId],
        );
      }
      _db.execute('COMMIT');
      return true;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  List<NasRelatedActor> _relatedActorsForMovies(
    String condition,
    List<Object?> parameters,
  ) {
    final rows = _db.select('''
      SELECT l.actor_id, COUNT(DISTINCT l.movie_id) AS movie_count
      FROM movie_actor_links l
      JOIN movies m ON m.id = l.movie_id
       WHERE m.lifecycle_state = 'active' AND $condition
      GROUP BY l.actor_id
      ORDER BY movie_count DESC, l.actor_id ASC
    ''', parameters);
    return rows
        .map((row) {
          final actor = findActor(row['actor_id'] as String);
          return actor == null
              ? null
              : NasRelatedActor(
                  actor: actor,
                  movieCount: row['movie_count'] as int,
                );
        })
        .whereType<NasRelatedActor>()
        .toList(growable: false);
  }

  NasPublisher _mapPublisher(Row row) => NasPublisher(
        id: row['id'] as String,
        profileIdentity: row['profile_identity'] as String,
        displayName: row['display_name'] as String,
        originalName: row['original_name'] as String?,
        countryRegion: row['country_region'] as String?,
        foundedDate: row['founded_date'] as String?,
        logoAssetId: row['logo_asset_id'] as String?,
        movieCount: row['movie_count'] as int,
        seriesCount: row['series_count'] as int,
        durationMs: (row['duration_ms'] as int?) == 0
            ? null
            : row['duration_ms'] as int?,
        createdAt: row['created_at'] as String,
        updatedAt: row['updated_at'] as String,
        archivedAt: row['archived_at'] as String?,
      );

  NasSeries _mapSeries(Row row) => NasSeries(
        id: row['id'] as String,
        profileIdentity: row['profile_identity'] as String,
        displayName: row['display_name'] as String,
        originalName: row['original_name'] as String?,
        translatedName: row['translated_name'] as String?,
        publisherId: row['publisher_id'] as String?,
        releaseDate: row['release_date'] as String?,
        posterAssetId: row['poster_asset_id'] as String?,
        movieCount: row['movie_count'] as int,
        episodeCount: row['episode_count'] as int,
        durationMs: (row['duration_ms'] as int?) == 0
            ? null
            : row['duration_ms'] as int?,
        createdAt: row['created_at'] as String,
        updatedAt: row['updated_at'] as String,
        archivedAt: row['archived_at'] as String?,
      );

  NasActor _mapActor(Row row) => NasActor(
        id: row['id'] as String,
        profileIdentity: row['profile_identity'] as String,
        stageName: row['stage_name'] as String?,
        originalName: row['original_name'] as String?,
        translatedName: row['translated_name'] as String?,
        aliases: decodeTextList(row['aliases_json'] as String?),
        gender: row['gender'] as String?,
        romanizedName: row['romanized_name'] as String?,
        birthDate: row['birth_date'] as String?,
        birthMonth: row['birth_month'] as String?,
        heightCm: row['height_cm'] as int?,
        weightKg: row['weight_kg'] as int?,
        measurements: row['measurements'] as String?,
        bodyType: row['body_type'] as String?,
        country: row['country'] as String?,
        birthplace: row['birthplace'] as String?,
        cup: row['cup'] as String?,
        careerPeriod: row['career_period'] as String?,
        debutMonth: row['debut_month'] as String?,
        debutDescription: row['debut_description'] as String?,
        accountUrl: row['account_url'] as String?,
        officialSiteUrl: row['official_site_url'] as String?,
        photoAssetId: row['photo_asset_id'] as String?,
        backdropAssetId: row['backdrop_asset_id'] as String?,
        publisherIds: publisherIdsForActor(row['id'] as String),
        movieCount: row['movie_count'] as int,
        createdAt: row['created_at'] as String,
        updatedAt: row['updated_at'] as String,
        archivedAt: row['archived_at'] as String?,
      );

  NasMdcngActorImportRecord _mapMdcngActorImportRecord(Row row) =>
      NasMdcngActorImportRecord(
        id: row['id'] as String,
        actorId: row['actor_id'] as String,
        sourceId: row['source_id'] as String,
        taskId: row['task_id'] as String,
        embyId: row['emby_id'] as String,
        sourceFingerprint: row['source_fingerprint'] as String,
        appliedFields: decodeTextList(row['applied_fields_json'] as String?),
        createdAt: row['created_at'] as String,
      );
}
