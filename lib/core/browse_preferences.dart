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
  bool operator [](BrowseOption option) =>
      store.setting<bool>(option.key) ?? option.defaultValue;
  void set(BrowseOption option, bool value) {
    if (this[option] == value) return;
    store.setSetting(option.key, value);
    notifyListeners();
  }

  bool get overlaysText => this[BrowseOption.textOverlay];
  bool get hidesText => this[BrowseOption.coverOnly] && !overlaysText;
}
