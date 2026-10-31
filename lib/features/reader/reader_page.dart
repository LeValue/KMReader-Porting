import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'page_transition.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/models.dart';
import '../../core/next_book.dart';
import '../../core/api.dart';
import '../../core/repository.dart';
import '../../core/document_cache.dart';
import '../../core/translation.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../../ui/reader_options.dart';
import '../../ui/theme.dart';
import 'document_readers.dart';
import 'reading_session.dart';
import 'progress_gate.dart';
import 'tap_zones.dart';
import 'tap_zone_hints.dart';
import 'page_parts.dart';
import 'page_image_view.dart';
import 'reader_viewport.dart';
import 'wide_page.dart';
import 'cover_page.dart';
import 'reader_display.dart';
import 'page_crop.dart';
import 'reader_text_page.dart';
import 'page_upscaler.dart';
import 'raster_pages.dart';
import '../../ui/wheel_scroll.dart';

class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.repository,
    required this.book,
    this.incognito = false,
    this.readListId,
    this.rasterPages,
    this.onNextBook,
    this.initialPreferences,
  });
  final Repository repository;
  final Book book;
  final bool incognito;
  final String? readListId;
  final RasterPages? rasterPages;
  final ReaderPreferences? initialPreferences;
  final Future<void> Function()? onNextBook;
  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final _curl = GlobalKey<ReaderPageTransitionState>();
  final _pageBoundary = GlobalKey();
  Future<ui.Image?> _capturePageImage() async {
    final boundary = _pageBoundary.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || boundary.debugNeedsPaint) {
      return null;
    }
    return boundary.toImage(
      pixelRatio: boundary.size.longestSide > 2048
          ? 2048 / boundary.size.longestSide
          : 1,
    );
  }

  bool _previewing = false;
  Drag? _pageDrag(DragStartDetails details) {
    if (!_pages.hasClients) return null;
    final p = _session.preferences;
    final reverse = p.direction == ReadingDirection.rtl;
    if (!p.motion.followGesture ||
        !p.animate ||
        MediaQuery.disableAnimationsOf(context)) {
      return DiscreteReaderDrag(reverse: reverse, onTurn: _turn);
    }
    if (p.transition != 'curl' || _curl.currentState == null) {
      return _pages.position.drag(details, () {});
    }
    final origin = _viewIndex;
    final boundary =
        _pageBoundary.currentContext?.findRenderObject() as RenderBox?;
    return _curl.currentState!.drag(
      reverse: reverse,
      width: boundary?.size.width ?? MediaQuery.sizeOf(context).width,
      preview: (delta) async {
        final target = (origin + delta).clamp(0, _viewCount - 1);
        if (target == origin || !mounted) return false;
        _previewing = true;
        _pages.jumpToPage(target);
        await WidgetsBinding.instance.endOfFrame;
        return true;
      },
      finish: (delta, commit) async {
        if (!mounted || !_pages.hasClients) return;
        if (commit) {
          final target = (origin + delta).clamp(0, _viewCount - 1);
          _previewing = true;
          _pages.jumpToPage(target);
          _previewing = false;
          setState(() {
            _partIndex = target;
            _session.go(
              _split ? _parts[target].page : _session.firstPage(target),
            );
          });
        } else {
          _pages.jumpToPage(_viewIndex);
          await WidgetsBinding.instance.endOfFrame;
          _previewing = false;
        }
        _settled();
      },
    );
  }

  void _turn(int delta) {
    if (_session.preferences.transition == 'curl' &&
        _session.preferences.animate &&
        !MediaQuery.disableAnimationsOf(context) &&
        _session.preferences.mode == ReadingMode.paged &&
        _curl.currentState != null) {
      unawaited(
        _curl.currentState!.turn(
          'curl',
          _session.preferences.direction == ReadingDirection.rtl
              ? -delta
              : delta,
          () async {
            _turnDirect(delta);
            await WidgetsBinding.instance.endOfFrame;
          },
        ),
      );
    } else {
      _turnDirect(delta);
    }
  }

  Future<void> _showSolo(int page) async {
    try {
      final bytes = await _pageBytes(page);
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => PageImageView(
            bytes: bytes,
            directory: widget.repository.directory,
            title: widget.book.title,
            page: page,
            keepAwake:
                widget.repository.store.setting<bool>(
                  'keepScreenAwakeWhileReading',
                ) ==
                true,
            fullscreen:
                widget.repository.store.setting<bool>('autoFullscreenOnOpen') ==
                true,
          ),
        ),
      );
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _imageMenu() async {
    final first = _split
        ? _session.page
        : _session.firstPage(_session.itemIndex);
    final count = _split ? 1 : _session.visiblePages(_session.itemIndex);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => ReaderSafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (
                var page = first;
                page < first + count && page <= widget.book.pages;
                page++
              )
                ListTile(
                  title: Text(
                    tr(sheet, 'Show Page %d Solo').replaceAll('%d', '$page'),
                  ),
                  subtitle: Text(tr(sheet, 'Save Image')),
                  leading: const Icon(Icons.crop_portrait),
                  onTap: () {
                    Navigator.pop(sheet);
                    _showSolo(page);
                  },
                ),
              ListTile(
                title: Text(tr(sheet, 'Recognize Text')),
                leading: const Icon(Icons.text_fields),
                onTap: () {
                  Navigator.pop(sheet);
                  _recognizeText();
                },
              ),
              ListTile(
                title: Text(tr(sheet, 'Rotate Page')),
                leading: const Icon(Icons.rotate_right),
                onTap: () {
                  Navigator.pop(sheet);
                  _configure(
                    _session.preferences.copy(
                      rotation: (_session.preferences.rotation + 1) % 4,
                    ),
                  );
                },
              ),
            ],
          ),
        ).withWheelScrolling(),
      ),
    );
  }

  late ReadingSession _session;
  late ReaderProgressGate _progressGate;
  bool _preparing = false;
  Object? _preparationError;
  bool _openingHints = false;
  Timer? _hintTimer;
  Future<void> _prepareOffline() async {
    setState(() {
      _preparing = true;
      _preparationError = null;
    });
    try {
      await widget.repository.download(widget.book);
    } catch (error) {
      if (mounted) _preparationError = error;
    } finally {
      if (mounted) {
        setState(() => _preparing = false);
        _preload();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_session.preferences.pageLayout != 'auto') return;
    final size = MediaQuery.sizeOf(context);
    final spread = size.width > size.height;
    if (spread == _session.preferences.spread) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _session.preferences.pageLayout == 'auto' &&
          _session.preferences.spread != spread) {
        _configure(
          _session.preferences.copy(spread: spread, pageLayout: 'auto'),
        );
      }
    });
  }

  late final String? _readListId;
  late PageController _pages;
  final _zoom = TransformationController();
  int _gesturePage = 0;
  double _decodeZoom = 1;
  bool _scrolling = false, _interacting = false;
  Timer? _settleTimer;
  ThemeData? _readerTheme;
  Brightness? _readerBrightness;

  void _activity(bool active) {
    _interacting = active;
    if (active) {
      _settleTimer?.cancel();
      _preloadTimer?.cancel();
      _preloadGeneration++;
    } else {
      _settled();
    }
  }

  void _settled() {
    if (_previewing || _scrolling || _interacting || !mounted) return;
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 40), () {
      if (!mounted || _previewing || _scrolling || _interacting) return;
      _rememberPart();
      _commitIfReady();
      _preload();
    });
  }

  bool _scrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      _scrolling = true;
      _settleTimer?.cancel();
      _preloadTimer?.cancel();
      _preloadGeneration++;
    } else if (notification is ScrollEndNotification) {
      _scrolling = false;
      _settled();
    }
    return false;
  }

  void _zoomSettled(double scale) {
    final decode = scale > 1.1 ? 2.0 : 1.0;
    if (mounted && decode != _decodeZoom) setState(() => _decodeZoom = decode);
  }

  void _resetZoom() {
    _zoom.value = Matrix4.identity();
    _decodeZoom = 1;
  }

  void _tap(Offset point, Size size) {
    if (_zoom.value.getMaxScaleOnAxis() > 1.001) {
      setState(() => _controls = !_controls);
      return;
    }
    switch (tapAction(
      point.dx / size.width,
      point.dy / size.height,
      _session.preferences,
    )) {
      case TapAction.previous:
        _turn(-1);
      case TapAction.next:
        _turn(1);
      case TapAction.controls:
        setState(() => _controls = !_controls);
    }
  }

  final _scroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  bool _controls = true, _verticalReady = false;
  bool? _fullscreenOverride;
  bool get _isFullscreen =>
      _fullscreenOverride ??
      (widget.repository.store.setting<bool>('autoFullscreenOnOpen') == true);
  void _toggleFullscreen() => setState(() {
    final enabled = !_isFullscreen;
    _fullscreenOverride = enabled;
    _controls = !enabled;
  });
  final Set<int> _readyPages = {};
  List<Json> _dimensions = [];
  Map<int, double> _aspects = {};
  List<PagePart> _parts = [];
  Set<int> _splitPages = {};
  int _partIndex = 0, _geometryRevision = 0;
  bool _loadingDimensions = false;
  bool _dimensionsLoaded = false;
  bool _initialPartPending = false;
  Json _seriesMetadata = {};
  bool _loadingSeries = false;
  bool get _raster =>
      widget.book.format == 'comic' || widget.rasterPages != null;
  Future<Uint8List> _pageBytes(int page, {bool speculative = false}) =>
      widget.rasterPages?.page(page) ??
      (speculative
          ? widget.repository.prefetchPage(widget.book.id, page)
          : widget.repository.page(widget.book.id, page));
  Future<void> _loadSeriesDirection() async {
    if (_loadingSeries ||
        _seriesMetadata.isNotEmpty ||
        !_raster ||
        widget.book.seriesId.isEmpty ||
        !_session.preferences.useSeriesDirection) {
      return;
    }
    _loadingSeries = true;
    try {
      final series = object(
        await widget.repository.get(
          '/api/v1/series/${Uri.encodeComponent(widget.book.seriesId)}',
          cacheFirst: true,
          cacheKey: 'detail:series:${widget.book.seriesId}',
        ),
      );
      if (!mounted) return;
      _seriesMetadata = object(series['metadata']);
      if (_session.preferences.useSeriesDirection) {
        final resolved = seriesReaderPreferences(
          _session.preferences,
          _seriesMetadata,
        );
        if (resolved.mode != _session.preferences.mode ||
            resolved.direction != _session.preferences.direction) {
          _configure(resolved);
        }
      }
    } on ApiFailure {
      /* Existing reader defaults remain available offline. */
    } finally {
      _loadingSeries = false;
    }
  }

  bool get _split =>
      _session.preferences.mode == ReadingMode.paged &&
      ['auto', 'ltr', 'rtl'].contains(_session.preferences.splitWide) &&
      _parts.any((p) => p.half != 0);
  int get _viewIndex => _split ? _partIndex : _session.itemIndex;
  int get _viewCount => _split ? _parts.length : _session.itemCount;
  bool get _atEnd => _split ? _partIndex == _parts.length - 1 : _session.atEnd;
  Future<void> _loadDimensions() async {
    if (_loadingDimensions || _dimensionsLoaded || !_raster) {
      return;
    }
    _loadingDimensions = true;
    try {
      final data =
          widget.rasterPages?.dimensions ??
          await widget.repository.get(
            '/api/v1/books/${Uri.encodeComponent(widget.book.id)}/pages',
            cacheFirst: true,
          );
      if (!mounted) return;
      _dimensions = (data as List).map(object).toList();
      _aspects = {
        for (final page in _dimensions)
          if (integer(page['height']) > 0 && integer(page['width']) > 0)
            integer(page['number']):
                integer(page['width']) / integer(page['height']),
      };
      _dimensionsLoaded = true;
      if (_initialPartPending &&
          !widget.book.completed &&
          _session.preferences.splitWide != 'scroll') {
        final position = object(
          widget.repository.store.cached(
            widget.repository.profile.id,
            'readerPart:${widget.book.id}',
          ),
        );
        final local = DateTime.tryParse(text(position['modified']));
        final remote = DateTime.tryParse(
          text(widget.book.progress['lastModified']),
        );
        final page = integer(position['page']);
        if (page >= 1 &&
            page <= widget.book.pages &&
            local != null &&
            (remote == null || !remote.isAfter(local))) {
          _session.go(page);
          _parts = [PagePart(page, integer(position['half']))];
          _partIndex = 0;
        }
      }
      _initialPartPending = false;
      _geometryRevision++;
      _configure(_session.preferences);
    } catch (e) {
      if (mounted) {
        _dimensionsLoaded = true;
        _initialPartPending = false;
        _commitIfReady();
        showError(context, e);
      }
    } finally {
      _loadingDimensions = false;
    }
  }

  void _rebuildParts(ReaderPreferences p) {
    final oldHalf = _parts.elementAtOrNull(_partIndex)?.half ?? 0;
    _parts = pageParts(widget.book.pages, _dimensions, p);
    _splitPages = _parts
        .where((part) => part.half != 0)
        .map((part) => part.page)
        .toSet();
    var index = _parts.indexWhere(
      (part) => part.page == _session.page && part.half == oldHalf,
    );
    if (index < 0) {
      index = _parts.indexWhere((part) => part.page == _session.page);
    }
    _partIndex = index < 0 ? 0 : index;
  }

  late Json _savedPan = object(
    widget.repository.store.cached(
      widget.repository.profile.id,
      'readerPan:${widget.book.id}',
    ),
  );
  double _panFraction(int page) {
    if (integer(_savedPan['page']) != page ||
        _savedPan['direction'] != _session.preferences.direction.name) {
      return 0;
    }
    final saved = DateTime.tryParse(text(_savedPan['modified']));
    final remote = DateTime.tryParse(
      text(widget.book.progress['lastModified']),
    );
    if (saved == null || remote != null && remote.isAfter(saved)) return 0;
    return _savedPan['fraction'] is num
        ? (_savedPan['fraction'] as num).toDouble().clamp(0, 1)
        : 0;
  }

  void _savePan(int page, double fraction) {
    if (widget.incognito || !fraction.isFinite || !mounted) return;
    _savedPan = {
      'page': page,
      'fraction': fraction.clamp(0, 1),
      'direction': _session.preferences.direction.name,
      'modified': DateTime.now().toUtc().toIso8601String(),
    };
    widget.repository.store.cache(
      widget.repository.profile.id,
      'readerPan:${widget.book.id}',
      _savedPan,
    );
  }

  void _rememberPart() {
    if (widget.incognito || !_split) return;
    final part = _parts[_partIndex];
    widget.repository.store.cache(
      widget.repository.profile.id,
      'readerPart:${widget.book.id}',
      {
        'page': part.page,
        'half': part.half,
        'modified': DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  void _turnDirect(int delta) {
    _resetZoom();
    if (!_split) {
      if (_session.preferences.mode != ReadingMode.paged &&
          _scroll.isAttached) {
        final positions = _positions.itemPositions.value;
        final current = positions
            .where((item) => item.index == _session.page - 1)
            .firstOrNull;
        final height = current == null
            ? 1.0
            : current.itemTrailingEdge - current.itemLeadingEdge;
        final amount = _session.preferences.tapScroll / 100;
        final alignment = (current?.itemLeadingEdge ?? 0) - delta * amount;
        final target = alignment < -height
            ? _session.page
            : alignment > 1
            ? _session.page - 2
            : _session.page - 1;
        _scroll.scrollTo(
          index: target.clamp(0, widget.book.pages - 1),
          alignment: target == _session.page - 1
              ? alignment
              : delta > 0
              ? alignment + height
              : alignment - height,
          duration: Duration(
            milliseconds: _session.preferences.animate ? 240 : 1,
          ),
        );
      } else {
        _go(
          _session.firstPage(
            (_session.itemIndex + delta).clamp(0, _session.itemCount - 1),
          ),
        );
      }
      return;
    }
    final index = (_partIndex + delta).clamp(0, _parts.length - 1);
    if (_session.preferences.animate &&
        !MediaQuery.disableAnimationsOf(context) &&
        _session.preferences.transition != 'curl') {
      _pages.animateToPage(
        index,
        duration: Duration(milliseconds: _session.preferences.motion.duration),
        curve: Curves.easeInOutCubic,
      );
    } else {
      _pages.jumpToPage(index);
    }
  }

  Widget _motion(int index, Widget child, Color background) =>
      _session.preferences.animate && !MediaQuery.disableAnimationsOf(context)
      ? CoverPage(
          controller: _pages,
          index: index,
          reverse: _session.preferences.direction == ReadingDirection.rtl,
          background: background,
          motion: _session.preferences.motion,
          cover: _session.preferences.transition == 'cover',
          child: child,
        )
      : child;

  Timer? _preloadTimer;
  int _preloadGeneration = 0;
  void _preload() {
    _preloadTimer?.cancel();
    final generation = ++_preloadGeneration;
    if (!_raster ||
        _scrolling ||
        _interacting ||
        _preparing ||
        _preparationError != null) {
      return;
    }
    final anchor = _session.page;
    final window = preloadWindow(_session.preferences.preload);
    _preloadTimer = Timer(const Duration(milliseconds: 80), () async {
      final width =
          (MediaQuery.sizeOf(context).width *
                  MediaQuery.devicePixelRatioOf(context))
              .ceil()
              .clamp(1, 4096);
      final candidates = [
        for (var i = 1; i <= window.after; i++) anchor + i,
        for (var i = 1; i <= window.before; i++) anchor - i,
      ];
      for (final page in candidates) {
        if (!mounted || generation != _preloadGeneration) return;
        if (page < 1 || page > widget.book.pages) continue;
        try {
          final bytes = await _pageBytes(page, speculative: true);
          if (!mounted || generation != _preloadGeneration) return;
          var factor = _splitPages.contains(page) ? 2.0 : 1.0;
          final settings = _session.preferences;
          final originalAspect = _aspects[page] ?? 1;
          final aspect = settings.rotation.isOdd
              ? 1 / originalAspect
              : originalAspect;
          if (settings.mode == ReadingMode.paged &&
              settings.splitWide == 'scroll' &&
              aspect > 1) {
            final size = MediaQuery.sizeOf(context);
            factor = (size.height * aspect / size.width).clamp(1, 8).toDouble();
          }
          await precacheImage(
            ResizeImage.resizeIfNeeded(
              (width * factor).ceil().clamp(1, 4096),
              null,
              MemoryImage(bytes),
            ),
            context,
            onError: (_, _) {},
          );
        } catch (_) {
          // Visible pages retain their own retry UI; preloading is optional.
        }
      }
    });
  }

  void _commitIfReady() {
    if (_previewing || _scrolling || _interacting) return;
    if (['auto', 'ltr', 'rtl'].contains(_session.preferences.splitWide) &&
        !_dimensionsLoaded) {
      return;
    }
    if (_split) {
      final part = _parts[_partIndex];
      if (_partIndex < _parts.length - 1 &&
          _parts[_partIndex + 1].page == part.page) {
        return;
      }
      if (_readyPages.contains(part.page)) _session.rendered(part.page);
      return;
    }
    final first = _session.firstPage(_session.itemIndex);
    for (
      var page = first;
      page < first + _session.visiblePages(_session.itemIndex) &&
          page <= widget.book.pages;
      page++
    ) {
      if (!_readyPages.contains(page)) return;
    }
    _session.rendered(first);
  }

  late final FocusNode _focus;
  @override
  void initState() {
    super.initState();
    widget.repository.readerOpened(widget.book.id);
    _readListId =
        widget.readListId ?? widget.repository.readLists.owner(widget.book.id);
    if (!widget.incognito && _readListId != null) {
      unawaited(
        widget.repository.readLists.record(_readListId, widget.book.id),
      );
    }
    _focus = FocusNode();
    final json = widget.repository.store.cached(
      widget.repository.profile.id,
      'reader:${widget.book.id}',
    );
    final defaults = widget.repository.store.setting<dynamic>('readerDefault');
    final initial = {
      ...object(defaults),
      ...?widget.initialPreferences?.toJson(),
      ...object(json),
    };
    if (initial['pageLayout'] == 'dual-forced') initial['spread'] = true;
    if (initial['pageLayout'] == 'single') initial['spread'] = false;
    if (json != null && !initial.containsKey('useSeriesDirection')) {
      initial['useSeriesDirection'] = false;
    }
    _seriesMetadata = object(
      object(
        widget.repository.store.cached(
          widget.repository.profile.id,
          'detail:series:${widget.book.seriesId}',
        ),
      )['metadata'],
    );
    _progressGate = ReaderProgressGate(
      widget.book,
      widget.repository.store.setting<int>('progressRecordingThreshold') ?? 0,
    );
    _controls =
        widget.repository.store.setting<bool>('autoFullscreenOnOpen') != true;
    _session = ReadingSession(
      count: widget.book.pages,
      initialPage: widget.book.completed ? 1 : widget.book.page,
      preferences: seriesReaderPreferences(
        ReaderPreferences.fromJson(initial),
        _seriesMetadata,
      ),
      incognito: widget.incognito,
      onCommit: (page) {
        if (_progressGate.allows(page)) {
          widget.repository.setProgress(widget.book, page);
        }
      },
    );
    _rebuildParts(_session.preferences);
    _initialPartPending = _session.preferences.splitWide != 'none';
    _openingHints = _session.preferences.showTapHints;
    _hintTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _openingHints = false);
    });
    if (!widget.incognito &&
        widget.repository.store.setting<bool>('offlineFirstReading') == true) {
      _preparing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _prepareOffline();
      });
    }
    _pages = PageController(initialPage: _viewIndex);
    _positions.itemPositions.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focus.requestFocus();
        _verticalReady = true;
        _preload();
        if (_session.preferences.splitWide != 'none') _loadDimensions();
        _loadSeriesDirection();
      }
    });
  }

  @override
  void dispose() {
    _documentLease?.close();
    _hintTimer?.cancel();
    widget.repository.readerClosed(widget.book, incognito: widget.incognito);
    _preloadGeneration++;
    _preloadTimer?.cancel();
    _settleTimer?.cancel();
    _zoom.dispose();
    _focus.dispose();
    _pages.dispose();
    _positions.itemPositions.removeListener(_onScroll);
    _session.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_verticalReady || _session.preferences.mode == ReadingMode.paged) {
      return;
    }
    final visible =
        _positions.itemPositions.value
            .where((p) => p.itemTrailingEdge > .1 && p.itemLeadingEdge < .5)
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    if (visible.isNotEmpty && visible.first.index + 1 != _session.page) {
      setState(() => _session.go(visible.first.index + 1));
      _settled();
    }
  }

  void _go(int page) {
    _resetZoom();
    _session.go(page);
    if (_split) {
      _partIndex = _parts.indexWhere((part) => part.page == _session.page);
    }
    if (_session.preferences.mode == ReadingMode.paged && _pages.hasClients) {
      if (!_session.preferences.animate ||
          MediaQuery.disableAnimationsOf(context) ||
          _session.preferences.transition == 'curl') {
        _pages.jumpToPage(_viewIndex);
        setState(() {});
        _settled();
        return;
      }
      _pages.animateToPage(
        _viewIndex,
        duration: Duration(milliseconds: _session.preferences.motion.duration),
        curve: Curves.easeInOutCubic,
      );
    } else if (_scroll.isAttached) {
      _scroll.scrollTo(
        index: _session.page - 1,
        duration: const Duration(milliseconds: 240),
      );
    }
    setState(() {});
    _settled();
  }

  void _configure(ReaderPreferences preferences) {
    _curl.currentState?.cancelGesture();
    preferences = seriesReaderPreferences(preferences, _seriesMetadata);
    final old = _pages;
    _resetZoom();
    _scrolling = false;
    setState(() {
      _verticalReady = false;
      _session.configure(preferences);
      _rebuildParts(preferences);
      _pages = PageController(initialPage: _viewIndex);
    });
    widget.repository.store.cache(
      widget.repository.profile.id,
      'reader:${widget.book.id}',
      preferences.toJson(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      old.dispose();
      _verticalReady = true;
      if (mounted) _preload();
      if (mounted && preferences.splitWide != 'none') _loadDimensions();
      if (mounted &&
          preferences.useSeriesDirection &&
          _seriesMetadata.isEmpty) {
        _loadSeriesDirection();
      }
    });
  }

  DocumentLease? _documentLease;
  Future<File> _document() async {
    final lease = await widget.repository.documents.open(
      widget.book,
      pinned: widget.repository.bookFile(widget.book),
      offline: widget.repository.offline,
    );
    if (!mounted) {
      lease.close();
      throw StateError('Reader closed');
    }
    _documentLease?.close();
    _documentLease = lease;
    return lease.file;
  }

  bool _ocrOpening = false;
  Future<void> _recognizeText() async {
    if (_ocrOpening) return;
    setState(() => _ocrOpening = true);
    try {
      final bytes = await _pageBytes(_session.page);
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderDisplay(
            child: ReaderTextPage(
              providers: TranslationProviders(widget.repository.store),
              bytes: bytes,
              ocr: widget.repository.ocr,
              detector: widget.repository.bubbles,
              title: '${widget.book.title} · ${_session.page}',
              sourceLanguage:
                  text(
                    widget.book.metadata['language'],
                    text(_seriesMetadata['language']),
                  ).isEmpty
                  ? null
                  : text(
                      widget.book.metadata['language'],
                      text(_seriesMetadata['language']),
                    ),
              contextMetadata:
                  '${widget.book.seriesTitle} · ${widget.book.title} · ${widget.book.metadata['authors'] ?? ''} · ${widget.book.metadata['genres'] ?? ''}',
              incognito: widget.incognito,
            ),
          ),
        ),
      );
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _ocrOpening = false);
    }
  }

  Future<void> _nextBook() async {
    if (_openingNext) return;
    setState(() => _openingNext = true);
    try {
      if (widget.onNextBook != null) {
        await widget.onNextBook!();
        return;
      }
      final next = await NextBookResolver(widget.repository)
          .after(widget.book, readListId: _readListId);
      if (!mounted || next == null) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ReaderPage(
            repository: widget.repository,
            book: next,
            incognito: widget.incognito,
            readListId: _readListId,
          ),
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _openingNext = false);
    }
  }

  bool _openingNext = false;

  void _settings() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 760),
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, update) {
        void apply(ReaderPreferences p) {
          _configure(p);
          update(() {});
        }

        final p = _session.preferences;
        return ReaderSafeArea(
          child: ReaderOptionsPanel(
            title: 'Reader Settings',
            children:
                [
                      Wrap(
                        spacing: 10,
                        children: [
                          for (final mode in ReadingMode.values)
                            ChoiceChip(
                              label: Text(switch (mode) {
                                ReadingMode.paged => tr(context, 'Paged'),
                                ReadingMode.vertical => tr(context, 'Vertical'),
                                ReadingMode.webtoon => 'Webtoon',
                              }),
                              selected: p.mode == mode,
                              onSelected: (_) => apply(
                                p.copy(mode: mode, useSeriesDirection: false),
                              ),
                            ),
                        ],
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          tr(context, 'Use Series Reading Direction'),
                        ),
                        value: p.useSeriesDirection,
                        onChanged: (value) =>
                            apply(p.copy(useSeriesDirection: value)),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr(context, 'Right to Left')),
                        value: p.direction == ReadingDirection.rtl,
                        onChanged: (v) => apply(
                          p.copy(
                            direction: v
                                ? ReadingDirection.rtl
                                : ReadingDirection.ltr,
                            useSeriesDirection: false,
                          ),
                        ),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr(context, 'Double Page')),
                        value: p.spread,
                        onChanged:
                            p.mode == ReadingMode.paged && p.splitWide == 'none'
                            ? (v) => apply(p.copy(spread: v))
                            : null,
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr(context, 'Split Wide Pages')),
                        subtitle: Text(
                          tr(
                            context,
                            {
                                  'none': 'reader.tapZoneMode.none',
                                  'auto': 'reader.tapZoneMode.auto',
                                  'ltr': 'Left to Right',
                                  'rtl': 'Right to Left',
                                  'scroll': 'reader.splitWidePage.scroll',
                                }[p.splitWide] ??
                                p.splitWide,
                          ),
                        ),
                        onTap: () async {
                          final value = await chooseValue(
                            context,
                            title: 'Split Wide Pages',
                            selected: p.splitWide,
                            choices: {
                              'none': 'reader.tapZoneMode.none',
                              'auto': 'reader.tapZoneMode.auto',
                              'ltr': 'Left to Right',
                              'rtl': 'Right to Left',
                              'scroll': 'reader.splitWidePage.scroll',
                            },
                          );
                          if (value != null && mounted && context.mounted) {
                            apply(p.copy(splitWide: value, spread: false));
                          }
                        },
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr(context, 'Page Fit')),
                        subtitle: Text(
                          tr(
                            context,
                            {
                                  'contain': 'Fit Page',
                                  'fitWidth': 'Fit Width',
                                  'cover': 'Fill Screen',
                                }[p.fit] ??
                                'Fit Page',
                          ),
                        ),
                        onTap: () async {
                          final fit = await chooseValue(
                            context,
                            title: 'Page Fit',
                            selected: p.fit,
                            choices: {
                              'contain': 'Fit Page',
                              'fitWidth': 'Fit Width',
                              'cover': 'Fill Screen',
                            },
                          );
                          if (fit != null && mounted && context.mounted) {
                            apply(p.copy(fit: fit));
                          }
                        },
                      ),
                      if (Theme.of(context).platform == TargetPlatform.android)
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(tr(context, 'Use Display Cutout')),
                          subtitle: Text(
                            tr(
                              context,
                              'Allow the page behind the camera notch',
                            ),
                          ),
                          value: p.extendIntoCutout,
                          onChanged: (value) =>
                              apply(p.copy(extendIntoCutout: value)),
                        ),
                      for (final setting in [
                        'tapMode',
                        'tapInversion',
                        'preload',
                      ])
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            tr(
                              context,
                              {
                                'tapMode': 'Tap Zones',
                                'tapInversion': 'Tap Zone Inversion',
                                'preload': 'Preloading',
                              }[setting]!,
                            ),
                          ),
                          subtitle: Text(
                            tr(
                              context,
                              {
                                'tapMode': p.tapMode,
                                'tapInversion': p.tapInversion,
                                'preload': p.preload,
                              }[setting]!,
                            ),
                          ),
                          onTap: () async {
                            final choices = switch (setting) {
                              'tapMode' => {
                                'none': 'reader.tapZoneMode.none',
                                'default': 'reader.tapZoneMode.default',
                                'edge': 'reader.tapZoneMode.edge',
                                'kindle': 'reader.tapZoneMode.kindle',
                                'lShape': 'reader.tapZoneMode.lShape',
                                'tSplit': 'reader.tapZoneMode.tSplit',
                              },
                              'tapInversion' => {
                                'auto': 'reader.tapZoneInversionMode.auto',
                                'normal': 'reader.tapZoneInversionMode.normal',
                                'inverted':
                                    'reader.tapZoneInversionMode.inverted',
                              },
                              _ => {
                                'lowMemory': 'Low Memory',
                                'balanced': 'Balanced',
                                'fastPageTurns': 'Fast Page Turns',
                              },
                            };
                            final selected = await chooseValue(
                              context,
                              title: {
                                'tapMode': 'Tap Zones',
                                'tapInversion': 'Tap Zone Inversion',
                                'preload': 'Preloading',
                              }[setting]!,
                              selected: {
                                'tapMode': p.tapMode,
                                'tapInversion': p.tapInversion,
                                'preload': p.preload,
                              }[setting]!,
                              choices: choices,
                            );
                            if (selected != null &&
                                mounted &&
                                context.mounted) {
                              apply(switch (setting) {
                                'tapMode' => p.copy(tapMode: selected),
                                'tapInversion' => p.copy(
                                  tapInversion: selected,
                                ),
                                _ => p.copy(preload: selected),
                              });
                            }
                          },
                        ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr(context, 'Border Cropping')),
                        subtitle: Text(
                          tr(
                            context,
                            {
                              'disabled': 'Disabled',
                              'conservative': 'Conservative',
                              'aggressive': 'Aggressive',
                            }[p.borderCrop]!,
                          ),
                        ),
                        onTap: () async {
                          final value = await chooseValue(
                            context,
                            title: 'Border Cropping',
                            selected: p.borderCrop,
                            choices: const {
                              'disabled': 'Disabled',
                              'conservative': 'Conservative',
                              'aggressive': 'Aggressive',
                            },
                          );
                          if (value != null && mounted && context.mounted) {
                            apply(p.copy(borderCrop: value));
                          }
                        },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr(context, 'Waifu2x Upscaling')),
                        subtitle: Text(
                          tr(
                            context,
                            'Automatically enhance low-resolution pages',
                          ),
                        ),
                        value:
                            widget.repository.store.setting<String>(
                              'imageUpscalingMode',
                            ) ==
                            'auto',
                        onChanged: (value) {
                          widget.repository.store.setSetting(
                            'imageUpscalingMode',
                            value ? 'auto' : 'disabled',
                          );
                          apply(p);
                        },
                      ),
                      if (widget.repository.store.setting<String>(
                            'imageUpscalingMode',
                          ) ==
                          'auto')
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(tr(context, 'Upscale Trigger Scale')),
                          subtitle: Slider(
                            value:
                                (widget.repository.store.setting<double>(
                                          'imageUpscaleAutoTriggerScale',
                                        ) ??
                                        1.05)
                                    .clamp(1, 3),
                            min: 1,
                            max: 3,
                            divisions: 40,
                            label:
                                '${(widget.repository.store.setting<double>('imageUpscaleAutoTriggerScale') ?? 1.05).toStringAsFixed(2)}x',
                            onChanged: (value) {
                              widget.repository.store.setSetting(
                                'imageUpscaleAutoTriggerScale',
                                value,
                              );
                              update(() {});
                            },
                            onChangeEnd: (_) => apply(p),
                          ),
                        ),
                      Text(tr(context, 'Double Tap Zoom Scale')),
                      Row(
                        children: [
                          Expanded(
                            child: Slider(
                              value: p.doubleTapZoom,
                              min: 1,
                              max: 8,
                              divisions: 14,
                              label: '${p.doubleTapZoom.toStringAsFixed(1)}×',
                              onChanged: (value) =>
                                  apply(p.copy(doubleTapZoom: value)),
                            ),
                          ),
                          Text('${p.doubleTapZoom.toStringAsFixed(1)}×'),
                        ],
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr(context, 'Page Transition Style')),
                        subtitle: Text(
                          tr(
                            context,
                            p.transition == 'curl'
                                ? 'reader.page_transition.page_curl'
                                : p.transition == 'cover'
                                ? 'reader.page_transition.cover'
                                : 'reader.page_transition.scroll',
                          ),
                        ),
                        onTap: () async {
                          final value = await chooseValue(
                            context,
                            title: 'Page Transition Style',
                            selected: p.transition,
                            choices: const {
                              'slide': 'reader.page_transition.scroll',
                              'cover': 'reader.page_transition.cover',
                              'curl': 'reader.page_transition.page_curl',
                            },
                          );
                          if (value != null && mounted && context.mounted) {
                            apply(p.copy(transition: value));
                          }
                        },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr(context, 'Page Turn Animation')),
                        value: p.animate,
                        onChanged: (v) => apply(p.copy(animate: v)),
                      ),
                      ReaderMotionOptions(
                        motion: p.motion,
                        onChanged: (motion) => apply(p.copy(motion: motion)),
                      ),
                      TextButton(
                        onPressed: () {
                          widget.repository.store.setSetting(
                            'readerDefault',
                            p.toJson(),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(tr(context, 'Saved'))),
                          );
                        },
                        child: Text(tr(context, 'Use as Default')),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr(context, 'Rotate Page')),
                        trailing: const Icon(CupertinoIcons.rotate_right),
                        onTap: () =>
                            apply(p.copy(rotation: (p.rotation + 1) % 4)),
                      ),
                      Wrap(
                        spacing: 10,
                        children: [
                          for (final c in ['black', 'white', 'sepia'])
                            ChoiceChip(
                              label: Text(tr(context, c)),
                              selected: p.background == c,
                              onSelected: (_) => apply(p.copy(background: c)),
                            ),
                        ],
                      ),
                    ]
                    .map(
                      (child) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: child,
                      ),
                    )
                    .toList(),
          ),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (_preparing || _preparationError != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.book.title)),
        body: _preparationError == null
            ? const Center(child: CircularProgressIndicator.adaptive())
            : FailureView(error: _preparationError!, retry: _prepareOffline),
      );
    }
    if (!_raster) {
      return ReaderDisplay(
        keepAwake:
            widget.repository.store.setting<bool>(
              'keepScreenAwakeWhileReading',
            ) ==
            true,
        showKeyboardHelp:
            widget.repository.store.setting<bool>('showKeyboardHelpOverlay') !=
            false,
        fullscreen:
            widget.repository.store.setting<bool>('autoFullscreenOnOpen') ==
            true,
        child: DocumentReader(
          onNextBook: _nextBook,
          repository: widget.repository,
          book: widget.book,
          load: _document,
          incognito: widget.incognito,
        ),
      );
    }
    final settings = _session.preferences;
    final background = switch (settings.background) {
      'white' => Colors.white,
      'sepia' => const Color(0xffefe5d0),
      'gray' => Colors.grey,
      'system' => Theme.of(context).colorScheme.surface,
      _ => Colors.black,
    };
    final modeKey =
        '${settings.mode}:${settings.spread}:${settings.direction}:${settings.splitWide}:$_geometryRevision';
    final scaffold = Scaffold(
      backgroundColor: background,
      body: Focus(
        focusNode: _focus,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.escape) {
            if (!_controls || _isFullscreen) {
              setState(() {
                _fullscreenOverride = false;
                _controls = true;
              });
            } else {
              Navigator.maybePop(context);
            }
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.f11) {
            _toggleFullscreen();
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.space) {
            if (widget.repository.store.setting<String>('spaceKeyAction') ==
                'nextPage') {
              _turn(1);
            } else {
              setState(() => _controls = !_controls);
            }
            return KeyEventResult.handled;
          }
          final rtl = settings.direction == ReadingDirection.rtl;
          if (key == LogicalKeyboardKey.arrowDown ||
              key == LogicalKeyboardKey.pageDown ||
              key ==
                  (rtl
                      ? LogicalKeyboardKey.arrowLeft
                      : LogicalKeyboardKey.arrowRight)) {
            _turn(1);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowUp ||
              key == LogicalKeyboardKey.pageUp ||
              key ==
                  (rtl
                      ? LogicalKeyboardKey.arrowRight
                      : LogicalKeyboardKey.arrowLeft)) {
            _turn(-1);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: ReaderPageSurface(
                extendIntoCutout: settings.extendIntoCutout,
                child: ReaderPageTransition(
                  key: _curl,
                  captureImage: _capturePageImage,
                  motion: settings.motion,
                  child: RepaintBoundary(
                    key: _pageBoundary,
                    child: GestureDetector(
                      onLongPress: settings.liveText
                          ? _recognizeText
                          : settings.imageContextMenu
                          ? _imageMenu
                          : null,
                      child: NotificationListener<ScrollNotification>(
                        onNotification: _scrollNotification,
                        child: widget.book.pages == 0
                            ? EmptyView(
                                title: 'No Pages',
                                message: 'This book has no readable pages.',
                                icon: CupertinoIcons.book,
                              )
                            : settings.mode == ReadingMode.paged
                            ? LayoutBuilder(
                                builder: (context, constraints) =>
                                    ReaderViewport(
                                      controller: _zoom,
                                      doubleTapZoom: settings.doubleTapEnabled
                                          ? settings.doubleTapZoom
                                          : 1,
                                      onContact: () =>
                                          _gesturePage = _pages.hasClients
                                          ? (_pages.page ?? 0).round()
                                          : _viewIndex,
                                      onPinch: () {
                                        if (_pages.hasClients) {
                                          _pages.jumpToPage(_gesturePage);
                                        }
                                      },
                                      startScroll: _pageDrag,
                                      onActivityChanged: _activity,
                                      onZoomSettled: _zoomSettled,
                                      onTap: (point) =>
                                          _tap(point, constraints.biggest),
                                      onWheel: (delta) {
                                        if (!_scrolling && delta != 0) {
                                          _turn(delta.sign.toInt());
                                        }
                                      },
                                      child: PageView.builder(
                                        key: ValueKey(modeKey),
                                        controller: _pages,
                                        physics:
                                            const NeverScrollableScrollPhysics(),
                                        allowImplicitScrolling: true,
                                        reverse:
                                            settings.direction ==
                                            ReadingDirection.rtl,
                                        itemCount: _viewCount,
                                        onPageChanged: (index) {
                                          if (_previewing) return;
                                          setState(() {
                                            _resetZoom();
                                            _partIndex = index;
                                            _session.go(
                                              _split
                                                  ? _parts[index].page
                                                  : _session.firstPage(index),
                                            );
                                          });
                                          _settled();
                                        },
                                        itemBuilder: (context, index) {
                                          if (_split) {
                                            final part = _parts[index];
                                            return _motion(
                                              index,
                                              _PageImage(
                                                rasterPages: widget.rasterPages,
                                                repository: widget.repository,
                                                book: widget.book,
                                                page: part.page,
                                                half: part.half,
                                                halfAspect: part.aspect,
                                                decodeZoom: index == _viewIndex
                                                    ? _decodeZoom
                                                    : 1,
                                                preferences: settings,
                                                onReady: () {
                                                  _readyPages.add(part.page);
                                                  _commitIfReady();
                                                },
                                              ),
                                              background,
                                            );
                                          }
                                          final page = _session.firstPage(
                                            index,
                                          );
                                          final children = [
                                            for (
                                              var i = page;
                                              i <
                                                      page +
                                                          _session.visiblePages(
                                                            index,
                                                          ) &&
                                                  i <= widget.book.pages;
                                              i++
                                            )
                                              Expanded(
                                                child: _PageImage(
                                                  rasterPages:
                                                      widget.rasterPages,
                                                  repository: widget.repository,
                                                  book: widget.book,
                                                  page: i,
                                                  pageAspect: _aspects[i] ?? 1,
                                                  initialPan: _panFraction(i),
                                                  onPanSettled: (fraction) =>
                                                      _savePan(i, fraction),
                                                  active: index == _viewIndex,
                                                  startPageScroll: (details) =>
                                                      _pages.hasClients
                                                      ? _pages.position.drag(
                                                          details,
                                                          () {},
                                                        )
                                                      : null,
                                                  onWideTap: _tap,
                                                  onControls: () => setState(
                                                    () =>
                                                        _controls = !_controls,
                                                  ),
                                                  decodeZoom:
                                                      index == _viewIndex
                                                      ? _decodeZoom
                                                      : 1,
                                                  preferences: settings,
                                                  onReady: () {
                                                    _readyPages.add(i);
                                                    _commitIfReady();
                                                  },
                                                ),
                                              ),
                                          ];
                                          return _motion(
                                            index,
                                            Row(
                                              textDirection:
                                                  settings.direction ==
                                                      ReadingDirection.rtl
                                                  ? TextDirection.rtl
                                                  : TextDirection.ltr,
                                              children: children,
                                            ),
                                            background,
                                          );
                                        },
                                      ),
                                    ),
                              )
                            : ScrollablePositionedList.builder(
                                key: ValueKey(modeKey),
                                itemScrollController: _scroll,
                                physics: const NeverScrollableScrollPhysics(),
                                itemPositionsListener: _positions,
                                initialScrollIndex: _session.page - 1,
                                itemCount: widget.book.pages,
                                itemBuilder: (context, index) =>
                                    GestureDetector(
                                      onTapUp: (details) => _tap(
                                        details.localPosition,
                                        MediaQuery.sizeOf(context),
                                      ),
                                      child: FractionallySizedBox(
                                        widthFactor:
                                            settings.mode == ReadingMode.webtoon
                                            ? settings.webtoonWidth / 100
                                            : 1,
                                        child: Padding(
                                          padding: EdgeInsets.only(
                                            bottom:
                                                settings.mode ==
                                                    ReadingMode.webtoon
                                                ? 0
                                                : 12,
                                          ),
                                          child: _PageImage(
                                            rasterPages: widget.rasterPages,
                                            repository: widget.repository,
                                            book: widget.book,
                                            page: index + 1,
                                            preferences: settings,
                                            vertical: true,
                                            onActivityChanged: _activity,
                                            onReady: () {
                                              _readyPages.add(index + 1);
                                              _commitIfReady();
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (!_controls && settings.showPageNumber)
              Positioned(
                bottom: 16,
                right: 16,
                child: ReaderSafeArea(
                  child: IgnorePointer(
                    child: Text(
                      '${_session.page} / ${widget.book.pages}',
                      style: const TextStyle(
                        color: Colors.white,
                        shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                      ),
                    ),
                  ),
                ),
              ),
            if (!_controls && settings.showProgress)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: LinearProgressIndicator(
                    value: widget.book.pages == 0
                        ? 0
                        : _session.page / widget.book.pages,
                    minHeight: 3,
                  ),
                ),
              ),
            if (_openingHints)
              Positioned.fill(
                child: ReaderPageSurface(
                  extendIntoCutout: settings.extendIntoCutout,
                  child: TapZoneHints(preferences: settings),
                ),
              ),
            if (_controls)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: settings.controlsGradient
                        ? LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: const [
                              Color(0xe6000000),
                              Color(0x22000000),
                            ],
                          )
                        : null,
                  ),
                  child: ReaderSafeArea(
                    bottom: false,
                    child: Row(
                      children: [
                        IconButton(
                          color: Colors.white,
                          tooltip: tr(context, 'Close'),
                          icon: const Icon(CupertinoIcons.xmark),
                          onPressed: () => Navigator.pop(context),
                        ),
                        Expanded(
                          child: Text(
                            widget.book.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (widget.incognito)
                          const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(
                              CupertinoIcons.eye_slash,
                              color: Colors.white,
                            ),
                          ),
                        IconButton(
                          color: Colors.white,
                          tooltip: tr(
                            context,
                            _isFullscreen ? 'Exit Full Screen' : 'Full Screen',
                          ),
                          onPressed: _toggleFullscreen,
                          icon: const Icon(
                            CupertinoIcons.arrow_up_left_arrow_down_right,
                          ),
                        ),
                        IconButton(
                          color: Colors.white,
                          tooltip: tr(context, 'Recognize Text'),
                          onPressed: _ocrOpening ? null : _recognizeText,
                          icon: const Icon(Icons.text_fields),
                        ),
                        IconButton(
                          color: Colors.white,
                          onPressed: _settings,
                          tooltip: tr(context, 'Reader Settings'),
                          icon: const Icon(CupertinoIcons.slider_horizontal_3),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_controls && widget.book.pages > 0)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: settings.controlsGradient
                        ? LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: const [
                              Color(0xe6000000),
                              Color(0x22000000),
                            ],
                          )
                        : null,
                  ),
                  child: ReaderSafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            IconButton(
                              color: Colors.white,
                              onPressed: () => _turn(-1),
                              icon: const Icon(CupertinoIcons.chevron_left),
                            ),
                            Expanded(
                              child: Slider(
                                value: _session.page.toDouble(),
                                min: 1,
                                max: widget.book.pages > 1
                                    ? widget.book.pages.toDouble()
                                    : 2,
                                onChanged: widget.book.pages <= 1
                                    ? null
                                    : (v) => _go(v.round()),
                              ),
                            ),
                            IconButton(
                              color: Colors.white,
                              onPressed: () => _turn(1),
                              icon: const Icon(CupertinoIcons.chevron_right),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '${_session.page} / ${widget.book.pages}${_split && _parts[_partIndex].half != 0 ? ' · ${_parts[_partIndex].half == 1 ? tr(context, 'Left') : tr(context, 'Right')}' : ''}',
                                style: const TextStyle(color: Colors.white),
                              ),
                              if (_atEnd)
                                TextButton(
                                  onPressed: _openingNext ? null : _nextBook,
                                  child: Text(
                                    tr(context, 'Next Book'),
                                    style: const TextStyle(color: Colors.white),
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
          ],
        ),
      ),
    );
    final brightness = settings.background == 'system'
        ? Theme.of(context).brightness
        : settings.background == 'black'
        ? Brightness.dark
        : Brightness.light;
    if (_readerTheme == null || brightness != _readerBrightness) {
      _readerBrightness = brightness;
      _readerTheme = appTheme(brightness);
    }
    return Theme(
      data: _readerTheme!,
      child: ReaderDisplay(
        keepAwake:
            widget.repository.store.setting<bool>(
              'keepScreenAwakeWhileReading',
            ) ==
            true,
        showKeyboardHelp:
            widget.repository.store.setting<bool>('showKeyboardHelpOverlay') !=
            false,
        fullscreen:
            _fullscreenOverride ??
            (widget.repository.store.setting<bool>('autoFullscreenOnOpen') ==
                true),
        child: scaffold,
      ),
    );
  }
}

class _PageImage extends StatefulWidget {
  const _PageImage({
    required this.repository,
    required this.book,
    required this.page,
    required this.preferences,
    required this.onReady,
    this.vertical = false,
    this.half = 0,
    this.halfAspect = 1,
    this.decodeZoom = 1,
    this.onActivityChanged,
    this.pageAspect = 1,
    this.initialPan = 0,
    this.onPanSettled,
    this.active = true,
    this.startPageScroll,
    this.onWideTap,
    this.onControls,
    this.rasterPages,
  });
  final RasterPages? rasterPages;
  final double pageAspect, initialPan;
  final ValueChanged<double>? onPanSettled;
  final bool active;
  final Drag? Function(DragStartDetails)? startPageScroll;
  final void Function(Offset, Size)? onWideTap;
  final VoidCallback? onControls;
  final Repository repository;
  final Book book;
  final int page;
  final ReaderPreferences preferences;
  final VoidCallback onReady;
  final bool vertical;
  final int half;
  final double halfAspect, decodeZoom;
  final ValueChanged<bool>? onActivityChanged;
  @override
  State<_PageImage> createState() => _PageImageState();
}

class _PageImageState extends State<_PageImage>
    with AutomaticKeepAliveClientMixin {
  late Future<(Uint8List, PageCrop?)> _future;
  Future<(Uint8List, PageCrop?)> _load({bool refresh = false}) async {
    final bytes = widget.rasterPages != null
        ? await widget.rasterPages!.page(widget.page, refresh: refresh)
        : refresh
        ? await widget.repository.refreshPage(widget.book.id, widget.page)
        : await widget.repository.page(widget.book.id, widget.page);
    return (bytes, await pageCrop(bytes, widget.preferences.borderCrop));
  }

  final _transform = TransformationController();
  bool _reported = false;
  double _verticalStart = 0, _verticalDecode = 1, _wideDecode = 1;
  bool _gestureActive = false;
  @override
  bool get wantKeepAlive => widget.vertical && _gestureActive;
  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_PageImage old) {
    super.didUpdateWidget(old);
    if (old.page != widget.page ||
        old.book.id != widget.book.id ||
        old.half != widget.half ||
        old.preferences.borderCrop != widget.preferences.borderCrop) {
      _reported = false;
      _future = _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final content = FutureBuilder<(Uint8List, PageCrop?)>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SizedBox(
            height: widget.vertical ? 300 : null,
            child: FailureView(
              error: snapshot.error!,
              retry: () => setState(() {
                _reported = false;
                _future = _load();
              }),
            ),
          );
        }
        if (!snapshot.hasData) {
          return SizedBox(
            height: widget.vertical ? 400 : null,
            child: const Center(child: CircularProgressIndicator.adaptive()),
          );
        }
        final crop = snapshot.data!.$2;
        final halfAspect = crop == null ? widget.halfAspect : crop.aspect / 2;
        final aspect = crop?.aspect ?? widget.pageAspect;
        final orientedAspect = widget.preferences.rotation.isOdd
            ? 1 / aspect
            : aspect;
        final wide =
            !widget.vertical &&
            widget.half == 0 &&
            widget.preferences.splitWide == 'scroll' &&
            orientedAspect > 1 &&
            widget.startPageScroll != null;
        final decodeFactor = wide
            ? (MediaQuery.sizeOf(context).height *
                          orientedAspect /
                          MediaQuery.sizeOf(context).width)
                      .clamp(1, 8) *
                  _wideDecode
            : widget.vertical
            ? _verticalDecode
            : widget.decodeZoom;
        final fit = widget.vertical
            ? BoxFit.fitWidth
            : switch (widget.preferences.fit) {
                'fitWidth' => BoxFit.fitWidth,
                'cover' => BoxFit.cover,
                _ => BoxFit.contain,
              };
        final image = UpscaledPageImage(
          bytes: snapshot.data!.$1,
          upscaler: widget.repository.pageUpscaler,
          enabled:
              widget.repository.store.setting<String>('imageUpscalingMode') ==
              'auto',
          threshold:
              widget.repository.store.setting<double>(
                'imageUpscaleAutoTriggerScale',
              ) ??
              1.05,
          screen:
              MediaQuery.sizeOf(context) *
              MediaQuery.devicePixelRatioOf(context),
          builder: (bytes) => Image.memory(
            bytes,
            cacheWidth:
                (MediaQuery.sizeOf(context).width *
                        MediaQuery.devicePixelRatioOf(context) *
                        decodeFactor *
                        (widget.half == 0 ? 1 : 2))
                    .ceil()
                    .clamp(1, 4096),
            width: double.infinity,
            fit: crop == null ? fit : BoxFit.fill,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, synchronous) {
              if ((frame != null || synchronous) && !_reported) {
                _reported = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) widget.onReady();
                });
              }
              return widget.preferences.showPageShadow
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: .3),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                      child: child,
                    )
                  : child;
            },
            errorBuilder: (context, error, stack) => FailureView(
              error: error,
              retry: () => setState(() {
                _reported = false;
                _future = _load(refresh: true);
              }),
            ),
          ),
        );
        final cropped = crop == null
            ? image
            : PageCropView(crop: crop, fit: fit, child: image);
        final rotated = RotatedBox(
          quarterTurns: widget.preferences.rotation,
          child: widget.half == 0
              ? cropped
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth
                        .clamp(0, constraints.maxHeight * halfAspect)
                        .toDouble();
                    final height = width / halfAspect;
                    return Center(
                      child: SizedBox(
                        width: width,
                        height: height,
                        child: ClipRect(
                          child: OverflowBox(
                            alignment: widget.half == 1
                                ? Alignment.centerLeft
                                : Alignment.centerRight,
                            minWidth: width * 2,
                            maxWidth: width * 2,
                            minHeight: height,
                            maxHeight: height,
                            child: SizedBox(
                              width: width * 2,
                              height: height,
                              child: cropped,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        );
        return wide
            ? WidePage(
                key: ValueKey('wide:${widget.book.id}:${widget.page}'),
                aspect: orientedAspect,
                initialFraction: widget.initialPan,
                onPanSettled: widget.onPanSettled,
                rtl: widget.preferences.direction == ReadingDirection.rtl,
                active: widget.active,
                doubleTapZoom: widget.preferences.doubleTapEnabled
                    ? widget.preferences.doubleTapZoom
                    : 1,
                startPageScroll: widget.startPageScroll!,
                onTap: widget.onWideTap,
                onControls: widget.onControls,
                onZoomSettled: (scale) {
                  final decode = scale > 1.1 ? 2.0 : 1.0;
                  if (mounted && decode != _wideDecode) {
                    setState(() => _wideDecode = decode);
                  }
                },
                child: rotated,
              )
            : rotated;
      },
    );
    if (!widget.vertical) return RepaintBoundary(child: content);
    ScrollPosition? position() => Scrollable.maybeOf(context)?.position;
    return ReaderViewport(
      controller: _transform,
      doubleTapZoom: widget.preferences.doubleTapEnabled
          ? widget.preferences.doubleTapZoom
          : 1,
      axis: Axis.vertical,
      onContact: () => _verticalStart = position()?.pixels ?? 0,
      onPinch: () => position()?.jumpTo(_verticalStart),
      startScroll: (details) => position()?.drag(details, () {}),
      onActivityChanged: (active) {
        _gestureActive = active;
        updateKeepAlive();
        widget.onActivityChanged?.call(active);
      },
      onZoomSettled: (scale) {
        final decode = scale > 1.1 ? 2.0 : 1.0;
        if (mounted && decode != _verticalDecode) {
          setState(() => _verticalDecode = decode);
        }
      },
      onWheel: (delta) => position()?.pointerScroll(delta),
      child: content,
    );
  }
}
