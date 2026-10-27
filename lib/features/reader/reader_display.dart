import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Keeps reader display ownership across pushReplacement transitions, restoring
/// the application window only after the last comic reader has closed.
class ReaderDisplay extends StatefulWidget {
  const ReaderDisplay({super.key, required this.child});
  final Widget child;
  static const channel = MethodChannel('dev.levalue.kmreader/reader_display');
  @override
  State<ReaderDisplay> createState() => _ReaderDisplayState();
}

class _ReaderDisplayState extends State<ReaderDisplay>
    with WidgetsBindingObserver {
  static int _readers = 0;
  late final bool _android;
  bool _keyboardOpen = false;
  Future<void> _set(bool enabled) async {
    try {
      await ReaderDisplay.channel.invokeMethod<void>('setReaderMode', enabled);
    } on MissingPluginException {
      // Desktop and widget tests do not have an Android window.
    }
  }

  @override
  void initState() {
    super.initState();
    _android = defaultTargetPlatform == TargetPlatform.android && !kIsWeb;
    if (_android) {
      WidgetsBinding.instance.addObserver(this);
      if (_readers++ == 0) unawaited(_set(true));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_set(true));
  }

  @override
  void didChangeMetrics() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final open = views.first.viewInsets.bottom > 0;
    if (_keyboardOpen && !open) unawaited(_set(true));
    _keyboardOpen = open;
  }

  @override
  void dispose() {
    if (_android) {
      WidgetsBinding.instance.removeObserver(this);
      if (--_readers == 0) unawaited(_set(false));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
