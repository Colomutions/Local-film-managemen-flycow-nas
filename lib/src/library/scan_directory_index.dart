import 'package:sqlite3/sqlite3.dart';

import '../library_models.dart';
import 'library_values.dart';

/// Directory ownership is persisted by each episode's source path and owner.
/// Derive it from those records so compose/split operations cannot leave a
/// second, stale ownership table behind. Offline sources participate as well.
class NasScanDirectoryIndex {
  NasScanDirectoryIndex(Database db, String categoryId,
      List<NasCategoryMediaSource> sources, String mediaRootId) {
    final rows = db.select('''
      SELECT e.*, m.collection_key, m.entry_type, m.episode_sort_mode,
        m.scan_grouping_mode
      FROM episodes e JOIN movies m ON m.id=e.movie_id
      WHERE m.category_id=? AND m.lifecycle_state='active'
        AND m.merged_into_movie_id IS NULL
    ''', [categoryId]);
    final canonicalEpisodesByPath = <String, Map<String, Object?>>{};
    for (final row in rows) {
      final path = row['relative_path'] as String;
      final rootId = row['media_root_id'] as String;
      final movieId = row['movie_id'] as String;
      final episode = Map<String, Object?>.from(row);
      _episodesByMovie.putIfAbsent(movieId, () => []).add(episode);
      if (row['entry_type'] != 'single' ||
          row['collection_key'] != null ||
          row['scan_grouping_mode'] != 'automatic') {
        _protectedMovies.add(movieId);
      }
      if (rootId == mediaRootId) {
        episodesByPath[path] = episode;
      }
      final slash = path.lastIndexOf('/');
      if (slash >= 0) {
        final canonicalPath =
            '${canonicalWorkDirectory(path.substring(0, slash))}${path.substring(slash)}';
        final key = '$rootId:$canonicalPath';
        final previous = canonicalEpisodesByPath[key];
        if (previous != null) {
          // 先扫描另一块盘时也要发现去后缀目标碰撞，避免提前归并。
          _protectedMovies.add(previous['movie_id'] as String);
          _protectedMovies.add(movieId);
        } else {
          canonicalEpisodesByPath[key] = episode;
        }
      }
      String? matchedDirectory;
      for (final source in sources) {
        final prefix = '${source.relativePath}/';
        if (source.mediaRootId != rootId || !path.startsWith(prefix)) continue;
        final directory = workDirectory(path.substring(prefix.length));
        if (directory == null) break;
        owners.putIfAbsent(directory, () => {}).add(movieId);
        matchedDirectory = directory;
        break;
      }
      // Whole-movie composition must never pull an unrelated directory or an
      // unbound episode into this work. Explicit manual splits stay protected.
      if (matchedDirectory == null) {
        _protectedMovies.add(movieId);
      } else {
        _directoriesByMovie
            .putIfAbsent(movieId, () => {})
            .add(matchedDirectory);
      }
    }
  }

  final episodesByPath = <String, Map<String, Object?>>{};
  final owners = <String, Set<String>>{};
  final _episodesByMovie = <String, List<Map<String, Object?>>>{};
  final _directoriesByMovie = <String, Set<String>>{};
  final _protectedMovies = <String>{};

  /// Existing automatic singles may be regrouped only when every owner and
  /// every one of its episodes belongs exclusively to this work directory.
  /// Natural filename order also supplies a stable, intuitive metadata source.
  List<String> automaticSingleMovieIds(String directory) {
    final movieIds = owners[directory];
    if (movieIds == null || movieIds.length < 2 || movieIds.length > 100) {
      return const [];
    }
    if (movieIds.any((id) =>
        _protectedMovies.contains(id) ||
        _directoriesByMovie[id]?.length != 1 ||
        !(_directoriesByMovie[id]?.contains(directory) ?? false))) {
      return const [];
    }
    final episodes = [
      for (final id in movieIds) ..._episodesByMovie[id]!,
    ];
    if (episodes.length > 500) return const [];
    episodes.sort((a, b) {
      final aPath = a['relative_path'] as String;
      final bPath = b['relative_path'] as String;
      final byName = naturalSortKey(aPath).compareTo(naturalSortKey(bPath));
      if (byName != 0) return byName;
      final byPath = aPath.toLowerCase().compareTo(bPath.toLowerCase());
      return byPath != 0
          ? byPath
          : (a['id'] as String).compareTo(b['id'] as String);
    });
    return {for (final episode in episodes) episode['movie_id'] as String}
        .toList(growable: false);
  }

  static String? workDirectory(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? null : canonicalWorkDirectory(path.substring(0, slash));
  }

  /// Only the explicitly supported suffix removal is a rename candidate.
  /// Existence and size/mtime are checked by the caller before changing IDs.
  Map<String, List<Map<String, Object?>>> suffixRenameCandidates(
      Set<String> currentPaths) {
    final candidates = <String, List<Map<String, Object?>>>{};
    for (final entry in episodesByPath.entries) {
      final path = entry.key;
      if (currentPaths.contains(path)) continue;
      final slash = path.lastIndexOf('/');
      if (slash < 0) continue;
      final parent = path.substring(0, slash);
      final canonical = canonicalWorkDirectory(parent);
      if (canonical == parent) continue;
      final newPath = '$canonical${path.substring(slash)}';
      candidates.putIfAbsent(newPath, () => []).add(entry.value);
    }
    return candidates;
  }
}
