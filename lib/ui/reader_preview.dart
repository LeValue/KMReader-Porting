import 'dart:async';

/// Bounded live preview: at most one layout in flight and one latest pending
/// value. A slow WebView cannot accumulate a queue of obsolete slider positions.
class ReaderPreview<T> {
  ReaderPreview(
    this.apply, {
    required this.onError,
    this.delay = const Duration(milliseconds: 80),
  });
  final Future<void> Function(T) apply;
  final void Function(Object) onError;
  final Duration delay;
  Timer? _timer;
  T? _pending;
  bool _hasPending = false;
  Future<void>? _running;
  void schedule(T value) {
    _pending = value;
    _hasPending = true;
    if (_timer != null || _running != null) return;
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(flush().catchError((Object error) => onError(error)));
    });
  }

  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final current = _running;
    if (current != null) return current;
    late Future<void> work;
    work = Future<void>(() async {
      try {
        while (_hasPending) {
          final value = _pending as T;
          _pending = null;
          _hasPending = false;
          await apply(value);
        }
      } finally {
        _running = null;
      }
    });
    _running = work;
    return work;
  }
}
