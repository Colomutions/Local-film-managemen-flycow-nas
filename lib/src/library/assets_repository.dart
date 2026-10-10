import 'package:sqlite3/sqlite3.dart';

import '../auth.dart';
import '../library_models.dart';
import 'library_values.dart';

/// Owns managed artwork records; file operations remain in the artwork service.
class NasAssetsRepository {
  NasAssetsRepository(
    this._connection, {
    required this.findMovieForAdmin,
  });

  final Database Function() _connection;
  Database get _db => _connection();
  final NasLibraryMovie? Function(String movieId) findMovieForAdmin;

  NasManagedAsset addManagedAsset({
    required String id,
    required String purpose,
    required String fileName,
    required String mimeType,
  }) {
    final asset = NasManagedAsset(
      id: id,
      purpose: purpose,
      fileName: fileName,
      mimeType: mimeType,
      createdAt: now(),
    );
    _db.execute('''
      INSERT INTO managed_assets(id, purpose, file_name, mime_type, created_at)
      VALUES (?, ?, ?, ?, ?)
    ''', [
      asset.id,
      asset.purpose,
      asset.fileName,
      asset.mimeType,
      asset.createdAt
    ]);
    return asset;
  }

  NasManagedAsset? findManagedAsset(String assetId) {
    final rows = _db.select('''
      SELECT id, purpose, file_name, mime_type, created_at
      FROM managed_assets WHERE id = ?
    ''', [assetId]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    return NasManagedAsset(
      id: row['id'] as String,
      purpose: row['purpose'] as String,
      fileName: row['file_name'] as String,
      mimeType: row['mime_type'] as String,
      createdAt: row['created_at'] as String,
    );
  }

  /// 删除受管理资产记录，供演员删除等场景同步清理 NAS 资产目录。
  NasManagedAsset? removeManagedAsset(String assetId) {
    final asset = findManagedAsset(assetId);
    if (asset == null) return null;
    _db.execute('DELETE FROM managed_assets WHERE id = ?', [assetId]);
    return asset;
  }

  List<NasCarouselImage> carouselImagesForMovie(String movieId) =>
      _db.select('''
        SELECT id, movie_id, file_name, created_at
        FROM movie_carousel_images WHERE movie_id = ? ORDER BY created_at, id
      ''', [movieId]).map(_mapCarouselImage).toList(growable: false);

  NasCarouselImage? addCarouselImage({
    required String movieId,
    required String fileName,
  }) {
    if (findMovieForAdmin(movieId) == null) return null;
    final image = NasCarouselImage(
      id: newUuidV4(),
      movieId: movieId,
      fileName: fileName,
      createdAt: now(),
    );
    _db.execute(
      'INSERT INTO movie_carousel_images(id, movie_id, file_name, created_at) VALUES (?, ?, ?, ?)',
      [image.id, image.movieId, image.fileName, image.createdAt],
    );
    return image;
  }

  NasCarouselImage? removeCarouselImage({
    required String movieId,
    required String imageId,
  }) {
    final rows = _db.select('''
      SELECT id, movie_id, file_name, created_at FROM movie_carousel_images
      WHERE id = ? AND movie_id = ?
    ''', [imageId, movieId]);
    if (rows.isEmpty) return null;
    final image = _mapCarouselImage(rows.single);
    _db.execute('DELETE FROM movie_carousel_images WHERE id = ?', [imageId]);
    return image;
  }

  NasCarouselImage? findCarouselImage(String imageId) {
    final rows = _db.select('''
      SELECT id, movie_id, file_name, created_at FROM movie_carousel_images
      WHERE id = ?
    ''', [imageId]);
    return rows.isEmpty ? null : _mapCarouselImage(rows.single);
  }

  NasCarouselImage _mapCarouselImage(Row row) => NasCarouselImage(
        id: row['id'] as String,
        movieId: row['movie_id'] as String,
        fileName: row['file_name'] as String,
        createdAt: row['created_at'] as String,
      );
}
