import 'dart:async';
import 'dart:io';

import '../library_database.dart';

import 'response.dart';

/// Watch-history filtering and protocol responses.
class NasHistoryHttpApi {
  NasHistoryHttpApi(this._libraryDatabase);
  final NasLibraryDatabase _libraryDatabase;

  Future<void> history(HttpRequest request) => writeApiJson(
        request.response,
        HttpStatus.ok,
        {
          'data': {
            'items': _libraryDatabase
                .listPlaybackHistory(
                  titleQuery: request.uri.queryParameters['q'] ?? '',
                )
                .map(
                  (item) => {
                    'id': item.id,
                    'movieId': item.movieId,
                    'episodeId': item.episodeId,
                    'title': item.title,
                    'originalTitle': item.originalTitle,
                    'catalogNumber': item.catalogNumber,
                    if (item.posterFileName != null)
                      'posterUrl': '/api/v1/assets/posters/${item.movieId}',
                    'startedAt': item.startedAt,
                    'endedAt': item.endedAt,
                    'endPositionMs': item.endPositionMs,
                    'durationMs': item.durationMs,
                  },
                )
                .toList(growable: false),
          },
        },
      );

  /// 观影记录的筛选、统计、排序和分页全由 NAS 完成，普通影视用户可只读访问。
  Future<void> watchHistory(HttpRequest request) async {
    final parameters = request.uri.queryParameters;
    final query = (parameters['q'] ?? '').trim();
    final page = int.tryParse(parameters['page'] ?? '1') ?? 0;
    final pageSize = int.tryParse(parameters['pageSize'] ?? '20') ?? 0;
    final sort = parameters['sort'] ?? 'startedAt';
    final order = parameters['order'] ?? 'desc';
    final device = parameters['device'];
    final fromInput = parameters['from'];
    final toInput = parameters['to'];
    final startedOnOrAfter = _watchHistoryDateBoundary(fromInput);
    final startedBefore = _watchHistoryDateBoundary(toInput, exclusive: true);
    if (query.length > 240 ||
        page < 1 ||
        pageSize < 1 ||
        pageSize > 50 ||
        !const {'startedAt', 'watchDurationMs', 'lastReportedAt'}
            .contains(sort) ||
        !const {'asc', 'desc'}.contains(order) ||
        (device != null &&
            device != 'all' &&
            !const {'windows', 'android', 'unknown'}.contains(device)) ||
        (fromInput != null && startedOnOrAfter == null) ||
        (toInput != null && startedBefore == null) ||
        (startedOnOrAfter != null &&
            startedBefore != null &&
            !DateTime.parse(startedOnOrAfter)
                .isBefore(DateTime.parse(startedBefore)))) {
      return writeApiError(request, HttpStatus.badRequest, 'invalid_request');
    }
    final result = _libraryDatabase.watchHistoryPage(
      NasWatchHistoryQuery(
        query: query,
        startedOnOrAfter: startedOnOrAfter,
        startedBefore: startedBefore,
        devicePlatform: device == 'all' ? null : device,
        sort: sort,
        order: order,
        page: page,
        pageSize: pageSize,
      ),
    );
    await writeApiJson(request.response, HttpStatus.ok, {
      'data': {
        'items': result.items
            .map(_watchHistoryRecordPayload)
            .toList(growable: false),
        'continueItems': result.continueItems
            .map(_watchHistoryRecordPayload)
            .toList(growable: false),
        'stats': {
          'recordCount': result.stats.recordCount,
          'watchDurationMs': result.stats.watchDurationMs,
          'continueCount': result.stats.continueCount,
          'activeDeviceCount': result.stats.activeDeviceCount,
        },
        'deviceCounts': result.deviceCounts,
      },
      'page': {
        'number': result.number,
        'size': result.size,
        'total': result.total,
        'hasMore': result.hasMore,
      },
    });
  }

  String? _watchHistoryDateBoundary(String? value, {bool exclusive = false}) {
    if (value == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      return null;
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return null;
    final boundary = DateTime.utc(parsed.year, parsed.month, parsed.day)
        .add(exclusive ? const Duration(days: 1) : Duration.zero);
    return boundary.toIso8601String();
  }

  Map<String, Object?> _watchHistoryRecordPayload(
          NasWatchHistoryRecord record) =>
      {
        'recordId': record.recordId,
        'movieId': record.movieId,
        'episodeId': record.episodeId,
        'title': record.title,
        'originalTitle': record.originalTitle,
        'catalogNumber': record.catalogNumber,
        'episodeTitle': record.episodeTitle,
        'sourceName': record.sourceName,
        if (record.posterFileName != null)
          'posterUrl': '/api/v1/assets/posters/${record.movieId}',
        'startedAt': record.startedAt,
        'lastReportedAt': record.lastReportedAt,
        'endedAt': record.endedAt,
        'watchDurationMs': record.watchDurationMs,
        'lastPositionMs': record.lastPositionMs,
        'durationMs': record.durationMs,
        'status': record.status,
        'deviceId': record.deviceId,
        'devicePlatform': record.devicePlatform,
      };
}
