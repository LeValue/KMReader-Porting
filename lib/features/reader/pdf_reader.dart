import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'pdf_preferences.dart';

class PdfReader extends StatefulWidget {
  const PdfReader({
    super.key,
    required this.file,
    required this.repository,
    required this.book,
    required this.incognito,
  });
  final File file;
  final Repository repository;
  final Book book;
  final bool incognito;
  @override
  State<PdfReader> createState() => _PdfReaderState();
}

class _PdfReaderState extends State<PdfReader> {
  final _controller = PdfViewerController();
  PdfTextSearcher? _searcher;
  PdfDocument? _searchDocument;
  PdfPageTextRange? _lastSearchMatch;
  bool _ready = false, _search = false;
  int _page = 1;
  int _focusedPage = 1;
  late PdfPreferences _preferences;
  PdfReaderLayout? _layout;
  Size _viewport = Size.zero;
  bool _reconfiguring = false, _navigating = false;
  int _passwordAttempts = 0;
  Timer? _snapTimer;
  String get _key => 'pdf:${widget.book.id}';

  void _searchMoved() {
    final searcher = _searcher;
    final index = searcher?.currentIndex;
    final match =
        index != null && index >= 0 && index < searcher!.matches.length
        ? searcher.matches[index]
        : null;
    if (!identical(match, _lastSearchMatch)) {
      _lastSearchMatch = match;
      if (match != null) _focusedPage = match.pageNumber;
    }
  }

  Future<String?> _password() async {
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return null;
    var input = '';
    _passwordAttempts++;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'PDF Password')),
        content: TextField(
          autofocus: true,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: tr(context, 'Password'),
            errorText: _passwordAttempts > 1
                ? tr(context, 'Incorrect password. Try again.')
                : null,
          ),
          onChanged: (value) => input = value,
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input),
            child: Text(tr(context, 'Open')),
          ),
        ],
      ),
    );
  }

  Future<void> _seriesDirection() async {
    if (!_preferences.useSeriesDirection || widget.book.seriesId.isEmpty) {
      return;
    }
    try {
      final series = object(
        await widget.repository.get(
          '/api/v1/series/${Uri.encodeComponent(widget.book.seriesId)}',
          cacheKey: 'detail:series:${widget.book.seriesId}',
          cacheFirst: true,
        ),
      );
      if (mounted && _preferences.useSeriesDirection) {
        _configure(
          _preferences.forSeries(object(series['metadata'])),
          persist: false,
        );
      }
    } on ApiFailure {
      // Cached/default direction still works without connectivity.
    }
  }

  void _configure(PdfPreferences preferences, {bool persist = true}) {
    final geometryChanged =
        preferences.presentation != _preferences.presentation ||
        preferences.rtl != _preferences.rtl ||
        preferences.coverSolo != _preferences.coverSolo;
    setState(() => _preferences = preferences);
    if (persist) {
      widget.repository.store.cache(
        widget.repository.profile.id,
        _key,
        preferences.toJson(),
      );
    }
    if (geometryChanged) _reflow();
  }

  void _reflow() {
    if (!_ready || _reconfiguring) return;
    _reconfiguring = true;
    final page = _page;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_controller.isReady) return;
      _controller.invalidate();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_controller.isReady) return;
      await _goTo(page, record: false, duration: Duration.zero);
      if (mounted) _reconfiguring = false;
    });
  }

  Future<void> _goTo(
    int page, {
    bool record = true,
    Duration duration = const Duration(milliseconds: 180),
  }) async {
    if (!_ready || !_controller.isReady || _navigating) return;
    page = page.clamp(1, _controller.pageCount);
    _focusedPage = page;
    _navigating = true;
    try {
      final slot = _layout?.slots[page - 1];
      if (slot != null) {
        await _controller.goToArea(
          rect: slot,
          anchor: PdfPageAnchor.all,
          duration: duration,
        );
      } else {
        await _controller.goToPage(pageNumber: page, duration: duration);
      }
      if (!mounted) return;
      setState(() => _page = page);
      if (record && !widget.incognito) {
        widget.repository.setProgress(widget.book, page);
      }
    } finally {
      _navigating = false;
    }
  }

  void _snap() {
    if (_preferences.presentation.resolved(_viewport) !=
            PdfPresentation.singlePaged ||
        !_ready) {
      return;
    }
    _snapTimer?.cancel();
    _snapTimer = Timer(const Duration(milliseconds: 130), () {
      if (!mounted || !_controller.isReady || _reconfiguring || _navigating) {
        return;
      }
      final layout = _layout;
      if (layout == null) return;
      final page = layout.nearestPage(_controller.visibleRect);
      final slot = layout.slots[page - 1];
      final fit = (_controller.viewSize.width / slot.width).clamp(
        0.0,
        _controller.viewSize.height / slot.height,
      );
      // Keep panning freely while zoomed into text or artwork.
      if (_controller.currentZoom <= fit * 1.05) _goTo(page);
    });
  }

  Future<void> _settings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) {
          void change(PdfPreferences value) {
            _configure(value);
            refresh(() {});
          }

          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: Text(
                      tr(context, 'PDF Settings'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  for (final mode in PdfPresentation.values)
                    ListTile(
                      title: Text(tr(context, mode.label)),
                      leading: Icon(
                        _preferences.presentation == mode
                            ? CupertinoIcons.checkmark_circle_fill
                            : CupertinoIcons.circle,
                      ),
                      onTap: () => change(
                        _preferences.copy(
                          presentation: mode,
                          useSeriesDirection: false,
                        ),
                      ),
                    ),
                  SwitchListTile(
                    title: Text(tr(context, 'Cover Page Alone')),
                    value: _preferences.coverSolo,
                    onChanged: (value) =>
                        change(_preferences.copy(coverSolo: value)),
                  ),
                  SwitchListTile(
                    title: Text(tr(context, 'Right to Left')),
                    value: _preferences.rtl,
                    onChanged: (value) => change(
                      _preferences.copy(rtl: value, useSeriesDirection: false),
                    ),
                  ),
                  SwitchListTile(
                    title: Text(tr(context, 'Use Series Reading Direction')),
                    value: _preferences.useSeriesDirection,
                    onChanged: (value) {
                      change(_preferences.copy(useSeriesDirection: value));
                      if (value) _seriesDirection();
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SegmentedButton<String>(
                      segments: [
                        for (final entry in const {
                          'white': 'White',
                          'sepia': 'Sepia',
                          'black': 'Black',
                        }.entries)
                          ButtonSegment(
                            value: entry.key,
                            label: Text(tr(context, entry.value)),
                          ),
                      ],
                      selected: {_preferences.background},
                      onSelectionChanged: (value) =>
                          change(_preferences.copy(background: value.first)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _jump() async {
    var input = '$_page';
    final value = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'Go to Page')),
        content: TextFormField(
          initialValue: input,
          autofocus: true,
          keyboardType: TextInputType.number,
          onChanged: (value) => input = value,
          onFieldSubmitted: (value) =>
              Navigator.pop(context, int.tryParse(value)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, int.tryParse(input)),
            child: Text(tr(context, 'Go')),
          ),
        ],
      ),
    );
    if (value != null && mounted) await _goTo(value);
  }

  @override
  void initState() {
    super.initState();
    _page = widget.book.completed
        ? 1
        : widget.book.page.clamp(1, widget.book.pages.clamp(1, 1000000));
    _focusedPage = _page;
    final cached = widget.repository.store.cached(
      widget.repository.profile.id,
      _key,
    );
    _preferences = PdfPreferences.fromJson(object(cached));
    final series = object(
      widget.repository.store.cached(
        widget.repository.profile.id,
        'detail:series:${widget.book.seriesId}',
      ),
    );
    _preferences = _preferences.forSeries(object(series['metadata']));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _seriesDirection();
    });
  }

  @override
  void dispose() {
    _snapTimer?.cancel();
    _searcher?.dispose();
    super.dispose();
  }

  Future<void> _outline() async {
    if (!_controller.isReady) return;
    final nodes = await _controller.document.loadOutline();
    if (!mounted) return;
    Widget node(PdfOutlineNode item) => item.children.isEmpty
        ? ListTile(
            title: Text(item.title),
            onTap: () {
              Navigator.pop(context);
              _controller.goToDest(item.dest);
            },
          )
        : ExpansionTile(
            title: Text(item.title),
            children: [
              if (item.dest != null)
                ListTile(
                  title: Text(tr(context, 'Go to Page')),
                  onTap: () {
                    Navigator.pop(context);
                    _controller.goToDest(item.dest);
                  },
                ),
              ...item.children.map(node),
            ],
          );
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => nodes.isEmpty
          ? const EmptyView(title: 'No Table of Contents')
          : ListView(children: nodes.map(node).toList()),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.book.title),
      actions: [
        if (widget.incognito) const Icon(CupertinoIcons.eye_slash),
        IconButton(
          tooltip: tr(context, 'PDF Settings'),
          onPressed: _settings,
          icon: const Icon(CupertinoIcons.slider_horizontal_3),
        ),
        IconButton(
          tooltip: tr(context, 'Search'),
          onPressed: () => setState(() => _search = !_search),
          icon: const Icon(CupertinoIcons.search),
        ),
        IconButton(
          tooltip: tr(context, 'Table of Contents'),
          onPressed: _outline,
          icon: const Icon(CupertinoIcons.list_bullet),
        ),
      ],
    ),
    body: Column(
      children: [
        if (_search && _searcher != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: tr(context, 'Search'),
                    ),
                    onChanged: (v) => _searcher!.startTextSearch(v),
                  ),
                ),
                ListenableBuilder(
                  listenable: _searcher!,
                  builder: (_, _) => Text(
                    '${(_searcher!.currentIndex ?? -1) + 1}/${_searcher!.matches.length}',
                  ),
                ),
                IconButton(
                  onPressed: _searcher!.goToPrevMatch,
                  icon: const Icon(CupertinoIcons.chevron_up),
                ),
                IconButton(
                  onPressed: _searcher!.goToNextMatch,
                  icon: const Icon(CupertinoIcons.chevron_down),
                ),
              ],
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final viewport = constraints.biggest;
              if (_viewport != viewport) {
                _viewport = viewport;
                _reflow();
              }
              return Focus(
                autofocus: true,
                onKeyEvent: (node, event) {
                  if (event is! KeyDownEvent || !_ready) {
                    return KeyEventResult.ignored;
                  }
                  final key = event.logicalKey;
                  final next = _preferences.rtl
                      ? LogicalKeyboardKey.arrowLeft
                      : LogicalKeyboardKey.arrowRight;
                  final previous = _preferences.rtl
                      ? LogicalKeyboardKey.arrowRight
                      : LogicalKeyboardKey.arrowLeft;
                  if (key == next || key == LogicalKeyboardKey.pageDown) {
                    _goTo(_page + 1);
                    return KeyEventResult.handled;
                  }
                  if (key == previous || key == LogicalKeyboardKey.pageUp) {
                    _goTo(_page - 1);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Listener(
                  onPointerSignal: (_) => _snap(),
                  child: PdfViewer.file(
                    widget.file.path,
                    passwordProvider: _password,
                    controller: _controller,
                    initialPageNumber: _page,
                    params: PdfViewerParams(
                      sizeDelegateProvider:
                          const PdfViewerSizeDelegateProviderLegacy(
                            useAlternativeFitScaleAsMinScale: false,
                            minScale: .05,
                          ),
                      layoutPages: (pages, params) {
                        final layout = PdfReaderLayout(
                          sizes: [
                            for (final page in pages)
                              Size(page.width, page.height),
                          ],
                          preferences: _preferences,
                          viewport: _viewport,
                          margin: params.margin,
                        );
                        _layout = layout;
                        return PdfPageLayout(
                          pageLayouts: layout.pages,
                          documentSize: layout.documentSize,
                        );
                      },
                      calculateCurrentPageNumber:
                          (visible, pages, controller) => _layout?.nearestPage(
                            visible,
                            preferred: _focusedPage,
                          ),
                      enableKeyboardNavigation: false,
                      backgroundColor: switch (_preferences.background) {
                        'black' => Colors.black,
                        'sepia' => const Color(0xffe8dcc3),
                        _ => const Color(0xffeeeeee),
                      },
                      pageImageColorFilter: switch (_preferences.background) {
                        'black' => const ColorFilter.matrix([
                          -1,
                          0,
                          0,
                          0,
                          255,
                          0,
                          -1,
                          0,
                          0,
                          255,
                          0,
                          0,
                          -1,
                          0,
                          255,
                          0,
                          0,
                          0,
                          1,
                          0,
                        ]),
                        'sepia' => const ColorFilter.mode(
                          Color(0xfff4ecd8),
                          BlendMode.modulate,
                        ),
                        _ => null,
                      },
                      scrollHorizontallyByMouseWheel:
                          _preferences.presentation.resolved(_viewport) ==
                          PdfPresentation.singlePaged,
                      onInteractionStart: (_) => _snapTimer?.cancel(),
                      onInteractionEnd: (_) => _snap(),
                      pagePaintCallbacks: [
                        if (_searcher != null)
                          _searcher!.pageTextMatchPaintCallback,
                      ],
                      onViewerReady: (document, controller) {
                        if (!mounted) return;
                        if (!identical(_searchDocument, document)) {
                          _searcher?.dispose();
                          _searcher = PdfTextSearcher(_controller);
                          _lastSearchMatch = null;
                          _searcher!.addListener(_searchMoved);
                          _searchDocument = document;
                        }
                        setState(() => _ready = true);
                        _reflow();
                      },
                      onPageChanged: (page) {
                        if (!_ready ||
                            page == null ||
                            !mounted ||
                            _reconfiguring ||
                            _navigating) {
                          return;
                        }
                        setState(() => _page = page);
                        _focusedPage = page;
                        if (!widget.incognito) {
                          widget.repository.setProgress(widget.book, page);
                        }
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (_ready)
          SafeArea(
            top: false,
            child: Row(
              children: [
                IconButton(
                  tooltip: tr(context, 'Previous Page'),
                  onPressed: _page > 1 ? () => _goTo(_page - 1) : null,
                  icon: const Icon(CupertinoIcons.chevron_left),
                ),
                Expanded(
                  child: Slider(
                    min: 1,
                    max: _controller.pageCount.clamp(2, 1000000).toDouble(),
                    value: _page
                        .clamp(1, _controller.pageCount.clamp(2, 1000000))
                        .toDouble(),
                    onChanged: _controller.pageCount > 1
                        ? (v) => setState(() => _page = v.round())
                        : null,
                    onChangeEnd: (value) => _goTo(value.round()),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: TextButton(
                    onPressed: _jump,
                    child: Text('$_page / ${_controller.pageCount}'),
                  ),
                ),
                IconButton(
                  tooltip: tr(context, 'Next Page'),
                  onPressed: _page < _controller.pageCount
                      ? () => _goTo(_page + 1)
                      : null,
                  icon: const Icon(CupertinoIcons.chevron_right),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
