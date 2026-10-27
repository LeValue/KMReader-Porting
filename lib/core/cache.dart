import 'dart:async';
import 'dart:io';

Future<void> trimMediaCache(Directory directory, int budget) async {
  if (!await directory.exists()) return;
  final files = <(File, FileStat)>[];
  var total = 0;
  await for (final entity in directory.list()) {
    if (entity is! File || entity.path.endsWith('.part')) continue;
    final stat = await entity.stat();
    if (stat.type != FileSystemEntityType.file) continue;
    files.add((entity, stat));
    total += stat.size;
  }
  files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
  for (final file in files) {
    if (total <= budget) break;
    try {
      await file.$1.delete();
      total -= file.$2.size;
    } on FileSystemException {
      /* A reader may still hold the file on Windows. */
    }
  }
}

/// Bounded by bytes as well as entries; callers retain ownership of values.
class WeightedCache<K, V> {
  WeightedCache({
    required this.maxWeight,
    required this.weight,
    this.maxEntries = 128,
  });
  final int maxWeight, maxEntries;
  final int Function(V) weight;
  final _values = <K, V>{};
  int _weight = 0;
  int get currentWeight => _weight;
  V? operator [](K key) {
    final value = _values.remove(key);
    if (value != null) _values[key] = value;
    return value;
  }

  void put(K key, V value) {
    remove(key);
    if (weight(value) > maxWeight) return;
    _values[key] = value;
    _weight += weight(value);
    while (_weight > maxWeight || _values.length > maxEntries) {
      remove(_values.keys.first);
    }
  }

  void remove(K key) {
    final old = _values.remove(key);
    if (old != null) _weight -= weight(old);
  }

  void clear() {
    _values.clear();
    _weight = 0;
  }
}

/// Speculative requests leave capacity available for visible content.
class ImageRequests {
  final _waiting = <_ImageRequest>[];
  final _known = <String, _ImageRequest>{};
  int _active = 0, _speculative = 0;
  bool _closed = false;
  Future<T> run<T>(
    String key,
    Future<T> Function() load, {
    bool speculative = false,
  }) {
    if (_closed) return Future.error(StateError('Image scheduler closed'));
    final existing = _known[key];
    if (existing != null) {
      if (!speculative) existing.speculative = false;
      _pump();
      return existing.result.future.then((value) => value as T);
    }
    final request = _ImageRequest(key, load, speculative);
    _known[key] = request;
    _waiting.add(request);
    _pump();
    return request.result.future.then((value) => value as T);
  }

  void _pump() {
    while (!_closed && _active < 4 && _waiting.isNotEmpty) {
      var index = _waiting.indexWhere((r) => !r.speculative);
      if (index < 0) {
        if (_speculative >= 1) return;
        index = 0;
      }
      final request = _waiting.removeAt(index);
      final speculative = request.speculative;
      _active++;
      if (speculative) _speculative++;
      Future.sync(request.load)
          .then(request.result.complete, onError: request.result.completeError)
          .whenComplete(() {
            _active--;
            if (speculative) _speculative--;
            _known.remove(request.key);
            _pump();
          });
    }
  }

  void close() {
    _closed = true;
    for (final request in _waiting) {
      request.result.completeError(StateError('Image scheduler closed'));
    }
    _waiting.clear();
  }
}

class _ImageRequest {
  _ImageRequest(this.key, this.load, this.speculative);
  final String key;
  final Future<dynamic> Function() load;
  bool speculative;
  final result = Completer<dynamic>();
}
