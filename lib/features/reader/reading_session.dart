import 'package:flutter/foundation.dart';

import '../../core/models.dart';

class ReadingSession extends ChangeNotifier {
  ReadingSession({
    required this.count,
    required int initialPage,
    required this.preferences,
    required this.onCommit,
    this.incognito = false,
  }) : page = initialPage.clamp(1, count > 0 ? count : 1),
       _committed = initialPage;
  final int count;
  final bool incognito;
  final void Function(int) onCommit;
  ReaderPreferences preferences;
  int page;
  int _committed;
  int get step =>
      preferences.spread &&
          preferences.mode == ReadingMode.paged &&
          preferences.splitWide == 'none'
      ? 2
      : 1;
  int get _coverOffset => step == 2 && preferences.soloCover ? 1 : 0;
  int firstPage(int index) => _coverOffset == 1 && index == 0
      ? 1
      : _coverOffset + (index - _coverOffset) * step + 1;
  int indexForPage(int value) => _coverOffset == 1 && value == 1
      ? 0
      : _coverOffset + (value - _coverOffset - 1) ~/ step;
  int visiblePages(int index) => _coverOffset == 1 && index == 0 ? 1 : step;
  int get itemIndex => indexForPage(page);
  int get itemCount => _coverOffset + ((count - _coverOffset) / step).ceil();
  bool get atEnd => itemIndex + 1 >= itemCount;
  void go(int value) {
    if (count < 1) return;
    final next = value.clamp(1, count);
    if (next == page) return;
    page = next;
    notifyListeners();
  }

  void next() => go(firstPage((itemIndex + 1).clamp(0, itemCount - 1)));
  void previous() => go(firstPage((itemIndex - 1).clamp(0, itemCount - 1)));
  void rendered(int value) {
    if (indexForPage(value) != itemIndex || incognito || count == 0) return;
    final visible = (firstPage(itemIndex) + visiblePages(itemIndex) - 1).clamp(
      1,
      count,
    );
    if (_committed != visible) {
      _committed = visible;
      onCommit(visible);
    }
  }

  void configure(ReaderPreferences value) {
    preferences = value;
    notifyListeners();
  }
}
