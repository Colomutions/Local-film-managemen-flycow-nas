import 'dart:async';

import '../config.dart';
import '../library_database.dart';
import '../media_service.dart';

/// Resolves an indexed episode against its configured media root.
class NasMediaResolver {
  NasMediaResolver(this._libraryDatabase, this._mediaService, this.config);
  final NasLibraryDatabase _libraryDatabase;
  final NasConfig config;
  final NasMediaService _mediaService;

  Future<NasMediaFile?> fileForEpisode(NasLibraryEpisode episode) async {
    final root = _libraryDatabase.findMediaRoot(episode.mediaRootId);
    if (root == null || !root.isOnline) return null;
    return root.containerPath == config.mediaDir
        ? _mediaService.fileForRelativePath(episode.relativePath)
        : _mediaService.fileForRootRelativePath(
            rootPath: root.containerPath,
            relativePath: episode.relativePath,
          );
  }
}
