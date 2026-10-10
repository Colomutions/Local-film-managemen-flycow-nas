import 'dart:async';

import '../backup_service.dart';
import '../config.dart';
import '../library_database.dart';
import '../movie_actor.dart';
import '../persistent_state.dart';

import 'validation.dart';

/// Builds stable protocol payloads from library records.
class NasLibraryPresenter {
  NasLibraryPresenter(this._libraryDatabase, this.config);
  final NasLibraryDatabase _libraryDatabase;
  final NasConfig config;

  Map<String, Object?> _publisherReferencePayload(NasPublisher publisher) => {
        'id': publisher.id,
        'displayName': publisher.displayName,
      };

  Map<String, Object?> _seriesReferencePayload(NasSeries series) => {
        'id': series.id,
        'displayName': series.displayName,
        'publisherId': series.publisherId,
      };

  Map<String, Object?> publisherPayload(
    NasPublisher publisher, {
    bool includeTags = false,
  }) {
    final logo = publisher.logoAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(publisher.logoAssetId!);
    return {
      ..._publisherReferencePayload(publisher),
      'originalName': publisher.originalName,
      'countryRegion': publisher.countryRegion,
      'foundedDate': publisher.foundedDate,
      'organizationRoles': _libraryDatabase.companyRoles(publisher.id),
      'sourceProfiles':
          _libraryDatabase.scrapeProfiles('company', publisher.id),
      'logoAsset': logo == null ? null : managedAssetPayload(logo),
      'movieCount': publisher.movieCount,
      'seriesCount': publisher.seriesCount,
      'durationMs': publisher.durationMs,
      if (includeTags)
        'tags': _libraryDatabase
            .tagsForPublisher(publisher.id)
            .map(tagPayload)
            .toList(growable: false),
      'createdAt': publisher.createdAt,
      'updatedAt': publisher.updatedAt,
      'archivedAt': publisher.archivedAt,
    };
  }

  Map<String, Object?> seriesPayload(
    NasSeries series, {
    bool includeTags = false,
  }) {
    final publisher = series.publisherId == null
        ? null
        : _libraryDatabase.findPublisher(series.publisherId!);
    final poster = series.posterAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(series.posterAssetId!);
    return {
      ..._seriesReferencePayload(series),
      'originalName': series.originalName,
      'translatedName': series.translatedName,
      'publisher':
          publisher == null ? null : _publisherReferencePayload(publisher),
      'releaseDate': series.releaseDate,
      'posterAsset': poster == null ? null : managedAssetPayload(poster),
      'movieCount': series.movieCount,
      'episodeCount': series.episodeCount,
      'durationMs': series.durationMs,
      if (includeTags)
        'tags': _libraryDatabase
            .tagsForSeries(series.id)
            .map(tagPayload)
            .toList(growable: false),
      'createdAt': series.createdAt,
      'updatedAt': series.updatedAt,
      'archivedAt': series.archivedAt,
    };
  }

  Map<String, Object?> actorPayload(NasActor actor) {
    final photoAsset = actor.photoAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(actor.photoAssetId!);
    final backdropAsset = actor.backdropAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(actor.backdropAssetId!);
    return {
      'id': actor.id,
      'stageName': actor.stageName,
      'sourceProfiles': _libraryDatabase.scrapeProfiles('actor', actor.id),
      'originalName': actor.originalName,
      'translatedName': actor.translatedName,
      'aliases': actor.aliases,
      'gender': actor.gender,
      'romanizedName': actor.romanizedName,
      'birthDate': actor.birthDate,
      'birthMonth': actor.birthMonth,
      'age': nasActorAge(actor.birthMonth),
      'heightCm': actor.heightCm,
      'weightKg': actor.weightKg,
      'measurements': actor.measurements,
      'bodyType': actor.bodyType,
      'country': actor.country,
      'birthplace': actor.birthplace,
      'cup': actor.cup,
      'careerPeriod': actor.careerPeriod,
      'debutMonth': actor.debutMonth,
      'debutDescription': actor.debutDescription,
      'accountUrl': actor.accountUrl,
      'officialSiteUrl': actor.officialSiteUrl,
      'photoAsset': photoAsset == null ? null : managedAssetPayload(photoAsset),
      'backdropAsset':
          backdropAsset == null ? null : managedAssetPayload(backdropAsset),
      'publishers': _libraryDatabase
          .publishersForActor(actor.id)
          .map(_publisherReferencePayload)
          .toList(growable: false),
      'movieCount': actor.movieCount,
      'createdAt': actor.createdAt,
      'updatedAt': actor.updatedAt,
      'archivedAt': actor.archivedAt,
    };
  }

  Map<String, Object?> managedAssetPayload(NasManagedAsset asset) => {
        'id': asset.id,
        'purpose': asset.purpose,
        'url': '/api/v1/assets/${asset.id}?v=${asset.fileName}',
        'mimeType': asset.mimeType,
        'createdAt': asset.createdAt,
      };

  Map<String, Object?> databaseSummary(NasLibraryMovie movie) => {
        'id': movie.id,
        'title': movie.title,
        'originalTitle': movie.originalTitle,
        'catalogNumber': movie.catalogNumber,
        'publisher': movie.publisherId == null
            ? null
            : {
                'id': movie.publisherId,
                'displayName': movie.publisherName,
              },
        'series': movie.seriesId == null
            ? null
            : {
                'id': movie.seriesId,
                'displayName': movie.seriesName,
                'publisherId': movie.publisherId,
              },
        'actors': nasMovieActorsToJson(movie.actors),
        'category': categoryForMoviePayload(movie.id),
        'tags': _libraryDatabase
            .tagsForMovie(movie.id)
            .map(tagPayload)
            .toList(growable: false),
        'tagPaths': _libraryDatabase
            .tagPathsForMovie(movie.id)
            .map((path) => path.names)
            .toList(growable: false),
        'episodeCount': movie.episodeCount,
        'entryType': movie.entryType,
        'durationMs': movie.durationMs,
        'resolutionLabel': movie.resolutionLabel,
        'resolutionWidth': movie.videoWidth,
        'resolutionHeight': movie.videoHeight,
        'posterUrl': movie.posterFileName == null
            ? null
            : '/api/v1/assets/posters/${movie.id}',
        'isFavorite': movie.isFavorite,
        'playCount': movie.playCount,
        'resumePositionMs': 0,
        'updatedAt': movie.updatedAt,
      };

  /// 搜索列表不携带标签或路径，避免逐部影片读取标签后让客户端再次筛选。
  Map<String, Object?> databaseSearchSummary(NasLibraryMovie movie) => {
        'id': movie.id,
        'title': movie.title,
        'originalTitle': movie.originalTitle,
        'catalogNumber': movie.catalogNumber,
        'publisher': movie.publisherId == null
            ? null
            : {
                'id': movie.publisherId,
                'displayName': movie.publisherName,
              },
        'series': movie.seriesId == null
            ? null
            : {
                'id': movie.seriesId,
                'displayName': movie.seriesName,
                'publisherId': movie.publisherId,
              },
        'category': movie.categoryId == null
            ? null
            : {'id': movie.categoryId, 'name': movie.categoryName},
        'episodeCount': movie.episodeCount,
        'entryType': movie.entryType,
        'durationMs': movie.durationMs,
        'resolutionLabel': movie.resolutionLabel,
        'resolutionWidth': movie.videoWidth,
        'resolutionHeight': movie.videoHeight,
        'posterUrl': movie.posterFileName == null
            ? null
            : '/api/v1/assets/posters/${movie.id}',
        'isFavorite': movie.isFavorite,
        'playCount': movie.playCount,
        'resumePositionMs': 0,
        'updatedAt': movie.updatedAt,
      };

  Future<Map<String, Object?>> databaseDetails(NasLibraryMovie movie) async {
    final episodePage = _libraryDatabase.episodePageForMovie(
      movieId: movie.id,
      page: 1,
      pageSize: 10,
    );
    final resumeTarget = _libraryDatabase.resumeTargetForMovie(movie.id);
    return {
      ...databaseSummary(movie),
      'organizations': _libraryDatabase.movieCompanies(movie.id),
      'sourceMetadata': _libraryDatabase.scrapeMovieProfile(movie.id),
      'actors':
          movie.actors.map(_movieActorDetailsPayload).toList(growable: false),
      'summary': movie.summary,
      'lastPlayedAt': _libraryDatabase.lastPlaybackStartedAtForMovie(movie.id),
      'continuePlayback': resumeTarget == null
          ? null
          : {
              'episodeId': resumeTarget.episodeId,
              'positionMs': resumeTarget.positionMs,
            },
      // 保留首段数据给旧只读客户端；完整选集必须继续请求分页接口。
      'episodes': episodePage.items.map(episodePayload).toList(growable: false),
      'episodePage': {
        'number': episodePage.number,
        'size': episodePage.size,
        'total': episodePage.total,
        'hasMore': episodePage.hasMore,
      },
      'carouselImages': _libraryDatabase
          .carouselImagesForMovie(movie.id)
          .map(
            (image) => {
              'id': image.id,
              'url': '/api/v1/assets/carousel-images/${image.id}',
            },
          )
          .toList(growable: false),
    };
  }

  Map<String, Object?> _movieActorDetailsPayload(NasMovieActor relation) {
    final actorId = relation.id;
    final actor = actorId == null ? null : _libraryDatabase.findActor(actorId);
    final photoAsset = actor?.photoAssetId == null
        ? null
        : _libraryDatabase.findManagedAsset(actor!.photoAssetId!);
    return {
      ...relation.toJson(),
      'originalName': actor?.originalName,
      'photoAsset': photoAsset == null ? null : managedAssetPayload(photoAsset),
    };
  }

  Map<String, Object?> mediaRootPayload(NasMediaRoot root) => {
        'id': root.id,
        'name': root.name,
        'readOnly': root.readOnly,
        'enabled': root.enabled,
        'createdAt': root.createdAt,
        'updatedAt': root.updatedAt,
        'lastScannedAt': root.lastScannedAt,
        'isOnline': root.isOnline,
      };

  Map<String, Object?> devicePayload(NasDeviceToken device) => {
        'deviceId': device.deviceId,
        'scope': device.scope,
        'expiresAt': device.expiresAt.toUtc().toIso8601String(),
        'platform': device.platform,
      };

  Map<String, Object> backupPayload(NasBackupRecord backup) => backup.toJson();

  Map<String, Object?> categoryPayload(NasLibraryCategory category) => {
        'id': category.id,
        'name': category.name,
        'movieCount': category.movieCount,
        'color': category.color,
        // 旧字段保留首个来源，正式客户端应使用 sources。
        'directoryKey': category.mediaSources.isEmpty
            ? category.mediaRelativePath
            : _categorySourceDirectoryKey(category.mediaSources.first),
        'directoryName': category.mediaSources.isEmpty
            ? category.mediaRelativePath?.split('/').last
            : category.mediaSources.first.relativePath.split('/').last,
        'sources': category.mediaSources
            .map(
              (source) => {
                'id': source.id,
                'directoryKey': _categorySourceDirectoryKey(source),
                'directoryName': source.relativePath.split('/').last,
                'sourceName': source.sourceName,
                'isOnline': source.isOnline,
                'lastScannedAt': source.lastScannedAt,
              },
            )
            .toList(growable: false),
        'createdAt': category.createdAt,
        'updatedAt': category.updatedAt,
      };

  Map<String, Object?>? categoryForMoviePayload(String movieId) {
    final category = _libraryDatabase.categoryForMovie(movieId);
    return category == null ? null : categoryPayload(category);
  }

  Map<String, Object?> tagPayload(NasLibraryTag tag) => {
        'id': tag.id,
        'name': tag.name,
        'level': tag.level,
        'description': tag.description,
        'color': tag.color,
        'createdAt': tag.createdAt,
        'updatedAt': tag.updatedAt,
        'archivedAt': tag.archivedAt,
      };

  /// 浏览端搜索目录只暴露匹配所需的稳定身份和展示名称。
  Map<String, Object?> movieSearchTagPayload(NasLibraryTag tag) => {
        'id': tag.id,
        'name': tag.name,
        'level': tag.level,
      };

  Map<String, Object?> adminEpisodePayload(NasLibraryEpisode episode) => {
        'id': episode.id,
        'movieId': episode.movieId,
        'title': episode.title,
        'sourceName': episode.relativePath.split('/').last,
        'source': {
          'name': episode.sourceName,
          'isOnline': episode.sourceOnline,
        },
        'durationMs': episode.durationMs,
        'resolutionLabel': episode.resolutionLabel,
        'videoWidth': episode.videoWidth,
        'videoHeight': episode.videoHeight,
        'fileSize': episode.fileSize,
        'isAvailable': episode.isAvailable && episode.sourceOnline,
        'updatedAt': episode.updatedAt,
      };

  String _categorySourceDirectoryKey(NasCategoryMediaSource source) {
    final root = _libraryDatabase.findMediaRoot(source.mediaRootId);
    if (root == null || root.containerPath == config.mediaDir) {
      return source.relativePath;
    }
    final rootName = root.containerPath
        .replaceAll('\\', '/')
        .split('/')
        .where((item) => item.isNotEmpty)
        .last;
    return '$rootName/${source.relativePath}';
  }

  Map<String, Object?> episodePayload(NasLibraryEpisode episode) => {
        'id': episode.id,
        'title': episode.title,
        'sourceName': episode.relativePath.split('/').last,
        'source': {
          'name': episode.sourceName,
          'isOnline': episode.sourceOnline,
        },
        'durationMs': episode.durationMs,
        'resolutionLabel': episode.resolutionLabel,
        'videoWidth': episode.videoWidth,
        'videoHeight': episode.videoHeight,
        'fileSize': episode.fileSize,
        'isAvailable': episode.isAvailable && episode.sourceOnline,
      };
}
