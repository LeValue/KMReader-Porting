import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/api.dart';
import '../../core/file_export.dart';
import '../../core/models.dart';
import '../../core/reader_defaults.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/reader_options.dart';
import '../../ui/reader_chrome.dart';
import '../../ui/strings.dart';
import 'pdf_preferences.dart';
import 'pdf_raster_pages.dart';
import 'progress_gate.dart';
import 'reader_display.dart';
import '../../ui/wheel_scroll.dart';

class PdfReader extends StatefulWidget {
  const PdfReader({
    super.key,
    required this.file,
    required this.repository,
    required this.book,
    required this.incognito,
    this.onNextBook,
  });
  final File file;
  final Repository repository;
  final Book book;
  final bool incognito;
  final Future<void> Function()? onNextBook;
  @override
  State<PdfReader> createState() => _PdfReaderState();
}

class _PdfReaderState extends State<PdfReader> {
  final _controller = PdfViewerController();
  Book get _progressBook => !_controller.isReady
      ? widget.book
      : Book({
          ...widget.book.json,
          'media': {...widget.book.media, 'pagesCount': _controller.pageCount},
        });
  PdfTextSearcher? _searcher;
  PdfDocument? _searchDocument;
  PdfPageTextRange? _lastSearchMatch;
  bool _ready = false, _search = false;
  int _page = 1;
  int _focusedPage = 1;
  late PdfPreferences _preferences;
  late ReaderProgressGate _progressGate;
  PdfReaderLayout? _layout;
  Size _viewport = Size.zero;
  bool _reconfiguring = false, _navigating = false;
  bool _needsReflow = false;
  int? _pendingStep;
  bool _openingNext = false, _controls = true;
  bool _zoomed = false;
  bool _exporting = false;
  int _passwordAttempts = 0;
  Timer? _snapTimer;
  final _pointers = <int>{};
  ({int pointer, Offset origin, int page})? _pageDrag;
  String get _key => 'pdf:${widget.book.id}';
  bool get _paged => _preferences.presentation.resolved(_viewport).isPaged;

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
        preferences.vertical != _preferences.vertical ||
        preferences.coverSolo != _preferences.coverSolo;
    if (persist) {
      final changes = readerPreferenceChanges(
        _preferences.toJson(),
        preferences.toJson(),
      );
      if (_preferences.useSeriesDirection && !preferences.useSeriesDirection) {
        changes.addAll({
          'rtl': preferences.rtl,
          'vertical': preferences.vertical,
        });
      }
      if (changes.isNotEmpty) {
        writeReaderVolumePreferences(
          widget.repository.store,
          widget.repository.profile.id,
          _key,
          changes,
        );
      }
    }
    setState(() => _preferences = preferences);
    if (geometryChanged) _reflow();
  }

  void _reflow() {
    if (!_ready) return;
    _needsReflow = true;
    if (_reconfiguring || _navigating) return;
    _reconfiguring = true;
    final page = _page;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted || !_controller.isReady) return;
        _needsReflow = false;
        _controller.invalidate();
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || !_controller.isReady) return;
        await _goTo(page, record: false, duration: Duration.zero);
      } finally {
        _reconfiguring = false;
        _zoomChanged();
        _resumeNavigation();
      }
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
    _snapTimer?.cancel();
    if (MediaQuery.disableAnimationsOf(context)) duration = Duration.zero;
    try {
      final slot = _layout?.slots[page - 1];
      Future<void> move(Duration time) => slot != null
          ? _controller.goToArea(
              rect: slot,
              anchor: PdfPageAnchor.all,
              duration: time,
            )
          : _controller.goToPage(pageNumber: page, duration: time);
      // A native interaction can cancel pdfrx's animation ticker and
      // leave its future pending. Settle the intended slot on interruption.
      await move(duration).timeout(
        duration + const Duration(milliseconds: 120),
        onTimeout: () async {
          if (mounted && _controller.isReady) await move(Duration.zero);
        },
      );
      if (!mounted) return;
      setState(() => _page = page);
      if (record && !widget.incognito && _progressGate.allows(page)) {
        widget.repository.setProgress(_progressBook, page);
      }
    } finally {
      _navigating = false;
      _zoomChanged();
      _resumeNavigation();
    }
  }

  void _resumeNavigation() {
    if (!mounted || !_controller.isReady || _navigating || _reconfiguring) {
      return;
    }
    if (_needsReflow) {
      _reflow();
    } else if (_pendingStep case final int direction) {
      _pendingStep = null;
      unawaited(_step(direction));
    }
  }

  int? _adjacent(int direction, [int? origin]) =>
      _layout?.adjacentPage(origin ?? _page, direction);

  Future<void> _step(int direction, {int? from}) async {
    if (!_ready || !_controller.isReady || _openingNext) return;
    if (_navigating || _reconfiguring) {
      if (from == null) _pendingStep = direction;
      return;
    }
    final page = _adjacent(direction, from);
    if (page != null) {
      await _goTo(page);
    } else if (from != null) {
      await _goTo(from, record: false);
    } else if (direction > 0 && widget.onNextBook != null) {
      setState(() => _openingNext = true);
      try {
        await widget.onNextBook!();
      } catch (error) {
        if (mounted) showError(context, error);
      } finally {
        if (mounted) setState(() => _openingNext = false);
      }
    }
  }

  bool? _handleKey(LogicalKeyboardKey key, bool firstPress) {
    if (!_ready ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return null;
    }
    final rtl = _preferences.rtl;
    if (key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.arrowDown ||
        key ==
            (rtl
                ? LogicalKeyboardKey.arrowLeft
                : LogicalKeyboardKey.arrowRight)) {
      unawaited(_step(1));
      return true;
    }
    if (key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.arrowUp ||
        key ==
            (rtl
                ? LogicalKeyboardKey.arrowRight
                : LogicalKeyboardKey.arrowLeft)) {
      unawaited(_step(-1));
      return true;
    }
    if (key != LogicalKeyboardKey.space) return null;
    if (widget.repository.store.setting<String>('spaceKeyAction') ==
        'nextPage') {
      unawaited(_step(HardwareKeyboard.instance.isShiftPressed ? -1 : 1));
    } else if (firstPress) {
      setState(() => _controls = !_controls);
    }
    return true;
  }

  bool _isAtFit(int page) {
    final layout = _layout;
    if (!_controller.isReady || layout == null || page > layout.slots.length) {
      return false;
    }
    final slot = layout.slots[page - 1], view = _controller.viewSize;
    final fit = (view.width / slot.width).clamp(0.0, view.height / slot.height);
    return _controller.currentZoom <= fit * 1.05;
  }

  void _zoomChanged() {
    if (!mounted || !_ready || !_paged || _navigating || _reconfiguring) {
      return;
    }
    final zoomed = !_isAtFit(_focusedPage);
    if (_zoomed != zoomed) setState(() => _zoomed = zoomed);
  }

  void _startPageDrag(PointerDownEvent event) {
    _pointers.add(event.pointer);
    if (_pointers.length != 1) {
      _pageDrag = null;
      return;
    }
    if (!_paged ||
        !_ready ||
        _navigating ||
        !_isAtFit(_page) ||
        event.kind == PointerDeviceKind.mouse &&
            event.buttons != kPrimaryMouseButton) {
      return;
    }
    _snapTimer?.cancel();
    _pageDrag = (
      pointer: event.pointer,
      origin: event.localPosition,
      page: _page,
    );
  }

  void _endPageDrag(PointerEvent event) {
    _pointers.remove(event.pointer);
    final drag = _pageDrag;
    if (drag == null || drag.pointer != event.pointer) return;
    _pageDrag = null;
    if (!_isAtFit(drag.page)) return;
    final offset = event.localPosition - drag.origin;
    final axis = _preferences.vertical ? offset.dy : offset.dx;
    final other = _preferences.vertical ? offset.dx : offset.dy;
    final extent = _preferences.vertical ? _viewport.height : _viewport.width;
    final threshold = (extent * .1).clamp(24.0, 56.0);
    if (event is PointerUpEvent &&
        axis.abs() >= threshold &&
        axis.abs() > other.abs()) {
      final forward = axis < 0 != (!_preferences.vertical && _preferences.rtl);
      scheduleMicrotask(() {
        if (mounted) unawaited(_step(forward ? 1 : -1, from: drag.page));
      });
    }
  }

  void _snap() {
    if (!_paged || !_ready || _pageDrag != null) {
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
      // Keep panning freely while zoomed into text or artwork.
      if (_isAtFit(page)) unawaited(_goTo(page));
    });
  }

  Future<void> _settings() async {
    await showReaderOptions(
      context,
      (context) => StatefulBuilder(
        builder: (context, refresh) {
          void change(PdfPreferences value) {
            _configure(value);
            refresh(() {});
          }

          return ReaderSafeArea(
            child: ReaderOptionsPanel(
              title: 'PDF Settings',
              useAppPalette: true,
              compact: true,
              fill: true,
              children: [
                ReaderOptionGroup(
                  title: 'Reading',
                  children: [
                    ReaderOptionPicker(
                      title: 'Page Presentation',
                      value: _preferences.presentation.value,
                      choices: {
                        for (final mode in PdfPresentation.values)
                          mode.value: mode.label,
                      },
                      onChanged: (value) => change(
                        _preferences.copy(
                          presentation: PdfPresentation.values.firstWhere(
                            (mode) => mode.value == value,
                          ),
                        ),
                      ),
                    ),
                    if (_preferences.presentation.isDual ||
                        _preferences.presentation == PdfPresentation.auto)
                      SwitchListTile.adaptive(
                        title: Text(tr(context, 'Cover Page Alone')),
                        value: _preferences.coverSolo,
                        onChanged: (value) =>
                            change(_preferences.copy(coverSolo: value)),
                      ),
                    ReaderOptionPicker(
                      title: 'Preferred Direction',
                      value: _preferences.vertical
                          ? 'vertical'
                          : _preferences.rtl
                          ? 'rtl'
                          : 'ltr',
                      choices: const {
                        'ltr': 'Left to Right',
                        'rtl': 'Right to Left',
                        'vertical': 'Vertical',
                      },
                      onChanged: (value) => change(
                        _preferences.copy(
                          rtl: value == 'rtl',
                          vertical: value == 'vertical',
                          useSeriesDirection: false,
                        ),
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
                  ],
                ),
                ReaderOptionGroup(
                  title: 'Appearance',
                  children: [
                    ReaderOptionPicker(
                      title: 'Reader Background',
                      value: _preferences.background,
                      choices: const {
                        'system': 'System',
                        'white': 'White',
                        'sepia': 'Sepia',
                        'gray': 'Gray',
                        'black': 'Black',
                      },
                      onChanged: (value) =>
                          change(_preferences.copy(background: value)),
                    ),
                    SwitchListTile.adaptive(
                      title: Text(tr(context, 'Controls Gradient Background')),
                      value: _preferences.controlsGradient,
                      onChanged: (value) =>
                          change(_preferences.copy(controlsGradient: value)),
                    ),
                    SwitchListTile.adaptive(
                      title: Text(
                        tr(context, 'Show Progress Bar While Reading'),
                      ),
                      value: _preferences.showProgress,
                      onChanged: (value) =>
                          change(_preferences.copy(showProgress: value)),
                    ),
                  ],
                ),
                ListTile(
                  leading: const Icon(Icons.restore),
                  title: Text(tr(context, 'Use Global Defaults')),
                  onTap: () {
                    final store = widget.repository.store;
                    writeReaderVolumePreferences(
                      store,
                      widget.repository.profile.id,
                      _key,
                      {},
                      reset: _preferences.toJson().keys,
                    );
                    _configure(
                      PdfPreferences.fromJson(
                        object(store.setting<dynamic>('pdfDefault')),
                      ),
                      persist: false,
                    );
                    _seriesDirection();
                    refresh(() {});
                  },
                ),
              ],
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
    _controller.addListener(_zoomChanged);
    _controls =
        widget.repository.store.setting<bool>('autoFullscreenOnOpen') != true;
    _page = widget.book.completed
        ? 1
        : widget.book.page.clamp(
            1,
            (widget.book.pages > 0 ? widget.book.pages : 1000000),
          );
    _focusedPage = _page;
    final cached = widget.repository.store.cached(
      widget.repository.profile.id,
      _key,
    );
    _preferences = PdfPreferences.fromJson({
      ...object(widget.repository.store.setting<dynamic>('pdfDefault')),
      ...object(cached),
    });
    _progressGate = ReaderProgressGate(
      widget.book,
      widget.repository.store.setting<int>('progressRecordingThreshold') ?? 0,
    );
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
    _controller.removeListener(_zoomChanged);
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
      sheetAnimationStyle: readerSheetAnimation(context),
      showDragHandle: true,
      builder: (context) => nodes.isEmpty
          ? const EmptyView(title: 'No Table of Contents')
          : ListView(children: nodes.map(node).toList()).withWheelScrolling(),
    );
  }

  List<int> get _exportPages {
    final slots = _layout?.slots;
    if (slots == null || _focusedPage < 1 || _focusedPage > slots.length) {
      return [];
    }
    final slot = slots[_focusedPage - 1];
    return [
      if (_focusedPage > 1 && slots[_focusedPage - 2] == slot) _focusedPage - 1,
      _focusedPage,
      if (_focusedPage < slots.length && slots[_focusedPage] == slot)
        _focusedPage + 1,
    ];
  }

  Future<void> _exportPage(int page) async {
    if (!_controller.isReady || _exporting) return;
    setState(() => _exporting = true);
    try {
      final bytes = await PdfRasterPages.renderPage(
        _controller.document.pages[page - 1],
        quality: PdfRasterQuality.parse(
          widget.repository.store.setting<String>('pdfOfflineRenderQuality'),
        ),
      );
      if (mounted) {
        await saveEncodedPageImage(
          bytes,
          widget.repository.directory,
          page: page,
        );
      }
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: _controls
        ? AppBar(
            backgroundColor: _preferences.controlsGradient
                ? null
                : Colors.transparent,
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
              if (_ready)
                PopupMenuButton<int>(
                  tooltip: tr(context, 'Save Image'),
                  enabled: !_exporting && _exportPages.isNotEmpty,
                  icon: const Icon(Icons.save_alt),
                  onSelected: _exportPage,
                  itemBuilder: (_) => [
                    for (final page in _exportPages)
                      PopupMenuItem(
                        value: page,
                        child: Text(
                          tr(
                            context,
                            'Save Page %d as Image',
                          ).replaceAll('%d', '$page'),
                        ),
                      ),
                  ],
                ),
            ],
          )
        : null,
    body: SafeArea(
      top: false,
      bottom: false,
      child: Column(
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
                    return event is! KeyUpEvent &&
                            _handleKey(
                                  event.logicalKey,
                                  event is KeyDownEvent,
                                ) ==
                                true
                        ? KeyEventResult.handled
                        : KeyEventResult.ignored;
                  },
                  child: Listener(
                    onPointerDown: _startPageDrag,
                    onPointerUp: _endPageDrag,
                    onPointerCancel: _endPageDrag,
                    onPointerSignal: (_) => _snap(),
                    child: PdfViewer.file(
                      widget.file.path,
                      passwordProvider: _password,
                      controller: _controller,
                      initialPageNumber: _page,
                      params: PdfViewerParams(
                        // The native canvas may pan while zoomed or in
                        // continuous layout. At fit, the pointer listener
                        // owns page gestures so pdfrx cannot start a fling.
                        panEnabled: !_paged || _zoomed,
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
                            (visible, pages, controller) => _layout
                                ?.nearestPage(visible, preferred: _focusedPage),
                        onKey: (_, key, firstPress) =>
                            _handleKey(key, firstPress),
                        onGeneralTap: (_, _, details) {
                          if (details.type == PdfViewerGeneralTapType.tap &&
                              details.tapOn == PdfViewerPart.background) {
                            setState(() => _controls = !_controls);
                            return true;
                          }
                          return false;
                        },
                        backgroundColor: switch (_preferences.background) {
                          'black' => Colors.black,
                          'sepia' => const Color(0xffe8dcc3),
                          'gray' => Colors.grey,
                          'system' => Theme.of(context).colorScheme.surface,
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
                            _paged && !_preferences.vertical,
                        onInteractionStart: (_) => _snapTimer?.cancel(),
                        onInteractionEnd: (_) {
                          if (_zoomed) _snap();
                        },
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
                              _pageDrag != null ||
                              _reconfiguring ||
                              _navigating) {
                            return;
                          }
                          setState(() => _page = page);
                          _focusedPage = page;
                          if (!widget.incognito && _progressGate.allows(page)) {
                            widget.repository.setProgress(_progressBook, page);
                          }
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_ready && _preferences.showProgress)
            LinearProgressIndicator(
              value: _controller.pageCount > 0
                  ? _page / _controller.pageCount
                  : 0,
              minHeight: 3,
            ),
          if (_ready)
            ReaderSafeArea(
              top: false,
              child: Row(
                children: [
                  IconButton(
                    tooltip: tr(context, 'Previous Page'),
                    onPressed: _adjacent(-1) != null ? () => _step(-1) : null,
                    icon: const Icon(CupertinoIcons.chevron_left),
                  ),
                  Expanded(
                    child: Slider(
                      min: 1,
                      semanticFormatterCallback: (value) => readingPageLabel(
                        context,
                        value.round(),
                        _controller.pageCount,
                      ),
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
                    child: Tooltip(
                      message: tr(context, 'Go to Page'),
                      child: TextButton(
                        onPressed: _jump,
                        child: Semantics(
                          label: readingPageLabel(
                            context,
                            _page,
                            _controller.pageCount,
                          ),
                          excludeSemantics: true,
                          child: Text('$_page / ${_controller.pageCount}'),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: tr(
                      context,
                      _adjacent(1) == null && widget.onNextBook != null
                          ? 'Next Book'
                          : 'Next Page',
                    ),
                    onPressed:
                        !_openingNext &&
                            (_adjacent(1) != null || widget.onNextBook != null)
                        ? () => _step(1)
                        : null,
                    icon: _openingNext
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _adjacent(1) == null && widget.onNextBook != null
                                ? Icons.skip_next_outlined
                                : CupertinoIcons.chevron_right,
                          ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
