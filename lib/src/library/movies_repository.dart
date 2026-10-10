import 'package:sqlite3/sqlite3.dart';

import '../library_models.dart';
import 'library_values.dart';

/// Owns movie and episode edits and index removal.
class NasMoviesRepository {
  NasMoviesRepository(
    this._connection, {
    required this.findEpisode,
    required this.findMovie,
    required this.findMovieForAdmin,
    required this.transaction,
  });

  final Database Function() _connection;
  Database get _db => _connection();
  final NasLibraryEpisode? Function(String episodeId) findEpisode;
  final NasLibraryMovie? Function(String movieId) findMovie;
  final NasLibraryMovie? Function(String movieId) findMovieForAdmin;
  final T Function<T>(T Function() action) transaction;

  NasLibraryMovie? setMovieFavorite({
    required String movieId,
    required bool isFavorite,
  }) {
    if (findMovie(movieId) == null) return null;
    _db.execute(
      'UPDATE movies SET is_favorite = ?, updated_at = ? WHERE id = ?',
      [isFavorite ? 1 : 0, now(), movieId],
    );
    return findMovie(movieId);
  }

  NasRemovedMovieIndex? removeMovieFromIndex(String movieId) {
    final movie = findMovie(movieId);
    if (movie == null) return null;
    return transaction(() => removeMovieIndex(movie));
  }

  /// 调用方负责事务；先解除限制删除的引用，再级联清理影片关联。
  NasRemovedMovieIndex removeMovieIndex(NasLibraryMovie movie) {
    final movieId = movie.id;
    final carouselFileNames = _db
        .select(
          'SELECT file_name FROM movie_carousel_images WHERE movie_id = ?',
          [movieId],
        )
        .map((row) => row['file_name'] as String)
        .toList(growable: false);
    _db.execute('''DELETE FROM mdcng_import_records WHERE movie_id = ? OR
      episode_id IN (SELECT id FROM episodes WHERE movie_id = ?)''',
        [movieId, movieId]);
    _db.execute(
        'UPDATE movies SET merged_into_movie_id=NULL WHERE merged_into_movie_id=?',
        [movieId]);
    _db.execute("DELETE FROM scrape_fields WHERE kind='movie' AND entity_id=?",
        [movieId]);
    _db.execute("DELETE FROM scrape_sources WHERE kind='movie' AND entity_id=?",
        [movieId]);
    _db.execute('DELETE FROM movies WHERE id = ?', [movieId]);
    return NasRemovedMovieIndex(
      posterFileName: movie.posterFileName,
      carouselFileNames: carouselFileNames,
    );
  }

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
  }) {
    if (findMovieForAdmin(movieId) == null) return null;
    if (title == null &&
        !updateOriginalTitle &&
        !updateCatalogNumber &&
        !updatePublisherName &&
        !updateSeriesName &&
        summary == null) {
      return findMovieForAdmin(movieId);
    }
    final assignments = <String>[];
    final values = <Object?>[];
    if (title != null) {
      assignments.add('title = ?');
      values.add(title);
    }
    if (updateOriginalTitle) {
      assignments.add('original_title = ?');
      values.add(nullableTrimmed(originalTitle));
    }
    if (updateCatalogNumber) {
      assignments.add('catalog_number = ?');
      values.add(nullableTrimmed(catalogNumber));
    }
    if (updatePublisherName) {
      assignments.add('publisher_name = ?');
      values.add(nullableTrimmed(publisherName));
    }
    if (updateSeriesName) {
      assignments.add('series_name = ?');
      values.add(nullableTrimmed(seriesName));
    }
    if (summary != null) {
      assignments.add('summary = ?');
      values.add(summary);
    }
    assignments.add('updated_at = ?');
    values.add(now());
    values.add(movieId);
    _db.execute(
      'UPDATE movies SET ${assignments.join(', ')} WHERE id = ?',
      values,
    );
    return findMovieForAdmin(movieId);
  }

  NasLibraryEpisode? updateEpisodeTitle({
    required String episodeId,
    required String title,
  }) {
    final episode = findEpisode(episodeId);
    if (episode == null) return null;
    _db.execute(
      'UPDATE episodes SET title = ?, updated_at = ? WHERE id = ?',
      [title, now(), episodeId],
    );
    return findEpisode(episodeId);
  }

  NasLibraryMovie? updateMoviePosterFileName({
    required String movieId,
    required String posterFileName,
  }) {
    if (findMovieForAdmin(movieId) == null) return null;
    _db.execute(
      'UPDATE movies SET poster_file_name = ?, updated_at = ? WHERE id = ?',
      [posterFileName, now(), movieId],
    );
    return findMovieForAdmin(movieId);
  }

  NasLibraryEpisode? updateEpisodeSourceAfterRename({
    required String episodeId,
    required String relativePath,
    required String title,
    required int fileSize,
    required int mediaModifiedAt,
  }) {
    final episode = findEpisode(episodeId);
    if (episode == null) return null;
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute(
        '''UPDATE episodes
           SET relative_path = ?, title = ?, file_size = ?, media_modified_at = ?,
               is_available = 1, updated_at = ?
           WHERE id = ?''',
        [
          relativePath,
          title,
          fileSize,
          mediaModifiedAt,
          now(),
          episodeId,
        ],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return findEpisode(episodeId);
  }
}
