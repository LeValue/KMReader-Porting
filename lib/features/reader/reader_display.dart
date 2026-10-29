import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Keeps reader display ownership across pushReplacement transitions, restoring
/// the application window only after the last comic reader has closed.
class ReaderDisplay extends StatefulWidget {
  const ReaderDisplay({
    super.key,
    required this.child,
    this.keepAwake = false,
    this.fullscreen = false,
    this.showKeyboardHelp = false,
  });
  final bool keepAwake, fullscreen, showKeyboardHelp;
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
  static int _readers = 0, _awakeReaders = 0;
  static bool _awake = false;
  static final _fullscreenOwners = <Object, bool>{};
  static bool _fullscreen = false;
  final _owner = Object();
  late final bool _native;
  bool _keyboardHints = false;
  Timer? _keyboardHintTimer;
  Widget get _content => Stack(
    alignment: Alignment.topLeft,
    fit: StackFit.expand,
    children: [
      widget.child,
      if (_keyboardHints)
        Positioned(
          top: 100,
          left: 24,
          right: 24,
          child: const IgnorePointer(
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0xdd202020),
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                ),
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    '← → · PgUp/PgDn · Space · Esc',
                    style: TextStyle(color: Color(0xffffffff), fontSize: 16),
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
  bool _awakeOwned = false;
  ValueListenable<TickerModeData>? _tickerMode;
  void _updateAwakeOwnership() {
    if (defaultTargetPlatform == TargetPlatform.windows && !kIsWeb) {
      _fullscreenOwners[_owner] =
          widget.fullscreen && (_tickerMode?.value.enabled ?? true);
      _publishFullscreen();
    }
    final wanted = widget.keepAwake && (_tickerMode?.value.enabled ?? true);
    if (wanted == _awakeOwned) return;
    _awakeOwned = wanted;
    _awakeReaders += wanted ? 1 : -1;
    _setAwake(_awakeReaders > 0 && _foreground);
  }

  static void _publishFullscreen() {
    final wanted = _fullscreenOwners.values.any((value) => value);
    if (wanted == _fullscreen) return;
    _fullscreen = wanted;
    unawaited(
      ReaderDisplay.channel
          .invokeMethod<void>('setFullscreen', wanted)
          .catchError((Object _) {}),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_native) return;
    final notifier = TickerMode.getValuesNotifier(context);
    if (notifier != _tickerMode) {
      _tickerMode?.removeListener(_updateAwakeOwnership);
      _tickerMode = notifier;
      notifier.addListener(_updateAwakeOwnership);
    }
    _updateAwakeOwnership();
  }

  static void _setAwake(bool enabled) {
    if (_awake == enabled) return;
    _awake = enabled;
    unawaited(() async {
      try {
        await ReaderDisplay.channel.invokeMethod<void>('setKeepAwake', enabled);
      } on MissingPluginException {
        /* Older native hosts and widget tests. */
      } on PlatformException {
        /* The OS retains control of its power policy. */
      }
    }());
  }

  static bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

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
    _keyboardHints =
        widget.showKeyboardHelp &&
        defaultTargetPlatform == TargetPlatform.windows;
    if (_keyboardHints) {
      _keyboardHintTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _keyboardHints = false);
      });
    }
    _android = defaultTargetPlatform == TargetPlatform.android && !kIsWeb;
    _native =
        !kIsWeb &&
        (_android || defaultTargetPlatform == TargetPlatform.windows);
    if (_native && !_android) WidgetsBinding.instance.addObserver(this);
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
  void didUpdateWidget(ReaderDisplay old) {
    super.didUpdateWidget(old);
    if (_native &&
        (widget.keepAwake != old.keepAwake ||
            widget.fullscreen != old.fullscreen)) {
      _updateAwakeOwnership();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_android && state == AppLifecycleState.resumed) unawaited(_set(true));
    if (_awakeReaders > 0) _setAwake(state == AppLifecycleState.resumed);
  }

  @override
  void didChangeMetrics() {
    if (!_android) return;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final open = views.first.viewInsets.bottom > 0;
    if (_keyboardOpen && !open) unawaited(_set(true));
    _keyboardOpen = open;
  }

  @override
  void dispose() {
    _keyboardHintTimer?.cancel();
    _tickerMode?.removeListener(_updateAwakeOwnership);
    _fullscreenOwners.remove(_owner);
    _publishFullscreen();
    if (_native && _awakeOwned && --_awakeReaders == 0) _setAwake(false);
    if (_native && !_android) WidgetsBinding.instance.removeObserver(this);
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
      if (media == null) return _content;
      final padding = _readerPadding(media, physical);
      return MediaQuery(
        data: media.copyWith(padding: padding, viewPadding: padding),
        child: _content,
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

/// The last mounted publication owns status-bar visibility across replacement.
class ReaderStatusBar extends StatefulWidget {
  const ReaderStatusBar({
    super.key,
    required this.visible,
    required this.child,
  });
  final bool visible;
  final Widget child;
  @override
  State<ReaderStatusBar> createState() => _ReaderStatusBarState();
}

class _ReaderStatusBarState extends State<ReaderStatusBar> {
  static final _owners = <Object, bool>{};
  final _owner = Object();
  void _update() {
    _owners[_owner] = widget.visible;
    _publish();
  }

  static void _publish() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    unawaited(
      ReaderDisplay.channel
          .invokeMethod<void>(
            'setReaderStatusBarVisible',
            _owners.isNotEmpty && _owners.values.last,
          )
          .catchError((Object _) {}),
    );
  }

  @override
  void initState() {
    super.initState();
    _update();
  }

  @override
  void didUpdateWidget(ReaderStatusBar old) {
    super.didUpdateWidget(old);
    if (old.visible != widget.visible) _update();
  }

  @override
  void dispose() {
    _owners.remove(_owner);
    _publish();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
