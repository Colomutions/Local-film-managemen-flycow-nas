part of '../library_database.dart';

class SourceDeletionException implements Exception {
  const SourceDeletionException(this.code);
  final String code;
}

class _DeletionFile {
  _DeletionFile(this.file, this.label, this.kind) : stat = file.statSync();

  final File file;
  final String label;
  final String kind;
  final FileStat stat;
  final episodes = <NasLibraryEpisode>[];

  List<Object?> get fingerprint => [
        file.path,
        kind,
        stat.size,
        stat.modified.microsecondsSinceEpoch,
        stat.changed.microsecondsSinceEpoch,
      ];
}

String _physicalPath(String path) =>
    Directory(path).absolute.path.replaceAll(Platform.pathSeparator, '/');

String _name(FileSystemEntity entry) =>
    entry.path.split(Platform.pathSeparator).last;
String _stem(String name) =>
    name.substring(0, name.lastIndexOf('.')).toLowerCase();
bool _image(String name) =>
    RegExp(r'\.(jpg|jpeg|png|webp|gif)$', caseSensitive: false).hasMatch(name);
const _galleryNames = {'extrafanart', 'extrathumbs', 'screenshots', '截图', '剧照'};
bool _safeComponent(String value) =>
    value.isNotEmpty &&
    value != '.' &&
    value != '..' &&
    !RegExp(r'[/\\:\x00]').hasMatch(value);

/// Resolve each parent without following symlinks, including replaced work folders.
void _checkDirectory(Directory base, Directory directory) {
  final root = _physicalPath(base.path);
  final path = _physicalPath(directory.path);
  if (path != root && !path.startsWith('$root/')) {
    throw const SourceDeletionException('source_delete_changed');
  }
  var parent = base;
  if (FileSystemEntity.typeSync(parent.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const SourceDeletionException('source_delete_unavailable');
  }
  if (path == root) return;
  for (final part in path.substring(root.length + 1).split('/')) {
    if (!_safeComponent(part))
      throw const SourceDeletionException('source_delete_changed');
    parent = Directory('${parent.path}/$part');
    if (FileSystemEntity.typeSync(parent.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const SourceDeletionException('source_delete_unavailable');
    }
  }
}

class _SourceDeletionPlan {
  final files = <_DeletionFile>[];
  final kept = <String>{};
  final episodes = <List<String>>[];
  final finished = <String>[];

  String token(String movieId) => sha256Hex(jsonEncode([
        movieId,
        episodes,
        finished,
        files.map((f) => f.fingerprint).toList(),
        kept.toList()..sort(),
      ]));

  Map<String, Object?> preview(String movieId) => {
        'previewToken': token(movieId),
        'episodeCount': episodes.length,
        'files': [
          for (final f in files) {'path': f.label, 'kind': f.kind}
        ],
        'kept': kept.toList()..sort(),
        'alreadyDeleted': finished,
      };
}

// Include the hidden sources of an explicitly composed collection. A source
// that still owns episodes keeps its assets, as do other users of shared art.
const _deletionOwners = '''WITH RECURSIVE owners(id) AS (
  SELECT ? UNION SELECT m.id FROM movies m JOIN owners ON m.merged_into_movie_id=owners.id
  WHERE m.lifecycle_state='merged' AND NOT EXISTS (SELECT 1 FROM episodes e WHERE e.movie_id=m.id)
) ''';

extension NasSourceDeletion on NasLibraryDatabase {
  bool posterUsedByOtherMovie(String fileName, String movieId) => _db.select(
        'SELECT 1 FROM movies WHERE poster_file_name=? AND id<>? LIMIT 1',
        [fileName, movieId],
      ).isNotEmpty;

  Map<String, Object?> movieSourceDeletion({
    required String movieId,
    required String mediaDir,
    String? previewToken,
  }) {
    final movie = findMovie(movieId);
    if (movie == null)
      throw const SourceDeletionException('resource_not_found');
    if (hasActivePlayback?.call({movieId}) ?? false) {
      throw const SourceDeletionException('collection_playback_active');
    }
    if (_db.select(
        '''SELECT 1 FROM scrape_tasks WHERE status IN ('pending','running','retry')
        AND json_extract(payload,'\$.movieId')=? UNION ALL SELECT 1 FROM ai_metadata_tasks
        WHERE status IN ('queued','running') AND movie_id=? LIMIT 1''',
        [movieId, movieId]).isNotEmpty) {
      throw const SourceDeletionException('collection_task_active');
    }
    final plan = _SourceDeletionPlan();
    final folders = <String, List<NasLibraryEpisode>>{};
    final media = Directory(mediaDir);
    final videosByPath = <String, _DeletionFile>{};
    for (final episode in episodesForMovie(movieId)) {
      final root = findMediaRoot(episode.mediaRootId);
      if (root == null || !root.isOnline || !root.enabled) {
        throw const SourceDeletionException('source_delete_unavailable');
      }
      final parts = episode.relativePath.split('/');
      if (!parts.every(_safeComponent) || !isVideo(parts.last)) {
        throw const SourceDeletionException('source_delete_changed');
      }
      final file =
          File('${root.containerPath}/${episode.relativePath}').absolute;
      _checkDirectory(media, file.parent);
      final label = '${root.name}/${episode.relativePath}';
      plan.episodes
          .add([episode.id, episode.mediaRootId, episode.relativePath]);
      folders.putIfAbsent(file.parent.path, () => []).add(episode);
      final type = FileSystemEntity.typeSync(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound &&
          _db.select(
            '''SELECT 1 FROM source_delete_receipts WHERE episode_id=? AND movie_id=?
           AND media_root_id=? AND relative_path=?''',
            [episode.id, movieId, root.id, episode.relativePath],
          ).isNotEmpty) {
        plan.finished.add(label);
        continue;
      }
      if (type != FileSystemEntityType.file || !episode.isAvailable) {
        throw const SourceDeletionException('source_delete_unavailable');
      }
      final target = videosByPath.putIfAbsent(
          _physicalPath(file.path), () => _DeletionFile(file, label, 'video'));
      target.episodes.add(episode);
      if (target.stat.size != episode.fileSize ||
          (episode.mediaModifiedAt != null &&
              target.stat.modified.microsecondsSinceEpoch !=
                  episode.mediaModifiedAt)) {
        throw const SourceDeletionException('source_delete_changed');
      }
    }
    plan.files.addAll(videosByPath.values);
    if (folders.isEmpty)
      throw const SourceDeletionException('source_delete_empty');
    for (final folder in folders.entries) {
      _collectSidecars(plan, Directory(folder.key), folder.value, movieId);
    }
    void managed(String? name, String directory, String kind, bool shared) {
      if (name == null ||
          !RegExp(r'^[a-zA-Z0-9-]+\.(png|jpe?g|webp)$').hasMatch(name)) return;
      final file = File('$dataDir/artwork/$directory/$name').absolute;
      final label = '幕境/$directory/$name';
      _checkDirectory(Directory(dataDir), file.parent);
      final type = FileSystemEntity.typeSync(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return;
      if (shared || type != FileSystemEntityType.file) {
        plan.kept.add(label);
      } else {
        plan.files.add(_DeletionFile(file, label, kind));
      }
    }

    for (final row in _db.select("""$_deletionOwners
      SELECT DISTINCT m.poster_file_name AS name, EXISTS (
        SELECT 1 FROM movies other WHERE other.poster_file_name=m.poster_file_name
          AND other.id NOT IN (SELECT id FROM owners)) AS shared
      FROM movies m JOIN owners ON owners.id=m.id WHERE m.poster_file_name IS NOT NULL""",
        [movieId])) {
      managed(row['name'] as String, 'posters', 'poster', row['shared'] == 1);
    }
    for (final row in _db.select("""$_deletionOwners
      SELECT DISTINCT i.file_name AS name, EXISTS (
        SELECT 1 FROM movie_carousel_images other WHERE other.file_name=i.file_name
          AND other.movie_id NOT IN (SELECT id FROM owners)) AS shared
      FROM movie_carousel_images i JOIN owners ON owners.id=i.movie_id""",
        [movieId])) {
      managed(
          row['name'] as String, 'carousel', 'screenshot', row['shared'] == 1);
    }
    // Preserve NFO references until their images are gone; remove indexed videos last.
    int order(_DeletionFile f) => f.kind == 'video'
        ? 2
        : f.kind == 'nfo'
            ? 1
            : 0;
    plan.files.sort((a, b) {
      final rank = order(a).compareTo(order(b));
      return rank != 0 ? rank : a.file.path.compareTo(b.file.path);
    });
    if (previewToken == null) return plan.preview(movieId);
    if (previewToken != plan.token(movieId)) {
      throw const SourceDeletionException('source_delete_changed');
    }

    // Check every participating mount before unlinking anything. The probe is
    // unique, empty, and removed immediately, including on shared category roots.
    for (final path in plan.files.map((f) => f.file.parent.path).toSet()) {
      Directory(path).createTempSync('.mujing-delete-check-').deleteSync();
    }
    for (final f in plan.files) {
      final base = f.kind == 'poster' || f.kind == 'screenshot'
          ? Directory(dataDir)
          : media;
      _checkDirectory(base, f.file.parent);
      if (FileSystemEntity.typeSync(f.file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          jsonEncode(_DeletionFile(f.file, f.label, f.kind).fingerprint) !=
              jsonEncode(f.fingerprint)) {
        throw const SourceDeletionException('source_delete_changed');
      }
      for (final episode in f.episodes) {
        // Survives process termination between unlink and the final index transaction.
        _db.execute(
            'INSERT OR REPLACE INTO source_delete_receipts VALUES (?,?,?,?)',
            [episode.id, movieId, episode.mediaRootId, episode.relativePath]);
      }
      f.file.deleteSync();
    }
    transaction(() {
      _db.execute('''$_deletionOwners UPDATE movies SET poster_file_name=NULL
        WHERE id<>? AND id IN (SELECT id FROM owners)''', [movieId, movieId]);
      _db.execute('''$_deletionOwners DELETE FROM movie_carousel_images
        WHERE movie_id IN (SELECT id FROM owners)''', [movieId]);
      _removeMovieIndex(movie);
    });
    return {'deleted': true};
  }

  void _collectSidecars(_SourceDeletionPlan plan, Directory folder,
      List<NasLibraryEpisode> episodes, String movieId) {
    final ownNames =
        episodes.map((e) => e.relativePath.split('/').last).toSet();
    final ownStems = ownNames.map(_stem).toSet();
    final prefix = '${_physicalPath(folder.path)}/';
    // A legacy /media root and a /media/diskN root can address the same file.
    final neighbors = _db
        .select(r'''WITH paths AS (
      SELECT replace(r.container_path, '\','/') || '/' || e.relative_path AS path
      FROM episodes e JOIN media_roots r ON r.id=e.media_root_id WHERE e.movie_id<>?)
      SELECT substr(path,length(?)+1) AS name FROM paths
      WHERE substr(path,1,length(?))=? AND instr(substr(path,length(?)+1),'/')=0''',
            [movieId, prefix, prefix, prefix, prefix])
        .map((r) => r['name'] as String)
        .toSet();
    if (neighbors.intersection(ownNames).isNotEmpty) {
      throw const SourceDeletionException('source_delete_shared_video');
    }
    final entries = folder.listSync(followLinks: false);
    for (final e in entries) {
      final name = _name(e);
      if (isVideo(name) && !ownNames.contains(name)) neighbors.add(name);
    }
    final foreignStems = neighbors.where(isVideo).map(_stem).toSet();
    final stems = ownStems.difference(foreignStems);
    final dedicated = neighbors.isEmpty &&
        _db.select(r'''
      SELECT 1 FROM media_roots r WHERE replace(r.container_path,'\','/')=?
      UNION ALL SELECT 1 FROM category_media_sources s JOIN media_roots r ON r.id=s.media_root_id
      WHERE replace(r.container_path,'\','/') || '/' || s.relative_path=? LIMIT 1''',
            [_physicalPath(folder.path), _physicalPath(folder.path)]).isEmpty;
    final first = episodes.first;
    final slash = first.relativePath.lastIndexOf('/');
    final display =
        '${first.sourceName}/${slash < 0 ? '' : first.relativePath.substring(0, slash + 1)}';
    final claimed = <String>{}, protected = <String>{};
    final nfos =
        entries.where((e) => _name(e).toLowerCase().endsWith('.nfo')).toList();
    bool targetNfo(String name) =>
        stems.contains(_stem(name)) ||
        (dedicated && name.toLowerCase() == 'movie.nfo');
    final exclusive = dedicated && nfos.every((e) => targetNfo(_name(e)));
    bool matchesArtwork(String base, Set<String> owners) {
      if (owners.contains(base)) return true;
      for (final suffix in ['-poster', '-fanart', '-thumb']) {
        if (base.endsWith(suffix) &&
            owners.contains(base.substring(0, base.length - suffix.length)))
          return true;
      }
      return false;
    }

    final localImages = entries
        .map(_name)
        .where(_image)
        .map((name) => name.toLowerCase())
        .toSet();
    // Read other movies' NFOs only when there is a candidate image to delete.
    final matchingArtwork =
        localImages.any((name) => matchesArtwork(_stem(name), stems));
    final ownNfos = nfos.where((e) => targetNfo(_name(e)));
    final otherNfos = nfos.where((e) => !targetNfo(_name(e)));
    var unreadableForeignNfo = false;
    for (final entry in ownNfos.followedBy(otherNfos)) {
      final name = _name(entry);
      final own = targetNfo(name);
      if (own && entry is File) {
        plan.files.add(_DeletionFile(entry, '$display$name', 'nfo'));
      } else if (ownStems.contains(_stem(name))) {
        plan.kept.add('$display$name');
      }
      if (localImages.isEmpty ||
          (!own &&
              (unreadableForeignNfo ||
                  (!matchingArtwork && !claimed.any(localImages.contains)))))
        continue;
      if (entry is! File || entry.lengthSync() > 1024 * 1024) {
        if (!own) unreadableForeignNfo = true;
        continue;
      }
      try {
        final nfo = const MdcngNfoParser().parse(entry.readAsStringSync());
        for (final image
            in [nfo.poster, nfo.thumb, nfo.fanart].whereType<String>()) {
          if (_safeComponent(image) && _image(image))
            (own ? claimed : protected).add(image.toLowerCase());
        }
      } on FormatException {
        if (!own) unreadableForeignNfo = true;
      }
    }

    for (final entry in entries) {
      final name = _name(entry);
      final lower = name.toLowerCase();
      if (_galleryNames.contains(lower)) {
        if (!exclusive || entry is! Directory) {
          plan.kept.add('$display$name/');
          continue;
        }
        for (final child in entry.listSync(followLinks: false)) {
          final label = '$display$name/${_name(child)}';
          if (child is File && _image(_name(child))) {
            plan.files.add(_DeletionFile(child, label, 'gallery'));
          } else {
            plan.kept.add(label);
          }
        }
      } else if (_image(lower)) {
        final base = _stem(lower);
        final generic = const {
          'poster',
          'fanart',
          'thumb',
          'cover',
          'folder',
          'backdrop',
          'landscape'
        }.contains(base);
        final byName = matchesArtwork(base, stems);
        if (!generic && !byName && !claimed.contains(lower)) continue;
        if (entry is File &&
            !protected.contains(lower) &&
            !matchesArtwork(base, foreignStems) &&
            !unreadableForeignNfo &&
            (exclusive || !generic && (byName || claimed.contains(lower)))) {
          plan.files.add(_DeletionFile(entry, '$display$name', 'artwork'));
        } else {
          plan.kept.add('$display$name');
        }
      }
    }
  }
}
