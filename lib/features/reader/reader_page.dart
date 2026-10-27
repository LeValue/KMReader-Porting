import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../../ui/theme.dart';
import 'document_readers.dart';
import 'reading_session.dart';

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
  late PageController _pages;
  final _scroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  bool _controls = true, _verticalReady = false;
  final Set<int> _readyPages = {};
  Timer? _preloadTimer;
  int _preloadGeneration = 0;
  void _preload() {
    _preloadTimer?.cancel();
    final generation = ++_preloadGeneration;
    if (widget.book.format != 'comic') return;
    final anchor = _session.page;
    final step = _session.step;
    _preloadTimer = Timer(const Duration(milliseconds: 80), () async {
      final width =
          (MediaQuery.sizeOf(context).width *
                  MediaQuery.devicePixelRatioOf(context) *
                  2)
              .ceil()
              .clamp(1, 4096);
      final candidates = [
        for (var i = 1; i <= 2 * step; i++) anchor + i,
        anchor - 1,
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
            ResizeImage.resizeIfNeeded(width, null, MemoryImage(bytes)),
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
    _focus = FocusNode();
    final json = widget.repository.store.cached(
      widget.repository.profile.id,
      'reader:${widget.book.id}',
    );
    final defaults = widget.repository.store.setting<dynamic>('readerDefault');
    _session = ReadingSession(
      count: widget.book.pages,
      initialPage: widget.book.completed ? 1 : widget.book.page,
      preferences: ReaderPreferences.fromJson(object(json ?? defaults)),
      incognito: widget.incognito,
      onCommit: (page) => widget.repository.setProgress(widget.book, page),
    );
    _pages = PageController(initialPage: _session.itemIndex);
    _positions.itemPositions.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focus.requestFocus();
        _verticalReady = true;
        _preload();
      }
    });
  }

  @override
  void dispose() {
    _preloadGeneration++;
    _preloadTimer?.cancel();
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
      _preload();
      _commitIfReady();
    }
  }

  void _go(int page) {
    _session.go(page);
    _preload();
    if (_session.preferences.mode == ReadingMode.paged && _pages.hasClients) {
      _pages.animateToPage(
        _session.itemIndex,
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
  }

  void _configure(ReaderPreferences preferences) {
    final old = _pages;
    setState(() {
      _verticalReady = false;
      _session.configure(preferences);
      _pages = PageController(initialPage: _session.itemIndex);
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

  Future<void> _nextBook() async {
    try {
      final prefix = widget.readListId == null
          ? '/api/v1/books/${Uri.encodeComponent(widget.book.id)}'
          : '/api/v1/readlists/${Uri.encodeComponent(widget.readListId!)}/books/${Uri.encodeComponent(widget.book.id)}';
      final data = await widget.repository.get('$prefix/next');
      if (!mounted || data == null) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ReaderPage(
            repository: widget.repository,
            book: Book(object(data)),
            incognito: widget.incognito,
            readListId: widget.readListId,
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
        return SafeArea(
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
                          onSelected: (_) => apply(p.copy(mode: mode)),
                        ),
                    ],
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
                      ),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr(context, 'Double Page')),
                    value: p.spread,
                    onChanged: p.mode == ReadingMode.paged
                        ? (v) => apply(p.copy(spread: v))
                        : null,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr(context, 'Fit Width')),
                    value: p.fit == 'fitWidth',
                    onChanged: (v) =>
                        apply(p.copy(fit: v ? 'fitWidth' : 'contain')),
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
      return DocumentReader(
        repository: widget.repository,
        book: widget.book,
        load: _document,
        incognito: widget.incognito,
      );
    }
    final settings = _session.preferences;
    final background = switch (settings.background) {
      'white' => Colors.white,
      'sepia' => const Color(0xffefe5d0),
      _ => Colors.black,
    };
    final modeKey = '${settings.mode}:${settings.spread}:${settings.direction}';
    final scaffold = Scaffold(
      backgroundColor: background,
      body: SafeArea(
        child: Focus(
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
              _go(_session.page + _session.step);
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowUp ||
                key == LogicalKeyboardKey.pageUp ||
                key ==
                    (rtl
                        ? LogicalKeyboardKey.arrowRight
                        : LogicalKeyboardKey.arrowLeft)) {
              _go(_session.page - _session.step);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Stack(
            children: [
              if (widget.book.pages == 0)
                EmptyView(
                  title: 'No Pages',
                  message: 'This book has no readable pages.',
                  icon: CupertinoIcons.book,
                )
              else if (settings.mode == ReadingMode.paged)
                LayoutBuilder(
                  builder: (context, constraints) => GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapUp: (details) {
                      final x = details.localPosition.dx / constraints.maxWidth;
                      if (x < .28) {
                        _go(
                          _session.page +
                              (settings.direction == ReadingDirection.rtl
                                  ? _session.step
                                  : -_session.step),
                        );
                      } else if (x > .72) {
                        _go(
                          _session.page +
                              (settings.direction == ReadingDirection.rtl
                                  ? -_session.step
                                  : _session.step),
                        );
                      } else {
                        setState(() => _controls = !_controls);
                      }
                    },
                    child: PageView.builder(
                      key: ValueKey(modeKey),
                      controller: _pages,
                      reverse: settings.direction == ReadingDirection.rtl,
                      itemCount: _session.itemCount,
                      onPageChanged: (index) {
                        setState(() => _session.go(index * _session.step + 1));
                        _preload();
                        _commitIfReady();
                      },
                      itemBuilder: (context, index) {
                        final page = index * _session.step + 1;
                        final children = [
                          for (
                            var i = page;
                            i < page + _session.step && i <= widget.book.pages;
                            i++
                          )
                            Expanded(
                              child: _PageImage(
                                repository: widget.repository,
                                book: widget.book,
                                page: i,
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
              else
                ScrollablePositionedList.builder(
                  key: ValueKey(modeKey),
                  itemScrollController: _scroll,
                  itemPositionsListener: _positions,
                  initialScrollIndex: _session.page - 1,
                  itemCount: widget.book.pages,
                  itemBuilder: (context, index) => GestureDetector(
                    onTap: () => setState(() => _controls = !_controls),
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: settings.mode == ReadingMode.webtoon ? 0 : 12,
                      ),
                      child: _PageImage(
                        repository: widget.repository,
                        book: widget.book,
                        page: index + 1,
                        preferences: settings,
                        vertical: true,
                        onReady: () {
                          _readyPages.add(index + 1);
                          _commitIfReady();
                        },
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
                          onPressed: _settings,
                          tooltip: tr(context, 'Reader Settings'),
                          icon: const Icon(CupertinoIcons.slider_horizontal_3),
                        ),
                      ],
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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            IconButton(
                              color: Colors.white,
                              onPressed: () =>
                                  _go(_session.page - _session.step),
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
                              onPressed: () =>
                                  _go(_session.page + _session.step),
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
                                '${_session.page} / ${widget.book.pages}',
                                style: const TextStyle(color: Colors.white),
                              ),
                              if (_session.atEnd)
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
            ],
          ),
        ),
      ),
    );
    return Theme(
      data: appTheme(
        settings.background == 'black' ? Brightness.dark : Brightness.light,
      ),
      child: scaffold,
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
  });
  final Repository repository;
  final Book book;
  final int page;
  final ReaderPreferences preferences;
  final VoidCallback onReady;
  final bool vertical;
  @override
  State<_PageImage> createState() => _PageImageState();
}

class _PageImageState extends State<_PageImage> {
  late Future<Uint8List> _future;
  final _transform = TransformationController();
  bool _reported = false;
  @override
  void initState() {
    super.initState();
    _future = widget.repository.page(widget.book.id, widget.page);
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_PageImage old) {
    super.didUpdateWidget(old);
    if (old.page != widget.page || old.book.id != widget.book.id) {
      _reported = false;
      _future = widget.repository.page(widget.book.id, widget.page);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return SizedBox(
          height: widget.vertical ? 300 : null,
          child: FailureView(
            error: snapshot.error!,
            retry: () => setState(() {
              _reported = false;
              _future = widget.repository.page(widget.book.id, widget.page);
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
      final image = Image.memory(
        snapshot.data!,
        cacheWidth:
            (MediaQuery.sizeOf(context).width *
                    MediaQuery.devicePixelRatioOf(context) *
                    2)
                .ceil()
                .clamp(1, 4096),
        width: double.infinity,
        fit: widget.vertical
            ? BoxFit.fitWidth
            : widget.preferences.fit == 'fitWidth'
            ? BoxFit.fitWidth
            : BoxFit.contain,
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
          retry: () => setState(
            () => _future = widget.repository.image(
              '/api/v1/books/${Uri.encodeComponent(widget.book.id)}/pages/${widget.page}',
              refresh: true,
            ),
          ),
        ),
      );
      return GestureDetector(
        onDoubleTap: () => _transform.value = _transform.value.isIdentity()
            ? (Matrix4.identity()..scaleByDouble(2, 2, 1, 1))
            : Matrix4.identity(),
        child: InteractiveViewer(
          transformationController: _transform,
          minScale: 1,
          maxScale: 6,
          child: RotatedBox(
            quarterTurns: widget.preferences.rotation,
            child: image,
          ),
        ),
      );
    },
  );
}
