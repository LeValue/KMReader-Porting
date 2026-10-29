import 'dart:convert';

import 'models.dart';
import 'store.dart';

/// Global changes take precedence over older per-book snapshots for those keys,
/// retaining locators, progress and unrelated book-specific choices.
void updateReaderDefaults(LocalStore store, String bucket, Json changes) {
  final prefix = const {
    'readerDefault': 'reader:',
    'epubDefault': 'epub:',
    'pdfDefault': 'pdf:',
  }[bucket];
  store.db.execute('SAVEPOINT reader_defaults');
  try {
    store.setSetting(bucket, {
      ...object(store.setting<dynamic>(bucket)),
      ...changes,
    });
    if (prefix != null) {
      for (final row in store.db.select(
        'SELECT server,key,value FROM cache WHERE key LIKE ?',
        ['$prefix%'],
      )) {
        final saved = object(jsonDecode(row['value'] as String));
        if (!changes.keys.any(saved.containsKey)) continue;
        for (final key in changes.keys) {
          saved.remove(key);
        }
        store.db.execute('UPDATE cache SET value=? WHERE server=? AND key=?', [
          jsonEncode(saved),
          row['server'],
          row['key'],
        ]);
      }
    }
    store.db.execute('RELEASE reader_defaults');
  } catch (_) {
    store.db.execute('ROLLBACK TO reader_defaults');
    store.db.execute('RELEASE reader_defaults');
    rethrow;
  }
}

/// Only new installations adopt the original defaults. Existing saved values
/// and legacy fallbacks are kept during upgrades.
void initializeReaderDefaults(LocalStore store) {
  if (store.setting<int>('upstreamReaderDefaults') != null) return;
  if (store.servers.isEmpty &&
      store.db.select('SELECT 1 FROM cache LIMIT 1').isEmpty) {
    store.setSetting('readerDefault', {
      'pageLayout': 'auto',
      'soloCover': true,
      'background': 'system',
      'showPageShadow': true,
      'controlsGradient': false,
      'showTapHints': true,
      'doubleTapZoom': 3.0,
      ...object(store.setting<dynamic>('readerDefault')),
    });
    store.setSetting('epubDefault', {
      'theme': 'system',
      'advancedLayout': false,
      'fontSize': 19.0,
      'lineHeight': 1.2,
      'indent': 2.0,
      ...object(store.setting<dynamic>('epubDefault')),
    });
    store.setSetting('pdfDefault', {
      'background': 'system',
      'controlsGradient': false,
      ...object(store.setting<dynamic>('pdfDefault')),
    });
    if (store.setting<dynamic>('progressRecordingThreshold') == null) {
      store.setSetting('progressRecordingThreshold', 3);
    }
  }
  store.setSetting('upstreamReaderDefaults', 1);
}
