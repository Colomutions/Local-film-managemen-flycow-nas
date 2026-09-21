import 'dart:async';

class NasNovelWriteBarrier {
  var _activeMutations = 0;
  var _capturePending = false;
  Completer<void>? _mutationsDrained;
  Completer<void>? _captureFinished;
  Future<void> _captureQueue = Future.value();

  Future<T> runMutation<T>(Future<T> Function() action) async {
    while (_capturePending) {
      await _captureFinished!.future;
    }
    _activeMutations++;
    try {
      return await action();
    } finally {
      _activeMutations--;
      if (_activeMutations == 0) {
        _mutationsDrained?.complete();
        _mutationsDrained = null;
      }
    }
  }

  Future<T> runCapture<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _captureQueue = _captureQueue.then((_) async {
      _capturePending = true;
      _captureFinished = Completer<void>();
      try {
        if (_activeMutations > 0) {
          _mutationsDrained ??= Completer<void>();
          await _mutationsDrained!.future;
        }
        result.complete(await action());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      } finally {
        _capturePending = false;
        _captureFinished!.complete();
        _captureFinished = null;
      }
    });
    return result.future;
  }
}
