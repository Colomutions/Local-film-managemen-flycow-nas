import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'auth.dart';
import 'library_models.dart';
import 'library/assets_repository.dart';
import 'library/collections_repository.dart';
import 'library/library_values.dart';
import 'library/metadata_repository.dart';
import 'library/movies_repository.dart';
import 'library/playback_repository.dart';
import 'library/profiles_repository.dart';
import 'library/queries_repository.dart';
import 'library/scan_repository.dart';
import 'library/schema_repository.dart';
import 'library/taxonomy_repository.dart';
import 'library/taxonomy_transfer.dart';
import 'media_service.dart';
import 'metadata_probe.dart';
import 'novels/novel_repository.dart';

// Preserve existing database imports while allowing model-only dependencies.
export 'library_models.dart';

part 'library/scrape_database.dart';
part 'library/supplement_database.dart';

String _normalizeCatalogNumber(String value) => normalizeCatalogNumber(value);

class NasLibraryDatabase {
  static const currentSchemaVersion = NasSchemaRepository.currentSchemaVersion;

  NasLibraryDatabase(this.dataDir);

  late final _schema = NasSchemaRepository(() => _db);

  late final _scan = NasScanRepository(
    () => _db,
    carouselImagesForMovie: carouselImagesForMovie,
    findCategory: findCategory,
    findMovieForAdmin: findMovieForAdmin,
    mediaSourcesForCategory: mediaSourcesForCategory,
    transaction: transaction,
  );

  late final _queries = NasQueriesRepository(
    () => _db,
    actorsForMovie: actorsForMovie,
    findCategory: findCategory,
  );

  late final _profiles = NasProfilesRepository(
    () => _db,
    tagsForRelation: _tagsForRelation,
    findManagedAsset: findManagedAsset,
    findMovieForAdmin: findMovieForAdmin,
    listMovies: listMovies,
    markScrapeManual: (kind, id, fields) => markScrapeManual(kind, id, fields),
    movieCompanies: (movieId) => movieCompanies(movieId),
    reconcileScrapeActorMovies: ([actorId]) =>
        reconcileScrapeActorMovies(actorId),
  );

  late final _assets = NasAssetsRepository(
    () => _db,
    findMovieForAdmin: findMovieForAdmin,
  );

  late final _metadata = NasMetadataRepository(
    () => _db,
    findActor: findActor,
    findEpisode: findEpisode,
    findMovieForAdmin: findMovieForAdmin,
    findTag: findTag,
    recordGalleryOrigin: (imageId, kind) => recordGalleryOrigin(imageId, kind),
  );

  late final _movies = NasMoviesRepository(
    () => _db,
    findEpisode: findEpisode,
    findMovie: findMovie,
    findMovieForAdmin: findMovieForAdmin,
    transaction: transaction,
  );

  late final _collections = NasCollectionsRepository(
    () => _db,
    episodeGrouping: _episodeGrouping,
    movieIdForScannedEpisode: _movieIdForScannedEpisode,
    carouselImagesForMovie: carouselImagesForMovie,
    findCategory: findCategory,
    findMovieForAdmin: findMovieForAdmin,
    listCategories: listCategories,
    dataDir: dataDir,
  );

  late final _taxonomy = NasTaxonomyRepository(
    () => _db,
    removeMovieIndex: _removeMovieIndex,
    findMediaRoot: findMediaRoot,
    findMovieForAdmin: findMovieForAdmin,
    listMediaRoots: listMediaRoots,
    transaction: transaction,
  );

  late final _playback = NasPlaybackRepository(() => _db);

  final String dataDir;
  Database? _database;

  Database get _db => _database ?? (throw StateError('Database is not open.'));

  NasNovelRepository get novels => NasNovelRepository(_db);

  Future<void> open() async {
    if (_database != null) return;
    final directory = Directory('$dataDir${Platform.pathSeparator}db');
    await directory.create(recursive: true);
    await Directory(
            '$dataDir${Platform.pathSeparator}artwork${Platform.pathSeparator}posters')
        .create(recursive: true);
    await Directory(
            '$dataDir${Platform.pathSeparator}artwork${Platform.pathSeparator}carousel')
        .create(recursive: true);
    final database =
        sqlite3.open('${directory.path}${Platform.pathSeparator}mujing.sqlite');
    try {
      database.execute('PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;');
      _database = database;
      _migrate();
      initializeScraping();
      _initializeRevisions();
    } catch (_) {
      database.dispose();
      _database = null;
      rethrow;
    }
  }

  // TEMP counters roll back with business writes and never write to the WAL.
  String _revisionEpoch = newUuidV4();
  void _initializeRevisions() {
    _revisionEpoch = newUuidV4();
    _db.execute('PRAGMA temp_store=MEMORY');
    _db.execute(
        'CREATE TEMP TABLE resource_revisions (kind TEXT PRIMARY KEY, value INTEGER NOT NULL)');
    for (final kind in ['library', 'taxonomy', 'watch', 'artwork']) {
      _db.execute('INSERT INTO resource_revisions VALUES (?, 0)', [kind]);
    }
    final tables = _db.select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
    for (final row in tables) {
      final table = row['name'] as String;
      if (!RegExp(r'^[a-z_]+$').hasMatch(table)) continue;
      final kind = table.contains('playback')
          ? 'watch'
          : table.contains('tag') ||
                  table == 'library_categories' ||
                  table == 'category_media_sources'
              ? 'taxonomy'
              : table.contains('asset') || table == 'movie_carousel_images'
                  ? 'artwork'
                  : 'library';
      for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
        _db.execute(
            "CREATE TEMP TRIGGER revision_${table}_$operation AFTER $operation ON main.$table BEGIN UPDATE resource_revisions SET value=value+1 WHERE kind='$kind'; END");
      }
    }
  }

  Map<String, String> get revisions => {
        for (final row
            in _db.select('SELECT kind, value FROM resource_revisions'))
          row['kind'] as String: '$_revisionEpoch:${row['value']}',
      };

  T transaction<T>(T Function() action) {
    _db.execute('SAVEPOINT storage_batch');
    try {
      final result = action();
      _db.execute('RELEASE storage_batch');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK TO storage_batch');
      _db.execute('RELEASE storage_batch');
      rethrow;
    }
  }

  Future<void> close() async {
    _database?.dispose();
    _database = null;
  }

  Future<void> checkpointAndClose() async {
    if (_database == null) return;
    _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    await close();
  }

  bool validateIntegrity() {
    final result = _db.select('PRAGMA integrity_check');
    return result.length == 1 && result.single['integrity_check'] == 'ok';
  }

  Future<void> createBackupSnapshot(File target) async {
    await target.parent.create(recursive: true);
    final escapedPath = target.absolute.path.replaceAll("'", "''");
    _db.execute("VACUUM INTO '$escapedPath'");
  }

  void _migrate() => _schema.migrate();

  NasMediaRoot ensureConfiguredMediaRoot({
    required String rootName,
    required String containerPath,
  }) =>
      _scan.ensureConfiguredMediaRoot(
          rootName: rootName, containerPath: containerPath);

  List<NasMediaRoot> listMediaRoots() => _scan.listMediaRoots();

  NasMediaRoot? findMediaRoot(String mediaRootId) =>
      _scan.findMediaRoot(mediaRootId);

  Future<NasScanResult> scanConfiguredRoot({
    required String rootName,
    required String containerPath,
    required NasMediaService mediaService,
    NasMediaMetadataProbe metadataProbe = const NasMediaMetadataProbe(),
  }) =>
      _scan.scanConfiguredRoot(
          rootName: rootName,
          containerPath: containerPath,
          mediaService: mediaService,
          metadataProbe: metadataProbe);

  Future<NasScanResult> scanMediaRoot({
    required String mediaRootId,
    required NasMediaService mediaService,
    String? categoryId,
    String? directoryRelativePath,
    NasMediaMetadataProbe metadataProbe = const NasMediaMetadataProbe(),
  }) =>
      _scan.scanMediaRoot(
          mediaRootId: mediaRootId,
          mediaService: mediaService,
          categoryId: categoryId,
          directoryRelativePath: directoryRelativePath,
          metadataProbe: metadataProbe);

  Future<NasScanResult> scanCategory({
    required String categoryId,
    Future<void> Function()? beforeFile,
    required String mediaRootId,
    required NasMediaService mediaService,
    NasMediaMetadataProbe metadataProbe = const NasMediaMetadataProbe(),
  }) =>
      _scan.scanCategory(
          categoryId: categoryId,
          beforeFile: beforeFile,
          mediaRootId: mediaRootId,
          mediaService: mediaService,
          metadataProbe: metadataProbe);

  String _movieIdForScannedEpisode({
    required String categoryId,
    required String? collectionKey,
    required String title,
  }) =>
      _scan.movieIdForScannedEpisode(
          categoryId: categoryId, collectionKey: collectionKey, title: title);

  EpisodeGrouping _episodeGrouping(String path) => _scan.episodeGrouping(path);

  List<NasLibraryMovie> listMovies({String query = ''}) =>
      _queries.listMovies(query: query);

  /// 影集目标选择专用的服务端分页查询，绝不借用客户端当前影片墙。
  NasMovieSearchPage searchSeries({
    String query = '',
    required String categoryId,
    int page = 1,
    int pageSize = 20,
  }) =>
      _queries.searchSeries(
          query: query, categoryId: categoryId, page: page, pageSize: pageSize);

  /// 在 SQLite 中完成搜索、三组标签条件、排序和分页，绝不回传全量影片。
  NasMovieSearchPage searchMovies(NasMovieSearchFilter filter) =>
      _queries.searchMovies(filter);

  List<NasPublisher> listPublishers({
    String query = '',
    bool includeArchived = false,
  }) =>
      _profiles.listPublishers(query: query, includeArchived: includeArchived);

  NasPublisher? findPublisher(String publisherId) =>
      _profiles.findPublisher(publisherId);

  NasPublisher? findPublisherByProfileIdentity(String profileIdentity) =>
      _profiles.findPublisherByProfileIdentity(profileIdentity);

  bool publisherDisplayNameExists(String displayName) =>
      _profiles.publisherDisplayNameExists(displayName);

  NasPublisher? findPublisherByDisplayName(String displayName) =>
      _profiles.findPublisherByDisplayName(displayName);

  NasPublisher createPublisher({
    required String displayName,
    String? profileIdentity,
    String? originalName,
    String? countryRegion,
    String? foundedDate,
    String? logoAssetId,
  }) =>
      _profiles.createPublisher(
          displayName: displayName,
          profileIdentity: profileIdentity,
          originalName: originalName,
          countryRegion: countryRegion,
          foundedDate: foundedDate,
          logoAssetId: logoAssetId);

  NasPublisher? updatePublisher(
          String publisherId, Map<String, Object?> values) =>
      _profiles.updatePublisher(publisherId, values);

  NasPublisher? archivePublisher(String publisherId) =>
      _profiles.archivePublisher(publisherId);

  bool publisherHasReferences(String publisherId) =>
      _profiles.publisherHasReferences(publisherId);

  bool deletePublisher(String publisherId) =>
      _profiles.deletePublisher(publisherId);

  List<NasSeries> listSeries({
    String query = '',
    String? publisherId,
    bool includeArchived = false,
  }) =>
      _profiles.listSeries(
          query: query,
          publisherId: publisherId,
          includeArchived: includeArchived);

  NasSeries? findSeries(String seriesId) => _profiles.findSeries(seriesId);

  NasSeries? findSeriesByProfileIdentity(String profileIdentity) =>
      _profiles.findSeriesByProfileIdentity(profileIdentity);

  bool seriesDisplayNameExists(String displayName) =>
      _profiles.seriesDisplayNameExists(displayName);

  NasSeries createSeries({
    required String displayName,
    String? profileIdentity,
    String? publisherId,
    String? originalName,
    String? translatedName,
    String? releaseDate,
    String? posterAssetId,
  }) =>
      _profiles.createSeries(
          displayName: displayName,
          profileIdentity: profileIdentity,
          publisherId: publisherId,
          originalName: originalName,
          translatedName: translatedName,
          releaseDate: releaseDate,
          posterAssetId: posterAssetId);

  NasSeries? updateSeries(String seriesId, Map<String, Object?> values) =>
      _profiles.updateSeries(seriesId, values);

  NasSeries? archiveSeries(String seriesId) =>
      _profiles.archiveSeries(seriesId);

  bool deleteSeries(String seriesId) => _profiles.deleteSeries(seriesId);

  List<NasLibraryMovie> moviesForPublisher(String publisherId,
          {String query = ''}) =>
      _profiles.moviesForPublisher(publisherId, query: query);

  List<NasLibraryMovie> moviesForSeries(String seriesId, {String query = ''}) =>
      _profiles.moviesForSeries(seriesId, query: query);

  List<NasSeries> seriesForPublisher(String publisherId, {String query = ''}) =>
      _profiles.seriesForPublisher(publisherId, query: query);

  List<NasLibraryTag> tagsForPublisher(String publisherId) =>
      _profiles.tagsForPublisher(publisherId);

  List<NasLibraryTag> tagsForSeries(String seriesId) =>
      _profiles.tagsForSeries(seriesId);

  List<NasRelatedActor> actorsForPublisher(String publisherId) =>
      _profiles.actorsForPublisher(publisherId);

  List<NasRelatedActor> actorsForSeries(String seriesId) =>
      _profiles.actorsForSeries(seriesId);

  List<String> publisherIdsForActor(String actorId) =>
      _profiles.publisherIdsForActor(actorId);

  List<NasPublisher> publishersForActor(String actorId) =>
      _profiles.publishersForActor(actorId);

  bool setActorPublisherIds({
    required String actorId,
    required List<String> publisherIds,
  }) =>
      _profiles.setActorPublisherIds(
          actorId: actorId, publisherIds: publisherIds);

  /// 统一解析影片关系，系列存在时始终以系列所属发行商为准。
  ({String? publisherId, String? seriesId})? resolveMovieRelations({
    required String movieId,
    String? publisherId,
    required bool updatePublisherId,
    String? seriesId,
    required bool updateSeriesId,
  }) =>
      _profiles.resolveMovieRelations(
          movieId: movieId,
          publisherId: publisherId,
          updatePublisherId: updatePublisherId,
          seriesId: seriesId,
          updateSeriesId: updateSeriesId);

  NasLibraryMovie? updateMovieRelations({
    required String movieId,
    required String? publisherId,
    required bool updatePublisherId,
    required String? seriesId,
    required bool updateSeriesId,
  }) =>
      _profiles.updateMovieRelations(
          movieId: movieId,
          publisherId: publisherId,
          updatePublisherId: updatePublisherId,
          seriesId: seriesId,
          updateSeriesId: updateSeriesId);

  List<NasActor> listActors({
    String query = '',
    String? gender,
    bool includeArchived = false,
  }) =>
      _profiles.listActors(
          query: query, gender: gender, includeArchived: includeArchived);

  NasActor? findActor(String actorId) => _profiles.findActor(actorId);

  NasActor? findActorByProfileIdentity(String profileIdentity) =>
      _profiles.findActorByProfileIdentity(profileIdentity);

  bool actorDisplayNameExists(String displayName) =>
      _profiles.actorDisplayNameExists(displayName);

  /// 仅接受与任一已保存演员名称完全相等的活动演员，模糊候选必须人工处理。
  NasActor? findActiveActorByExactName(String name) =>
      _profiles.findActiveActorByExactName(name);

  /// 同时核对所有姓名和别名；不同名字指向多位演员时必须人工选择。
  List<NasActor> findActorsByExactNames(Iterable<String> names,
          {bool includeArchived = false}) =>
      _profiles.findActorsByExactNames(names, includeArchived: includeArchived);

  List<NasActor> actorsForMovie(String movieId) =>
      _profiles.actorsForMovie(movieId);

  List<NasLibraryMovie> moviesForActor(String actorId, {String query = ''}) =>
      _profiles.moviesForActor(actorId, query: query);

  List<NasActorCoactor> coactorsForActor(String actorId) =>
      _profiles.coactorsForActor(actorId);

  List<NasActor> findSimilarActors({
    String? stageName,
    String? originalName,
    String? translatedName,
    List<String> aliases = const [],
    List<NasActor>? candidates,
  }) =>
      _profiles.findSimilarActors(
          stageName: stageName,
          originalName: originalName,
          translatedName: translatedName,
          aliases: aliases,
          candidates: candidates);

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
  }) =>
      _profiles.createActor(
          profileIdentity: profileIdentity,
          stageName: stageName,
          originalName: originalName,
          translatedName: translatedName,
          aliases: aliases,
          gender: gender,
          romanizedName: romanizedName,
          birthDate: birthDate,
          birthMonth: birthMonth,
          heightCm: heightCm,
          weightKg: weightKg,
          measurements: measurements,
          bodyType: bodyType,
          country: country,
          birthplace: birthplace,
          cup: cup,
          careerPeriod: careerPeriod,
          debutMonth: debutMonth,
          debutDescription: debutDescription,
          accountUrl: accountUrl,
          officialSiteUrl: officialSiteUrl,
          photoAssetId: photoAssetId,
          backdropAssetId: backdropAssetId,
          publisherNames: publisherNames);

  NasActor? updateActor(String actorId, Map<String, Object?> values) =>
      _profiles.updateActor(actorId, values);

  NasMdcngActorImportRecord? findMdcngActorImport({
    required String sourceId,
    required String taskId,
    required String sourceFingerprint,
  }) =>
      _profiles.findMdcngActorImport(
          sourceId: sourceId,
          taskId: taskId,
          sourceFingerprint: sourceFingerprint);

  NasActor? findActorByMdcngSource({
    required String sourceId,
    required String embyId,
  }) =>
      _profiles.findActorByMdcngSource(sourceId: sourceId, embyId: embyId);

  Set<String> mdcngDeferredEmbyIdsForSource(String sourceId) =>
      _profiles.mdcngDeferredEmbyIdsForSource(sourceId);

  bool isMdcngActorDeferred(
          {required String sourceId, required String embyId}) =>
      _profiles.isMdcngActorDeferred(sourceId: sourceId, embyId: embyId);

  void setMdcngActorDeferred({
    required String sourceId,
    required String embyId,
    required bool deferred,
  }) =>
      _profiles.setMdcngActorDeferred(
          sourceId: sourceId, embyId: embyId, deferred: deferred);

  Map<String, String> mdcngProfileKeysForSource(String sourceId) =>
      _profiles.mdcngProfileKeysForSource(sourceId);

  void linkActorToMdcngSource({
    required String sourceId,
    required String embyId,
    required String actorId,
    required String sourceName,
    required String profileKey,
    bool reconcileMovies = true,
  }) =>
      _profiles.linkActorToMdcngSource(
          sourceId: sourceId,
          embyId: embyId,
          actorId: actorId,
          sourceName: sourceName,
          profileKey: profileKey,
          reconcileMovies: reconcileMovies);

  bool actorHasOtherMdcngIdentity(
          String actorId, String sourceId, String embyId) =>
      _profiles.actorHasOtherMdcngIdentity(actorId, sourceId, embyId);

  NasMdcngActorImportRecord addMdcngActorImport({
    required String actorId,
    required String sourceId,
    required String taskId,
    required String embyId,
    required String sourceFingerprint,
    required List<String> appliedFields,
  }) =>
      _profiles.addMdcngActorImport(
          actorId: actorId,
          sourceId: sourceId,
          taskId: taskId,
          embyId: embyId,
          sourceFingerprint: sourceFingerprint,
          appliedFields: appliedFields);

  NasActor? archiveActor(String actorId) => _profiles.archiveActor(actorId);

  /// 删除无活跃影片关联的演员；归并审计关系不再阻止资料清理。
  bool deleteActor(String actorId) => _profiles.deleteActor(actorId);

  /// Removes the current MDCNG actor import state in one transaction. All
  /// actor-to-movie links are removed first so every actor can be deleted,
  /// including actors that are currently used by active movies.
  NasMdcngActorReset clearAllMdcngActors() => _profiles.clearAllMdcngActors();

  bool setMovieActorIds({
    required String movieId,
    required List<String> actorIds,
  }) =>
      _profiles.setMovieActorIds(movieId: movieId, actorIds: actorIds);

  NasManagedAsset addManagedAsset({
    required String id,
    required String purpose,
    required String fileName,
    required String mimeType,
  }) =>
      _assets.addManagedAsset(
          id: id, purpose: purpose, fileName: fileName, mimeType: mimeType);

  NasManagedAsset? findManagedAsset(String assetId) =>
      _assets.findManagedAsset(assetId);

  /// 删除受管理资产记录，供演员删除等场景同步清理 NAS 资产目录。
  NasManagedAsset? removeManagedAsset(String assetId) =>
      _assets.removeManagedAsset(assetId);

  NasAiTask? createAiTask({
    required String movieId,
    required String instructions,
  }) =>
      _metadata.createAiTask(movieId: movieId, instructions: instructions);

  NasAiTask? findAiTask(String taskId) => _metadata.findAiTask(taskId);

  NasAiTask? markAiTaskRunning(String taskId) =>
      _metadata.markAiTaskRunning(taskId);

  NasAiTask? completeAiTask(String taskId, Map<String, Object?> result) =>
      _metadata.completeAiTask(taskId, result);

  NasAiTask? failAiTask(String taskId, String errorCode) =>
      _metadata.failAiTask(taskId, errorCode);

  bool get hasMediaRoots => _queries.hasMediaRoots;

  bool get hasScannedMediaRoots => _queries.hasScannedMediaRoots;

  NasLibraryMovie? findMovie(String movieId) => _queries.findMovie(movieId);

  NasLibraryMovie? findMovieForAdmin(String movieId) =>
      _queries.findMovieForAdmin(movieId);

  List<String> activeMovieIdsForCategory(String categoryId) =>
      _queries.activeMovieIdsForCategory(categoryId);

  String? preferredMdcngEpisodeIdForMovie(String movieId) =>
      _queries.preferredMdcngEpisodeIdForMovie(movieId);

  bool hasDefaultScannedTitle(String movieId) =>
      _queries.hasDefaultScannedTitle(movieId);

  NasLibraryMovie? setMovieFavorite({
    required String movieId,
    required bool isFavorite,
  }) =>
      _movies.setMovieFavorite(movieId: movieId, isFavorite: isFavorite);

  NasRemovedMovieIndex? removeMovieFromIndex(String movieId) =>
      _movies.removeMovieFromIndex(movieId);

  /// 调用方负责事务；先解除限制删除的引用，再级联清理影片关联。
  NasRemovedMovieIndex _removeMovieIndex(NasLibraryMovie movie) =>
      _movies.removeMovieIndex(movie);

  /// 统一替换影片可编辑元数据，供 Windows 手动管理与未来 AI 富化共用。
  NasLibraryMovie? updateMovieMetadata({
    required String movieId,
    String? title,
    String? originalTitle,
    bool updateOriginalTitle = false,
    String? catalogNumber,
    bool updateCatalogNumber = false,
    String? publisherName,
    bool updatePublisherName = false,
    String? seriesName,
    bool updateSeriesName = false,
    String? summary,
  }) =>
      _movies.updateMovieMetadata(
          movieId: movieId,
          title: title,
          originalTitle: originalTitle,
          updateOriginalTitle: updateOriginalTitle,
          catalogNumber: catalogNumber,
          updateCatalogNumber: updateCatalogNumber,
          publisherName: publisherName,
          updatePublisherName: updatePublisherName,
          seriesName: seriesName,
          updateSeriesName: updateSeriesName,
          summary: summary);

  List<NasLibraryEpisode> episodesForMovie(String movieId) =>
      _queries.episodesForMovie(movieId);

  NasEpisodePage episodePageForMovie({
    required String movieId,
    String query = '',
    required int page,
    required int pageSize,
    String? anchorEpisodeId,
  }) =>
      _queries.episodePageForMovie(
          movieId: movieId,
          query: query,
          page: page,
          pageSize: pageSize,
          anchorEpisodeId: anchorEpisodeId);

  NasScannedMediaFilePage scannedMediaFiles({
    required int page,
    required int pageSize,
    String query = '',
  }) =>
      _queries.scannedMediaFiles(page: page, pageSize: pageSize, query: query);

  NasLibraryMovie createEmptySeries({
    required String title,
    required String categoryId,
  }) =>
      _collections.createEmptySeries(title: title, categoryId: categoryId);

  bool mergeEpisodesIntoSeries({
    required String targetMovieId,
    required List<String> episodeIds,
    required String metadataSourceMovieId,
  }) =>
      _collections.mergeEpisodesIntoSeries(
          targetMovieId: targetMovieId,
          episodeIds: episodeIds,
          metadataSourceMovieId: metadataSourceMovieId);

  List<NasLibraryMovie>? splitEpisodesIntoSingles({
    required String movieId,
    required List<String> episodeIds,
  }) =>
      _collections.splitEpisodesIntoSingles(
          movieId: movieId, episodeIds: episodeIds);

  List<NasCollectionMigrationCandidate> collectionMigrationPreview() =>
      _collections.collectionMigrationPreview();

  NasLibraryMovie? applyCollectionMigration({
    required String key,
    required String metadataSourceMovieId,
  }) =>
      _collections.applyCollectionMigration(
          key: key, metadataSourceMovieId: metadataSourceMovieId);

  NasLibraryEpisode? findEpisode(String episodeId) =>
      _queries.findEpisode(episodeId);

  NasLibraryEpisode? updateEpisodeTitle({
    required String episodeId,
    required String title,
  }) =>
      _movies.updateEpisodeTitle(episodeId: episodeId, title: title);

  List<NasLibraryCategory> listCategories() => _taxonomy.listCategories();

  NasLibraryCategory? findCategory(String categoryId) =>
      _taxonomy.findCategory(categoryId);

  // 与影片墙一致：按逻辑影片统计，影集只算一部；离线记录仍保留，归并来源不计入。

  List<NasCategoryMediaSource> mediaSourcesForCategory(String categoryId) =>
      _taxonomy.mediaSourcesForCategory(categoryId);

  bool replaceCategoryMediaSources({
    required String categoryId,
    required List<NasCategoryMediaSourceInput> sources,
  }) =>
      _taxonomy.replaceCategoryMediaSources(
          categoryId: categoryId, sources: sources);

  bool hasCategoryName(String name, {String? excludingId}) =>
      _taxonomy.hasCategoryName(name, excludingId: excludingId);

  NasLibraryCategory createCategory(String name,
          {String? mediaRelativePath, String? color}) =>
      _taxonomy.createCategory(name,
          mediaRelativePath: mediaRelativePath, color: color);

  NasLibraryCategory? updateCategory(
    String categoryId, {
    required String name,
    String? mediaRelativePath,
    String? color,
    bool updateColor = false,
    required bool updateMediaRelativePath,
  }) =>
      _taxonomy.updateCategory(categoryId,
          name: name,
          mediaRelativePath: mediaRelativePath,
          color: color,
          updateColor: updateColor,
          updateMediaRelativePath: updateMediaRelativePath);

  bool deleteCategory(String categoryId, {bool deleteMovies = false}) =>
      _taxonomy.deleteCategory(categoryId, deleteMovies: deleteMovies);

  /// 原子删除分类和索引，返回仅供清理 NAS 内部图片副本的信息。
  List<NasRemovedMovieIndex>? deleteCategoryWithIndexes(String categoryId,
          {bool deleteMovies = false}) =>
      _taxonomy.deleteCategoryWithIndexes(categoryId,
          deleteMovies: deleteMovies);

  NasCategoryTaxonomyTransfer exportCategoryTaxonomy() =>
      _taxonomy.exportCategoryTaxonomy();

  NasTaxonomyTransferResult importCategoryTaxonomy(
    NasCategoryTaxonomyTransfer transfer,
  ) =>
      _taxonomy.importCategoryTaxonomy(transfer);

  List<NasLibraryTag> listTags({int? level, bool includeArchived = false}) =>
      _taxonomy.listTags(level: level, includeArchived: includeArchived);

  NasLibraryTag? findTag(String tagId) => _taxonomy.findTag(tagId);

  NasLibraryTag? findActiveTagByName(String name) =>
      _taxonomy.findActiveTagByName(name);

  bool hasTagName(String name, {String? excludingId}) =>
      _taxonomy.hasTagName(name, excludingId: excludingId);

  NasLibraryTag createTag({
    required String name,
    required int level,
    String description = '',
    String? color,
    List<String> parentIds = const [],
  }) =>
      _taxonomy.createTag(
          name: name,
          level: level,
          description: description,
          color: color,
          parentIds: parentIds);

  NasLibraryTag? updateTag({
    required String tagId,
    required String name,
    required String description,
    String? color,
    required List<String> parentIds,
  }) =>
      _taxonomy.updateTag(
          tagId: tagId,
          name: name,
          description: description,
          color: color,
          parentIds: parentIds);

  bool archiveTag(String tagId) => _taxonomy.archiveTag(tagId);

  bool deleteTag(String tagId) => _taxonomy.deleteTag(tagId);

  NasTagOverview tagOverview() => _taxonomy.tagOverview();

  List<NasTagDirectoryRoot> tagDirectory({String query = ''}) =>
      _taxonomy.tagDirectory(query: query);

  /// 仅返回活跃的一、二级标签及进入二级时需要的一级路径上下文。
  List<NasMovieSearchTagDirectoryRoot> movieSearchTagDirectory({
    String query = '',
  }) =>
      _taxonomy.movieSearchTagDirectory(query: query);

  /// 固定 30 条读取某个二级标签的直属三级标签，不展开其余目录。
  NasMovieSearchThirdLevelTagPage movieSearchThirdLevelTags({
    required String parentTagId,
    String query = '',
    int page = 1,
    int pageSize = 30,
  }) =>
      _taxonomy.movieSearchThirdLevelTags(
          parentTagId: parentTagId,
          query: query,
          page: page,
          pageSize: pageSize);

  NasTagDetails? tagDetails({
    required String tagId,
    String? contextParentId,
    String? contextRootId,
  }) =>
      _taxonomy.tagDetails(
          tagId: tagId,
          contextParentId: contextParentId,
          contextRootId: contextRootId);

  NasTagChildPage tagChildren({
    required String parentTagId,
    String query = '',
    bool? associated,
    String sort = 'movieCount',
    String order = 'desc',
    int page = 1,
    int pageSize = 10,
  }) =>
      _taxonomy.tagChildren(
          parentTagId: parentTagId,
          query: query,
          associated: associated,
          sort: sort,
          order: order,
          page: page,
          pageSize: pageSize);

  NasTagMoviePage tagMovies({
    required String tagId,
    String query = '',
    String? categoryId,
    String? resolution,
    String sort = 'lastPlayedAt',
    String order = 'desc',
    int page = 1,
    int pageSize = 15,
  }) =>
      _taxonomy.tagMovies(
          tagId: tagId,
          query: query,
          categoryId: categoryId,
          resolution: resolution,
          sort: sort,
          order: order,
          page: page,
          pageSize: pageSize);

  NasTagTaxonomyTransfer exportTagTaxonomy() => _taxonomy.exportTagTaxonomy();

  NasTaxonomyTransferResult importTagTaxonomy(
          NasTagTaxonomyTransfer transfer) =>
      _taxonomy.importTagTaxonomy(transfer);

  List<String> taxonomyViolations() => _taxonomy.taxonomyViolations();

  List<String> categoryTaxonomyViolations() =>
      _taxonomy.categoryTaxonomyViolations();

  NasLibraryCategory? categoryForMovie(String movieId) =>
      _taxonomy.categoryForMovie(movieId);

  /// Batch the current page's associations; load tag ancestry only once.
  Map<String, Map<String, Object?>> browseAssociations(List<String> ids) =>
      _taxonomy.browseAssociations(ids);

  List<NasTagPath> tagPathsForMovie(String movieId) =>
      _taxonomy.tagPathsForMovie(movieId);

  List<NasTagPath> allTagPaths() => _taxonomy.allTagPaths();

  List<NasLibraryTag> tagsForMovie(String movieId) =>
      _taxonomy.tagsForMovie(movieId);

  List<NasLibraryTag> _tagsForRelation(
    String condition,
    List<Object?> parameters,
  ) =>
      _taxonomy.tagsForRelation(condition, parameters);

  bool setMovieTaxonomy({
    required String movieId,
    required bool updateCategory,
    required String? categoryId,
    required bool updateTagIds,
    required List<String> tagIds,
  }) =>
      _taxonomy.setMovieTaxonomy(
          movieId: movieId,
          updateCategory: updateCategory,
          categoryId: categoryId,
          updateTagIds: updateTagIds,
          tagIds: tagIds);

  Map<String, NasMovieMetadataFieldSource> metadataFieldSourcesForMovie(
    String movieId,
  ) =>
      _metadata.metadataFieldSourcesForMovie(movieId);

  /// 由常规管理接口调用，以便后续 MDCNG 预览识别人工已确认的字段。
  bool markMovieMetadataFieldsManual({
    required String movieId,
    required Iterable<String> fieldKeys,
  }) =>
      _metadata.markMovieMetadataFieldsManual(
          movieId: movieId, fieldKeys: fieldKeys);

  /// 原子写入已经由管理员确认的 MDCNG 字段，并保存可追溯的来源摘要。
  NasMdcngImportRecord applyMdcngMetadata(NasMdcngMetadataApply input) =>
      _metadata.applyMdcngMetadata(input);

  NasLibraryMovie? updateMoviePosterFileName({
    required String movieId,
    required String posterFileName,
  }) =>
      _movies.updateMoviePosterFileName(
          movieId: movieId, posterFileName: posterFileName);

  NasLibraryEpisode? updateEpisodeSourceAfterRename({
    required String episodeId,
    required String relativePath,
    required String title,
    required int fileSize,
    required int mediaModifiedAt,
  }) =>
      _movies.updateEpisodeSourceAfterRename(
          episodeId: episodeId,
          relativePath: relativePath,
          title: title,
          fileSize: fileSize,
          mediaModifiedAt: mediaModifiedAt);

  NasEpisodePlaybackProgress? playbackProgressForEpisode({
    required String movieId,
    required String episodeId,
  }) =>
      _playback.playbackProgressForEpisode(
          movieId: movieId, episodeId: episodeId);

  int resumePositionMsForEpisode({
    required String movieId,
    required String episodeId,
  }) =>
      _playback.resumePositionMsForEpisode(
          movieId: movieId, episodeId: episodeId);

  NasPlaybackResumeTarget? resumeTargetForMovie(String movieId) =>
      _playback.resumeTargetForMovie(movieId);

  String recordPlaybackStarted({
    required String movieId,
    required String episodeId,
    String deviceId = 'legacy',
    String devicePlatform = 'unknown',
    String? startedAt,
    int? durationMs,
  }) =>
      _playback.recordPlaybackStarted(
          movieId: movieId,
          episodeId: episodeId,
          deviceId: deviceId,
          devicePlatform: devicePlatform,
          startedAt: startedAt,
          durationMs: durationMs);

  /// 只更新当前正式播放会话绑定的那一条记录，绝不按影片合并历史活动。
  void reportPlaybackHistory({
    required String historyId,
    required String lastReportedAt,
    required int watchDurationMs,
    required int lastPositionMs,
    required int? durationMs,
    required String playbackStatus,
  }) =>
      _playback.reportPlaybackHistory(
          historyId: historyId,
          lastReportedAt: lastReportedAt,
          watchDurationMs: watchDurationMs,
          lastPositionMs: lastPositionMs,
          durationMs: durationMs,
          playbackStatus: playbackStatus);

  void finishPlaybackHistory({
    required String historyId,
    required int? endPositionMs,
    required int? durationMs,
    String? lastReportedAt,
    int? watchDurationMs,
    String playbackStatus = 'ended',
  }) =>
      _playback.finishPlaybackHistory(
          historyId: historyId,
          endPositionMs: endPositionMs,
          durationMs: durationMs,
          lastReportedAt: lastReportedAt,
          watchDurationMs: watchDurationMs,
          playbackStatus: playbackStatus);

  NasWatchHistoryPage watchHistoryPage(NasWatchHistoryQuery query) =>
      _playback.watchHistoryPage(query);

  List<NasPlaybackHistoryItem> listPlaybackHistory({String titleQuery = ''}) =>
      _playback.listPlaybackHistory(titleQuery: titleQuery);

  void savePlaybackProgress({
    required String movieId,
    required String episodeId,
    required int positionMs,
    required int durationMs,
  }) =>
      _playback.savePlaybackProgress(
          movieId: movieId,
          episodeId: episodeId,
          positionMs: positionMs,
          durationMs: durationMs);

  List<NasCarouselImage> carouselImagesForMovie(String movieId) =>
      _assets.carouselImagesForMovie(movieId);

  String? lastPlaybackStartedAtForMovie(String movieId) =>
      _playback.lastPlaybackStartedAtForMovie(movieId);

  NasCarouselImage? addCarouselImage({
    required String movieId,
    required String fileName,
  }) =>
      _assets.addCarouselImage(movieId: movieId, fileName: fileName);

  NasCarouselImage? removeCarouselImage({
    required String movieId,
    required String imageId,
  }) =>
      _assets.removeCarouselImage(movieId: movieId, imageId: imageId);

  NasCarouselImage? findCarouselImage(String imageId) =>
      _assets.findCarouselImage(imageId);

  static String _now() => now();
}
