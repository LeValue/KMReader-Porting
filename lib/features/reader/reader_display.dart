import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Keeps reader display ownership across pushReplacement transitions, restoring
/// the application window only after the last comic reader has closed.
class ReaderDisplay extends StatefulWidget {
  const ReaderDisplay({super.key, required this.child});
  final Widget child;
  static const channel = MethodChannel('dev.levalue.kmreader/reader_display');
  // Physical pixels from Android. Flutter's padding can become zero when
  // immersive mode hides system bars, even though the display cutout remains.
  static final _safeInsets = ValueNotifier<EdgeInsets>(EdgeInsets.zero);
  static final _cutoutInsets = ValueNotifier<EdgeInsets>(EdgeInsets.zero);
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
      final result = await ReaderDisplay.channel.invokeMethod<Object?>(
        'setReaderMode',
        enabled,
      );
      if (_readers > 0 && enabled) _updateInsets(result);
    } on MissingPluginException {
      // Desktop and widget tests do not have an Android window.
    }
  }

  static void _updateInsets(Object? value) {
    if (value is! Map) return;
    double edge(String key) =>
        math.max(0, (value[key] as num?)?.toDouble() ?? 0);
    ReaderDisplay._safeInsets.value = EdgeInsets.fromLTRB(
      edge('left'),
      edge('top'),
      edge('right'),
      edge('bottom'),
    );
    ReaderDisplay._cutoutInsets.value = EdgeInsets.fromLTRB(
      edge('cutoutLeft'),
      edge('cutoutTop'),
      edge('cutoutRight'),
      edge('cutoutBottom'),
    );
  }

  @override
  void initState() {
    super.initState();
    _android = defaultTargetPlatform == TargetPlatform.android && !kIsWeb;
    if (_android) {
      WidgetsBinding.instance.addObserver(this);
      if (_readers++ == 0) {
        ReaderDisplay.channel.setMethodCallHandler((call) async {
          if (call.method == 'readerInsets' && _readers > 0) {
            _updateInsets(call.arguments);
          }
        });
        unawaited(_set(true));
      }
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
      if (--_readers == 0) {
        ReaderDisplay.channel.setMethodCallHandler(null);
        scheduleMicrotask(() {
          if (_readers == 0) {
            ReaderDisplay._safeInsets.value = EdgeInsets.zero;
            ReaderDisplay._cutoutInsets.value = EdgeInsets.zero;
          }
        });
        unawaited(_set(false));
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<EdgeInsets>(
    valueListenable: ReaderDisplay._safeInsets,
    builder: (context, physical, _) {
      final media = MediaQuery.maybeOf(context);
      if (media == null) return widget.child;
      final padding = _readerPadding(media, physical);
      return MediaQuery(
        data: media.copyWith(padding: padding, viewPadding: padding),
        child: widget.child,
      );
    },
  );
}

/// Uses the available display without hiding page lettering under hardware.
/// System-bar space stays available; only the actual cutout is excluded.
class ReaderPageSurface extends StatelessWidget {
  const ReaderPageSurface({
    super.key,
    required this.child,
    this.extendIntoCutout = false,
  });
  final Widget child;
  final bool extendIntoCutout;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<EdgeInsets>(
    valueListenable: ReaderDisplay._cutoutInsets,
    builder: (context, physical, _) => Padding(
      padding: extendIntoCutout
          ? EdgeInsets.zero
          : physical / MediaQuery.devicePixelRatioOf(context),
      child: child,
    ),
  );
}

EdgeInsets _readerPadding(MediaQueryData media, EdgeInsets physical) {
  final native = physical / media.devicePixelRatio;
  double edge(double padding, double viewPadding, double cutout) =>
      math.max(padding, math.max(viewPadding, cutout));
  return EdgeInsets.fromLTRB(
    edge(media.padding.left, media.viewPadding.left, native.left),
    edge(media.padding.top, media.viewPadding.top, native.top),
    edge(media.padding.right, media.viewPadding.right, native.right),
    media.viewInsets.bottom > 0
        ? media.padding.bottom
        : edge(media.padding.bottom, media.viewPadding.bottom, native.bottom),
  );
}

/// Protects reader chrome and sheets without shrinking the page surface.
/// Insets remain valid with hidden bars and move to the sides after rotation.
class ReaderSafeArea extends StatelessWidget {
  const ReaderSafeArea({
    super.key,
    required this.child,
    this.top = true,
    this.bottom = true,
  });
  final Widget child;
  final bool top, bottom;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<EdgeInsets>(
    valueListenable: ReaderDisplay._safeInsets,
    builder: (context, physical, _) {
      final media = MediaQuery.of(context);
      return MediaQuery(
        data: media.copyWith(padding: _readerPadding(media, physical)),
        child: SafeArea(top: top, bottom: bottom, child: child),
      );
    },
  );
}
