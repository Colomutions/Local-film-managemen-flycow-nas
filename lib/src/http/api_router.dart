import 'dart:io';
import '../persistent_state.dart';
import '../comics/comic_http.dart';
import '../novels/novel_http.dart';
import 'movies.dart';
import 'scraping.dart';
import 'playback.dart';
import 'operations.dart';
import 'taxonomy.dart';
import 'artwork.dart';
import 'mdcng_movies.dart';
import 'mdcng_actors.dart';
import 'scan.dart';
import 'profile_packages.dart';
import 'ai.dart';
import 'profiles.dart';
import 'history.dart';
import 'response.dart';

/// Dispatches requests after the server has checked maintenance, device token
/// and admin scope. Each API owns its domain operations and state.
class NasApiRouter {
  NasApiRouter({
    required NasMoviesHttpApi movies,
    required NasScrapingHttpApi scraping,
    required NasPlaybackHttpApi playback,
    required NasOperationsHttpApi operations,
    required NasTaxonomyHttpApi taxonomy,
    required NasArtworkHttpApi artwork,
    required NasMdcngMoviesHttpApi mdcngMovies,
    required NasMdcngActorsHttpApi mdcngActors,
    required NasScanHttpApi scans,
    required NasProfilePackagesHttpApi profilePackages,
    required NasAiHttpApi ai,
    required NasProfilesHttpApi profiles,
    required NasHistoryHttpApi history,
    required this.novelApi,
    required this.comicApi,
  })  : _moviesApi = movies,
        _scrapingApi = scraping,
        _playback = playback,
        _operations = operations,
        _taxonomyApi = taxonomy,
        _assets = artwork,
        _mdcngMovies = mdcngMovies,
        _mdcngActors = mdcngActors,
        _scans = scans,
        _packagesApi = profilePackages,
        _aiApi = ai,
        _profilesApi = profiles,
        _historyApi = history;

  final NasMoviesHttpApi _moviesApi;
  final NasScrapingHttpApi _scrapingApi;
  final NasPlaybackHttpApi _playback;
  final NasOperationsHttpApi _operations;
  final NasTaxonomyHttpApi _taxonomyApi;
  final NasArtworkHttpApi _assets;
  final NasMdcngMoviesHttpApi _mdcngMovies;
  final NasMdcngActorsHttpApi _mdcngActors;
  final NasScanHttpApi _scans;
  final NasProfilePackagesHttpApi _packagesApi;
  final NasAiHttpApi _aiApi;
  final NasProfilesHttpApi _profilesApi;
  final NasHistoryHttpApi _historyApi;
  final NasNovelHttpApi? Function() novelApi;
  final ComicHttpApi? Function() comicApi;
  NasNovelHttpApi? get _novelApi => novelApi();
  ComicHttpApi? get _comicApi => comicApi();

  Future<void> handle(HttpRequest request,
      {required NasDeviceToken device, required String tokenHash}) async {
    final path = request.uri.path;
    if (request.method == 'GET' && path == '/api/v1/cinema-home') {
      return await _moviesApi.cinemaHome(request);
    }
    if (path == '/api/v1/admin/scraping' ||
        path.startsWith('/api/v1/admin/scraping/')) {
      return await _scrapingApi.scrapingRequest(request);
    }
    if (request.method == 'POST' &&
        RegExp(r'^/api/v1/playback/sessions/[^/]+/finish$').hasMatch(path)) {
      return await _playback.finishPlayback(request, tokenHash);
    }
    if (path == '/api/v1/comics' ||
        path.startsWith('/api/v1/comics/') ||
        path == '/api/v1/admin/comics' ||
        path.startsWith('/api/v1/admin/comics/')) {
      final comicApi = _comicApi;
      return comicApi == null
          ? await writeApiError(request, HttpStatus.serviceUnavailable,
              'comic_storage_unavailable')
          : await comicApi.handle(request,
              deviceId: device.deviceId, admin: device.scope == 'admin');
    }
    final novelApi = _novelApi;
    if (request.method == 'GET' && path == '/api/v1/novels') {
      return novelApi == null
          ? await writeApiError(request, HttpStatus.serviceUnavailable,
              'novel_storage_unavailable')
          : await novelApi.list(request);
    }
    if (request.method == 'POST' && path == '/api/v1/novels') {
      return novelApi == null
          ? await writeApiError(request, HttpStatus.serviceUnavailable,
              'novel_storage_unavailable')
          : await novelApi.create(
              request,
              deviceId: device.deviceId,
              isAdmin: device.scope == 'admin',
            );
    }
    if ((request.method == 'GET' || request.method == 'HEAD') &&
        RegExp(r'^/api/v1/novels/[^/]+/content$').hasMatch(path)) {
      return novelApi == null
          ? await writeApiError(request, HttpStatus.serviceUnavailable,
              'novel_storage_unavailable')
          : await novelApi.content(request, request.uri.pathSegments[3]);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/novels/[^/]+$').hasMatch(path)) {
      return novelApi == null
          ? await writeApiError(request, HttpStatus.serviceUnavailable,
              'novel_storage_unavailable')
          : await novelApi.detail(request, request.uri.pathSegments[3]);
    }
    if (request.method == 'PUT' &&
        RegExp(r'^/api/v1/admin/novels/[^/]+$').hasMatch(path)) {
      return novelApi == null
          ? await writeApiError(request, HttpStatus.serviceUnavailable,
              'novel_storage_unavailable')
          : await novelApi.replace(
              request,
              deviceId: device.deviceId,
              novelId: request.uri.pathSegments[4],
            );
    }
    if (request.method == 'DELETE' &&
        RegExp(r'^/api/v1/admin/novels/[^/]+$').hasMatch(path)) {
      return novelApi == null
          ? await writeApiError(request, HttpStatus.serviceUnavailable,
              'novel_storage_unavailable')
          : await novelApi.delete(
              request,
              deviceId: device.deviceId,
              novelId: request.uri.pathSegments[4],
            );
    }
    if (request.method == 'GET' && path == '/api/v1/admin/media-roots') {
      return await _operations.adminMediaRoots(request);
    }
    if (request.method == 'GET' && path == '/api/v1/admin/media-directories') {
      return await _operations.adminMediaDirectories(request);
    }
    if (request.method == 'GET' && path == '/api/v1/admin/devices') {
      return await _operations.adminDevices(request);
    }
    if (request.method == 'DELETE' &&
        RegExp(r'^/api/v1/admin/devices/[^/]+$').hasMatch(path)) {
      return await _operations.revokeAdminDevice(request);
    }
    if (request.method == 'POST' && path == '/api/v1/admin/backups') {
      return await _operations.createAdminBackup(request);
    }
    if (request.method == 'GET' && path == '/api/v1/admin/backups') {
      return await _operations.adminBackups(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/admin/backups/[^/]+$').hasMatch(path)) {
      return await _operations.adminBackup(request);
    }
    if (request.method == 'GET' && path == '/api/v1/admin/categories') {
      return await _taxonomyApi.adminCategories(request);
    }
    if (request.method == 'GET' &&
        path == '/api/v1/admin/taxonomy/categories') {
      return await _taxonomyApi.exportAdminCategoryTaxonomy(request);
    }
    if (request.method == 'POST' &&
        path == '/api/v1/admin/taxonomy/categories') {
      return await _taxonomyApi.importAdminCategoryTaxonomy(request);
    }
    if (request.method == 'POST' && path == '/api/v1/admin/categories') {
      return await _taxonomyApi.createAdminCategory(request);
    }
    if (RegExp(r'^/api/v1/admin/categories/[^/]+$').hasMatch(path)) {
      if (request.method == 'PATCH')
        return await _taxonomyApi.updateAdminCategory(request);
      if (request.method == 'DELETE')
        return await _taxonomyApi.deleteAdminCategory(request);
    }
    if (request.method == 'GET' &&
        path == '/api/v1/admin/tag-management/overview') {
      return await _taxonomyApi.tagManagementOverview(request);
    }
    if (request.method == 'GET' &&
        path == '/api/v1/admin/tag-management/directory') {
      return await _taxonomyApi.tagManagementDirectory(request);
    }
    if (request.method == 'GET' &&
        path == '/api/v1/admin/tag-management/parent-candidates') {
      return await _taxonomyApi.tagManagementParentCandidates(request);
    }
    if (request.method == 'GET' &&
        path == '/api/v1/admin/tag-management/selectable') {
      return await _taxonomyApi.tagManagementSelectableTags(request);
    }
    if (request.method == 'GET' &&
        path == '/api/v1/admin/tag-management/template') {
      return await _taxonomyApi.tagManagementTemplate(request);
    }
    if (request.method == 'GET' &&
        path == '/api/v1/admin/tag-management/export') {
      return await _taxonomyApi.tagManagementExport(request);
    }
    if (request.method == 'POST' &&
        path == '/api/v1/admin/tag-management/import') {
      return await _taxonomyApi.importTagManagement(request);
    }
    if (request.method == 'POST' &&
        path == '/api/v1/admin/tag-management/tags') {
      return await _taxonomyApi.createTagManagementTag(request);
    }
    if (RegExp(r'^/api/v1/admin/tag-management/tags/[^/]+/archive$')
        .hasMatch(path)) {
      if (request.method == 'POST')
        return await _taxonomyApi.archiveTagManagementTag(request);
    }
    if (RegExp(r'^/api/v1/admin/tag-management/tags/[^/]+/children$')
        .hasMatch(path)) {
      if (request.method == 'GET')
        return await _taxonomyApi.tagManagementChildren(request);
    }
    if (RegExp(r'^/api/v1/admin/tag-management/tags/[^/]+/movies$')
        .hasMatch(path)) {
      if (request.method == 'GET')
        return await _taxonomyApi.tagManagementMovies(request);
    }
    if (RegExp(r'^/api/v1/admin/tag-management/tags/[^/]+$').hasMatch(path)) {
      if (request.method == 'GET')
        return await _taxonomyApi.tagManagementDetails(request);
      if (request.method == 'PATCH')
        return await _taxonomyApi.updateTagManagementTag(request);
      if (request.method == 'DELETE')
        return await _taxonomyApi.deleteTagManagementTag(request);
    }
    if (request.method == 'PATCH' &&
        RegExp(r'^/api/v1/admin/movies/[^/]+$').hasMatch(path)) {
      return await _moviesApi.updateAdminMovie(request);
    }
    if (request.method == 'PATCH' &&
        RegExp(r'^/api/v1/admin/movies/[^/]+/favorite$').hasMatch(path)) {
      return await _moviesApi.updateAdminMovieFavorite(request);
    }
    if (request.method == 'DELETE' &&
        RegExp(r'^/api/v1/admin/movies/[^/]+$').hasMatch(path)) {
      return await _moviesApi.removeAdminMovieFromIndex(request);
    }
    if (request.method == 'POST' &&
        RegExp(r'^/api/v1/admin/movies/[^/]+/poster$').hasMatch(path)) {
      return await _assets.uploadAdminMoviePoster(request);
    }
    if (request.method == 'POST' &&
        RegExp(r'^/api/v1/admin/movies/[^/]+/carousel-images$')
            .hasMatch(path)) {
      return await _assets.uploadAdminMovieCarouselImage(request);
    }
    if (request.method == 'DELETE' &&
        RegExp(r'^/api/v1/admin/movies/[^/]+/carousel-images/[^/]+$')
            .hasMatch(path)) {
      return await _assets.deleteAdminMovieCarouselImage(request);
    }
    if (request.method == 'PATCH' &&
        RegExp(r'^/api/v1/admin/episodes/[^/]+/source-name$').hasMatch(path)) {
      return await _moviesApi.renameAdminEpisodeSource(request);
    }
    if (request.method == 'PATCH' &&
        RegExp(r'^/api/v1/admin/episodes/[^/]+$').hasMatch(path)) {
      return await _moviesApi.updateAdminEpisode(request);
    }
    if (request.method == 'GET' && path == '/api/v1/admin/media-files') {
      return await _moviesApi.adminMediaFiles(request);
    }
    if (request.method == 'POST' &&
        path == '/api/v1/admin/mdcng-imports/preview') {
      return await _mdcngMovies.previewMdcngImport(request);
    }
    if (request.method == 'POST' &&
        path == '/api/v1/admin/mdcng-imports/apply') {
      return await _mdcngMovies.applyMdcngImport(request);
    }
    if (request.method == 'POST' && path == '/api/v1/admin/mdcng-import-jobs') {
      return await _mdcngMovies.createMdcngBatchJob(request);
    }
    if (request.method == 'GET' && path == '/api/v1/admin/mdcng-import-jobs') {
      return await _mdcngMovies.listMdcngBatchJobs(request);
    }
    if (request.method == 'GET' &&
        path == '/api/v1/admin/mdcng-import-jobs/preview') {
      return await _mdcngMovies.previewMdcngBatchJob(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/admin/mdcng-import-jobs/[^/]+$').hasMatch(path)) {
      return await _mdcngMovies.getMdcngBatchJob(request);
    }
    if (request.method == 'POST' &&
        RegExp(r'^/api/v1/admin/mdcng-import-jobs/[^/]+/(retry|cancel)$')
            .hasMatch(path)) {
      return await _mdcngMovies.changeMdcngBatchJob(request);
    }
    if (request.method == 'GET' &&
        path == '/api/v1/admin/mdcng-actor-imports') {
      return await _mdcngActors.listMdcngActorImports(request);
    }
    if (request.method == 'PUT' &&
        path == '/api/v1/admin/mdcng-actor-imports/decision') {
      return await _mdcngActors.setMdcngActorImportDecision(request);
    }
    if (request.method == 'POST' &&
        path == '/api/v1/admin/mdcng-actor-imports/reset') {
      return await _mdcngActors.resetMdcngActors(request);
    }
    if (request.method == 'POST' &&
        path == '/api/v1/admin/mdcng-actor-imports/preview') {
      return await _mdcngActors.previewMdcngActorImport(request);
    }
    if (request.method == 'POST' &&
        path == '/api/v1/admin/mdcng-actor-imports/apply') {
      return await _mdcngActors.applyMdcngActorImport(request);
    }
    if (request.method == 'GET' &&
        path == '/api/v1/admin/mdcng-actor-imports/batch-preview') {
      return await _mdcngActors.previewMdcngActorBatchImport(request);
    }
    if (request.method == 'POST' &&
        path == '/api/v1/admin/mdcng-actor-imports/batch-apply') {
      return await _mdcngActors.applyMdcngActorBatchImport(request);
    }
    if (request.method == 'POST' && path == '/api/v1/admin/collections') {
      return await _moviesApi.createAdminCollection(request);
    }
    if (request.method == 'POST' &&
        RegExp(r'^/api/v1/admin/collections/[^/]+/episodes$').hasMatch(path)) {
      return await _moviesApi.mergeAdminCollectionEpisodes(request);
    }
    if (request.method == 'POST' &&
        RegExp(r'^/api/v1/admin/collections/[^/]+/split$').hasMatch(path)) {
      return await _moviesApi.splitAdminCollectionEpisodes(request);
    }
    if (request.method == 'GET' &&
        path == '/api/v1/admin/collection-migrations/preview') {
      return await _moviesApi.collectionMigrationPreview(request);
    }
    if (request.method == 'POST' &&
        path == '/api/v1/admin/collection-migrations/apply') {
      return await _moviesApi.applyCollectionMigration(request);
    }
    if (request.method == 'POST' && path == '/api/v1/admin/scan-jobs') {
      return await _scans.createScanJob(request);
    }
    if (request.method == 'GET' && path == '/api/v1/admin/scan-jobs') {
      return await _scans.listScanJobs(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/admin/scan-jobs/[^/]+$').hasMatch(path)) {
      return await _scans.scanJob(request);
    }
    if (request.method == 'POST' && path == '/api/v1/admin/assets/images') {
      return await _assets.uploadManagedImage(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/admin/profile-packages/(actor|publisher|series)/template$')
            .hasMatch(path)) {
      return await _packagesApi.downloadProfilePackageTemplate(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/admin/profile-packages/(actor|publisher|series)/export$')
            .hasMatch(path)) {
      return await _packagesApi.exportProfilePackage(request);
    }
    if (request.method == 'POST' &&
        RegExp(r'^/api/v1/admin/profile-packages/(actor|publisher|series)/import$')
            .hasMatch(path)) {
      return await _packagesApi.importProfilePackage(request);
    }
    if (request.method == 'GET' && path == '/api/v1/admin/ai/settings') {
      return await _aiApi.aiSettings(request);
    }
    if (request.method == 'PUT' && path == '/api/v1/admin/ai/settings') {
      return await _aiApi.updateAiSettings(request);
    }
    if (request.method == 'POST' && path == '/api/v1/admin/ai/tasks') {
      return await _aiApi.createAiTask(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/admin/ai/tasks/[^/]+$').hasMatch(path)) {
      return await _aiApi.aiTask(request);
    }
    if (request.method == 'POST' &&
        RegExp(r'^/api/v1/admin/ai/tasks/[^/]+/apply$').hasMatch(path)) {
      return await _aiApi.applyAiTask(request);
    }
    if (request.method == 'POST' && path == '/api/v1/admin/actors') {
      return await _profilesApi.createAdminActor(request);
    }
    if (request.method == 'PATCH' &&
        RegExp(r'^/api/v1/admin/actors/[^/]+$').hasMatch(path)) {
      return await _profilesApi.updateAdminActor(request);
    }
    if (request.method == 'DELETE' &&
        RegExp(r'^/api/v1/admin/actors/[^/]+$').hasMatch(path)) {
      return await _profilesApi.deleteAdminActor(request);
    }
    if (request.method == 'POST' &&
        RegExp(r'^/api/v1/admin/actors/[^/]+/archive$').hasMatch(path)) {
      return await _profilesApi.archiveAdminActor(request);
    }
    if (request.method == 'POST' && path == '/api/v1/admin/publishers') {
      return await _profilesApi.createAdminPublisher(request);
    }
    if (request.method == 'PATCH' &&
        RegExp(r'^/api/v1/admin/publishers/[^/]+$').hasMatch(path)) {
      return await _profilesApi.updateAdminPublisher(request);
    }
    if (request.method == 'DELETE' &&
        RegExp(r'^/api/v1/admin/publishers/[^/]+$').hasMatch(path)) {
      return await _profilesApi.deleteAdminPublisher(request);
    }
    if (request.method == 'POST' &&
        RegExp(r'^/api/v1/admin/publishers/[^/]+/archive$').hasMatch(path)) {
      return await _profilesApi.archiveAdminPublisher(request);
    }
    if (request.method == 'POST' &&
        RegExp(r'^/api/v1/admin/publishers/[^/]+/logo$').hasMatch(path)) {
      return await _profilesApi.uploadAdminPublisherLogo(request);
    }
    if (request.method == 'POST' && path == '/api/v1/admin/series') {
      return await _profilesApi.createAdminSeries(request);
    }
    if (request.method == 'PATCH' &&
        RegExp(r'^/api/v1/admin/series/[^/]+$').hasMatch(path)) {
      return await _profilesApi.updateAdminSeries(request);
    }
    if (request.method == 'DELETE' &&
        RegExp(r'^/api/v1/admin/series/[^/]+$').hasMatch(path)) {
      return await _profilesApi.deleteAdminSeries(request);
    }
    if (request.method == 'POST' &&
        RegExp(r'^/api/v1/admin/series/[^/]+/archive$').hasMatch(path)) {
      return await _profilesApi.archiveAdminSeries(request);
    }
    if (request.method == 'POST' &&
        RegExp(r'^/api/v1/admin/series/[^/]+/poster$').hasMatch(path)) {
      return await _profilesApi.uploadAdminSeriesPoster(request);
    }
    if (request.method == 'GET' && path == '/api/v1/movies') {
      return await _moviesApi.movies(request);
    }
    if (request.method == 'GET' && path == '/api/v1/collections') {
      return await _moviesApi.collections(request);
    }
    if (request.method == 'POST' && path == '/api/v1/movies/search') {
      return await _moviesApi.movieSearch(request);
    }
    if (request.method == 'GET' &&
        path == '/api/v1/movie-search/tags/directory') {
      return await _moviesApi.movieSearchTagDirectory(request);
    }
    if (request.method == 'GET' &&
        path == '/api/v1/movie-search/tags/third-level') {
      return await _moviesApi.movieSearchThirdLevelTags(request);
    }
    if (request.method == 'GET' && path == '/api/v1/categories') {
      return await _taxonomyApi.categories(request);
    }
    if (request.method == 'GET' && path == '/api/v1/actors') {
      return await _profilesApi.actors(request);
    }
    if (request.method == 'GET' && path == '/api/v1/publishers') {
      return await _profilesApi.publishers(request);
    }
    if (request.method == 'GET' && path == '/api/v1/series') {
      return await _profilesApi.series(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/publishers/[^/]+/movies$').hasMatch(path)) {
      return await _profilesApi.publisherMovies(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/publishers/[^/]+/series$').hasMatch(path)) {
      return await _profilesApi.publisherSeries(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/publishers/[^/]+/actors$').hasMatch(path)) {
      return await _profilesApi.publisherActors(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/publishers/[^/]+$').hasMatch(path)) {
      return await _profilesApi.publisherDetails(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/series/[^/]+/movies$').hasMatch(path)) {
      return await _profilesApi.seriesMovies(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/series/[^/]+/actors$').hasMatch(path)) {
      return await _profilesApi.seriesActors(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/series/[^/]+$').hasMatch(path)) {
      return await _profilesApi.seriesDetails(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/actors/[^/]+/coactors$').hasMatch(path)) {
      return await _profilesApi.actorCoactors(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/actors/[^/]+/movies$').hasMatch(path)) {
      return await _profilesApi.actorMovies(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/actors/[^/]+$').hasMatch(path)) {
      return await _profilesApi.actorDetails(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/movies/[^/]+/episodes$').hasMatch(path)) {
      return await _moviesApi.movieEpisodes(request);
    }
    if (request.method == 'GET' &&
        RegExp(r'^/api/v1/movies/[^/]+$').hasMatch(path)) {
      return await _moviesApi.movieDetails(request);
    }
    if (request.method == 'GET' && path == '/api/v1/tag-paths') {
      return await _taxonomyApi.tagPaths(request);
    }
    if (request.method == 'GET' && path == '/api/v1/favorites') {
      return await _moviesApi.emptyItems(request);
    }
    if (request.method == 'GET' && path == '/api/v1/history') {
      return await _historyApi.history(request);
    }
    if (request.method == 'GET' && path == '/api/v1/watch-history') {
      return await _historyApi.watchHistory(request);
    }
    if ((request.method == 'GET' || request.method == 'HEAD') &&
        RegExp(r'^/api/v1/assets/posters/[^/]+$').hasMatch(path)) {
      return await _assets.poster(request);
    }
    if ((request.method == 'GET' || request.method == 'HEAD') &&
        RegExp(r'^/api/v1/assets/carousel-images/[^/]+$').hasMatch(path)) {
      return await _assets.carouselImage(request);
    }
    if ((request.method == 'GET' || request.method == 'HEAD') &&
        RegExp(r'^/api/v1/assets/[^/]+$').hasMatch(path)) {
      return await _assets.managedAsset(request);
    }
    if (request.method == 'POST' && path == '/api/v1/playback/sessions') {
      return await _playback.createPlaybackSession(request, tokenHash, device);
    }
    if (request.method == 'POST' &&
        RegExp(r'^/api/v1/playback/sessions/[^/]+/started$').hasMatch(path)) {
      return await _playback.markPlaybackStarted(request, tokenHash);
    }
    if (request.method == 'PATCH' &&
        RegExp(r'^/api/v1/playback/sessions/[^/]+/progress$').hasMatch(path)) {
      return await _playback.savePlaybackProgress(request, tokenHash);
    }
    if (request.method == 'DELETE' &&
        RegExp(r'^/api/v1/playback/sessions/[^/]+$').hasMatch(path)) {
      return await _playback.deletePlaybackSession(request, tokenHash);
    }
    if ((request.method == 'GET' || request.method == 'HEAD') &&
        RegExp(r'^/api/v1/playback/sessions/[^/]+/stream$').hasMatch(path)) {
      return await _playback.streamPlayback(request, tokenHash);
    }
    await writeApiError(request, HttpStatus.notFound, 'resource_not_found');
  }
}
