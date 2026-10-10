import 'dart:convert';
import 'dart:math';

import '../library_models.dart';

/// Shared value helpers; no database or filesystem access.
String normalizeCatalogNumber(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');

const importCategoryColorOptions = [
  '#1677FF',
  '#8B5CF6',
  '#0FAF8F',
  '#E86A33',
  '#E5484D',
  '#D89B16',
];

const importTagColorOptions = [
  '#ffc266',
  '#58d5ff',
  '#73d8a4',
  '#b59aff',
  '#ff8eaa',
];

final importColorRandom = Random();

/// 导入文件没有声明颜色时，由 NAS 统一生成并持久化随机主题色。
String randomImportColor(List<String> options) =>
    options[importColorRandom.nextInt(options.length)];

String? nullableTrimmed(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String tagLevelName(int level) => switch (level) {
      1 => '一级',
      2 => '二级',
      3 => '三级',
      _ => '未知',
    };

bool isVideo(String path) => RegExp(
      r'\.(mp4|m4v|mkv|mov|webm|avi|wmv|flv|ts|m2ts|rmvb)$',
      caseSensitive: false,
    ).hasMatch(path);

String? collectionTitleFromDirectory(String value) {
  final match = RegExp(r'^(.*?)\s*[-－—]\s*影集\s*$').firstMatch(value);
  final title = match?.group(1)?.trim();
  return title == null || title.isEmpty ? null : title;
}

String naturalSortKey(String value) => value.toLowerCase().replaceAllMapped(
    RegExp(r'\d+'), (match) => match.group(0)!.padLeft(16, '0'));

String? normalizeRelativePath(String? value) {
  final normalized = value?.trim().replaceAll('\\', '/');
  if (normalized == null ||
      normalized.isEmpty ||
      normalized.startsWith('/') ||
      normalized.split('/').any(
            (segment) => segment.isEmpty || segment == '.' || segment == '..',
          )) {
    return null;
  }
  return normalized;
}

String titleFromPath(String relativePath) {
  final name = relativePath.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

String now() => DateTime.now().toUtc().toIso8601String();

class EpisodeGrouping {
  const EpisodeGrouping({
    this.rootPath,
    this.displayTitle,
    this.conflictPath,
  });

  final String? rootPath;
  final String? displayTitle;
  final String? conflictPath;

  bool get isConflict => conflictPath != null;
}

List<String> decodeTextList(String? value) {
  if (value == null || value.isEmpty) return const [];
  try {
    final decoded = jsonDecode(value);
    if (decoded is! List) return const [];
    return cleanTextList(decoded.whereType<String>());
  } on FormatException {
    return const [];
  }
}

List<String> cleanTextList(Iterable<String> values) => values
    .map((value) => value.trim())
    .where((value) => value.isNotEmpty)
    .toSet()
    .toList(growable: false);

String normalizeActorSearch(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[\s\-_.·•]+'), '');

String actorSearchText(NasActor actor) => normalizeActorSearch([
      actor.stageName,
      actor.originalName,
      actor.translatedName,
      actor.bodyType,
      ...actor.aliases,
    ].whereType<String>().join(' '));

const metadataFieldKeys = {
  'title',
  'originalTitle',
  'catalogNumber',
  'summary',
  'actors',
  'tags',
  'poster',
  'fanart',
  'publisher',
  'series',
  'category',
};
