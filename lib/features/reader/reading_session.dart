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
      preferences.spread && preferences.mode == ReadingMode.paged ? 2 : 1;
  int get itemIndex => (page - 1) ~/ step;
  int get itemCount => (count / step).ceil();
  bool get atEnd => page + step > count;
  void go(int value) {
    if (count < 1) return;
    final next = value.clamp(1, count);
    if (next == page) return;
    page = next;
    notifyListeners();
  }

  void next() => go(page + step);
  void previous() => go(page - step);
  void rendered(int value) {
    if ((value - 1) ~/ step != itemIndex || incognito || count == 0) return;
    final visible = (value + step - 1).clamp(1, count);
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
