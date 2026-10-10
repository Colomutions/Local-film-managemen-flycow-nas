/// Storage-independent movie library records, search inputs and results.
/// Import this library when only library models are needed.
library;

import 'movie_actor.dart';

class NasLibraryMovie {
  const NasLibraryMovie({
    required this.id,
    required this.title,
    this.originalTitle,
    this.catalogNumber,
    this.publisherId,
    this.publisherName,
    this.seriesId,
    this.seriesName,
    required this.summary,
    required this.actors,
    required this.posterFileName,
    required this.episodeCount,
    required this.durationMs,
    required this.entryType,
    required this.playCount,
    required this.isFavorite,
    required this.updatedAt,
    this.categoryId,
    this.categoryName,
    this.videoWidth,
    this.videoHeight,
    this.resolutionLabel,
  });

  final String id;
  final String title;
  final String? originalTitle;
  final String? catalogNumber;
  final String? publisherId;
  final String? publisherName;
  final String? seriesId;
  final String? seriesName;
  final String summary;
  final List<NasMovieActor> actors;
  final String? posterFileName;
  final int episodeCount;
  final int? durationMs;

  /// `single` 表示普通影片，`series` 表示可包含零到多集的影集。
  final String entryType;
  final int playCount;
  final bool isFavorite;
  final String updatedAt;
  final String? categoryId;
  final String? categoryName;
  final int? videoWidth;
  final int? videoHeight;
  final String? resolutionLabel;
}

class NasLibraryEpisode {
  const NasLibraryEpisode({
    required this.id,
    required this.movieId,
    required this.mediaRootId,
    required this.title,
    required this.relativePath,
    required this.fileSize,
    required this.isAvailable,
    required this.updatedAt,
    required this.sourceName,
    required this.sourceOnline,
    this.durationMs,
    this.videoWidth,
    this.videoHeight,
    this.resolutionLabel,
    this.mediaModifiedAt,
  });

  final String id;
  final String movieId;
  final String mediaRootId;
  final String title;
  final String relativePath;
  final int fileSize;
  final bool isAvailable;
  final String updatedAt;

  /// 仅供客户端展示的来源盘名称，绝不包含 NAS 宿主机路径。
  final String sourceName;
  final bool sourceOnline;
  final int? durationMs;
  final int? videoWidth;
  final int? videoHeight;
  final String? resolutionLabel;
  final int? mediaModifiedAt;
}

class NasRemovedMovieIndex {
  const NasRemovedMovieIndex({
    this.posterFileName,
    this.carouselFileNames = const [],
  });

  final String? posterFileName;
  final List<String> carouselFileNames;
}

class NasMediaRoot {
  const NasMediaRoot({
    required this.id,
    required this.name,
    this.color,
    required this.containerPath,
    required this.readOnly,
    required this.enabled,
    required this.createdAt,
    required this.updatedAt,
    required this.lastScannedAt,
    required this.isOnline,
  });

  final String id;
  final String name;
  final String? color;
  final String containerPath;
  final bool readOnly;
  final bool enabled;
  final String createdAt;
  final String updatedAt;
  final String? lastScannedAt;
  final bool isOnline;
}

/// 一个逻辑分类绑定到某块物理来源盘中的一个目录。
class NasCategoryMediaSource {
  const NasCategoryMediaSource({
    required this.id,
    required this.categoryId,
    required this.mediaRootId,
    required this.sourceName,
    required this.relativePath,
    required this.isOnline,
    this.lastScannedAt,
  });

  final String id;
  final String categoryId;
  final String mediaRootId;
  final String sourceName;
  final String relativePath;
  final bool isOnline;
  final String? lastScannedAt;

  /// 面向 API 的安全目录键；不携带容器或宿主机绝对路径。
  String get directoryKey => '$sourceName/$relativePath';
}

class NasCategoryMediaSourceInput {
  const NasCategoryMediaSourceInput({
    required this.mediaRootId,
    required this.relativePath,
  });

  final String mediaRootId;
  final String relativePath;
}

class NasLibraryCategory {
  const NasLibraryCategory({
    required this.id,
    required this.name,
    this.color,
    this.mediaRelativePath,
    required this.createdAt,
    required this.updatedAt,
    this.mediaSources = const [],
    this.movieCount = 0,
  });

  final String id;
  final String name;
  final String? color;
  final String? mediaRelativePath;
  final String createdAt;
  final String updatedAt;
  final List<NasCategoryMediaSource> mediaSources;
  final int movieCount;
}

class NasEpisodePage {
  const NasEpisodePage({
    required this.items,
    required this.number,
    required this.size,
    required this.total,
    required this.hasMore,
  });

  final List<NasLibraryEpisode> items;
  final int number;
  final int size;
  final int total;
  final bool hasMore;
}

class NasScannedMediaFile {
  const NasScannedMediaFile({
    required this.episode,
    required this.movieId,
    required this.movieTitle,
    required this.entryType,
    required this.categoryId,
  });

  final NasLibraryEpisode episode;
  final String movieId;
  final String movieTitle;
  final String entryType;
  final String? categoryId;
}

class NasScannedMediaFilePage {
  const NasScannedMediaFilePage({
    required this.items,
    required this.number,
    required this.size,
    required this.total,
    required this.hasMore,
  });

  final List<NasScannedMediaFile> items;
  final int number;
  final int size;
  final int total;
  final bool hasMore;
}

class NasCollectionMigrationCandidate {
  const NasCollectionMigrationCandidate({
    required this.key,
    required this.categoryId,
    required this.title,
    required this.episodeIds,
    required this.sourceMovieIds,
    required this.requiresMetadataChoice,
  });

  final String key;
  final String categoryId;
  final String title;
  final List<String> episodeIds;
  final List<String> sourceMovieIds;
  final bool requiresMetadataChoice;
}

class NasLibraryTag {
  const NasLibraryTag({
    required this.id,
    required this.name,
    required this.level,
    this.description = '',
    this.color,
    required this.createdAt,
    required this.updatedAt,
    this.archivedAt,
  });

  final String id;
  final String name;
  final int level;
  final String description;
  final String? color;
  final String createdAt;
  final String updatedAt;
  final String? archivedAt;
}

class NasTagPath {
  const NasTagPath({
    required this.placementId,
    required this.tagId,
    required this.tagName,
    required this.names,
  });

  final String placementId;
  final String tagId;
  final String tagName;
  final List<String> names;
}

class NasTagOverview {
  const NasTagOverview({
    required this.total,
    required this.levelOne,
    required this.levelTwo,
    required this.levelThree,
    required this.movieLinks,
  });

  final int total;
  final int levelOne;
  final int levelTwo;
  final int levelThree;
  final int movieLinks;
}

class NasTagDirectoryRoot {
  const NasTagDirectoryRoot({
    required this.tag,
    required this.movieCount,
    required this.children,
  });

  final NasLibraryTag tag;
  final int movieCount;
  final List<NasTagDirectoryChild> children;
}

class NasTagDirectoryChild {
  const NasTagDirectoryChild({required this.tag, required this.movieCount});

  final NasLibraryTag tag;
  final int movieCount;
}

class NasTagDetails {
  const NasTagDetails({
    required this.tag,
    required this.parents,
    required this.directChildCount,
    required this.movieCount,
    required this.path,
  });

  final NasLibraryTag tag;
  final List<NasLibraryTag> parents;
  final int directChildCount;
  final int movieCount;
  final List<NasLibraryTag> path;
}

class NasTagChildSummary {
  const NasTagChildSummary({required this.tag, required this.movieCount});

  final NasLibraryTag tag;
  final int movieCount;
}

class NasTagChildPage {
  const NasTagChildPage({
    required this.items,
    required this.number,
    required this.size,
    required this.total,
    required this.hasMore,
  });

  final List<NasTagChildSummary> items;
  final int number;
  final int size;
  final int total;
  final bool hasMore;
}

class NasTagMoviePage {
  const NasTagMoviePage({
    required this.movieIds,
    required this.number,
    required this.size,
    required this.total,
    required this.hasMore,
  });

  final List<String> movieIds;
  final int number;
  final int size;
  final int total;
  final bool hasMore;
}

/// 结构化影片搜索在数据库内使用的一个标签范围条件。
class NasMovieSearchTagCondition {
  const NasMovieSearchTagCondition({
    required this.group,
    required this.tagId,
    required this.includeDescendants,
  });

  final String group;
  final String tagId;
  final bool includeDescendants;
}

class NasMovieSearchFilter {
  const NasMovieSearchFilter({
    required this.query,
    required this.categoryId,
    this.categoryIds = const {},
    this.seriesIds = const {},
    this.publisherIds = const {},
    this.actorIds = const {},
    this.isFavorite,
    required this.resolutions,
    required this.watchStates,
    required this.sort,
    required this.order,
    required this.page,
    required this.pageSize,
    required this.tagConditions,
  });

  final String query;
  final String? categoryId;
  final Set<String> categoryIds;
  final Set<String> seriesIds;
  final Set<String> publisherIds;
  final Set<String> actorIds;
  final bool? isFavorite;
  final Set<String> resolutions;
  final Set<String> watchStates;
  final String sort;
  final String order;
  final int page;
  final int pageSize;
  final List<NasMovieSearchTagCondition> tagConditions;

  Set<String> get effectiveCategoryIds => {
        ...categoryIds,
        if (categoryId != null) categoryId!,
      };

  bool get hasEntityConditions =>
      effectiveCategoryIds.isNotEmpty ||
      seriesIds.isNotEmpty ||
      publisherIds.isNotEmpty ||
      actorIds.isNotEmpty;
}

class NasMovieSearchPage {
  const NasMovieSearchPage({
    required this.items,
    required this.number,
    required this.size,
    required this.total,
    required this.hasMore,
  });

  final List<NasLibraryMovie> items;
  final int number;
  final int size;
  final int total;
  final bool hasMore;
}

/// 只读搜索目录的一级节点，不复用含管理资料的标签管理 DTO。
class NasMovieSearchTagDirectoryRoot {
  const NasMovieSearchTagDirectoryRoot({
    required this.tag,
    required this.movieCount,
    required this.children,
  });

  final NasLibraryTag tag;
  final int movieCount;
  final List<NasMovieSearchTagDirectoryChild> children;
}

class NasMovieSearchTagDirectoryChild {
  const NasMovieSearchTagDirectoryChild({
    required this.tag,
    required this.movieCount,
    required this.thirdLevelCount,
  });

  final NasLibraryTag tag;
  final int movieCount;
  final int thirdLevelCount;
}

class NasMovieSearchThirdLevelTagPage {
  const NasMovieSearchThirdLevelTagPage({
    required this.items,
    required this.number,
    required this.size,
    required this.total,
    required this.hasMore,
  });

  final List<NasTagChildSummary> items;
  final int number;
  final int size;
  final int total;
  final bool hasMore;
}

class NasScanResult {
  const NasScanResult({
    required this.scannedFiles,
    required this.availableEpisodes,
    this.conflicts = const [],
    this.removedEpisodes = 0,
    this.removedMovieIndexes = const [],
  });

  final int scannedFiles;
  final int availableEpisodes;
  final int removedEpisodes;
  final List<NasRemovedMovieIndex> removedMovieIndexes;

  /// 已跳过的嵌套影集范围，仅返回安全的相对目录标识。
  final List<String> conflicts;
}

class NasCarouselImage {
  const NasCarouselImage({
    required this.id,
    required this.movieId,
    required this.fileName,
    required this.createdAt,
  });

  final String id;
  final String movieId;
  final String fileName;
  final String createdAt;
}

/// NAS 原生演员资料，不依赖任何客户端本地数据库或路径。
class NasActor {
  const NasActor({
    required this.id,
    required this.profileIdentity,
    required this.stageName,
    this.originalName,
    this.translatedName,
    required this.aliases,
    this.gender,
    this.romanizedName,
    this.birthDate,
    this.birthMonth,
    this.heightCm,
    this.weightKg,
    this.measurements,
    this.bodyType,
    this.country,
    this.birthplace,
    this.cup,
    this.careerPeriod,
    this.debutMonth,
    this.debutDescription,
    this.accountUrl,
    this.officialSiteUrl,
    this.photoAssetId,
    this.backdropAssetId,
    required this.publisherIds,
    required this.movieCount,
    required this.createdAt,
    required this.updatedAt,
    this.archivedAt,
  });

  final String id;
  final String profileIdentity;
  final String? stageName;
  final String? originalName;
  final String? translatedName;
  final List<String> aliases;
  final String? gender;
  final String? romanizedName;
  final String? birthDate;
  final String? birthMonth;
  final int? heightCm;
  final int? weightKg;
  final String? measurements;
  final String? bodyType;
  final String? country;
  final String? birthplace;
  final String? cup;
  final String? careerPeriod;
  final String? debutMonth;
  final String? debutDescription;
  final String? accountUrl;
  final String? officialSiteUrl;
  final String? photoAssetId;
  final String? backdropAssetId;
  final List<String> publisherIds;
  final int movieCount;
  final String createdAt;
  final String updatedAt;
  final String? archivedAt;
}

/// 由 NAS 受管理目录保存的图片资产；文件系统绝对路径从不经 API 暴露。
class NasManagedAsset {
  const NasManagedAsset({
    required this.id,
    required this.purpose,
    required this.fileName,
    required this.mimeType,
    required this.createdAt,
  });

  final String id;
  final String purpose;
  final String fileName;
  final String mimeType;
  final String createdAt;
}

class NasMdcngActorReset {
  const NasMdcngActorReset({
    required this.deletedActors,
    required this.unlinkedMovieLinks,
    required this.assets,
  });

  final int deletedActors;
  final int unlinkedMovieLinks;
  final List<NasManagedAsset> assets;
}

/// 由共同影片关系推导出的合作演员，不能手工写入。
class NasActorCoactor {
  const NasActorCoactor({required this.actor, required this.movieCount});

  final NasActor actor;
  final int movieCount;
}

/// NAS 原生发行商实体；统计值始终由关联影片和系列即时聚合。
class NasPublisher {
  const NasPublisher({
    required this.id,
    required this.profileIdentity,
    required this.displayName,
    this.originalName,
    this.countryRegion,
    this.foundedDate,
    this.logoAssetId,
    required this.movieCount,
    required this.seriesCount,
    required this.durationMs,
    required this.createdAt,
    required this.updatedAt,
    this.archivedAt,
  });

  final String id;
  final String profileIdentity;
  final String displayName;
  final String? originalName;
  final String? countryRegion;
  final String? foundedDate;
  final String? logoAssetId;
  final int movieCount;
  final int seriesCount;
  final int? durationMs;
  final String createdAt;
  final String updatedAt;
  final String? archivedAt;
}

/// NAS 原生系列实体；总集数和总时长不允许客户端手工覆盖。
class NasSeries {
  const NasSeries({
    required this.id,
    required this.profileIdentity,
    required this.displayName,
    this.originalName,
    this.translatedName,
    this.publisherId,
    this.releaseDate,
    this.posterAssetId,
    required this.movieCount,
    required this.episodeCount,
    required this.durationMs,
    required this.createdAt,
    required this.updatedAt,
    this.archivedAt,
  });

  final String id;
  final String profileIdentity;
  final String displayName;
  final String? originalName;
  final String? translatedName;

  /// 新建阶段允许暂不归属发行商，但关联影片前必须补齐。
  final String? publisherId;
  final String? releaseDate;
  final String? posterAssetId;
  final int movieCount;
  final int episodeCount;
  final int? durationMs;
  final String createdAt;
  final String updatedAt;
  final String? archivedAt;
}

/// 发行商或系列下演员的参演影片数，仅作聚合展示。
class NasRelatedActor {
  const NasRelatedActor({required this.actor, required this.movieCount});

  final NasActor actor;
  final int movieCount;
}

/// NAS 持久化的 AI 元数据任务；任务结果由 NAS 保存后再由管理员应用。
class NasAiTask {
  const NasAiTask({
    required this.id,
    required this.movieId,
    required this.instructions,
    required this.status,
    required this.createdAt,
    this.resultJson,
    this.errorCode,
    this.finishedAt,
  });

  final String id;
  final String movieId;
  final String instructions;
  final String status;
  final String createdAt;
  final String? resultJson;
  final String? errorCode;
  final String? finishedAt;
}

/// NAS 自身持久化的播放历史；不包含任何 Windows 本地路径或客户端令牌。
class NasPlaybackHistoryItem {
  const NasPlaybackHistoryItem({
    required this.id,
    required this.movieId,
    required this.episodeId,
    required this.title,
    this.originalTitle,
    this.catalogNumber,
    required this.posterFileName,
    required this.startedAt,
    required this.endedAt,
    required this.endPositionMs,
    required this.durationMs,
  });

  final String id;
  final String movieId;
  final String episodeId;
  final String title;
  final String? originalTitle;
  final String? catalogNumber;
  final String? posterFileName;
  final String startedAt;
  final String? endedAt;
  final int? endPositionMs;
  final int? durationMs;
}

/// 观影记录查询的全部筛选和排序均由 NAS 执行，客户端只保存当前条件与页码。
class NasWatchHistoryQuery {
  const NasWatchHistoryQuery({
    required this.query,
    required this.startedOnOrAfter,
    required this.startedBefore,
    required this.devicePlatform,
    required this.sort,
    required this.order,
    required this.page,
    required this.pageSize,
  });

  final String query;
  final String? startedOnOrAfter;
  final String? startedBefore;
  final String? devicePlatform;
  final String sort;
  final String order;
  final int page;
  final int pageSize;
}

/// 一次正式播放对应一条稳定记录，始终同时保存逻辑影视和具体分集身份。
class NasWatchHistoryRecord {
  const NasWatchHistoryRecord({
    required this.recordId,
    required this.movieId,
    required this.episodeId,
    required this.title,
    required this.episodeTitle,
    required this.startedAt,
    required this.lastReportedAt,
    required this.watchDurationMs,
    required this.lastPositionMs,
    required this.durationMs,
    required this.status,
    required this.deviceId,
    required this.devicePlatform,
    this.originalTitle,
    this.catalogNumber,
    this.posterFileName,
    this.sourceName,
    this.endedAt,
  });

  final String recordId;
  final String movieId;
  final String episodeId;
  final String title;
  final String episodeTitle;
  final String startedAt;
  final String lastReportedAt;
  final int watchDurationMs;
  final int lastPositionMs;
  final int? durationMs;
  final String status;
  final String deviceId;
  final String devicePlatform;
  final String? originalTitle;
  final String? catalogNumber;
  final String? posterFileName;
  final String? sourceName;
  final String? endedAt;
}

class NasWatchHistoryStats {
  const NasWatchHistoryStats({
    required this.recordCount,
    required this.watchDurationMs,
    required this.continueCount,
    required this.activeDeviceCount,
  });

  final int recordCount;
  final int watchDurationMs;
  final int continueCount;
  final int activeDeviceCount;
}

class NasWatchHistoryPage {
  const NasWatchHistoryPage({
    required this.items,
    required this.number,
    required this.size,
    required this.total,
    required this.hasMore,
    required this.stats,
    required this.continueItems,
    required this.deviceCounts,
  });

  final List<NasWatchHistoryRecord> items;
  final int number;
  final int size;
  final int total;
  final bool hasMore;
  final NasWatchHistoryStats stats;
  final List<NasWatchHistoryRecord> continueItems;
  final Map<String, int> deviceCounts;
}

/// NAS 为一个影视条目统一计算的续播目标，始终指向具体分集。
class NasPlaybackResumeTarget {
  const NasPlaybackResumeTarget({
    required this.episodeId,
    required this.positionMs,
  });

  final String episodeId;
  final int positionMs;
}

/// 单个分集持久化的续播进度；位置和总时长必须成对读取，避免续播会话
/// 使用了旧的媒体探测时长。
class NasEpisodePlaybackProgress {
  const NasEpisodePlaybackProgress({
    required this.positionMs,
    required this.durationMs,
  });

  final int positionMs;
  final int durationMs;
}

/// 单次 MDCNG 确认导入的审计记录；不保存 NFO 原文或外部 URL。
class NasMdcngImportRecord {
  const NasMdcngImportRecord({
    required this.id,
    required this.movieId,
    required this.episodeId,
    required this.nfoFileName,
    required this.nfoContentHash,
    required this.appliedFieldKeys,
    required this.createdAt,
  });

  final String id;
  final String movieId;
  final String episodeId;
  final String nfoFileName;
  final String nfoContentHash;
  final List<String> appliedFieldKeys;
  final String createdAt;
}

/// Audit entry for a single confirmed MDCNG actor import.  It stores only
/// stable ids and field names; no source paths, credentials, or raw database
/// content are persisted.
class NasMdcngActorImportRecord {
  const NasMdcngActorImportRecord({
    required this.id,
    required this.actorId,
    required this.sourceId,
    required this.taskId,
    required this.embyId,
    required this.sourceFingerprint,
    required this.appliedFields,
    required this.createdAt,
  });

  final String id;
  final String actorId;
  final String sourceId;
  final String taskId;
  final String embyId;
  final String sourceFingerprint;
  final List<String> appliedFields;
  final String createdAt;
}

/// 某个影片字段最近一次确认的来源。无记录即为旧数据或来源未知。
class NasMovieMetadataFieldSource {
  const NasMovieMetadataFieldSource({
    required this.fieldKey,
    required this.sourceKind,
    this.importRecordId,
    this.sourceContentHash,
    required this.updatedAt,
  });

  final String fieldKey;
  final String sourceKind;
  final String? importRecordId;
  final String? sourceContentHash;
  final String updatedAt;
}

class NasMdcngMetadataApply {
  const NasMdcngMetadataApply({
    required this.movieId,
    required this.episodeId,
    required this.nfoFileName,
    required this.nfoContentHash,
    required this.fieldKeys,
    this.title,
    this.originalTitle,
    this.catalogNumber,
    this.summary,
    this.actorIds,
    this.tagIds,
    this.posterFileName,
    this.fanartFileName,
  });

  final String movieId;
  final String episodeId;
  final String nfoFileName;
  final String nfoContentHash;
  final List<String> fieldKeys;
  final String? title;
  final String? originalTitle;
  final String? catalogNumber;
  final String? summary;
  final List<String>? actorIds;
  final List<String>? tagIds;
  final String? posterFileName;
  final String? fanartFileName;
}
