import 'dart:convert';

class NasFixtureLibrary {
  static const movieId = 'fixture-movie-1';

  static final _posterBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL8DwAAAABJRU5ErkJggg==',
  );

  List<Map<String, Object?>> listMovies({String query = ''}) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isNotEmpty && !'幕境 NAS 示例影片'.toLowerCase().contains(normalized)) {
      return const [];
    }
    return [_summary()];
  }

  Map<String, Object?>? movieDetails(String movieId, {required bool isAvailable}) {
    if (movieId != NasFixtureLibrary.movieId) return null;
    return {
      ..._summary(),
      'summary': '仅用于 NAS API 契约验证的内存示例数据。',
      'episodes': [
        {
          'id': 'fixture-episode-1',
          'title': '正片',
          'durationMs': 600000,
          'fileSize': null,
          'isAvailable': isAvailable,
        },
      ],
    };
  }

  List<List<String>> tagPaths() => const [
        ['题材', '科幻'],
        ['年代', '2020年代'],
      ];

  List<int>? poster(String movieId) =>
      movieId == NasFixtureLibrary.movieId ? _posterBytes : null;

  Map<String, Object?> _summary() => {
        'id': movieId,
        'title': '幕境 NAS 示例影片',
        'actors': const ['示例演员'],
        'category': const {'id': 'fixture-category', 'name': '示例'},
        'tags': const [
          {'id': 'fixture-tag-scifi', 'name': '科幻'},
          {'id': 'fixture-tag-2020s', 'name': '2020年代'},
        ],
        'tagPaths': tagPaths(),
        'episodeCount': 1,
        'durationMs': 600000,
        'resolutionLabel': '1080p',
        'resolutionWidth': 1920,
        'resolutionHeight': 1080,
        'posterUrl': '/api/v1/assets/posters/$movieId',
        'isFavorite': false,
        'playCount': 0,
        'resumePositionMs': 0,
        'updatedAt': '2026-08-25T00:00:00.000Z',
      };
}
