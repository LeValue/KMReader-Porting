import '../../ui/reader_chrome.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/annotation_colors.dart';
import '../../core/models.dart';
import '../../core/external_links.dart';
import '../../core/repository.dart';
import '../../core/client_log.dart';
import '../../core/translation.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../../ui/reader_options.dart';
import '../../ui/theme.dart';
import 'epub_dictionary.dart';
import 'epub_document.dart';
import 'epub_overlay.dart';
import 'epub_reader_chrome.dart';
import 'epub_session.dart';
import 'reader_display.dart';
import 'tap_zones.dart';
import 'reader_text_page.dart';
import '../../ui/wheel_scroll.dart';

class BrowserEpubReader extends StatefulWidget {
  const BrowserEpubReader({
    super.key,
    required this.file,
    required this.repository,
    required this.book,
    this.incognito = false,
    this.onNextBook,
  });
  final File file;
  final Repository repository;
  final Book book;
  final bool incognito;
  final Future<void> Function()? onNextBook;
  @override
  State<BrowserEpubReader> createState() => _BrowserEpubReaderState();
}

class _BrowserEpubReaderState extends State<BrowserEpubReader> {
  late Future<EpubSession> _future;
  EpubSession? _session;
  InAppWebViewController? _browser;
  WebViewEnvironment? _environment;
  Widget? _webView;
  Completer<void> _browserClosed = Completer<void>();
  int _browserGeneration = 0, _recoveries = 0;
  bool _recovering = false, _recoveryFailed = false;
  bool _androidHybridComposition = false;
  bool _initialized = false, _controls = true, _fullscreen = false;
  Timer? _chromeTimer;
  AppLifecycleListener? _kindleLifecycle;
  Timer? _kindlePositionTimer;
  bool _checkingKindlePosition = false;
  Json? _dismissedKindlePosition;
  void _scheduleControlsHide() {
    _chromeTimer?.cancel();
    if (!_controls ||
        _sidePanel != null ||
        _settingsOpen ||
        _session?.ready != true) {
      return;
    }
    _chromeTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        setState(() => _controls = false);
      }
    });
  }

  bool _fixedLayout = false, _settingsOpen = false;
  final _selectionEvent = ValueNotifier<Json>({});
  final _panelFocus = FocusNode(debugLabel: 'EPUB right panel');
  WidgetBuilder? _sidePanel;
  Completer<void>? _sidePanelClosed;
  String? _sidePanelTitle;
  bool _searchPanelCompact = false;
  bool _searchPanelAtTop = false;
  int _searchGeneration = 0;
  String _activeSearchQuery = '';
  bool _verticalWriting = false;
  final _closed = Completer<void>();
  String? _error;
  String get _selection => text(_selectionEvent.value['text']);
  bool _turning = false;
  final _turns = <int>[];
  ThemeData? _readerTheme;
  Brightness? _readerBrightness;
  final _nonce = base64Url.encode(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );
  static Future<WebViewEnvironment>? _windowsEnvironment;

  @visibleForTesting
  InAppWebViewController? get browserController => _browser;

  @visibleForTesting
  String? get selectedText => _selection;

  void _showControls() {
    ReaderDisplay.setFullscreen(context, false);
    setState(() {
      _controls = true;
      _fullscreen = false;
    });
    _scheduleControlsHide();
  }

  void _toggleFullscreen() {
    final enabled = !_fullscreen;
    ReaderDisplay.setFullscreen(context, enabled);
    setState(() {
      _fullscreen = enabled;
      _controls = !enabled;
    });
    _scheduleControlsHide();
  }

  @override
  void initState() {
    super.initState();
    widget.repository.documentAnnotationChanges.addListener(
      _annotationsChanged,
    );
    if (Platform.isWindows) HardwareKeyboard.instance.addHandler(_readerKey);
    _fullscreen =
        widget.repository.store.setting<bool>('autoFullscreenOnOpen') == true;
    _future = _open();
    if (widget.repository.profile.isKindle && !widget.incognito) {
      _kindleLifecycle = AppLifecycleListener(
        onStateChange: (state) {
          _kindlePositionTimer?.cancel();
          if (state == AppLifecycleState.resumed) {
            _scheduleKindlePositionCheck();
            unawaited(_checkKindlePosition());
          }
        },
      );
      _scheduleKindlePositionCheck();
    }
  }

  bool get _readerInForeground =>
      mounted &&
      ModalRoute.of(context)?.isCurrent == true &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  void _scheduleKindlePositionCheck() {
    _kindlePositionTimer?.cancel();
    _kindlePositionTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_checkKindlePosition()),
    );
  }

  bool _canCheckKindlePosition(EpubSession session, {bool force = false}) =>
      _readerInForeground &&
      session.ready &&
      !session.auxiliary &&
      !session.layoutBusy &&
      !_turning &&
      !_settingsOpen &&
      widget.repository.canApplyDocumentPosition(widget.book, force: force);

  Future<void> _checkKindlePosition({bool force = false}) async {
    final session = _session;
    if (session == null ||
        _checkingKindlePosition ||
        !_canCheckKindlePosition(session, force: force)) {
      if (force && mounted) {
        _kindlePositionNotice('Kindle position unavailable');
      }
      return;
    }
    _checkingKindlePosition = true;
    final currentCfi = session.cfi;
    try {
      final initial = force ? null : session.initialKindleOffer;
      session.initialKindleOffer = null;
      final remote =
          initial ??
          await widget.repository.refreshDocumentPosition(
            widget.book,
            force: force,
          );
      if (remote == null ||
          !_canCheckKindlePosition(session, force: force) ||
          session.cfi != currentCfi ||
          session.chapterFor(text(remote['href'])) < 0 ||
          !force && mapEquals(remote, _dismissedKindlePosition)) {
        if (force && mounted) {
          _kindlePositionNotice('Kindle position unavailable');
        }
        return;
      }
      if (integer(remote['position']) + integer(remote['offset']) ==
          session.kindlePosition) {
        if (force || remote['acceptedConflict'] == true) {
          session.rememberKindleResume(remote);
        }
        return;
      }
      final automatic =
          force ||
          remote['acceptedConflict'] == true ||
          widget.repository.store.setting<bool>(
                'kindleAutoResume:${widget.repository.profile.id}',
              ) ==
              true;
      if (!automatic) {
        final choice = await _confirmKindlePosition(session, remote);
        if (choice != true) {
          _dismissedKindlePosition = remote;
          if (choice == false &&
              _canCheckKindlePosition(session) &&
              session.cfi == currentCfi) {
            session.keepKindlePosition(remote);
          }
          return;
        }
      }
      if (!_canCheckKindlePosition(session, force: force) ||
          session.cfi != currentCfi) {
        return;
      }
      final restored = await _call('resumeKindle', {
        ...session.kindleTarget(remote),
        'expectedCfi': currentCfi,
      });
      if (restored is Map &&
          mounted &&
          (session.cfi == currentCfi || session.cfi == restored['cfi']) &&
          widget.repository.canApplyDocumentPosition(
            widget.book,
            force: force,
          )) {
        session.receive({...object(restored), 'type': 'position'});
        session.rememberKindleResume(remote);
      } else {
        _dismissedKindlePosition = remote;
        if (force && mounted) {
          _kindlePositionNotice('Kindle position unavailable');
        }
      }
    } catch (_) {
      if (force && mounted) {
        _kindlePositionNotice('Kindle position unavailable');
      }
    } finally {
      _checkingKindlePosition = false;
    }
  }

  void _kindlePositionNotice(String key) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr(context, key))));

  Future<bool?> _confirmKindlePosition(EpubSession session, Json remote) async {
    final chapter = session.chapterFor(text(remote['href']));
    final updated = DateTime.tryParse(text(remote['displayModified']))
        ?.toLocal();
    final material = MaterialLocalizations.of(context);
    final title = tr(context, 'Resume reading from Kindle?');
    final details = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${tr(context, 'Current chapter')} · ${session.document.chapters[session.chapter].title}',
        ),
        Text(
          '${tr(context, 'Kindle chapter')} · ${session.document.chapters[chapter].title}',
        ),
        if (updated != null) ...[
          const SizedBox(height: 8),
          Text(
            '${tr(context, 'Last updated')} · ${material.formatShortDate(updated)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(updated))}',
          ),
        ],
      ],
    );
    List<Widget> actions(BuildContext dialog) => [
      TextButton(
        onPressed: () => Navigator.pop(dialog, false),
        child: Text(tr(dialog, 'Stay here')),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(dialog, true),
        child: Text(tr(dialog, 'Go to position')),
      ),
    ];
    if (MediaQuery.sizeOf(context).width < 600) {
      return showModalBottomSheet<bool>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheet) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(sheet).textTheme.titleLarge),
                const SizedBox(height: 16),
                details,
                const SizedBox(height: 16),
                OverflowBar(
                  spacing: 8,
                  alignment: MainAxisAlignment.end,
                  children: actions(sheet),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: details,
        scrollable: true,
        actions: actions(dialog),
      ),
    );
  }

  void _annotationsChanged() {
    if (mounted && _initialized && !widget.incognito) {
      unawaited(_call('annotations', _session?.readerAnnotations ?? []));
    }
  }

  Future<void> _prepareEnvironment() async {
    if (Platform.isAndroid) {
      final configuration = await ReaderDisplay.channel
          .invokeMapMethod<String, dynamic>('getEpubWebViewConfiguration');
      _androidHybridComposition = configuration?['hybridComposition'] == true;
    }
    if (Platform.isWindows) {
      if (await WebViewEnvironment.getAvailableVersion() == null) {
        throw StateError(
          'Install Microsoft Edge WebView2 Runtime to read EPUB books.',
        );
      }
      final pending = _windowsEnvironment ??= () async {
        final directory = await getApplicationCacheDirectory();
        final folder = Directory('${directory.path}/epub-browser');
        await folder.create(recursive: true);
        return WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: folder.path),
        );
      }();
      try {
        _environment = await pending;
      } catch (_) {
        if (identical(_windowsEnvironment, pending)) _windowsEnvironment = null;
        rethrow;
      }
    }
  }

  Future<EpubSession> _open() async {
    EpubSession? opened;
    try {
      await Future.wait<void>([
        EpubSession.open(
          widget.repository,
          widget.book,
          widget.file,
          incognito: widget.incognito,
        ).then<void>((session) => opened = session),
        _prepareEnvironment(),
      ]);
    } catch (_) {
      await opened?.close();
      rethrow;
    }
    final session = opened!;
    if (!mounted) {
      await session.close();
      throw StateError('Reader closed.');
    }
    _session = session;
    session.addListener(_changed);
    return session;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<dynamic> _call(String method, [dynamic value]) async {
    if (_browser == null || !mounted) return null;
    final generation = _browserGeneration;
    final browserClosed = _browserClosed.future;
    try {
      final work = _browser!.callAsyncJavaScript(
        functionBody:
            'return await window.reader.$method(${value == null ? '' : jsonEncode(value)});',
      );
      final result =
          await Future.any<CallAsyncJavaScriptResult?>([
            work,
            _closed.future.then((_) => null),
            browserClosed.then((_) => null),
          ]).timeout(
            Duration(
              seconds: method == 'search'
                  ? 60
                  : method == 'open'
                  ? 30
                  : 12,
            ),
          );
      if (generation != _browserGeneration) return null;
      if (result?.error != null) throw StateError(result!.error!);
      return result?.value;
    } catch (error) {
      if (mounted && generation == _browserGeneration) {
        setState(() => _error = error.toString());
      }
      return null;
    }
  }

  Future<void> _load() async {
    if (_initialized || _session == null || _browser == null) return;
    _initialized = true;
    _session!.darkEnvironment = Theme.of(context).brightness == Brightness.dark;
    await _call('open', {
      ..._session!.configuration(_nonce),
      'androidSelection': Platform.isAndroid,
      // A renderer that has just died must restore the readable publication
      // before attempting the same graphics path again. Keep saved preferences.
      if (_recoveries > 0) 'disableMotion': true,
    });
  }

  Future<void> _turn(int delta) async {
    final session = _session;
    if (session == null ||
        !session.ready ||
        session.auxiliary ||
        delta > 0 && session.atEnd) {
      return;
    }
    _scheduleControlsHide();
    if (_turning) {
      if (_turns.length < 8) _turns.add(delta);
      return;
    }
    _turning = true;
    final generation = _browserGeneration;
    try {
      await _call('turn', {
        'delta': delta,
        'style':
            session.preferences.animate &&
                !MediaQuery.disableAnimationsOf(context)
            ? session.preferences.transition
            : 'none',
      });
    } finally {
      if (generation == _browserGeneration) {
        _turning = false;
        if (mounted && _turns.isNotEmpty) unawaited(_turn(_turns.removeAt(0)));
      }
    }
  }

  Future<void> _restartBrowser({bool manual = false}) async {
    if (!mounted || _recovering || _session == null) return;
    if (manual) _recoveries = 0;
    if (_recoveries >= 2) {
      _session!.ready = false;
      if (!_browserClosed.isCompleted) _browserClosed.complete();
      setState(() {
        _browserGeneration++;
        _browser = null;
        _webView = null;
        _turning = false;
        _turns.clear();
        _recoveryFailed = true;
        _error = tr(context, 'reader.recoveryFailed');
      });
      return;
    }
    _recoveries++;
    ClientLog.instance.add('warning', 'epub', 'Recreating interrupted reader');
    _session!.save();
    _session!.ready = false;
    if (!_browserClosed.isCompleted) _browserClosed.complete();
    _browserClosed = Completer<void>();
    setState(() {
      _recovering = true;
      _recoveryFailed = false;
      _initialized = false;
      _error = null;
      _browser = null;
      _webView = null;
      _browserGeneration++;
      _turning = false;
      _turns.clear();
    });
    try {
      // Remove the failed native view before asking WebView2 for a new one.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      if (Platform.isWindows) {
        final old = _environment;
        _environment = null;
        _windowsEnvironment = null;
        try {
          await old?.dispose();
        } catch (_) {
          // The browser process may already have released this environment.
        }
        await _prepareEnvironment();
      }
      if (mounted) setState(() => _recovering = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _recovering = false;
          _recoveryFailed = true;
          _error = tr(context, 'reader.recoveryFailed');
        });
      }
    }
  }

  void _event(dynamic value) {
    if (!mounted ||
        value is! Map ||
        value['nonce'] != _nonce ||
        _session == null) {
      return;
    }
    final event = object(value);
    switch (event['type']) {
      case 'ready':
        if (_activeSearchQuery.isNotEmpty) {
          unawaited(_call('showSearch', _activeSearchQuery));
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scheduleControlsHide();
          if (_session?.initialKindleOffer != null) {
            unawaited(_checkKindlePosition());
          }
        });
        setState(() {
          _fixedLayout = event['layout'] == 'pre-paginated';
          _verticalWriting = text(event['writingMode']).startsWith('vertical');
        });
        break;
      case 'turn':
        _selectionEvent.value = {};
        unawaited(_turn(integer(event['delta'], 1)));
        return;
      case 'tap':
        // Mouse clicks select text; the explicit button/F11 owns fullscreen.
        if (Platform.isWindows &&
            event['pointerType'] != 'touch' &&
            event['pointerType'] != 'pen') {
          return;
        }
        final p = _session!.preferences;
        final action = p.flow == 'scrolled'
            ? TapAction.controls
            : tapAction(
                ((event['x'] as num?)?.toDouble() ?? .5),
                ((event['y'] as num?)?.toDouble() ?? .5),
                ReaderPreferences(
                  tapMode: p.tapMode,
                  tapInversion: p.tapInversion,
                  direction: _session!.host.direction == 'rtl'
                      ? ReadingDirection.rtl
                      : ReadingDirection.ltr,
                ),
              );
        if (action == TapAction.controls) {
          setState(() => _controls = !_controls);
          _scheduleControlsHide();
        } else {
          unawaited(_turn(action == TapAction.next ? 1 : -1));
        }
        return;
      case 'end':
        _session!.receive(event);
        unawaited(_finished());
        return;
      case 'error':
        setState(() => _error = text(event['message']));
        return;
      case 'controls':
        setState(() => _controls = !_controls);
        _scheduleControlsHide();
        return;
      case 'searchVisible':
        if (!Platform.isWindows &&
            _sidePanelTitle == 'Search' &&
            event['query'] == _activeSearchQuery) {
          FocusManager.instance.primaryFocus?.unfocus();
          setState(() {
            _searchPanelCompact = true;
            _searchPanelAtTop = event['lower'] == true;
          });
        }
        return;
      case 'fullscreen':
        _toggleFullscreen();
        return;
      case 'close':
        if (!_controls || _fullscreen) {
          _showControls();
        } else {
          Navigator.maybePop(context);
        }
        return;
      case 'selection':
        final selection = event['anchor'] is List ? event : <String, dynamic>{};
        if (!mapEquals(selection, _selectionEvent.value)) {
          _selectionEvent.value = selection;
        }
        return;
      case 'openNote':
        final marks = _session!.bookmarks;
        final note = marks
            .where((mark) => mark['id'] == event['id'])
            .firstOrNull;
        if (note != null) unawaited(_openNote(note));
        return;
      case 'link':
        unawaited(_link(text(event['href'])));
        return;
    }
    _session!.receive(event);
  }

  bool _endDialog = false;
  Future<void> _finished() async {
    if (_endDialog || !mounted) return;
    _endDialog = true;
    try {
      final next = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr(context, 'Book Completed')),
          content: Text(widget.book.title),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, 'Close')),
            ),
            if (widget.onNextBook != null)
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr(context, 'Next Book')),
              ),
          ],
        ),
      );
      if (next == true && mounted) {
        _session!.save();
        await widget.onNextBook?.call();
      }
    } finally {
      _endDialog = false;
    }
  }

  Future<void> _link(String href) async {
    final session = _session!;
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    final prefix = session.host.base.resolve('book/');
    if ((uri.scheme != prefix.scheme || uri.authority != prefix.authority) ||
        !uri.path.startsWith(prefix.path)) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr(context, 'External Link')),
          content: SelectableText(href),
          actions: [
            if (isExternalWebLink(uri))
              TextButton(
                onPressed: () async {
                  final failureMessage = tr(
                    context,
                    'Could not open the browser.',
                  );
                  try {
                    if (!await openExternalWebLink(uri)) {
                      throw StateError(failureMessage);
                    }
                    if (context.mounted) Navigator.pop(context);
                  } catch (error) {
                    if (context.mounted) {
                      showError(context, error);
                    }
                  }
                },
                child: Text(tr(context, 'Open in Browser')),
              ),
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: href));
                Navigator.pop(context);
              },
              child: Text(tr(context, 'Copy')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr(context, 'Close')),
            ),
          ],
        ),
      );
      return;
    }
    final path = Uri.decodeComponent(uri.path.substring(prefix.path.length));
    if (!session.document.isReadingResource(path)) return;
    if (session.document.chapters.any((chapter) => chapter.path == path)) {
      await _call(
        'display',
        session.relativeHref(path, fragment: uri.fragment),
      );
    } else {
      await _call('openAuxiliary', uri.toString());
    }
  }

  Future<void> _contents() async {
    final session = _session!;
    Widget node(EpubNavigationEntry entry) => entry.children.isNotEmpty
        ? ExpansionTile(
            initiallyExpanded: true,
            title: Text(entry.title),
            trailing: entry.location == null
                ? null
                : IconButton(
                    icon: const Icon(CupertinoIcons.arrow_right_circle),
                    onPressed: () => go(entry.location!),
                  ),
            children: entry.children.map(node).toList(),
          )
        : ListTile(
            title: Text(entry.title),
            onTap: entry.location == null ? null : () => go(entry.location!),
          );
    // The sheet closes before the browser receives navigation, preserving focus.
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => ReaderSafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .75,
          child: ListView(
            children: session.document.tableOfContents.map(node).toList(),
          ).withWheelScrolling(),
        ),
      ),
    );
  }

  void go(EpubLocation location) {
    Navigator.pop(context);
    unawaited(
      _call(
        'display',
        _session!.relativeHref(location.path, fragment: location.fragment),
      ),
    );
  }

  Future<List<Json>> _searchBook(String query) async {
    if (!Platform.isWindows && _sidePanelTitle == 'Search') {
      setState(() => _activeSearchQuery = query);
    } else {
      _activeSearchQuery = query;
    }
    final value = await _call('search', query);
    final decoded = value is String ? jsonDecode(value) : value;
    return (decoded as List? ?? []).map(object).toList();
  }

  Future<(ui.Image, int)?> _capturePageBeforeResize() async {
    final browser = _browser;
    if (browser == null || _session?.ready != true || _recovering) return null;
    try {
      final width =
          (await browser
                  .callAsyncJavaScript(
                    functionBody: 'return await reader.viewportBeforeResize();',
                  )
                  .timeout(const Duration(milliseconds: 160)))
              ?.value;
      if (width is! num) return null;
      final bytes = await browser.takeScreenshot().timeout(
        const Duration(milliseconds: 220),
      );
      if (bytes == null || !mounted || _browser != browser) return null;
      return (await decodeImageFromList(bytes), width.toInt());
    } catch (_) {
      // The sidebar still works while WebView2 recreates its surface.
      return null;
    }
  }

  Widget _readerToolbar(
    EpubSession session,
    Color background,
    Color foreground,
  ) {
    final activeBookmark = session.currentBookmark;
    Widget sidePanelButton(String title, IconData icon, VoidCallback? open) =>
        IconButton(
          tooltip: tr(context, title),
          icon: Icon(icon),
          isSelected: _sidePanelTitle == title,
          style: IconButton.styleFrom(
            backgroundColor: _sidePanelTitle == title
                ? foreground.withValues(alpha: .15)
                : Colors.transparent,
          ),
          onPressed: open,
        );
    return EpubToolbarLayout(
      leading: ReaderCapsule(
        background: background,
        foreground: foreground,
        child: IconButton(
          tooltip: tr(context, 'Close'),
          onPressed: () => Navigator.pop(context),
          icon: const Icon(CupertinoIcons.xmark),
        ),
      ),
      center: ReaderCapsule(
        background: background,
        foreground: foreground,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(
            epubOverlayText(context, session, 'controlsHeaderCenter'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      trailing: ReaderCapsule(
        background: background,
        foreground: foreground,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (session.auxiliary)
                IconButton(
                  tooltip: tr(context, 'Back to Reading'),
                  onPressed: () => _call('closeAuxiliary'),
                  icon: const Icon(CupertinoIcons.arrow_uturn_left),
                ),
              if (Platform.isWindows) ...[
                sidePanelButton('Search', Icons.search, _search),
                sidePanelButton(
                  'Bookmarks and annotations',
                  Icons.sticky_note_2_outlined,
                  widget.incognito ? null : _bookmarks,
                ),
                sidePanelButton('Text Settings', Icons.text_fields, _settings),
                IconButton(
                  tooltip: tr(context, 'Toggle Bookmark'),
                  onPressed:
                      widget.incognito ||
                          !session.ready ||
                          activeBookmark != null &&
                              !session.canRemoveAnnotation(activeBookmark)
                      ? null
                      : () => session.toggleBookmark(''),
                  isSelected: activeBookmark != null,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  selectedIcon: const Icon(Icons.bookmark),
                ),
                IconButton(
                  tooltip: tr(
                    context,
                    _fullscreen ? 'Exit Full Screen' : 'Full Screen',
                  ),
                  onPressed: _toggleFullscreen,
                  icon: const Icon(
                    CupertinoIcons.arrow_up_left_arrow_down_right,
                  ),
                ),
              ],
              PopupMenuButton<String>(
                onOpened: () => _chromeTimer?.cancel(),
                onCanceled: _scheduleControlsHide,
                onSelected: (v) => switch (v) {
                  'fullscreen' => _toggleFullscreen(),
                  'contents' => _contents(),
                  'search' => _search(),
                  'kindlePosition' => _checkKindlePosition(force: true),
                  'bookmarks' => _bookmarks(),
                  _ => _settings(),
                },
                itemBuilder: (_) => [
                  for (final entry in {
                    'contents': 'Table of Contents',
                    if (widget.repository.profile.isKindle && !widget.incognito)
                      'kindlePosition': 'Go to latest Kindle position',
                    if (!Platform.isWindows) ...{
                      'search': 'Search',
                      'bookmarks': 'Bookmarks and annotations',
                      'settings': 'Text Settings',
                      'fullscreen': _fullscreen
                          ? 'Exit Full Screen'
                          : 'Full Screen',
                    },
                  }.entries)
                    PopupMenuItem(
                      value: entry.key,
                      child: Text(tr(context, entry.value)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _readerLayout(Widget Function(Widget?) reader) {
    if (!Platform.isWindows) {
      final panel = _sidePanel;
      return Stack(
        fit: StackFit.expand,
        children: [
          reader(null),
          if (panel != null)
            LayoutBuilder(
              builder: (context, bounds) {
                final keyboard = MediaQuery.viewInsetsOf(context).bottom;
                final top = _searchPanelCompact && _searchPanelAtTop;
                final search = _sidePanelTitle == 'Search';
                final height = search
                    ? _searchPanelCompact
                          ? 48.0
                          : _activeSearchQuery.isEmpty || keyboard > 0
                          ? 62.0
                          : bounds.maxHeight * .56
                    : bounds.maxHeight * .50;
                return Align(
                  alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: top ? 0 : keyboard),
                    child: Semantics(
                      container: true,
                      child: SizedBox(
                        width: min(620, bounds.maxWidth),
                        height: min(
                          height,
                          max(0.0, bounds.maxHeight - keyboard),
                        ),
                        child: Material(
                          elevation: 6,
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(top ? 0 : 16),
                            bottom: Radius.circular(top ? 16 : 0),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: _searchPanelCompact
                              ? Row(
                                  children: [
                                    Expanded(
                                      child: TextButton.icon(
                                        onPressed: () => setState(
                                          () => _searchPanelCompact = false,
                                        ),
                                        icon: const Icon(
                                          Icons.search,
                                          size: 18,
                                        ),
                                        label: Text(tr(context, 'Search')),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: tr(context, 'Close'),
                                      onPressed: _closeSidePanel,
                                      icon: const Icon(Icons.close, size: 20),
                                    ),
                                  ],
                                )
                              : Builder(
                                  key: ValueKey(_sidePanelTitle),
                                  builder: panel,
                                ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      );
    }
    return EpubDesktopPanels(
      reader: reader,
      panel: _sidePanel == null
          ? null
          : Focus(
              focusNode: _panelFocus,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(left: 1),
                  child: Builder(
                    key: ValueKey(_sidePanelTitle),
                    builder: _sidePanel!,
                  ),
                ),
              ),
            ),
      capture: _capturePageBeforeResize,
      settle: (width) async {
        await _call(
          'viewportSettled',
          width,
        ).timeout(const Duration(milliseconds: 1200), onTimeout: () => null);
      },
    );
  }

  void _closeSidePanel() {
    final closed = _sidePanelClosed;
    if (closed == null) return;
    if (_sidePanelTitle == 'Search') _activeSearchQuery = '';
    _panelFocus.unfocus();
    setState(() {
      _sidePanel = null;
      _sidePanelTitle = null;
      _sidePanelClosed = null;
      _searchPanelCompact = false;
      _searchPanelAtTop = false;
    });
    closed.complete();
    _scheduleControlsHide();
  }

  Future<void> _showReaderPanel(
    String title,
    Widget Function(BuildContext panel, VoidCallback close) content, {
    double heightFraction = .65,
    bool dedicated = false,
    bool keyboard = false,
    bool withHeader = true,
    bool inline = false,
  }) async {
    if (!mounted) return;
    final theme = Theme.of(context);
    Widget panel(BuildContext context, VoidCallback close) => Theme(
      data: theme,
      child: Material(
        color: theme.scaffoldBackgroundColor,
        child: withHeader
            ? Column(
                children: [
                  EpubPanelHeader(title: title, close: close),
                  Expanded(child: content(context, close)),
                ],
              )
            : content(context, close),
      ),
    );
    if (Platform.isWindows || inline) {
      if (_sidePanelTitle == title) {
        _closeSidePanel();
        return;
      }
      _closeSidePanel();
      final closed = Completer<void>();
      _chromeTimer?.cancel();
      setState(() {
        _sidePanelTitle = title;
        _sidePanelClosed = closed;
        _sidePanel = (context) => panel(context, _closeSidePanel);
        _controls = true;
      });
      await closed.future;
      return;
    }
    if (dedicated) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (page) => Scaffold(
            body: ReaderSafeArea(child: panel(page, () => Navigator.pop(page))),
          ),
        ),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 620),
      barrierColor: withHeader ? null : Colors.transparent,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: theme.colorScheme.surface,
      builder: (sheet) {
        final size = MediaQuery.sizeOf(sheet);
        final inset = MediaQuery.viewInsetsOf(sheet).bottom;
        return Padding(
          padding: EdgeInsets.only(bottom: keyboard ? inset : 0),
          child: SizedBox(
            height: min(
              size.height * heightFraction,
              max(80, size.height - inset - 56),
            ),
            child: ReaderSafeArea(
              child: panel(sheet, () => Navigator.pop(sheet)),
            ),
          ),
        );
      },
    );
  }

  Future<void> _search([String initial = '']) async {
    if (_sidePanelTitle == 'Search') {
      _closeSidePanel();
      return;
    }
    final generation = ++_searchGeneration;
    final desktop = Platform.isWindows;
    var query = initial.trim(), submitted = query;
    final input = TextEditingController(text: query);
    Future<List<Json>>? request = query.isEmpty ? null : _searchBook(query);
    await _showReaderPanel(
      'Search',
      (context, close) => StatefulBuilder(
        builder: (context, update) {
          void submit() {
            final value = query.trim();
            if (value.isEmpty) return;
            update(() {
              submitted = value;
              request = _searchBook(value);
            });
            if (!desktop) FocusScope.of(context).unfocus();
          }

          void edit(String value) {
            final cleared = value.trim().isEmpty && submitted.isNotEmpty;
            update(() {
              query = value;
              if (cleared) {
                submitted = '';
                request = null;
              }
            });
            if (cleared) {
              if (desktop) {
                _activeSearchQuery = '';
              } else {
                setState(() => _activeSearchQuery = '');
              }
              unawaited(_call('clearSearch'));
            }
          }

          return Padding(
            padding: desktop
                ? const EdgeInsets.fromLTRB(14, 14, 14, 6)
                : const EdgeInsets.fromLTRB(10, 7, 5, 7),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: input,
                        autofocus: desktop && initial.isEmpty,
                        textInputAction: TextInputAction.search,
                        onChanged: edit,
                        decoration: InputDecoration(
                          hintText: tr(context, 'Search in book'),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 9,
                          ),
                          prefixIcon: IconButton(
                            tooltip: tr(context, 'Search'),
                            onPressed: submit,
                            icon: const Icon(Icons.search, size: 20),
                          ),
                          suffixIcon: query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: tr(context, 'Clear'),
                                  onPressed: () {
                                    input.clear();
                                    edit('');
                                  },
                                  icon: const Icon(Icons.clear, size: 18),
                                ),
                        ),
                        onSubmitted: (_) => submit(),
                      ),
                    ),
                    if (!desktop)
                      IconButton(
                        tooltip: tr(context, 'Close'),
                        onPressed: close,
                        icon: const Icon(Icons.close, size: 20),
                      ),
                  ],
                ),
                if (request != null &&
                    (desktop ||
                        MediaQuery.viewInsetsOf(context).bottom == 0)) ...[
                  const SizedBox(height: 9),
                  Expanded(
                    child: FutureBuilder(
                      future: request,
                      builder: (context, result) {
                        if (result.connectionState != ConnectionState.done) {
                          return const Align(
                            alignment: Alignment.topCenter,
                            child: LinearProgressIndicator(),
                          );
                        }
                        if (result.hasError) {
                          return Center(
                            child: Text(tr(context, 'Search unavailable')),
                          );
                        }
                        final matches = result.data ?? [];
                        if (matches.isEmpty) {
                          return Center(child: Text(tr(context, 'No results')));
                        }
                        return ListView.separated(
                          itemCount: matches.length + 1,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: Text(
                                  '${matches.length} ${tr(context, 'Search results')}',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                              );
                            }
                            final hit = matches[index - 1];
                            final excerpt = text(hit['excerpt']);
                            final parts = <TextSpan>[];
                            var start = 0;
                            final pattern = RegExp(
                              RegExp.escape(submitted),
                              caseSensitive: false,
                            );
                            for (final match in pattern.allMatches(excerpt)) {
                              parts.add(
                                TextSpan(
                                  text: excerpt.substring(start, match.start),
                                ),
                              );
                              parts.add(
                                TextSpan(
                                  text: match.group(0),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              );
                              start = match.end;
                            }
                            parts.add(TextSpan(text: excerpt.substring(start)));
                            final section = _session!.chapterFor(
                              text(hit['href']),
                            );
                            return Material(
                              borderRadius: BorderRadius.circular(10),
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerLow,
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: () {
                                  FocusScope.of(context).unfocus();
                                  if (!Platform.isWindows && mounted) {
                                    setState(() => _searchPanelCompact = true);
                                  }
                                  unawaited(_call('jumpToSearchResult', hit));
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (section >= 0) ...[
                                        Text(
                                          _session!
                                              .document
                                              .chapters[section]
                                              .title,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelMedium,
                                        ),
                                        const SizedBox(height: 5),
                                      ],
                                      Text.rich(TextSpan(children: parts)),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ).withWheelScrolling();
                      },
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
      withHeader: desktop,
      inline: true,
    );
    await WidgetsBinding.instance.endOfFrame;
    input.dispose();
    if (mounted && generation == _searchGeneration) await _call('clearSearch');
  }

  Widget _contextActions(Json selection) {
    final values = selection['anchor'];
    if (values is! List ||
        values.length != 4 ||
        values.any((v) => v is! num || !v.isFinite)) {
      return const SizedBox.shrink();
    }
    final anchor = Rect.fromLTRB(
      (values[0] as num).toDouble(),
      (values[1] as num).toDouble(),
      (values[2] as num).toDouble(),
      (values[3] as num).toDouble(),
    );
    final selected = text(selection['text']);
    final hasRange = selection['rangeCfi'] is String && !widget.incognito;
    ({String label, IconData icon, VoidCallback invoke}) action(
      String label,
      IconData icon,
      Future<void> Function() run,
    ) => (
      label: label,
      icon: icon,
      invoke: () {
        _selectionEvent.value = {};
        unawaited(_call('clearSelection'));
        unawaited(run());
      },
    );
    return EpubSelectionMenu(
      anchor: anchor,
      touch: !Platform.isWindows,
      actions: [
        if (selected.trim().isNotEmpty) ...[
          action(
            'Copy',
            Icons.copy_outlined,
            () => Clipboard.setData(ClipboardData(text: selected)),
          ),
          if (hasRange)
            action(
              'Highlight',
              Icons.highlight_outlined,
              () => _annotate(selection),
            ),
          if (dictionaryWord(selected) != null)
            action(
              'Dictionary',
              Icons.menu_book_outlined,
              () => _dictionary(selected),
            ),
          if (hasRange)
            action(
              'Add Note',
              Icons.edit_note,
              () => _annotate(selection, note: true),
            ),
          action('Search Selection', Icons.search, () => _search(selected)),
          action(
            'Translate Selected Text',
            Icons.translate,
            () => _translateSelection(selected),
          ),
        ] else if (selection['context'] == true) ...[
          action('Search', Icons.search, _search),
          action('Text Settings', Icons.text_fields, _settings),
        ],
      ],
    );
  }

  Future<void> _dictionary(String selection) async {
    final word = dictionaryWord(selection);
    final session = _session;
    if (word == null || session == null) return;
    final language = dictionaryLanguage(session.host.language);
    final request = widget.repository.offline
        ? Future<List<String>>.value([])
        : lookupDictionary(word, language);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => ReaderSafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheet).height * .5,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            children: [
              Text(
                tr(sheet, 'Dictionary'),
                style: Theme.of(sheet).textTheme.titleMedium,
              ),
              Text(word, style: Theme.of(sheet).textTheme.headlineSmall),
              const SizedBox(height: 12),
              FutureBuilder<List<String>>(
                future: request,
                builder: (context, result) {
                  if (result.connectionState != ConnectionState.done) {
                    return const LinearProgressIndicator();
                  }
                  final meanings = result.data ?? [];
                  if (meanings.isEmpty) {
                    return Text(
                      tr(context, 'Dictionary definition unavailable'),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final meaning in meanings)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(meaning),
                        ),
                    ],
                  );
                },
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: () => openExternalWebLink(
                    Uri.https('$language.wiktionary.org', '/wiki/$word'),
                  ),
                  child: Text(tr(sheet, 'Open Wiktionary')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _annotate(
    Json selection, {
    bool note = false,
    String previous = '',
  }) async {
    final session = _session;
    if (session == null || widget.incognito || selection['rangeCfi'] == null) {
      return;
    }
    String? body;
    String? color;
    if (note) {
      var value = previous;
      body = await showDialog<String>(
        context: context,
        builder: (dialog) => Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 16,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) => SizedBox(
              width: min(540, constraints.maxWidth),
              height: min(380, constraints.maxHeight),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      tr(context, previous.isEmpty ? 'Add Note' : 'Edit Note'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: TextFormField(
                        initialValue: previous,
                        autofocus: true,
                        expands: true,
                        minLines: null,
                        maxLines: null,
                        maxLength: 4000,
                        keyboardType: TextInputType.multiline,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (text) => value = text,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialog),
                            child: Text(tr(context, 'Cancel')),
                          ),
                          FilledButton(
                            onPressed: () =>
                                Navigator.pop(dialog, value.trim()),
                            child: Text(tr(context, 'Save')),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      if (body?.isNotEmpty != true) return;
    } else {
      color = await showDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(tr(dialog, 'Highlight color')),
          scrollable: true,
          content: SizedBox(
            width: 320,
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final entry in annotationColors.entries)
                  ChoiceChip(
                    label: Text(tr(dialog, entry.key)),
                    avatar: Icon(
                      Icons.circle,
                      size: 12,
                      color: _annotationInk(entry.value),
                    ),
                    selected:
                        entry.value == annotationColor(selection['color']),
                    showCheckmark: false,
                    onSelected: (_) => Navigator.pop(dialog, entry.value),
                  ),
              ],
            ),
          ),
        ),
      );
      if (color == null) return;
    }
    if (!mounted || !identical(session, _session)) return;
    if (session.saveAnnotation(selection, note: body, color: color)) {
      _annotationsChanged();
    }
  }

  Color _annotationInk(String hex) =>
      Color(0xff000000 | int.parse(hex.substring(1), radix: 16));

  Future<void> _quickNavigation() async {
    final session = _session!;
    final total = session.totalBookPages;
    final controller = TextEditingController();
    var progress = session.bookProgress;
    String? action;
    final target = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (context) => StatefulBuilder(
        builder: (context, update) => ReaderSafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              16 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Naviga nel volume',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  total == null
                      ? '${(progress * 100).round()}%'
                      : 'Pagina ~${(progress * total).floor().clamp(0, total - 1) + 1} di $total · ${(progress * 100).round()}%',
                ),
                Slider(
                  value: progress,
                  onChanged: (value) => update(() => progress = value),
                  onChangeEnd: (value) => Navigator.pop(context, value),
                ),
                if (total != null)
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: controller,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: 'Vai alla pagina (1–$total)',
                          ),
                          onSubmitted: (value) {
                            final page = int.tryParse(value);
                            if (page != null && page >= 1 && page <= total) {
                              Navigator.pop(context, (page - 1) / total);
                            }
                          },
                        ),
                      ),
                      IconButton(
                        tooltip: 'Vai',
                        onPressed: () {
                          final page = int.tryParse(controller.text);
                          if (page != null && page >= 1 && page <= total) {
                            Navigator.pop(context, (page - 1) / total);
                          }
                        },
                        icon: const Icon(Icons.arrow_forward),
                      ),
                    ],
                  ),
                const SizedBox(height: 10),
                Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    TextButton(
                      onPressed: session.chapter == 0
                          ? null
                          : () {
                              action = 'previous';
                              Navigator.pop(context);
                            },
                      child: const Text('Capitolo precedente'),
                    ),
                    TextButton(
                      onPressed:
                          session.chapter >=
                              session.document.chapters.length - 1
                          ? null
                          : () {
                              action = 'next';
                              Navigator.pop(context);
                            },
                      child: const Text('Capitolo successivo'),
                    ),
                    TextButton(
                      onPressed: () {
                        action = 'contents';
                        Navigator.pop(context);
                      },
                      child: Text(tr(context, 'Table of Contents')),
                    ),
                    if (!Platform.isWindows)
                      TextButton(
                        onPressed: () {
                          action = 'bookmarks';
                          Navigator.pop(context);
                        },
                        child: Text(tr(context, 'Bookmarks and annotations')),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    controller.dispose();
    if (!mounted) return;
    if (target != null) {
      final (chapter, progression) =
          session.pageIndex?.target(target) ??
          (
            (target * session.document.chapters.length).floor().clamp(
              0,
              session.document.chapters.length - 1,
            ),
            (target * session.document.chapters.length) % 1,
          );
      await _call('seek', {
        'href': session.relativeHref(session.document.chapters[chapter].path),
        'progression': progression,
      });
    } else if (action == 'contents') {
      await _contents();
    } else if (action == 'bookmarks') {
      await _bookmarks();
    } else if (action == 'previous' || action == 'next') {
      final chapter = (session.chapter + (action == 'next' ? 1 : -1)).clamp(
        0,
        session.document.chapters.length - 1,
      );
      await _call('seek', {
        'href': session.relativeHref(session.document.chapters[chapter].path),
        'progression': 0,
      });
    }
  }

  Future<void> _bookmarks() async {
    final session = _session!;
    var filter = 'all';
    String? color;
    var chapterFilter = -1;
    var filtersOpen = false;
    (String, Object)? selected;
    (String, Object) markKey(Json mark) =>
        (EpubSession.markType(mark), EpubSession.markRange(mark));
    await _showReaderPanel(
      'Bookmarks and annotations',
      (context, close) => ListenableBuilder(
        listenable: Listenable.merge([
          session,
          widget.repository.documentAnnotationChanges,
        ]),
        builder: (context, _) => StatefulBuilder(
          builder: (context, update) {
            final marks = session.bookmarks;
            final active = session.currentBookmark;
            final links = EpubAnnotationLinks(marks, session.chapterFor);
            final markChapters = {
              for (final mark in marks)
                text(mark['href']): session.chapterFor(text(mark['href'])),
            };
            final chapters = {
              for (final index in markChapters.values)
                if (index >= 0) index: session.document.chapters[index].title,
            };
            const types = {
              'all': 'All',
              'kindle.bookmark': 'Bookmarks',
              'kindle.highlight': 'Highlights',
              'kindle.note': 'Notes',
            };
            final inks = {
              for (final mark in marks)
                if (EpubSession.markType(mark) != 'kindle.bookmark')
                  links.colorFor(mark): links.colorFor(mark),
              for (final entry in annotationColors.entries)
                entry.value: tr(context, entry.key),
            };
            final selectedChapter = chapters.containsKey(chapterFilter)
                ? chapterFilter
                : -1;
            final selectedInk = inks.containsKey(color) ? color : null;
            final visible =
                marks.where((mark) {
                  final type = EpubSession.markType(mark);
                  if (selectedChapter >= 0 &&
                      markChapters[text(mark['href'])] != selectedChapter) {
                    return false;
                  }
                  if (selectedInk != null &&
                      (type == 'kindle.bookmark' ||
                          links.colorFor(mark) != selectedInk)) {
                    return false;
                  }
                  if (filter != 'all') return type == filter;
                  final highlight = links.highlightFor(mark);
                  return highlight == null ||
                      links.notesFor(highlight).firstOrNull?['id'] !=
                          mark['id'];
                }).toList()..sort((a, b) {
                  final chapter = session
                      .chapterFor(text(a['href']))
                      .compareTo(session.chapterFor(text(b['href'])));
                  if (chapter != 0) return chapter;
                  final start = a['kindleStart'], other = b['kindleStart'];
                  return start is int && other is int
                      ? start.compareTo(other)
                      : text(a['created']).compareTo(text(b['created']));
                });
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                EpubPanelHeader(
                  title: 'Bookmarks and annotations',
                  close: close,
                  trailing: IconButton(
                    tooltip: tr(context, 'Filters'),
                    isSelected: filtersOpen,
                    icon: const Icon(Icons.tune),
                    selectedIcon: const Icon(Icons.filter_list_off),
                    onPressed: () => update(() => filtersOpen = !filtersOpen),
                  ),
                ),
                if (!Platform.isWindows)
                  ListTile(
                    leading: Icon(
                      session.hasCurrentBookmark
                          ? Icons.bookmark
                          : Icons.bookmark_add_outlined,
                    ),
                    title: Text(tr(context, 'Toggle Bookmark')),
                    onTap:
                        widget.incognito ||
                            !session.ready ||
                            active != null &&
                                !session.canRemoveAnnotation(active)
                        ? null
                        : () => session.toggleBookmark(''),
                  ),
                if (filtersOpen)
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: min(
                        325,
                        MediaQuery.sizeOf(context).height * .42,
                      ),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            tr(context, 'Type'),
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          EpubAnnotationFilterGrid<String>(
                            options: [
                              for (final entry in types.entries)
                                (
                                  value: entry.key,
                                  label:
                                      '${tr(context, entry.value)} (${entry.key == 'all' ? marks.length : marks.where((mark) => EpubSession.markType(mark) == entry.key).length})',
                                  color: null,
                                ),
                            ],
                            selected: filter,
                            select: (value) => update(() => filter = value),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            tr(context, 'Color'),
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          EpubAnnotationFilterGrid<String?>(
                            options: [
                              (
                                value: null,
                                label: tr(context, 'All'),
                                color: null,
                              ),
                              for (final entry in inks.entries)
                                (
                                  value: entry.key,
                                  label: entry.value,
                                  color: _annotationInk(entry.key),
                                ),
                            ],
                            selected: selectedInk,
                            select: (value) => update(() => color = value),
                          ),
                          if (chapters.length > 1) ...[
                            const SizedBox(height: 8),
                            DropdownButton<int>(
                              isExpanded: true,
                              value: selectedChapter,
                              onChanged: (value) =>
                                  update(() => chapterFilter = value ?? -1),
                              items: [
                                DropdownMenuItem(
                                  value: -1,
                                  child: Text(tr(context, 'All chapters')),
                                ),
                                for (final entry in chapters.entries)
                                  DropdownMenuItem(
                                    value: entry.key,
                                    child: Text(
                                      entry.value,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: visible.isEmpty
                      ? Center(child: Text(tr(context, 'No annotations')))
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
                          itemCount: visible.length,
                          separatorBuilder: (_, _) => const Divider(height: 9),
                          itemBuilder: (context, i) {
                            final mark = visible[i];
                            final type = EpubSession.markType(mark);
                            final note = type == 'kindle.note'
                                ? mark
                                : links.notesFor(mark).firstOrNull;
                            final highlight = type == 'kindle.note'
                                ? links.highlightFor(mark)
                                : mark;
                            final chapter = session.chapterFor(
                              text(mark['href']),
                            );
                            final isBookmark = type == 'kindle.bookmark';
                            final excerpt = text(
                              highlight?['excerpt'],
                              text(mark['excerpt']),
                            );
                            final title = chapter < 0
                                ? ''
                                : session.document.chapters[chapter].title;
                            final markLabel = text(mark['label']);
                            final key = markKey(mark);
                            final canAddNote =
                                !isBookmark &&
                                note == null &&
                                mark['rangeCfi'] != null;
                            return EpubAnnotationTile(
                              key: ValueKey(key),
                              accent: isBookmark
                                  ? null
                                  : _annotationInk(links.colorFor(mark)),
                              icon: isBookmark
                                  ? Icons.bookmark_outline
                                  : note == null
                                  ? Icons.highlight_outlined
                                  : Icons.sticky_note_2_outlined,
                              label: tr(
                                context,
                                isBookmark
                                    ? 'Bookmark'
                                    : type == 'kindle.note'
                                    ? 'Note'
                                    : 'Annotation highlight',
                              ),
                              chapter: title,
                              body: isBookmark
                                  ? markLabel == title
                                        ? ''
                                        : markLabel
                                  : excerpt,
                              selected:
                                  selected == key ||
                                  selected == null &&
                                      session.isCurrentBookmark(mark),
                              open: () {
                                if (Platform.isWindows) {
                                  update(() => selected = key);
                                } else {
                                  close();
                                }
                                unawaited(_jumpToAnnotation(mark));
                              },
                              delete: session.canRemoveAnnotation(mark)
                                  ? () => _deleteMark(mark)
                                  : null,
                              noteLabel: note != null
                                  ? text(note['label'])
                                  : canAddNote
                                  ? tr(context, 'Add Note')
                                  : null,
                              openNote: note != null
                                  ? () => _openNote(note)
                                  : canAddNote
                                  ? () => _annotate({
                                      ...mark,
                                      'text': excerpt,
                                    }, note: true)
                                  : null,
                            );
                          },
                        ).withWheelScrolling(),
                ),
              ],
            );
          },
        ),
      ),
      dedicated: true,
      withHeader: false,
    );
  }

  Future<void> _jumpToAnnotation(Json mark) async {
    final session = _session!;
    if (EpubSession.markType(mark) == 'kindle.bookmark') {
      final chapter = session.chapterFor(text(mark['href']));
      if (chapter < 0 ||
          session.isCurrentBookmark(mark) && !session.auxiliary) {
        return;
      }
      await _call('jumpToBookmark', {
        'href': session.relativeHref(session.document.chapters[chapter].path),
        'cfi': ?mark['cfi'],
        'locator': ?mark['locator'],
      });
      return;
    }
    if (mark['locator'] is Map && mark['cfi'] == null) {
      final chapter = session.chapterFor(text(mark['href']));
      if (chapter < 0) return;
      await _call('seek', {
        'href': session.relativeHref(session.document.chapters[chapter].path),
        'locator': mark['locator'],
      });
    } else {
      await _call('display', mark['cfi']);
    }
  }

  Future<void> _openNote(Json note) async {
    final action = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(tr(dialog, 'Note')),
        scrollable: true,
        content: SelectableText(text(note['label'])),
        actions: [
          if (_session!.canRemoveAnnotation(note))
            TextButton(
              onPressed: () => Navigator.pop(dialog, 'delete'),
              child: Text(tr(dialog, 'Delete')),
            ),
          if (note['rangeCfi'] != null)
            TextButton(
              onPressed: () => Navigator.pop(dialog, 'edit'),
              child: Text(tr(dialog, 'Edit Note')),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(tr(dialog, 'Close')),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'edit') {
      await _annotate(
        {...note, 'text': note['excerpt']},
        note: true,
        previous: text(note['label']),
      );
    } else if (action == 'delete') {
      await _deleteMark(note);
    }
  }

  Future<void> _deleteMark(Json mark) async {
    final session = _session!;
    if (!session.canRemoveAnnotation(mark)) return;
    final hasRelated = EpubAnnotationLinks(
      session.bookmarks,
      session.chapterFor,
    ).relatedTo(mark).any(session.canRemoveAnnotation);
    if (!await confirm(
          context,
          'Delete',
          hasRelated
              ? 'Delete the note and its highlight?'
              : 'Delete this annotation?',
        ) ||
        !mounted) {
      return;
    }
    session.removeAnnotation(mark);
    _annotationsChanged();
  }

  Future<void> _translateSelection([String? selectedText]) async {
    final selected = selectedText ?? _selection;
    if (selected.trim().isEmpty) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderDisplay(
          child: ReaderTextPage(
            initialText: selected,
            providers: TranslationProviders(widget.repository.store),
            title: widget.book.title,
            incognito: widget.incognito,
          ),
        ),
      ),
    );
  }

  Future<void> _settings() async {
    if (_settingsOpen) {
      if (_sidePanelTitle == 'Text Settings') {
        _closeSidePanel();
      }
      return;
    }
    _settingsOpen = true;
    final session = _session!;
    var draft = session.preferences.toJson();
    String? applied = jsonEncode(draft);
    var pending = Future<void>.value();
    void preview() {
      final settings = jsonEncode(draft);
      if (applied == settings) return;
      applied = settings;
      final value = EpubPreferences.fromJson(draft);
      pending = pending
          .then((_) async {
            if (!mounted || applied != settings) return;
            session.setPreferences(value);
            await session.prepareFont();
            if (mounted) await _call('preferences', session.browserPreferences);
          })
          .catchError((Object error) {
            if (mounted) showError(context, error);
          });
    }

    try {
      await _showReaderPanel(
        'Text Settings',
        (context, close) => StatefulBuilder(
          builder: (context, update) {
            final session = _session!, p = EpubPreferences.fromJson(draft);
            Future<void> apply(String key, dynamic value) async {
              final next = EpubPreferences.fromJson({
                ...draft,
                key: key == 'columns' && value is String
                    ? int.tryParse(value) ?? 0
                    : value,
                if (const {
                  'fontSize',
                  'lineHeight',
                  'paragraphSpacing',
                  'indent',
                  'letterSpacing',
                  'wordSpacing',
                  'alignment',
                }.contains(key))
                  'advancedLayout': true,
              });
              draft = next.toJson();
              preview();
              update(() {});
            }

            Widget slider(
              String title,
              String key,
              double value,
              double min,
              double max,
              int divisions,
            ) => ReaderOptionSlider(
              key: ValueKey('epub-$key'),
              title: title,
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: (v) {
                draft[key] = v;
                if (const {
                  'fontSize',
                  'lineHeight',
                  'paragraphSpacing',
                  'indent',
                  'letterSpacing',
                  'wordSpacing',
                }.contains(key)) {
                  draft['advancedLayout'] = true;
                }
              },
              onChangeEnd: (v) => apply(key, v),
            );
            Widget picker(
              String title,
              String key,
              String value,
              Map<String, String> choices,
            ) => ReaderOptionPicker(
              key: ValueKey('epub-$key'),
              title: title,
              value: value,
              choices: choices,
              onChanged: (v) => apply(key, v),
            );
            return ReaderSafeArea(
              top: false,
              child: ReaderOptionsPanel(
                title: 'Text Settings',
                onClose: close,
                fill: true,
                useAppPalette: true,
                compact: !Platform.isWindows,
                children: [
                  if (_fixedLayout)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Text(
                        tr(context, 'This book uses a fixed page layout.'),
                      ),
                    )
                  else
                    ReaderOptionGroup(
                      title: 'Typography',
                      children: [
                        picker('Font', 'font', p.font, {
                          'publisher': 'Publisher Font',
                          'serif': 'Serif',
                          'sans-serif': 'Sans Serif',
                          for (final font in session.fonts.fonts)
                            'custom:${font['id']}': text(font['name']),
                        }),
                        slider(
                          'Text Size',
                          'fontSize',
                          p.fontSize,
                          4.75,
                          76,
                          75,
                        ),
                      ],
                    ),
                  ReaderOptionGroup(
                    title: 'Appearance',
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 5,
                          children: [
                            for (final (value, label, color) in const [
                              ('system', 'System', Color(0xff8193ab)),
                              ('white', 'white', Color(0xfffafafa)),
                              ('black', 'black', Color(0xff1c1c1c)),
                              ('sepia', 'sepia', Color(0xffe9d7b7)),
                              ('green', 'Green', Color(0xffc8e8d2)),
                              ('quiet', 'Quiet', Color(0xffe2e1dd)),
                            ])
                              ChoiceChip(
                                selected: p.theme == value,
                                label: Text(tr(context, label)),
                                avatar: CircleAvatar(backgroundColor: color),
                                onSelected: (_) => apply('theme', value),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  ReaderOptionGroup(
                    title: 'Reading',
                    children: [
                      picker('epub.reading_flow', 'flow', p.flow, {
                        'paged': 'Paged',
                        'scrolled': 'Vertical',
                      }),
                      if (!_verticalWriting)
                        picker('Columns', 'columns', '${p.columns}', {
                          '0': 'Automatic',
                          '1': '1',
                          '2': '2',
                        }),
                    ],
                  ),
                  if (!_fixedLayout)
                    ReaderOptionGroup(
                      title: 'Page layout',
                      children: [
                        slider(
                          'Line Height',
                          'lineHeight',
                          p.lineHeight,
                          .5,
                          3,
                          25,
                        ),
                        slider('Page Margins', 'margin', p.margin, 0, 100, 20),
                        picker(
                          'epub.text_alignment.title',
                          'alignment',
                          p.alignment,
                          {
                            'publisher':
                                'epub.text_alignment.publisher_default',
                            'left': 'left',
                            'right': 'right',
                            'justify': 'justify',
                            'center': 'center',
                          },
                        ),
                        slider(
                          'Paragraph Spacing',
                          'paragraphSpacing',
                          p.paragraphSpacing,
                          0,
                          3,
                          30,
                        ),
                        slider(
                          'Paragraph Indent',
                          'indent',
                          p.indent,
                          0,
                          8,
                          20,
                        ),
                        slider(
                          'Letter Spacing',
                          'letterSpacing',
                          p.letterSpacing,
                          -.05,
                          1,
                          105,
                        ),
                        slider(
                          'Word Spacing',
                          'wordSpacing',
                          p.wordSpacing,
                          0,
                          1,
                          20,
                        ),
                        ListTile(
                          leading: const Icon(Icons.add),
                          title: Text(tr(context, 'Import Font')),
                          onTap: () async {
                            try {
                              final font = await session.fonts.importFont();
                              if (font != null && context.mounted) {
                                await apply('font', 'custom:${font['id']}');
                              }
                            } catch (error) {
                              if (context.mounted) {
                                showError(context, error);
                              }
                            }
                          },
                        ),
                        for (final font in session.fonts.fonts)
                          ListTile(
                            title: Text(text(font['name'])),
                            trailing: IconButton(
                              tooltip: tr(context, 'Delete'),
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                if (!await confirm(
                                  context,
                                  'Delete',
                                  text(font['name']),
                                )) {
                                  return;
                                }
                                await session.fonts.remove(text(font['id']));
                                if (p.font == 'custom:${font['id']}') {
                                  await apply('font', 'publisher');
                                } else {
                                  update(() {});
                                }
                              },
                            ),
                          ),
                      ],
                    ),
                  ReaderOptionGroup(
                    title: 'Page Turn',
                    children: [
                      SwitchListTile.adaptive(
                        title: Text(tr(context, 'Animate Page Turns')),
                        value: p.animate,
                        onChanged: (v) => apply('animate', v),
                      ),
                      picker(
                        'Page Transition Style',
                        'transition',
                        p.transition,
                        {
                          'slide': 'reader.page_transition.scroll',
                          'cover': 'reader.page_transition.cover',
                          'curl': 'reader.page_transition.page_curl',
                          'none': 'None',
                        },
                      ),
                      ReaderMotionOptions(
                        motion: p.motion,
                        onChanged: (motion) {
                          draft = {...draft, ...motion.toJson()};
                          preview();
                          update(() {});
                        },
                      ),
                    ],
                  ),
                  ReaderOptionGroup(
                    title: 'Tap Zones',
                    children: [
                      picker('Tap Zones', 'tapMode', p.tapMode, {
                        for (final mode in [
                          'none',
                          'default',
                          'edge',
                          'kindle',
                          'lShape',
                          'tSplit',
                        ])
                          mode: 'reader.tapZoneMode.$mode',
                      }),
                      picker(
                        'Tap Zone Inversion',
                        'tapInversion',
                        p.tapInversion,
                        {
                          for (final mode in ['auto', 'normal', 'inverted'])
                            mode: 'reader.tapZoneInversionMode.$mode',
                        },
                      ),
                    ],
                  ),
                  OutlinedButton(
                    onPressed: () {
                      widget.repository.store.setSetting(
                        'epubDefault',
                        p.toJson(),
                      );
                      close();
                    },
                    child: Text(tr(context, 'Use as Default')),
                  ),
                ],
              ),
            );
          },
        ),
        inline: true,
        withHeader: false,
      );
    } finally {
      preview();
      await pending;
      _settingsOpen = false;
      if (mounted) _scheduleControlsHide();
    }
  }

  Widget _readerView(EpubSession session) {
    final generation = _browserGeneration;
    return _webView ??= InAppWebView(
      key: ValueKey(generation),
      webViewEnvironment: _environment,
      initialUrlRequest: URLRequest(
        url: WebUri(session.host.reader.toString()),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        disableContextMenu: true,
        // Retain texture composition where supported. Huawei Android 10 needs
        // hybrid composition to deliver visible frames; diagnostic builds can
        // explicitly compare both paths without changing saved preferences.
        useHybridComposition:
            const bool.hasEnvironment('KMREADER_EPUB_HYBRID_COMPOSITION')
            ? const bool.fromEnvironment('KMREADER_EPUB_HYBRID_COMPOSITION')
            : _androidHybridComposition,
        useOnRenderProcessGone: true,
        allowFileAccess: false,
        allowContentAccess: false,
        useShouldOverrideUrlLoading: true,
        transparentBackground: false,
        supportZoom: false,
        isInspectable: false,
      ),
      onWebViewCreated: (controller) {
        if (!mounted || generation != _browserGeneration) return;
        _browser = controller;
        controller.addJavaScriptHandler(
          handlerName: 'readerEvent',
          callback: (args) {
            if (mounted &&
                generation == _browserGeneration &&
                args.isNotEmpty) {
              _event(args.first);
            }
            return null;
          },
        );
      },
      onLoadStop: (_, _) async {
        if (generation == _browserGeneration) await _load();
      },
      onRenderProcessGone: (_, _) {
        if (generation == _browserGeneration) unawaited(_restartBrowser());
      },
      shouldOverrideUrlLoading: (controller, action) async {
        final uri = action.request.url;
        if (uri == null) {
          return NavigationActionPolicy.CANCEL;
        }
        if (!action.isForMainFrame &&
            uri.scheme == 'about' &&
            ['blank', 'srcdoc'].contains(uri.path)) {
          return NavigationActionPolicy.ALLOW;
        }
        if (!action.isForMainFrame &&
            uri.scheme == 'blob' &&
            uri.path.startsWith(session.host.base.origin)) {
          return NavigationActionPolicy.ALLOW;
        }
        return uri.scheme == session.host.base.scheme &&
                uri.authority == session.host.base.authority &&
                uri.path.startsWith(session.host.base.path)
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL;
      },
      onReceivedError: (_, request, error) {
        if (request.isForMainFrame == true &&
            mounted &&
            generation == _browserGeneration) {
          setState(() => _error = error.description);
        }
      },
    );
  }

  @override
  void dispose() {
    _kindleLifecycle?.dispose();
    _kindlePositionTimer?.cancel();
    widget.repository.documentAnnotationChanges.removeListener(
      _annotationsChanged,
    );
    if (Platform.isWindows) HardwareKeyboard.instance.removeHandler(_readerKey);
    if (!_closed.isCompleted) _closed.complete();
    if (!_browserClosed.isCompleted) _browserClosed.complete();
    _chromeTimer?.cancel();
    _selectionEvent.dispose();
    _panelFocus.dispose();
    _sidePanelClosed?.complete();
    _session?.removeListener(_changed);
    unawaited(_session?.close() ?? Future.value());
    super.dispose();
  }

  Future<void> _copySelection() async {
    final selected = await _call('selectedText');
    if (selected is String && selected.trim().isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: selected));
    }
  }

  bool _readerKey(KeyEvent event) => _key(event) == KeyEventResult.handled;

  KeyEventResult _key(KeyEvent event) {
    if (!Platform.isWindows ||
        event is KeyUpEvent ||
        _panelFocus.hasFocus ||
        ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey, rtl = _session?.host.direction == 'rtl';
    if (HardwareKeyboard.instance.isControlPressed &&
        key == LogicalKeyboardKey.keyC) {
      unawaited(_copySelection());
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent &&
        [
          LogicalKeyboardKey.f11,
          LogicalKeyboardKey.space,
          LogicalKeyboardKey.escape,
        ].contains(key)) {
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.pageUp) {
      final forward =
          key == LogicalKeyboardKey.pageDown ||
          key ==
              (rtl
                  ? LogicalKeyboardKey.arrowLeft
                  : LogicalKeyboardKey.arrowRight);
      unawaited(_turn(forward ? 1 : -1));
    } else if (key == LogicalKeyboardKey.space) {
      if (widget.repository.store.setting<String>('spaceKeyAction') ==
          'nextPage') {
        unawaited(_turn(1));
      } else {
        setState(() => _controls = !_controls);
        _scheduleControlsHide();
      }
    } else if (key == LogicalKeyboardKey.f11) {
      _toggleFullscreen();
    } else if (key == LogicalKeyboardKey.escape) {
      if (_selectionEvent.value.isNotEmpty) {
        _selectionEvent.value = {};
        unawaited(_call('clearSelection'));
      } else if (_sidePanel != null) {
        _closeSidePanel();
      } else if (!_controls || _fullscreen) {
        _showControls();
      } else {
        Navigator.maybePop(context);
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<EpubSession>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Scaffold(
          appBar: AppBar(title: Text(widget.book.title)),
          body: FailureView(
            error: snapshot.error!,
            retry: () => setState(() => _future = _open()),
          ),
        );
      }
      if (!snapshot.hasData) {
        return Scaffold(
          appBar: AppBar(title: Text(widget.book.title)),
          body: const Center(child: CircularProgressIndicator.adaptive()),
        );
      }
      final session = snapshot.data!;
      session.darkEnvironment = Theme.of(context).brightness == Brightness.dark;
      final background = Color(
        int.parse(session.themeColors.$1.substring(1), radix: 16) | 0xff000000,
      );
      final foreground = Color(
        int.parse(session.themeColors.$2.substring(1), radix: 16) | 0xff000000,
      );
      final brightness = session.dark ? Brightness.dark : Brightness.light;
      if (_readerTheme == null || _readerBrightness != brightness) {
        _readerBrightness = brightness;
        _readerTheme = appTheme(brightness);
      }
      final reader = ReaderStatusBar(
        visible:
            widget.repository.store.setting<bool>(
              'epubShowsStatusBarWhileReading',
            ) ==
            true,
        child: Theme(
          data: _readerTheme!,
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            backgroundColor: background,
            body: MouseRegion(
              onHover: (event) {
                final box = context.findRenderObject();
                if (box is RenderBox) {
                  final y = box.globalToLocal(event.position).dy;
                  if (y < 70 || y > box.size.height - 70) {
                    if (!_controls) setState(() => _controls = true);
                    _scheduleControlsHide();
                  }
                }
              },
              child: ReaderSafeArea(
                top: true,
                bottom: true,
                maintainBottomViewPadding: true,
                child: _readerLayout(
                  (pageCover) => Column(
                    children: [
                      if (_error != null)
                        MaterialBanner(
                          content: Text(_error!),
                          actions: [
                            TextButton(
                              onPressed: () => _restartBrowser(manual: true),
                              child: Text(tr(context, 'Retry')),
                            ),
                            TextButton(
                              onPressed: () => setState(() => _error = null),
                              child: Text(tr(context, 'Close')),
                            ),
                          ],
                        ),
                      Expanded(
                        key: const ValueKey('epub-surface-slot'),
                        child: Stack(
                          fit: StackFit.expand,
                          clipBehavior: pageCover == null
                              ? Clip.hardEdge
                              : Clip.none,
                          children: [
                            if (_recoveryFailed)
                              FailureView(
                                error: tr(context, 'reader.recoveryFailed'),
                                retry: () => _restartBrowser(manual: true),
                              )
                            else if (!_recovering)
                              RepaintBoundary(child: _readerView(session)),
                            ?pageCover,
                            if (_controls)
                              Positioned(
                                top: 8,
                                left: 12,
                                right: 12,
                                child: _readerToolbar(
                                  session,
                                  background,
                                  foreground,
                                ),
                              ),
                            if (!_controls) ...[
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                child: EpubReadingOverlay(
                                  session: session,
                                  header: true,
                                ),
                              ),
                              Positioned(
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: EpubReadingOverlay(
                                  session: session,
                                  header: false,
                                ),
                              ),
                            ],
                            if (_controls)
                              Positioned(
                                bottom: 8,
                                left: 20,
                                right: 20,
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 360,
                                    ),
                                    child: ReaderCapsule(
                                      background: background,
                                      foreground: foreground,
                                      child: Row(
                                        children: [
                                          IconButton(
                                            tooltip: tr(
                                              context,
                                              'Previous Page',
                                            ),
                                            onPressed: () => _turn(-1),
                                            icon: const Icon(
                                              CupertinoIcons.chevron_left,
                                            ),
                                          ),
                                          Expanded(
                                            child: TextButton(
                                              style: TextButton.styleFrom(
                                                foregroundColor: foreground,
                                              ),
                                              onPressed: _quickNavigation,
                                              child: Text(
                                                epubOverlayText(
                                                  context,
                                                  session,
                                                  'controlsFooterCenter',
                                                ),
                                                key: const ValueKey(
                                                  'epub-position',
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                          ),
                                          if (session.atEnd &&
                                              widget.onNextBook != null)
                                            IconButton(
                                              tooltip: tr(context, 'Next Book'),
                                              icon: const Icon(Icons.skip_next),
                                              onPressed: widget.onNextBook,
                                            ),
                                          IconButton(
                                            tooltip: tr(context, 'Next Page'),
                                            onPressed: () => _turn(1),
                                            icon: const Icon(
                                              CupertinoIcons.chevron_right,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (!_controls &&
                                object(
                                      widget.repository.store.setting<dynamic>(
                                        'epubOverlay',
                                      ),
                                    )['showsReaderProgressBar'] ==
                                    true)
                              Positioned(
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: LinearProgressIndicator(
                                  value:
                                      (session.chapter + session.progression) /
                                      session.document.chapters.length,
                                  minHeight: 3,
                                ),
                              ),
                            if (session.layoutBusy &&
                                session.ready &&
                                !_recovering)
                              const Align(
                                alignment: Alignment.bottomCenter,
                                child: LinearProgressIndicator(minHeight: 2),
                              ),
                            if (session.ready)
                              ValueListenableBuilder(
                                valueListenable: _selectionEvent,
                                builder: (context, selection, _) =>
                                    selection.isEmpty
                                    ? const SizedBox.shrink()
                                    : _contextActions(selection),
                              ),
                            if (!session.ready && !_recoveryFailed)
                              ColoredBox(
                                color: background,
                                child: const Center(
                                  child: CircularProgressIndicator.adaptive(),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      return PopScope(
        canPop: Platform.isWindows || _sidePanel == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && !Platform.isWindows && _sidePanel != null) {
            _closeSidePanel();
          }
        },
        child: reader,
      );
    },
  );
}
