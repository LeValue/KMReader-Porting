import 'package:flutter_test/flutter_test.dart';
import 'package:kmreader/core/browse_preferences.dart';
import 'package:kmreader/core/store.dart';
import 'package:sqlite3/sqlite3.dart';

class _CountingStore extends LocalStore {
  _CountingStore(super.db);
  int reads = 0;
  @override
  T? setting<T>(String key) {
    reads++;
    return super.setting<T>(key);
  }
}

void main() {
  test('catalog card preferences stay current without querying SQLite for every card', () {
    final store = _CountingStore(sqlite3.openInMemory());
    final preferences = BrowsePreferences(store);
    addTearDown(preferences.dispose);
    addTearDown(store.close);
    store.reads = 0;
    final watch = Stopwatch()..start();
    var enabled = 0;
    for (var card = 0; card < 20000; card++) {
      for (final option in BrowseOption.values) {
        if (preferences[option]) enabled++;
      }
    }
    watch.stop();
    // Record wall time for comparisons; functional acceptance uses database
    // access counts rather than machine-dependent timing thresholds.
    // ignore: avoid_print
    print(
      'Catalog preference benchmark: ${watch.elapsedMicroseconds} us, ${store.reads} SQL reads, enabled=$enabled',
    );
    expect(store.reads, lessThan(100));
    expect(preferences[BrowseOption.coverOnly], isFalse);
    // Other settings screens may write through LocalStore directly.
    store.setSetting(BrowseOption.coverOnly.key, true);
    expect(preferences[BrowseOption.coverOnly], isTrue);
    preferences.set(BrowseOption.coverOnly, false);
    expect(preferences[BrowseOption.coverOnly], isFalse);
    expect(store.setting<bool>(BrowseOption.coverOnly.key), isFalse);
  });
}
