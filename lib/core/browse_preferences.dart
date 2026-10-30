import 'package:flutter/foundation.dart';

import 'store.dart';

enum BrowseOption {
  ignoreSearchFilters('searchIgnoreFilters', false),
  textOverlay('cardTextOverlayMode', false),
  coverOnly('coverOnlyCards', false),
  seriesTitle('showBookCardSeriesTitle', true),
  preserveAspectRatio('thumbnailPreserveAspectRatio', true),
  shadow('thumbnailShowShadow', true),
  badges('thumbnailShowUnreadIndicator', true),
  blurUnread('thumbnailBlurUnreadCovers', false),
  progress('thumbnailShowProgressBar', true);

  const BrowseOption(this.key, this.defaultValue);
  final String key;
  final bool defaultValue;
}

class BrowsePreferences extends ChangeNotifier {
  BrowsePreferences(this.store);
  final LocalStore store;
  int _revision = -1;
  Map<BrowseOption, bool> _values = {};
  bool operator [](BrowseOption option) {
    if (_revision != store.settingsRevision) {
      _values = {
        for (final item in BrowseOption.values)
          item: store.setting<bool>(item.key) ?? item.defaultValue,
      };
      _revision = store.settingsRevision;
    }
    return _values[option]!;
  }

  void set(BrowseOption option, bool value) {
    if (this[option] == value) return;
    store.setSetting(option.key, value);
    notifyListeners();
  }

  bool get overlaysText => this[BrowseOption.textOverlay];
  bool get hidesText => this[BrowseOption.coverOnly] && !overlaysText;
}
