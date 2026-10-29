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
import '../../core/translation.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../../ui/theme.dart';
import 'epub_document.dart';
import 'epub_session.dart';
import 'reader_display.dart';
import 'tap_zones.dart';
import 'reader_text_page.dart';

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
  bool _initialized = false, _controls = true;
  bool _fixedLayout = false;
  final _closed = Completer<void>();
  String? _error, _selection;
  bool _turning = false;
  final _turns = <int>[];
  ThemeData? _readerTheme;
  Brightness? _readerBrightness;
  final _nonce = base64Url.encode(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );
  static Future<WebViewEnvironment>? _windowsEnvironment;

  @override
  void initState() {
    super.initState();
    _future = _open();
  }

  Future<EpubSession> _open() async {
    if (Platform.isWindows) {
      if (await WebViewEnvironment.getAvailableVersion() == null) {
        throw StateError(
          'Install Microsoft Edge WebView2 Runtime to read EPUB books.',
        );
      }
      _environment = await (_windowsEnvironment ??= () async {
        final directory = await getApplicationCacheDirectory();
        final folder = Directory('${directory.path}/epub-browser');
        await folder.create(recursive: true);
        return WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: folder.path),
        );
      }());
    }
    final session = await EpubSession.open(
      widget.repository,
      widget.book,
      widget.file,
      incognito: widget.incognito,
    );
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
          ]).timeout(
            Duration(
              seconds: method == 'search'
                  ? 60
                  : method == 'open'
                  ? 30
                  : 12,
            ),
          );
      if (result?.error != null) throw StateError(result!.error!);
      assert(() {
        debugPrint('EPUB command $method completed');
        return true;
      }());
      return result?.value;
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
      return null;
    }
  }

  Future<void> _load() async {
    if (_initialized || _session == null || _browser == null) return;
    _initialized = true;
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
    try {
      Uint8List? snapshot;
      if (session.preferences.transition != 'none') {
        try {
          snapshot = await _browser
              ?.takeScreenshot(
                screenshotConfiguration: ScreenshotConfiguration(
                  compressFormat: CompressFormat.JPEG,
                  quality: 85,
                ),
              )
              .timeout(const Duration(milliseconds: 250));
        } catch (_) {
          /* A missing animation snapshot must never block a page. */
        }
      }
      await _call('turn', {
        'delta': delta,
        'style': session.preferences.transition,
        if (snapshot != null)
          'snapshot': 'data:image/jpeg;base64,${base64Encode(snapshot)}',
      });
    } finally {
      _turning = false;
      if (mounted && _turns.isNotEmpty) unawaited(_turn(_turns.removeAt(0)));
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
        setState(() => _fixedLayout = event['layout'] == 'pre-paginated');
        break;
      case 'turn':
        unawaited(_turn(integer(event['delta'], 1)));
        return;
      case 'tap':
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
      case 'close':
        Navigator.maybePop(context);
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
                    if (context.mounted) showError(context, error);
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
          ),
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
                    ),
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

  Future<void> _bookmarks() async {
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
                  session.toggleBookmark(_selection ?? '');
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
          ),
        ),
      ),
    );
  }

  Future<void> _translateSelection() async {
    if (_selection?.trim().isNotEmpty != true) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderDisplay(
          child: ReaderTextPage(
            initialText: _selection,
            providers: TranslationProviders(widget.repository.store),
            title: widget.book.title,
            incognito: widget.incognito,
          ),
        ),
      ),
    );
  }

  Future<void> _settings() async {
    var draft = _session!.preferences.toJson();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final session = _session!, p = EpubPreferences.fromJson(draft);
          Future<void> apply(String key, dynamic value) async {
            final next = EpubPreferences.fromJson({...draft, key: value});
            draft = next.toJson();
            session.setPreferences(next);
            await session.prepareFont();
            if (!context.mounted) return;
            unawaited(_call('preferences', session.browserPreferences));
            update(() {});
          }

          Widget slider(
            String label,
            String key,
            double value,
            double min,
            double max,
            int steps,
          ) => Column(
            children: [
              Row(
                children: [
                  Expanded(child: Text(tr(context, label))),
                  Text(value.toStringAsFixed(2)),
                ],
              ),
              Slider(
                value: value,
                min: min,
                max: max,
                divisions: steps,
                onChanged: (v) => update(() => draft[key] = v),
                onChangeEnd: (v) => apply(key, v),
              ),
            ],
          );
          return ReaderSafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .78,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(context, 'Text Settings'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final flow in ['paged', 'scrolled'])
                          ChoiceChip(
                            label: Text(
                              tr(
                                context,
                                flow == 'paged' ? 'Paged' : 'Vertical',
                              ),
                            ),
                            selected: p.flow == flow,
                            onSelected: (_) => apply('flow', flow),
                          ),
                      ],
                    ),
                    if (_fixedLayout)
                      Text(tr(context, 'This book uses a fixed page layout.'))
                    else ...[
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final font in [
                            'publisher',
                            'serif',
                            'sans-serif',
                          ])
                            ChoiceChip(
                              label: Text(
                                tr(
                                  context,
                                  {
                                    'publisher': 'Publisher Font',
                                    'serif': 'Serif',
                                    'sans-serif': 'Sans Serif',
                                  }[font]!,
                                ),
                              ),
                              selected: p.font == font,
                              onSelected: (_) => apply('font', font),
                            ),
                        ],
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final font in session.fonts.fonts)
                            InputChip(
                              label: Text(text(font['name'])),
                              selected: p.font == 'custom:${font['id']}',
                              onSelected: (_) =>
                                  apply('font', 'custom:${font['id']}'),
                              onDeleted: () async {
                                await session.fonts.remove(text(font['id']));
                                if (!context.mounted) return;
                                if (p.font == 'custom:${font['id']}') {
                                  await apply('font', 'publisher');
                                } else {
                                  update(() {});
                                }
                              },
                            ),
                          ActionChip(
                            avatar: const Icon(Icons.add),
                            label: Text(tr(context, 'Import Font')),
                            onPressed: () async {
                              try {
                                final font = await session.fonts.importFont();
                                if (font != null && context.mounted) {
                                  await apply('font', 'custom:${font['id']}');
                                }
                              } catch (error) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(error.toString())),
                                  );
                                }
                              }
                            },
                          ),
                        ],
                      ),
                    ],
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final theme in ['white', 'sepia', 'black'])
                          ChoiceChip(
                            label: Text(tr(context, theme)),
                            selected: p.theme == theme,
                            onSelected: (_) => apply('theme', theme),
                          ),
                      ],
                    ),
                    if (!_fixedLayout)
                      slider('Text Size', 'fontSize', p.fontSize, 8, 60, 52),
                    Text(tr(context, 'Page Turn Animation')),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final style in ['slide', 'cover', 'curl', 'none'])
                          ChoiceChip(
                            label: Text(tr(context, style)),
                            selected: p.transition == style,
                            onSelected: (_) => apply('transition', style),
                          ),
                      ],
                    ),
                    Text(tr(context, 'Tap Zones')),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final mode in [
                          'none',
                          'default',
                          'edge',
                          'kindle',
                          'lShape',
                          'tSplit',
                        ])
                          ChoiceChip(
                            label: Text(
                              tr(context, 'reader.tapZoneMode.$mode'),
                            ),
                            selected: p.tapMode == mode,
                            onSelected: (_) => apply('tapMode', mode),
                          ),
                      ],
                    ),
                    Text(tr(context, 'Tap Zone Inversion')),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final mode in ['auto', 'normal', 'inverted'])
                          ChoiceChip(
                            label: Text(
                              tr(context, 'reader.tapZoneInversionMode.$mode'),
                            ),
                            selected: p.tapInversion == mode,
                            onSelected: (_) => apply('tapInversion', mode),
                          ),
                      ],
                    ),
                    if (!_fixedLayout) ...[
                      slider(
                        'Line Height',
                        'lineHeight',
                        p.lineHeight,
                        1,
                        3,
                        20,
                      ),
                      slider('Page Margins', 'margin', p.margin, 0, 100, 20),
                      slider(
                        'Paragraph Spacing',
                        'paragraphSpacing',
                        p.paragraphSpacing,
                        0,
                        3,
                        30,
                      ),
                      slider('Paragraph Indent', 'indent', p.indent, 0, 4, 20),
                      slider(
                        'Letter Spacing',
                        'letterSpacing',
                        p.letterSpacing,
                        -.05,
                        .3,
                        35,
                      ),
                      slider(
                        'Word Spacing',
                        'wordSpacing',
                        p.wordSpacing,
                        0,
                        1,
                        20,
                      ),
                    ],
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final count in [0, 1, 2])
                          ChoiceChip(
                            label: Text(
                              count == 0
                                  ? tr(context, 'Automatic')
                                  : _fixedLayout
                                  ? '${tr(context, 'Pages')}: $count'
                                  : '$count ${tr(context, 'Columns')}',
                            ),
                            selected: p.columns == count,
                            onSelected: (_) => apply('columns', count),
                          ),
                      ],
                    ),
                    if (!_fixedLayout) ...[
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final alignment in [
                            'publisher',
                            'left',
                            'right',
                            'justify',
                            'center',
                          ])
                            ChoiceChip(
                              label: Text(tr(context, alignment)),
                              selected: p.alignment == alignment,
                              onSelected: (_) => apply('alignment', alignment),
                            ),
                        ],
                      ),
                    ],
                    TextButton(
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
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    if (!_closed.isCompleted) _closed.complete();
    _session?.removeListener(_changed);
    unawaited(_session?.close() ?? Future.value());
    super.dispose();
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
      final background = session.preferences.theme == 'black'
          ? const Color(0xff1c1c1e)
          : session.preferences.theme == 'white'
          ? Colors.white
          : const Color(0xffefe5d0);
      final brightness = session.preferences.theme == 'black'
          ? Brightness.dark
          : Brightness.light;
      if (_readerTheme == null || _readerBrightness != brightness) {
        _readerBrightness = brightness;
        _readerTheme = appTheme(brightness);
      }
      return Theme(
        data: _readerTheme!,
        child: Scaffold(
          backgroundColor: background,
          appBar: _controls
              ? AppBar(
                  backgroundColor: background,
                  title: Text(widget.book.title),
                  actions: [
                    if (widget.incognito) const Icon(CupertinoIcons.eye_slash),
                    if (session.auxiliary)
                      IconButton(
                        tooltip: tr(context, 'Back to Reading'),
                        onPressed: () => _call('closeAuxiliary'),
                        icon: const Icon(CupertinoIcons.arrow_uturn_left),
                      ),
                    IconButton(
                      tooltip: tr(context, 'Full Screen'),
                      onPressed: () => setState(() => _controls = false),
                      icon: const Icon(
                        CupertinoIcons.arrow_up_left_arrow_down_right,
                      ),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (v) => switch (v) {
                        'contents' => _contents(),
                        'search' => _search(),
                        'bookmarks' => _bookmarks(),
                        'translate' => _translateSelection(),
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
                if (_error != null)
                  MaterialBanner(
                    content: Text(_error!),
                    actions: [
                      TextButton(
                        onPressed: () => setState(() => _error = null),
                        child: Text(tr(context, 'Close')),
                      ),
                    ],
                  ),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      InAppWebView(
                        webViewEnvironment: _environment,
                        initialUrlRequest: URLRequest(
                          url: WebUri(session.host.reader.toString()),
                        ),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          allowFileAccess: false,
                          allowContentAccess: false,
                          useShouldOverrideUrlLoading: true,
                          transparentBackground: false,
                          supportZoom: false,
                          isInspectable: false,
                        ),
                        onWebViewCreated: (controller) {
                          _browser = controller;
                          controller.addJavaScriptHandler(
                            handlerName: 'readerEvent',
                            callback: (args) {
                              if (args.isNotEmpty) _event(args.first);
                              return null;
                            },
                          );
                        },
                        onLoadStop: (_, _) => _load(),
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
                                  uri.authority ==
                                      session.host.base.authority &&
                                  uri.path.startsWith(session.host.base.path)
                              ? NavigationActionPolicy.ALLOW
                              : NavigationActionPolicy.CANCEL;
                        },
                        onReceivedError: (_, request, error) {
                          if (request.isForMainFrame == true && mounted) {
                            setState(() => _error = error.description);
                          }
                        },
                      ),
                      if (!session.ready)
                        ColoredBox(
                          color: background,
                          child: const Center(
                            child: CircularProgressIndicator.adaptive(),
                          ),
                        ),
                    ],
                  ),
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
                            '${session.document.chapters[session.chapter].title} · ${session.page}/${session.pages}',
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
      );
    },
  );
}
