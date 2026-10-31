import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/models.dart';
import '../../core/external_links.dart';
import '../../core/repository.dart';
import '../../core/client_log.dart';
import '../../core/translation.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../../ui/reader_options.dart';
import '../../ui/theme.dart';
import 'epub_document.dart';
import 'epub_overlay.dart';
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
  bool _initialized = false, _controls = true, _fullscreen = false;
  bool _fixedLayout = false, _settingsOpen = false;
  bool _verticalWriting = false;
  final _closed = Completer<void>();
  String? _error, _selection, _actionSelection;
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
  }

  void _toggleFullscreen() {
    final enabled = !_fullscreen;
    ReaderDisplay.setFullscreen(context, enabled);
    setState(() {
      _fullscreen = enabled;
      _controls = !enabled;
    });
  }

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) HardwareKeyboard.instance.addHandler(_readerKey);
    _fullscreen =
        widget.repository.store.setting<bool>('autoFullscreenOnOpen') == true;
    _future = _open();
  }

  Future<void> _prepareEnvironment() async {
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
      assert(() {
        debugPrint('EPUB command $method started');
        return true;
      }());
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
      assert(() {
        debugPrint('EPUB command $method completed');
        return true;
      }());
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
    await _call('open', _session!.configuration(_nonce));
  }

  Future<void> _turn(int delta) async {
    final session = _session;
    if (session == null || !session.ready || session.auxiliary) return;
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
    assert(() {
      if (event['type'] == 'position') {
        debugPrint(
          'EPUB position: page=${event['page']} pages=${event['pages']} valid=${event['progression'] is num} changed=${event['changed']}',
        );
      }
      return true;
    }());
    switch (event['type']) {
      case 'ready':
        setState(() {
          _fixedLayout = event['layout'] == 'pre-paginated';
          _verticalWriting = text(event['writingMode']).startsWith('vertical');
        });
        break;
      case 'turn':
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
        setState(() => _selection = text(event['text']));
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

  Future<void> _search() async {
    final controller = TextEditingController();
    List<Json> results = [];
    bool searching = false;
    String? error;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => ReaderSafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              12,
              20,
              MediaQuery.viewInsetsOf(context).bottom + 12,
            ),
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .65,
              child: Column(
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: tr(context, 'Search'),
                    ),
                    onSubmitted: (query) async {
                      if (searching || query.trim().isEmpty) return;
                      update(() {
                        searching = true;
                        error = null;
                      });
                      try {
                        final value = await _call('search', query.trim());
                        final decoded = value is String
                            ? jsonDecode(value)
                            : value;
                        if (context.mounted) {
                          update(
                            () => results = (decoded as List? ?? [])
                                .map(object)
                                .toList(),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) update(() => error = e.toString());
                      } finally {
                        if (context.mounted) update(() => searching = false);
                      }
                    },
                  ),
                  if (searching) const LinearProgressIndicator(),
                  if (error != null) Text(error!),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final result in results)
                          ListTile(
                            title: Text(text(result['excerpt'])),
                            onTap: () {
                              Navigator.pop(context);
                              unawaited(_call('display', result['cfi']));
                            },
                          ),
                      ],
                    ).withWheelScrolling(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    controller.dispose();
  }

  Future<void> _bookmarks([String? selectedText]) async {
    final selected = selectedText ?? _selection ?? '';
    final session = _session!;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => ReaderSafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(CupertinoIcons.bookmark),
                title: Text(tr(context, 'Toggle Bookmark')),
                onTap: () {
                  session.toggleBookmark(selected);
                  update(() {});
                },
              ),
              for (final mark in session.bookmarks)
                ListTile(
                  title: Text(text(mark['label'])),
                  onTap: () {
                    Navigator.pop(context);
                    unawaited(_call('display', mark['cfi']));
                  },
                  trailing: IconButton(
                    tooltip: tr(context, 'Delete'),
                    icon: const Icon(CupertinoIcons.trash),
                    onPressed: () {
                      final values = session.bookmarks
                        ..removeWhere((v) => v['cfi'] == mark['cfi']);
                      widget.repository.store.cache(
                        widget.repository.profile.id,
                        session.bookmarkKey,
                        values,
                      );
                      update(() {});
                    },
                  ),
                ),
            ],
          ).withWheelScrolling(),
        ),
      ),
    );
  }

  Future<void> _translateSelection([String? selectedText]) async {
    final selected = selectedText ?? _selection;
    if (selected?.trim().isNotEmpty != true) return;
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
    if (_settingsOpen) return;
    _settingsOpen = true;
    await _call('suspendInput', true);
    var draft = _session!.preferences.toJson();
    if (!mounted) return;
    try {
      await showModalBottomSheet<void>(
        context: context,
        constraints: const BoxConstraints(maxWidth: 760),
        isScrollControlled: true,
        builder: (context) => StatefulBuilder(
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
              session.setPreferences(next);
              await session.prepareFont();
              if (!context.mounted) return;
              unawaited(_call('preferences', session.browserPreferences));
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
              onChanged: (v) => draft[key] = v,
              onChangeEnd: (v) => apply(key, v),
            );
            Widget picker(
              String title,
              String key,
              String value,
              Map<String, String> choices,
            ) => ReaderOptionPicker(
              title: title,
              value: value,
              choices: choices,
              onChanged: (v) => apply(key, v),
            );
            return ReaderSafeArea(
              child: ReaderOptionsPanel(
                title: 'Text Settings',
                children: [
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
                    title: 'Appearance',
                    children: [
                      picker('Theme', 'theme', p.theme, {
                        'system': 'System',
                        'white': 'white',
                        'sepia': 'sepia',
                        'black': 'black',
                        'quiet': 'Quiet',
                        'green': 'Green',
                      }),
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
                          session.setPreferences(
                            EpubPreferences.fromJson(draft),
                          );
                          unawaited(
                            _call('preferences', session.browserPreferences),
                          );
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
                      Navigator.pop(context);
                    },
                    child: Text(tr(context, 'Use as Default')),
                  ),
                ],
              ),
            );
          },
        ),
      );
    } finally {
      _settingsOpen = false;
      await _call('suspendInput', false);
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
    if (Platform.isWindows) HardwareKeyboard.instance.removeHandler(_readerKey);
    if (!_closed.isCompleted) _closed.complete();
    if (!_browserClosed.isCompleted) _browserClosed.complete();
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

  bool _readerKey(KeyEvent event) {
    assert(() {
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowRight) {
        debugPrint(
          'EPUB paging key: current=${ModalRoute.of(context)?.isCurrent}, options=$_settingsOpen, key=${event.logicalKey.keyLabel}',
        );
      }
      return true;
    }());
    return _key(event) == KeyEventResult.handled;
  }

  KeyEventResult _key(KeyEvent event) {
    if (!Platform.isWindows ||
        event is KeyUpEvent ||
        _settingsOpen ||
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
      }
    } else if (key == LogicalKeyboardKey.f11) {
      _toggleFullscreen();
    } else if (key == LogicalKeyboardKey.escape) {
      if (_selection?.isNotEmpty == true) {
        setState(() => _selection = '');
        unawaited(_call('clearSelection'));
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
      final brightness = session.dark ? Brightness.dark : Brightness.light;
      if (_readerTheme == null || _readerBrightness != brightness) {
        _readerBrightness = brightness;
        _readerTheme = appTheme(brightness);
      }
      return ReaderStatusBar(
        visible:
            widget.repository.store.setting<bool>(
              'epubShowsStatusBarWhileReading',
            ) ==
            true,
        child: Theme(
          data: _readerTheme!,
          child: Scaffold(
            backgroundColor: background,
            appBar: _controls
                ? AppBar(
                    backgroundColor: background,
                    title: Text(
                      epubOverlayText(context, session, 'controlsHeaderCenter'),
                    ),
                    actions: [
                      if (widget.incognito)
                        const Icon(CupertinoIcons.eye_slash),
                      if (session.auxiliary)
                        IconButton(
                          tooltip: tr(context, 'Back to Reading'),
                          onPressed: () => _call('closeAuxiliary'),
                          icon: const Icon(CupertinoIcons.arrow_uturn_left),
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
                      PopupMenuButton<String>(
                        onOpened: () => _actionSelection = _selection,
                        onSelected: (v) => switch (v) {
                          'contents' => _contents(),
                          'search' => _search(),
                          'bookmarks' => _bookmarks(_actionSelection),
                          'translate' => _translateSelection(_actionSelection),
                          _ => _settings(),
                        },
                        itemBuilder: (_) => [
                          for (final entry in {
                            'contents': 'Table of Contents',
                            'search': 'Search',
                            'bookmarks': 'Bookmarks',
                            if (_selection?.trim().isNotEmpty == true)
                              'translate': 'Translate Selected Text',
                            'settings': 'Text Settings',
                          }.entries)
                            PopupMenuItem(
                              value: entry.key,
                              child: Text(tr(context, entry.value)),
                            ),
                        ],
                      ),
                    ],
                  )
                : null,
            body: ReaderSafeArea(
              top: !_controls,
              bottom: !_controls,
              child: Column(
                children: [
                  if (!_controls)
                    EpubReadingOverlay(session: session, header: true),
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
                      children: [
                        if (_recoveryFailed)
                          FailureView(
                            error: tr(context, 'reader.recoveryFailed'),
                            retry: () => _restartBrowser(manual: true),
                          )
                        else if (!_recovering)
                          RepaintBoundary(child: _readerView(session)),
                        if (session.layoutBusy && session.ready && !_recovering)
                          const Align(
                            alignment: Alignment.bottomCenter,
                            child: LinearProgressIndicator(minHeight: 2),
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
                  if (!_controls)
                    EpubReadingOverlay(session: session, header: false),
                  if (!_controls &&
                      object(
                            widget.repository.store.setting<dynamic>(
                              'epubOverlay',
                            ),
                          )['showsReaderProgressBar'] ==
                          true)
                    LinearProgressIndicator(
                      value:
                          (session.chapter + session.progression) /
                          session.document.chapters.length,
                      minHeight: 3,
                    ),
                  if (_controls)
                    ReaderSafeArea(
                      top: false,
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: tr(context, 'Previous Page'),
                            onPressed: () => _turn(-1),
                            icon: const Icon(CupertinoIcons.chevron_left),
                          ),
                          Expanded(
                            child: Text(
                              epubOverlayText(
                                context,
                                session,
                                'controlsFooterCenter',
                              ),
                              key: const ValueKey('epub-position'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
                          ),
                          if (session.atEnd && widget.onNextBook != null)
                            IconButton(
                              tooltip: tr(context, 'Next Book'),
                              icon: const Icon(Icons.skip_next),
                              onPressed: widget.onNextBook,
                            ),
                          IconButton(
                            tooltip: tr(context, 'Next Page'),
                            onPressed: () => _turn(1),
                            icon: const Icon(CupertinoIcons.chevron_right),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
