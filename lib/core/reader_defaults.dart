import 'dart:convert';

import 'models.dart';
import 'store.dart';

Json readerPreferenceChanges(Json previous, Json next) => {
  for (final entry in next.entries)
    if (previous[entry.key] != entry.value) entry.key: entry.value,
};

void writeReaderVolumePreferences(
  LocalStore store,
  String account,
  String key,
  Json changes, {
  Iterable<String> reset = const [],
}) {
  final patch = jsonEncode({for (final name in reset) name: null, ...changes});
  store.db.execute(
    '''
    INSERT INTO cache(server,key,value,updated) VALUES (?,?,json_patch('{}',?),?)
    ON CONFLICT(server,key) DO UPDATE SET
      value=json_patch(cache.value,?), updated=excluded.updated
  ''',
    [account, key, patch, DateTime.now().millisecondsSinceEpoch, patch],
  );
}

const _epubThemePreferenceKeys = {
  'theme',
  'colorScheme',
  'font',
  'fontWeight',
  'advancedLayout',
  'fontSize',
  'lineHeight',
  'margin',
  'columns',
  'alignment',
  'paragraphSpacing',
  'indent',
  'letterSpacing',
  'wordSpacing',
};

Json epubThemePreferences(Json values) => {
  for (final entry in values.entries)
    if (_epubThemePreferenceKeys.contains(entry.key)) entry.key: entry.value,
};

String epubSizeScale(num pixels) => '${(pixels / 19).toStringAsFixed(2)}×';
String epubMarginScale(num pixels) => '${(pixels / 24).toStringAsFixed(2)}×';

const _pdfRasterFields = <String, Set<String>>{
  'presentation': {'pageLayout', 'spread', 'mode'},
  'vertical': {'mode', 'direction'},
  'rtl': {'direction'},
  'coverSolo': {'soloCover'},
  'useSeriesDirection': {'useSeriesDirection', 'mode', 'direction'},
  'background': {'background'},
  'controlsGradient': {'controlsGradient'},
  'showProgress': {'showProgress'},
};

/// Global edits supersede older per-book values for the edited keys only.
void updateReaderDefaults(LocalStore store, String bucket, Json changes) {
  final resets = switch (bucket) {
    'readerDefault' => {
      'reader:': changes.keys,
      'pdf-raster:': changes.keys.where(
        (key) => !_pdfRasterFields.values.any((fields) => fields.contains(key)),
      ),
    },
    'epubDefault' => {'epub:': changes.keys},
    'pdfDefault' => {
      'pdf:': changes.keys,
      'pdf-raster:': changes.keys.expand(
        (key) => _pdfRasterFields[key] ?? const <String>{},
      ),
    },
    _ => <String, Iterable<String>>{},
  };
  store.transaction(() {
    store.setSetting(bucket, {
      ...object(store.setting<dynamic>(bucket)),
      ...changes,
    });
    for (final MapEntry(key: prefix, value: keys) in resets.entries) {
      final reset = keys.toSet();
      if (reset.isEmpty) continue;
      for (final row in store.db.select(
        'SELECT server,key,value FROM cache WHERE key LIKE ?',
        ['$prefix%'],
      )) {
        final saved = object(jsonDecode(row['value'] as String));
        if (!reset.any(saved.containsKey)) continue;
        for (final key in reset) {
          saved.remove(key);
        }
        store.db.execute('UPDATE cache SET value=? WHERE server=? AND key=?', [
          jsonEncode(saved),
          row['server'],
          row['key'],
        ]);
      }
    }
  });
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
      'doubleTapZoom': 2.0,
      'showProgress': true,
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
      'presentation': 'auto',
      'background': 'system',
      'controlsGradient': false,
      'showProgress': true,
      ...object(store.setting<dynamic>('pdfDefault')),
    });
    if (store.setting<dynamic>('progressRecordingThreshold') == null) {
      store.setSetting('progressRecordingThreshold', 3);
    }
  }
  store.setSetting('upstreamReaderDefaults', 1);
}
