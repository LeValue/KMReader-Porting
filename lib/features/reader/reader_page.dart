import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/models.dart';
import '../../core/api.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../../ui/theme.dart';
import 'document_readers.dart';
import 'reading_session.dart';
import 'tap_zones.dart';
import 'page_parts.dart';
import 'reader_viewport.dart';
import 'reader_display.dart';
import 'page_crop.dart';
import 'reader_ocr.dart';
import 'reader_text_page.dart';

class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.repository,
    required this.book,
    this.incognito = false,
    this.readListId,
  });
  final Repository repository;
  final Book book;
  final bool incognito;
  final String? readListId;
  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late ReadingSession _session;
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
    if (_scrolling || _interacting || !mounted) return;
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 40), () {
      if (!mounted || _scrolling || _interacting) return;
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
  final Set<int> _readyPages = {};
  List<Json> _dimensions = [];
  List<PagePart> _parts = [];
  Set<int> _splitPages = {};
  int _partIndex = 0, _geometryRevision = 0;
  bool _loadingDimensions = false;
  bool _dimensionsLoaded = false;
  bool _initialPartPending = false;
  Json _seriesMetadata = {};
  bool _loadingSeries = false;
  Future<void> _loadSeriesDirection() async {
    if (_loadingSeries ||
        _seriesMetadata.isNotEmpty ||
        widget.book.format != 'comic' ||
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
    if (_loadingDimensions ||
        _dimensionsLoaded ||
        widget.book.format != 'comic') {
      return;
    }
    _loadingDimensions = true;
    try {
      final data = await widget.repository.get(
        '/api/v1/books/${Uri.encodeComponent(widget.book.id)}/pages',
        cacheFirst: true,
      );
      if (!mounted) return;
      _dimensions = (data as List).map(object).toList();
      _dimensionsLoaded = true;
      if (_initialPartPending && !widget.book.completed) {
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

  void _turn(int delta) {
    _resetZoom();
    if (!_split) {
      _go(_session.page + delta * _session.step);
      return;
    }
    final index = (_partIndex + delta).clamp(0, _parts.length - 1);
    if (_session.preferences.animate) {
      _pages.animateToPage(
        index,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      _pages.jumpToPage(index);
    }
  }

  Timer? _preloadTimer;
  int _preloadGeneration = 0;
  void _preload() {
    _preloadTimer?.cancel();
    final generation = ++_preloadGeneration;
    if (widget.book.format != 'comic' || _scrolling || _interacting) return;
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
          final bytes = await widget.repository.prefetchPage(
            widget.book.id,
            page,
          );
          if (!mounted || generation != _preloadGeneration) return;
          await precacheImage(
            ResizeImage.resizeIfNeeded(
              (width * (_splitPages.contains(page) ? 2 : 1)).clamp(1, 4096),
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
    if (_scrolling || _interacting) return;
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
    final first = _session.itemIndex * _session.step + 1;
    for (
      var page = first;
      page < first + _session.step && page <= widget.book.pages;
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
    final initial = object(json ?? defaults);
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
    _session = ReadingSession(
      count: widget.book.pages,
      initialPage: widget.book.completed ? 1 : widget.book.page,
      preferences: seriesReaderPreferences(
        ReaderPreferences.fromJson(initial),
        _seriesMetadata,
      ),
      incognito: widget.incognito,
      onCommit: (page) => widget.repository.setProgress(widget.book, page),
    );
    _rebuildParts(_session.preferences);
    _initialPartPending = _session.preferences.splitWide != 'none';
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
      if (!_session.preferences.animate) {
        _pages.jumpToPage(_viewIndex);
        setState(() {});
        _settled();
        return;
      }
      _pages.animateToPage(
        _viewIndex,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
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

  Future<File> _document() async {
    final file = widget.repository.bookFile(widget.book);
    if (await file.exists()) return file;
    if (widget.repository.offline) {
      throw const FileSystemException('This book has not been downloaded.');
    }
    await widget.repository.api.download(
      '/api/v1/books/${Uri.encodeComponent(widget.book.id)}/file',
      file,
    );
    return file;
  }

  bool _ocrOpening = false;
  Future<void> _recognizeText() async {
    if (_ocrOpening) return;
    setState(() => _ocrOpening = true);
    try {
      final bytes = await widget.repository.page(widget.book.id, _session.page);
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderDisplay(
            child: ReaderTextPage(
              bytes: bytes,
              ocr: ReaderOcr(widget.repository.bookDirectory(widget.book.id)),
              title: '${widget.book.title} · ${_session.page}',
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
    try {
      final prefix = _readListId == null
          ? '/api/v1/books/${Uri.encodeComponent(widget.book.id)}'
          : '/api/v1/readlists/${Uri.encodeComponent(_readListId)}/books/${Uri.encodeComponent(widget.book.id)}';
      final data = await widget.repository.get('$prefix/next');
      if (!mounted || data == null) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ReaderPage(
            repository: widget.repository,
            book: Book(object(data)),
            incognito: widget.incognito,
            readListId: _readListId,
          ),
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _settings() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, update) {
        void apply(ReaderPreferences p) {
          _configure(p);
          update(() {});
        }

        final p = _session.preferences;
        return ReaderSafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(context, 'Reader Settings'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 20),
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
                    title: Text(tr(context, 'Use Series Reading Direction')),
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
                        tr(context, 'Allow the page behind the camera notch'),
                      ),
                      value: p.extendIntoCutout,
                      onChanged: (value) =>
                          apply(p.copy(extendIntoCutout: value)),
                    ),
                  for (final setting in ['tapMode', 'tapInversion', 'preload'])
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
                            'inverted': 'reader.tapZoneInversionMode.inverted',
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
                        if (selected != null && mounted && context.mounted) {
                          apply(switch (setting) {
                            'tapMode' => p.copy(tapMode: selected),
                            'tapInversion' => p.copy(tapInversion: selected),
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
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr(context, 'Page Turn Animation')),
                    value: p.animate,
                    onChanged: (v) => apply(p.copy(animate: v)),
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
                    onTap: () => apply(p.copy(rotation: (p.rotation + 1) % 4)),
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
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (widget.book.format != 'comic') {
      return ReaderDisplay(
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
            Navigator.maybePop(context);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.space) {
            setState(() => _controls = !_controls);
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
                          builder: (context, constraints) => ReaderViewport(
                            controller: _zoom,
                            doubleTapZoom: settings.doubleTapZoom,
                            onContact: () => _gesturePage = _pages.hasClients
                                ? (_pages.page ?? 0).round()
                                : _viewIndex,
                            onPinch: () {
                              if (_pages.hasClients) {
                                _pages.jumpToPage(_gesturePage);
                              }
                            },
                            startScroll: (details) => _pages.hasClients
                                ? _pages.position.drag(details, () {})
                                : null,
                            onActivityChanged: _activity,
                            onZoomSettled: _zoomSettled,
                            onTap: (point) => _tap(point, constraints.biggest),
                            onWheel: (delta) {
                              if (!_scrolling && delta != 0) {
                                _turn(delta.sign.toInt());
                              }
                            },
                            child: PageView.builder(
                              key: ValueKey(modeKey),
                              controller: _pages,
                              physics: const NeverScrollableScrollPhysics(),
                              allowImplicitScrolling: true,
                              reverse:
                                  settings.direction == ReadingDirection.rtl,
                              itemCount: _viewCount,
                              onPageChanged: (index) {
                                setState(() {
                                  _resetZoom();
                                  _partIndex = index;
                                  _session.go(
                                    _split
                                        ? _parts[index].page
                                        : index * _session.step + 1,
                                  );
                                });
                                _settled();
                              },
                              itemBuilder: (context, index) {
                                if (_split) {
                                  final part = _parts[index];
                                  return _PageImage(
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
                                  );
                                }
                                final page = index * _session.step + 1;
                                final children = [
                                  for (
                                    var i = page;
                                    i < page + _session.step &&
                                        i <= widget.book.pages;
                                    i++
                                  )
                                    Expanded(
                                      child: _PageImage(
                                        repository: widget.repository,
                                        book: widget.book,
                                        page: i,
                                        decodeZoom: index == _viewIndex
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
                                return Row(
                                  textDirection:
                                      settings.direction == ReadingDirection.rtl
                                      ? TextDirection.rtl
                                      : TextDirection.ltr,
                                  children: children,
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
                          itemBuilder: (context, index) => GestureDetector(
                            onTap: () => setState(() => _controls = !_controls),
                            child: Padding(
                              padding: EdgeInsets.only(
                                bottom: settings.mode == ReadingMode.webtoon
                                    ? 0
                                    : 12,
                              ),
                              child: _PageImage(
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
            if (_controls)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: .85),
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
                          tooltip: tr(context, 'Full Screen'),
                          onPressed: () => setState(() => _controls = false),
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
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: .85),
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
                                  onPressed: _nextBook,
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
    final brightness = settings.background == 'black'
        ? Brightness.dark
        : Brightness.light;
    if (_readerTheme == null || brightness != _readerBrightness) {
      _readerBrightness = brightness;
      _readerTheme = appTheme(brightness);
    }
    return Theme(
      data: _readerTheme!,
      child: ReaderDisplay(child: scaffold),
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
  });
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
    final bytes = refresh
        ? await widget.repository.image(
            '/api/v1/books/${Uri.encodeComponent(widget.book.id)}/pages/${widget.page}',
            refresh: true,
          )
        : await widget.repository.page(widget.book.id, widget.page);
    return (bytes, await pageCrop(bytes, widget.preferences.borderCrop));
  }

  final _transform = TransformationController();
  bool _reported = false;
  double _verticalStart = 0, _verticalDecode = 1;
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
        final fit = widget.vertical
            ? BoxFit.fitWidth
            : switch (widget.preferences.fit) {
                'fitWidth' => BoxFit.fitWidth,
                'cover' => BoxFit.cover,
                _ => BoxFit.contain,
              };
        final image = Image.memory(
          snapshot.data!.$1,
          cacheWidth:
              (MediaQuery.sizeOf(context).width *
                      MediaQuery.devicePixelRatioOf(context) *
                      (widget.vertical ? _verticalDecode : widget.decodeZoom) *
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
            return child;
          },
          errorBuilder: (context, error, stack) => FailureView(
            error: error,
            retry: () => setState(() {
              _reported = false;
              _future = _load(refresh: true);
            }),
          ),
        );
        final cropped = crop == null
            ? image
            : PageCropView(crop: crop, fit: fit, child: image);
        return RotatedBox(
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
      },
    );
    if (!widget.vertical) return RepaintBoundary(child: content);
    ScrollPosition? position() => Scrollable.maybeOf(context)?.position;
    return ReaderViewport(
      controller: _transform,
      doubleTapZoom: widget.preferences.doubleTapZoom,
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
