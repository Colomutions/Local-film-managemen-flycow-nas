import 'dart:convert';

import '../library/mdcng_nfo.dart';
import '../library_models.dart';

int nasCompareActors(NasActor left, NasActor right, String sort, String order) {
  int compared;
  switch (sort) {
    case 'age':
      compared = nasCompareNullableInt(
          nasActorAge(left.birthMonth), nasActorAge(right.birthMonth));
    case 'movieCount':
      compared = left.movieCount.compareTo(right.movieCount);
    case 'debutMonth':
      compared = nasCompareNullableString(left.debutMonth, right.debutMonth);
    default:
      compared = left.createdAt.compareTo(right.createdAt);
  }
  if (compared == 0) compared = left.id.compareTo(right.id);
  return order == 'asc' ? compared : -compared;
}

int nasCompareActorMovies(
  NasLibraryMovie left,
  NasLibraryMovie right,
  String sort,
  String order,
) {
  final compared = switch (sort) {
    'title' => left.title.compareTo(right.title),
    'durationMs' => nasCompareNullableInt(left.durationMs, right.durationMs),
    'createdAt' => left.updatedAt.compareTo(right.updatedAt),
    _ => left.playCount.compareTo(right.playCount),
  };
  final stable = compared == 0 ? left.id.compareTo(right.id) : compared;
  return order == 'asc' ? stable : -stable;
}

int nasComparePublishers(
  NasPublisher left,
  NasPublisher right,
  String sort,
  String order,
) {
  final compared = switch (sort) {
    'name' => left.displayName.compareTo(right.displayName),
    'movieCount' => left.movieCount.compareTo(right.movieCount),
    'seriesCount' => left.seriesCount.compareTo(right.seriesCount),
    _ => left.createdAt.compareTo(right.createdAt),
  };
  final stable = compared == 0 ? left.id.compareTo(right.id) : compared;
  return order == 'asc' ? stable : -stable;
}

int nasCompareSeries(
  NasSeries left,
  NasSeries right,
  String sort,
  String order,
) {
  final compared = switch (sort) {
    'name' => left.displayName.compareTo(right.displayName),
    'movieCount' => left.movieCount.compareTo(right.movieCount),
    'releaseDate' =>
      nasCompareNullableString(left.releaseDate, right.releaseDate),
    _ => left.createdAt.compareTo(right.createdAt),
  };
  final stable = compared == 0 ? left.id.compareTo(right.id) : compared;
  return order == 'asc' ? stable : -stable;
}

int? nasActorAge(String? birthMonth) {
  if (birthMonth == null ||
      !RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(birthMonth)) {
    return null;
  }
  final parts = birthMonth.split('-');
  final now = DateTime.now();
  return now.year -
      int.parse(parts[0]) -
      (now.month < int.parse(parts[1]) ? 1 : 0);
}

int nasCompareNullableInt(int? left, int? right) {
  if (left == null) return right == null ? 0 : 1;
  if (right == null) return -1;
  return left.compareTo(right);
}

int nasCompareNullableString(String? left, String? right) {
  if (left == null) return right == null ? 0 : 1;
  if (right == null) return -1;
  return left.compareTo(right);
}

bool nasIsValidFavoriteFilter(String? value) =>
    value == null || value == 'true' || value == 'false';

bool? nasFavoriteFilter(String? value) => switch (value) {
      'true' => true,
      'false' => false,
      _ => null,
    };

NasMovieSearchFilter? nasMovieSearchFilter(Map<String, dynamic>? body) {
  const requiredFields = {
    'q',
    'categoryId',
    'resolutions',
    'watchStates',
    'sort',
    'order',
    'page',
    'pageSize',
    'tagConditions',
  };
  const entityFields = {
    'categoryIds',
    'seriesIds',
    'publisherIds',
    'actorIds',
  };
  const fields = {...requiredFields, 'isFavorite', ...entityFields};
  if (body == null ||
      body.keys.any((key) => !fields.contains(key)) ||
      !body.keys.toSet().containsAll(requiredFields) ||
      body['q'] is! String ||
      (body['categoryId'] != null && body['categoryId'] is! String) ||
      (body['isFavorite'] != null && body['isFavorite'] is! bool) ||
      body['resolutions'] is! List ||
      body['watchStates'] is! List ||
      body['sort'] is! String ||
      body['order'] is! String ||
      body['page'] is! int ||
      body['pageSize'] is! int ||
      body['tagConditions'] is! Map) {
    return null;
  }
  final query = (body['q'] as String).trim();
  final categoryId = (body['categoryId'] as String?)?.trim();
  final page = body['page'] as int;
  final pageSize = body['pageSize'] as int;
  final resolutions = (body['resolutions'] as List)
      .map((value) => value is String ? value.trim() : null)
      .toList(growable: false);
  final watchStates = (body['watchStates'] as List)
      .map((value) => value is String ? value.trim() : null)
      .toList(growable: false);
  final entityIds = <String, Set<String>>{};
  for (final field in entityFields) {
    final raw = body[field];
    if (raw == null) {
      entityIds[field] = const {};
      continue;
    }
    if (raw is! List ||
        raw.isEmpty ||
        raw.length > 80 ||
        raw.any((value) => value is! String)) {
      return null;
    }
    final values = raw.cast<String>().map((value) => value.trim()).toList();
    if (values.any((value) => value.isEmpty) ||
        values.toSet().length != values.length) {
      return null;
    }
    entityIds[field] = values.toSet();
  }
  if (query.length > 240 ||
      categoryId?.isEmpty == true ||
      resolutions.any((value) => value == null || value.isEmpty) ||
      resolutions.toSet().length != resolutions.length ||
      resolutions.length > 8 ||
      watchStates.any((value) => value == null || value.isEmpty) ||
      watchStates.toSet().length != watchStates.length ||
      !watchStates.cast<String>().every(
            const {'unwatched', 'continue'}.contains,
          )) {
    return null;
  }
  final rawConditions = Map<String, dynamic>.from(
    body['tagConditions'] as Map,
  );
  const groups = {'all', 'any', 'exclude'};
  if (rawConditions.keys.any((key) => !groups.contains(key)) ||
      !rawConditions.keys.toSet().containsAll(groups)) {
    return null;
  }
  final conditions = <NasMovieSearchTagCondition>[];
  final seenTagIds = <String>{};
  for (final group in groups) {
    final values = rawConditions[group];
    if (values is! List || values.length > 80) return null;
    for (final raw in values) {
      if (raw is! Map) return null;
      final item = Map<String, dynamic>.from(raw);
      if (item.keys.length != 2 ||
          !item.keys.contains('tagId') ||
          !item.keys.contains('includeDescendants') ||
          item['tagId'] is! String ||
          item['includeDescendants'] is! bool) {
        return null;
      }
      final tagId = (item['tagId'] as String).trim();
      if (tagId.isEmpty || !seenTagIds.add(tagId)) return null;
      conditions.add(
        NasMovieSearchTagCondition(
          group: group,
          tagId: tagId,
          includeDescendants: item['includeDescendants'] as bool,
        ),
      );
    }
  }
  if (conditions.length > 120 ||
      page < 1 ||
      pageSize < 1 ||
      pageSize > 100 ||
      !const {
        'relevance',
        'createdAt',
        'title',
        'updatedAt',
        'durationMs',
        'recent'
      }.contains(body['sort']) ||
      !const {'asc', 'desc'}.contains(body['order'])) {
    return null;
  }
  return NasMovieSearchFilter(
    query: query,
    categoryId: categoryId,
    categoryIds: entityIds['categoryIds']!,
    seriesIds: entityIds['seriesIds']!,
    publisherIds: entityIds['publisherIds']!,
    actorIds: entityIds['actorIds']!,
    isFavorite: body['isFavorite'] as bool?,
    resolutions: resolutions.cast<String>().toSet(),
    watchStates: watchStates.cast<String>().toSet(),
    sort: body['sort'] as String,
    order: body['order'] as String,
    page: page,
    pageSize: pageSize,
    tagConditions: conditions,
  );
}

Map<String, Object?>? nasPublisherInputValues(
  Map<String, dynamic>? body, {
  required bool creating,
}) {
  if (body == null) return null;
  const fields = {
    'displayName': 'display_name',
    'originalName': 'original_name',
    'countryRegion': 'country_region',
    'foundedDate': 'founded_date',
    'logoAssetId': 'logo_asset_id',
  };
  if (body.keys.any((key) => !fields.containsKey(key))) return null;
  final values = <String, Object?>{};
  for (final entry in body.entries) {
    final value = entry.value;
    if (value != null && value is! String) return null;
    final normalized = value is String ? nasNullableTrimmed(value) : null;
    if (entry.key == 'displayName' && normalized == null) return null;
    if (entry.key == 'foundedDate' &&
        normalized != null &&
        !RegExp(r'^\d{4}(-\d{2}(-\d{2})?)?$').hasMatch(normalized)) {
      return null;
    }
    values[fields[entry.key]!] = normalized;
  }
  if (creating && (values['display_name'] as String?) == null) return null;
  return values;
}

Map<String, Object?>? nasSeriesInputValues(
  Map<String, dynamic>? body, {
  required bool creating,
}) {
  if (body == null) return null;
  const fields = {
    'displayName': 'display_name',
    'originalName': 'original_name',
    'translatedName': 'translated_name',
    'publisherId': 'publisher_id',
    'releaseDate': 'release_date',
    'posterAssetId': 'poster_asset_id',
  };
  if (body.keys.any((key) => !fields.containsKey(key))) return null;
  final values = <String, Object?>{};
  for (final entry in body.entries) {
    final value = entry.value;
    if (value != null && value is! String) return null;
    final normalized = value is String ? nasNullableTrimmed(value) : null;
    if (entry.key == 'displayName' && normalized == null) {
      return null;
    }
    if (entry.key == 'releaseDate' &&
        normalized != null &&
        !RegExp(r'^\d{4}(-\d{2}(-\d{2})?)?$').hasMatch(normalized)) {
      return null;
    }
    values[fields[entry.key]!] = normalized;
  }
  if (creating && (values['display_name'] as String?) == null) {
    return null;
  }
  return values;
}

Map<String, Object?>? nasActorInputValues(
  Map<String, dynamic>? body, {
  required bool creating,
}) {
  if (body == null) return null;
  const fields = {
    'stageName': 'stage_name',
    'originalName': 'original_name',
    'translatedName': 'translated_name',
    'romanizedName': 'romanized_name',
    'aliases': 'aliases_json',
    'gender': 'gender',
    'birthDate': 'birth_date',
    'birthMonth': 'birth_month',
    'heightCm': 'height_cm',
    'weightKg': 'weight_kg',
    'measurements': 'measurements',
    'bodyType': 'body_type',
    'country': 'country',
    'debutMonth': 'debut_month',
    'debutDescription': 'debut_description',
    'photoAssetId': 'photo_asset_id',
    'publisherIds': 'publisher_ids',
  };
  if (body.keys.any((key) => !fields.containsKey(key))) return null;
  final values = <String, Object?>{};
  for (final entry in body.entries) {
    final databaseKey = fields[entry.key]!;
    final value = entry.value;
    switch (entry.key) {
      case 'aliases':
        if (value is! List || value.any((item) => item is! String)) return null;
        values[databaseKey] =
            jsonEncode(nasCleanTextValues(value.cast<String>()));
      case 'publisherIds':
        if (value is! List || value.any((item) => item is! String)) return null;
        final publisherIds = nasCleanTextValues(value.cast<String>());
        if (publisherIds.length != value.length) return null;
        values[databaseKey] = publisherIds;
      case 'gender':
        if (value != null &&
            !const {'female', 'intersex', 'male'}.contains(value)) return null;
        values[databaseKey] = value;
      case 'birthMonth':
      case 'debutMonth':
        if (value != null &&
            (value is! String ||
                !RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(value))) {
          return null;
        }
        values[databaseKey] = value;
      case 'birthDate':
        if (value != null &&
            (value is! String ||
                !RegExp(r'^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$')
                    .hasMatch(value))) {
          return null;
        }
        values[databaseKey] = value;
      case 'heightCm':
        if (value != null && (value is! int || value < 1 || value > 300))
          return null;
        values[databaseKey] = value;
      case 'weightKg':
        if (value != null && (value is! int || value < 1 || value > 500))
          return null;
        values[databaseKey] = value;
      default:
        if (value != null && value is! String) return null;
        values[databaseKey] =
            value is String && value.trim().isEmpty ? null : value?.trim();
    }
  }
  if (creating &&
      ![
        values['stage_name'],
        values['original_name'],
        values['translated_name'],
        ...nasStringListFromJson(values['aliases_json'] as String?),
      ].any((value) => value is String && value.isNotEmpty)) {
    return null;
  }
  return values;
}

String nasSourceTitle(String sourceName) {
  final dot = sourceName.lastIndexOf('.');
  return dot <= 0 ? sourceName : sourceName.substring(0, dot);
}

String nasSourceFileName(String relativePath) =>
    relativePath.split('/').where((segment) => segment.isNotEmpty).last;

String? nasMdcngOriginalTitle(MdcngNfoMovie movie) {
  final original = nasNullableTrimmed(movie.originalTitle);
  return original == nasNullableTrimmed(movie.title) ? null : original;
}

Map<String, Object?> nasMdcngScalarFieldDiff({
  required String key,
  required String? currentValue,
  required String? proposedValue,
  required NasMovieMetadataFieldSource? source,
}) {
  final current = nasNullableTrimmed(currentValue);
  final proposed = nasNullableTrimmed(proposedValue);
  final status = proposed == null
      ? 'unavailable'
      : current == proposed
          ? 'unchanged'
          : current == null
              ? 'fill'
              : source?.sourceKind == 'mdcng'
                  ? 'replace_mdcng_owned'
                  : 'replace_requires_confirmation';
  return {
    'key': key,
    'status': status,
    'currentSource': source?.sourceKind ?? 'unknown',
    'requiresExplicitOverwrite':
        current != null && proposed != null && current != proposed,
  };
}

String? nasNullableTrimmed(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

List<String> nasProfileList(String? value) => (value ?? '')
    .split('|')
    .map((item) => item.trim())
    .where((item) => item.isNotEmpty)
    .toList(growable: false);

String? nasFirstProfileText(Iterable<String?> values) {
  for (final value in values) {
    final normalized = nasNullableTrimmed(value);
    if (normalized != null) return normalized;
  }
  return null;
}

List<String> nasStringListFromJson(String? value) {
  if (value == null || value.isEmpty) return const [];
  try {
    final decoded = jsonDecode(value);
    if (decoded is! List) return const [];
    return nasCleanTextValues(decoded.whereType<String>());
  } on FormatException {
    return const [];
  }
}

List<String> nasCleanTextValues(Iterable<String> values) => values
    .map((value) => value.trim())
    .where((value) => value.isNotEmpty)
    .toSet()
    .toList(growable: false);
