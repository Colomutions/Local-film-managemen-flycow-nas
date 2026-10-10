import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';
import '../library_models.dart';
import 'library_values.dart';

/// Owns persisted progress and watch history; does not schedule reports.
class NasPlaybackRepository {
  NasPlaybackRepository(this._connection);

  final Database Function() _connection;
  Database get _db => _connection();

  NasEpisodePlaybackProgress? playbackProgressForEpisode({
    required String movieId,
    required String episodeId,
  }) {
    final rows = _db.select('''
      SELECT position_ms, duration_ms FROM episode_playback_progress
      WHERE movie_id = ? AND episode_id = ?
    ''', [movieId, episodeId]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    return NasEpisodePlaybackProgress(
      positionMs: row['position_ms'] as int,
      durationMs: row['duration_ms'] as int,
    );
  }

  int resumePositionMsForEpisode({
    required String movieId,
    required String episodeId,
  }) =>
      playbackProgressForEpisode(movieId: movieId, episodeId: episodeId)
          ?.positionMs ??
      0;

  NasPlaybackResumeTarget? resumeTargetForMovie(String movieId) {
    final progressed = _db.select('''
      SELECT episode_id, position_ms
      FROM episode_playback_progress
      WHERE movie_id = ?
        AND position_ms > 0
        AND duration_ms > 0
        AND position_ms < duration_ms
      ORDER BY updated_at DESC, episode_id DESC
      LIMIT 1
    ''', [movieId]);
    if (progressed.isNotEmpty) {
      return NasPlaybackResumeTarget(
        episodeId: progressed.single['episode_id'] as String,
        positionMs: progressed.single['position_ms'] as int,
      );
    }

    final latestStarted = _db.select('''
      SELECT episode_id
      FROM playback_history
      WHERE movie_id = ?
      ORDER BY started_at DESC, id DESC
      LIMIT 1
    ''', [movieId]);
    if (latestStarted.isEmpty) return null;
    return NasPlaybackResumeTarget(
      episodeId: latestStarted.single['episode_id'] as String,
      positionMs: 0,
    );
  }

  String recordPlaybackStarted({
    required String movieId,
    required String episodeId,
    String deviceId = 'legacy',
    String devicePlatform = 'unknown',
    String? startedAt,
    int? durationMs,
  }) {
    final historyId = newUuidV4();
    final timestamp = startedAt ?? now();
    _db.execute(
      'UPDATE movies SET play_count = play_count + 1, updated_at = ? WHERE id = ?',
      [timestamp, movieId],
    );
    _db.execute(
      '''INSERT INTO playback_history(
           id, movie_id, episode_id, started_at, last_reported_at,
           watch_duration_ms, last_position_ms, playback_status,
           device_id, device_platform, duration_ms, end_position_ms
         ) VALUES (?, ?, ?, ?, ?, 0, 0, 'playing', ?, ?, ?, 0)''',
      [
        historyId,
        movieId,
        episodeId,
        timestamp,
        timestamp,
        deviceId,
        devicePlatform,
        durationMs,
      ],
    );
    return historyId;
  }

  /// 只更新当前正式播放会话绑定的那一条记录，绝不按影片合并历史活动。
  void reportPlaybackHistory({
    required String historyId,
    required String lastReportedAt,
    required int watchDurationMs,
    required int lastPositionMs,
    required int? durationMs,
    required String playbackStatus,
  }) {
    _db.execute('''
      UPDATE playback_history
      SET last_reported_at = ?, watch_duration_ms = ?, last_position_ms = ?,
          duration_ms = ?, end_position_ms = ?, playback_status = ?
      WHERE id = ?
    ''', [
      lastReportedAt,
      watchDurationMs,
      lastPositionMs,
      durationMs,
      lastPositionMs,
      playbackStatus,
      historyId,
    ]);
  }

  void finishPlaybackHistory({
    required String historyId,
    required int? endPositionMs,
    required int? durationMs,
    String? lastReportedAt,
    int? watchDurationMs,
    String playbackStatus = 'ended',
  }) {
    _db.execute(
      '''UPDATE playback_history
         SET ended_at = ?, last_reported_at = ?, end_position_ms = ?,
             last_position_ms = ?, duration_ms = ?, watch_duration_ms = ?,
             playback_status = ?
         WHERE id = ?''',
      [
        now(),
        lastReportedAt ?? now(),
        endPositionMs,
        endPositionMs ?? 0,
        durationMs,
        watchDurationMs ?? 0,
        playbackStatus,
        historyId,
      ],
    );
  }

  NasWatchHistoryPage watchHistoryPage(NasWatchHistoryQuery query) {
    final clauses = <String>[];
    final parameters = <Object?>[];
    final normalizedQuery = query.query.trim();
    final like = '%$normalizedQuery%';
    final catalogLike = '%${normalizeCatalogNumber(normalizedQuery)}%';
    if (normalizedQuery.isNotEmpty) {
      clauses.add('''(
        lower(m.title) LIKE lower(?)
        OR lower(COALESCE(m.original_title, '')) LIKE lower(?)
        OR lower(e.title) LIKE lower(?)
        OR lower(REPLACE(REPLACE(REPLACE(COALESCE(m.catalog_number, ''), '-', ''), '_', ''), ' ', '')) LIKE lower(?)
      )''');
      parameters.addAll([like, like, like, catalogLike]);
    }
    if (query.startedOnOrAfter != null) {
      clauses.add('h.started_at >= ?');
      parameters.add(query.startedOnOrAfter);
    }
    if (query.startedBefore != null) {
      clauses.add('h.started_at < ?');
      parameters.add(query.startedBefore);
    }
    if (query.devicePlatform != null) {
      clauses.add('h.device_platform = ?');
      parameters.add(query.devicePlatform);
    }
    final where = clauses.isEmpty ? '1 = 1' : clauses.join(' AND ');
    final sortExpression = switch (query.sort) {
      'watchDurationMs' => 'h.watch_duration_ms',
      'lastReportedAt' => 'h.last_reported_at',
      _ => 'h.started_at',
    };
    final direction = query.order == 'asc' ? 'ASC' : 'DESC';
    final offset = (query.page - 1) * query.pageSize;
    const from = '''
      FROM playback_history h
      JOIN movies m ON m.id = h.movie_id
      JOIN episodes e ON e.id = h.episode_id
      LEFT JOIN media_roots root ON root.id = e.media_root_id
    ''';
    final total = _db
        .select('SELECT COUNT(*) AS count $from WHERE $where', parameters)
        .single['count'] as int;
    final rows = _db.select('''
      SELECT h.id, h.movie_id, h.episode_id, h.started_at, h.last_reported_at,
             h.ended_at, h.watch_duration_ms, h.last_position_ms,
             h.duration_ms, h.playback_status, h.device_id, h.device_platform,
             m.title, m.original_title, m.catalog_number, m.poster_file_name,
             e.title AS episode_title, root.name AS source_name
      $from
      WHERE $where
      ORDER BY $sortExpression $direction, h.id $direction
      LIMIT ? OFFSET ?
    ''', [...parameters, query.pageSize, offset]);
    final statsRow = _db.select('''
      SELECT COUNT(*) AS record_count,
             COALESCE(SUM(h.watch_duration_ms), 0) AS watch_duration_ms,
             COUNT(DISTINCT h.device_id) AS active_device_count
      $from
      WHERE $where
    ''', parameters).single;
    final deviceRows = _db.select('''
      SELECT h.device_platform, COUNT(*) AS count
      $from
      WHERE $where
      GROUP BY h.device_platform
    ''', parameters);
    return NasWatchHistoryPage(
      items: rows.map(_mapWatchHistoryRecord).toList(growable: false),
      number: query.page,
      size: query.pageSize,
      total: total,
      hasMore: offset + rows.length < total,
      stats: NasWatchHistoryStats(
        recordCount: statsRow['record_count'] as int,
        watchDurationMs: statsRow['watch_duration_ms'] as int,
        continueCount: _continueWatchingItems().length,
        activeDeviceCount: statsRow['active_device_count'] as int,
      ),
      continueItems: _continueWatchingItems(),
      deviceCounts: {
        for (final row in deviceRows)
          row['device_platform'] as String: row['count'] as int,
      },
    );
  }

  List<NasWatchHistoryRecord> _continueWatchingItems() {
    final rows = _db.select('''
      SELECT COALESCE(h.id, '') AS id, p.movie_id, p.episode_id,
             COALESCE(h.started_at, p.updated_at) AS started_at,
             COALESCE(h.last_reported_at, p.updated_at) AS last_reported_at,
             h.ended_at, COALESCE(h.watch_duration_ms, 0) AS watch_duration_ms,
             p.position_ms AS last_position_ms, p.duration_ms,
             COALESCE(h.playback_status, 'paused') AS playback_status,
             COALESCE(h.device_id, 'legacy') AS device_id,
             COALESCE(h.device_platform, 'unknown') AS device_platform,
             m.title, m.original_title, m.catalog_number, m.poster_file_name,
             e.title AS episode_title, root.name AS source_name
      FROM episode_playback_progress p
      JOIN movies m ON m.id = p.movie_id
      JOIN episodes e ON e.id = p.episode_id
      LEFT JOIN media_roots root ON root.id = e.media_root_id
      LEFT JOIN playback_history h ON h.id = (
        SELECT latest.id FROM playback_history latest
        WHERE latest.episode_id = p.episode_id
        ORDER BY latest.last_reported_at DESC, latest.id DESC
        LIMIT 1
      )
      WHERE p.position_ms > 0 AND p.duration_ms > 0
        AND p.position_ms < p.duration_ms
      ORDER BY p.updated_at DESC, p.episode_id DESC
      LIMIT 12
    ''');
    return rows.map(_mapWatchHistoryRecord).toList(growable: false);
  }

  NasWatchHistoryRecord _mapWatchHistoryRecord(Row row) =>
      NasWatchHistoryRecord(
        recordId: row['id'] as String,
        movieId: row['movie_id'] as String,
        episodeId: row['episode_id'] as String,
        title: row['title'] as String,
        episodeTitle: row['episode_title'] as String,
        startedAt: row['started_at'] as String,
        lastReportedAt: row['last_reported_at'] as String,
        watchDurationMs: row['watch_duration_ms'] as int,
        lastPositionMs: row['last_position_ms'] as int,
        durationMs: row['duration_ms'] as int?,
        status: row['playback_status'] as String,
        deviceId: row['device_id'] as String,
        devicePlatform: row['device_platform'] as String,
        originalTitle: row['original_title'] as String?,
        catalogNumber: row['catalog_number'] as String?,
        posterFileName: row['poster_file_name'] as String?,
        sourceName: row['source_name'] as String?,
        endedAt: row['ended_at'] as String?,
      );

  List<NasPlaybackHistoryItem> listPlaybackHistory({String titleQuery = ''}) {
    final query = titleQuery.trim();
    final like = '%$query%';
    final normalizedCatalogQuery = normalizeCatalogNumber(query);
    final catalogLike = '%$normalizedCatalogQuery%';
    final rows = _db.select('''
      SELECT h.id, h.movie_id, h.episode_id, m.title, m.original_title,
             m.catalog_number, m.poster_file_name,
             h.started_at, h.ended_at, h.end_position_ms, h.duration_ms
        FROM playback_history h
        JOIN movies m ON m.id = h.movie_id
       WHERE (
         ? = ''
         OR lower(m.title) LIKE lower(?)
         OR lower(COALESCE(m.original_title, '')) LIKE lower(?)
         OR (? != '' AND lower(REPLACE(REPLACE(REPLACE(
           COALESCE(m.catalog_number, ''), '-', ''), '_', ''), ' ', '')) LIKE ?)
       )
       ORDER BY h.started_at DESC, h.id DESC
    ''', [query, like, like, normalizedCatalogQuery, catalogLike]);
    return rows
        .map(
          (row) => NasPlaybackHistoryItem(
            id: row['id'] as String,
            movieId: row['movie_id'] as String,
            episodeId: row['episode_id'] as String,
            title: row['title'] as String,
            originalTitle: row['original_title'] as String?,
            catalogNumber: row['catalog_number'] as String?,
            posterFileName: row['poster_file_name'] as String?,
            startedAt: row['started_at'] as String,
            endedAt: row['ended_at'] as String?,
            endPositionMs: row['end_position_ms'] as int?,
            durationMs: row['duration_ms'] as int?,
          ),
        )
        .toList(growable: false);
  }

  void savePlaybackProgress({
    required String movieId,
    required String episodeId,
    required int positionMs,
    required int durationMs,
  }) {
    final boundedPosition = positionMs > durationMs ? durationMs : positionMs;
    _db.execute('''
      INSERT INTO episode_playback_progress(
        movie_id, episode_id, position_ms, duration_ms, updated_at
      ) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(movie_id, episode_id) DO UPDATE SET
        position_ms = excluded.position_ms,
        duration_ms = excluded.duration_ms,
        updated_at = excluded.updated_at
    ''', [movieId, episodeId, boundedPosition, durationMs, now()]);
  }

  String? lastPlaybackStartedAtForMovie(String movieId) {
    final rows = _db.select('''
      SELECT started_at FROM playback_history
      WHERE movie_id = ?
      ORDER BY started_at DESC, id DESC
      LIMIT 1
    ''', [movieId]);
    return rows.isEmpty ? null : rows.single['started_at'] as String?;
  }
}
