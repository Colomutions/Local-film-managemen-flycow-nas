import 'dart:async';

/// One conservative queue for the service's storage pool. Distinct mount names
/// are not evidence of independent disks. Failed tasks never poison the queue.
class DiskWorkQueue {
  DiskWorkQueue({this.playbackActive, this.backgroundBytesPerSecond = 16 * 1024 * 1024});
  final bool Function()? playbackActive;
  final int backgroundBytesPerSecond;

  /// Cooperative pacing of background reads only; playback is never throttled.
  Stream<List<int>> read(Stream<List<int>> source) async* {
    await for (final bytes in source) {
      if (playbackActive?.call() ?? false) {
        await Future<void>.delayed(Duration(microseconds:
          (bytes.length * 1000000 / backgroundBytesPerSecond).ceil()));
      }
      yield bytes;
    }
  }

  Future<void> yieldToPlayback() async {
    if (playbackActive?.call() ?? false) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> _tail = Future.value();
  final Map<String, Future<Object?>> _pending = {};
  bool accepting = true;

  Future<T> run<T>(String key, Future<T> Function() action) {
    final existing = _pending[key];
    if (existing != null) return existing.then((value) => value as T);
    if (!accepting) return Future.error(StateError('Storage is in maintenance'));
    final result = _tail.then((_) => action());
    _pending[key] = result;
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    unawaited(_tail.then((_) => _pending.remove(key)));
    return result;
  }

  Future<void> drain() => _tail;
}
