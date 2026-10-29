import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'epub_document.dart';
import 'pdf_reader.dart';
import 'reader_display.dart';
import 'epub_reader.dart';

class DocumentReader extends StatefulWidget {
  const DocumentReader({
    super.key,
    required this.repository,
    required this.book,
    required this.load,
    required this.incognito,
    this.browserEpub = true,
    this.onNextBook,
  });
  final Repository repository;
  final Book book;
  final Future<File> Function() load;
  final bool incognito;
  final bool browserEpub;
  final Future<void> Function()? onNextBook;
  @override
  State<DocumentReader> createState() => _DocumentReaderState();
}

class _DocumentReaderState extends State<DocumentReader> {
  late Future<File> _file;
  @override
  void initState() {
    super.initState();
    _file = widget.load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<File>(
    future: _file,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Scaffold(
          appBar: AppBar(title: Text(widget.book.title)),
          body: FailureView(
            error: snapshot.error!,
            retry: () => setState(() => _file = widget.load()),
          ),
        );
      }
      if (!snapshot.hasData) {
        return Scaffold(
          appBar: AppBar(title: Text(widget.book.title)),
          body: const Center(child: CircularProgressIndicator.adaptive()),
        );
      }
      return widget.book.format == 'pdf'
          ? PdfReader(
              file: snapshot.data!,
              repository: widget.repository,
              book: widget.book,
              incognito: widget.incognito,
              onNextBook: widget.onNextBook,
            )
          : widget.browserEpub && (Platform.isAndroid || Platform.isWindows)
          ? BrowserEpubReader(
              onNextBook: widget.onNextBook,
              file: snapshot.data!,
              repository: widget.repository,
              book: widget.book,
              incognito: widget.incognito,
            )
          : _EpubReader(
              file: snapshot.data!,
              repository: widget.repository,
              book: widget.book,
              incognito: widget.incognito,
            );
    },
  );
}

class _EpubReader extends StatefulWidget {
  const _EpubReader({
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
  State<_EpubReader> createState() => _EpubReaderState();
}

class _EpubReaderState extends State<_EpubReader> {
  late Future<EpubDocument> _future;
  EpubDocument? _document;
  final ScrollController _scroll = ScrollController(keepScrollOffset: false);
  late _EpubWidgetFactory _htmlFactory;
  int _contentGeneration = 0;
  String? _pendingAnchor, _auxiliaryPath;
  double _auxiliaryProgress = 0;
  String get _currentPath =>
      _auxiliaryPath ?? _document!.chapters[_chapter].path;
  String? _htmlPath;
  String _html = '';
  String get _currentHtml {
    if (_htmlPath != _currentPath) {
      _html = EpubDocument.decodeText(_document!.resource(_currentPath));
      _htmlPath = _currentPath;
    }
    return _html;
  }

  int _chapter = 0;
  double _fontSize = 19, _progress = 0;
  String _theme = 'sepia', _font = 'serif';
  Timer? _debounce;
  bool _restoring = true;
  bool _positionDirty = false;
  List<String> _readingOrder = [];
  String get _key => 'epub:${widget.book.id}';
  @override
  void initState() {
    super.initState();
    _createFactory();
    _future = _open();
    _scroll.addListener(_scrolled);
  }

  Future<EpubDocument> _open() async {
    final settings = object(
      widget.repository.store.cached(widget.repository.profile.id, _key),
    );
    _chapter = integer(settings['chapter']);
    _fontSize = ((settings['fontSize'] as num?)?.toDouble() ?? 19).clamp(
      12,
      36,
    );
    _theme = text(settings['theme'], 'sepia');
    _font = text(settings['font'], 'serif');
    _progress = ((settings['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1);
    final doc = await EpubDocument.openAsync(widget.file.path);
    if (!mounted) {
      doc.close();
      throw const FileSystemException('Reader closed.');
    }
    if (!widget.repository.offline && settings.isEmpty) {
      try {
        final manifest = object(
          await widget.repository.api
              .request(
                '/api/v1/books/${Uri.encodeComponent(widget.book.id)}/manifest',
                extra: {'Accept': 'application/webpub+json'},
              )
              .timeout(const Duration(seconds: 4)),
        );
        _readingOrder = (manifest['readingOrder'] as List? ?? [])
            .map((v) => text(object(v)['href']))
            .toList();
        widget.repository.store.cache(
          widget.repository.profile.id,
          'epubOrder:${widget.book.id}',
          _readingOrder,
        );
        final remote = object(
          await widget.repository.api
              .request(
                '/api/v1/books/${Uri.encodeComponent(widget.book.id)}/progression',
                extra: {'Accept': 'application/vnd.readium.progression+json'},
              )
              .timeout(const Duration(seconds: 4)),
        );
        final locator = object(remote['locator']);
        final href = Uri.decodeComponent(text(locator['href']));
        final index = doc.chapters.indexWhere((v) => href.endsWith(v.path));
        if (index >= 0) {
          _chapter = index;
          _progress =
              (object(locator['locations'])['progression'] as num?)
                  ?.toDouble() ??
              0;
        }
      } catch (_) {}
    }
    if (_readingOrder.isEmpty) {
      final order = widget.repository.store.cached(
        widget.repository.profile.id,
        'epubOrder:${widget.book.id}',
      );
      if (order is List) _readingOrder = order.map((v) => '$v').toList();
    }
    if (!mounted) {
      doc.close();
      _document = null;
      throw const FileSystemException('Reader closed.');
    }
    _chapter = _chapter.clamp(0, doc.chapters.length - 1);
    _document = doc;
    return doc;
  }

  void _createFactory() {
    late final _EpubWidgetFactory factory;
    factory = _EpubWidgetFactory(() => _restore(factory));
    _htmlFactory = factory;
  }

  Future<void> _restore(_EpubWidgetFactory factory) async {
    if (!mounted ||
        factory != _htmlFactory ||
        !_restoring ||
        !_scroll.hasClients) {
      return;
    }
    final anchor = _pendingAnchor;
    if (anchor != null && anchor.isNotEmpty) {
      final found = await factory.onTapAnchorWrapper(anchor);
      if (!mounted || factory != _htmlFactory) return;
      if (!found) _scroll.jumpTo(0);
    } else {
      _scroll.jumpTo(
        (_auxiliaryPath == null ? _progress : _auxiliaryProgress) *
            _scroll.position.maxScrollExtent,
      );
    }
    if (!mounted || factory != _htmlFactory) return;
    _pendingAnchor = null;
    _restoring = false;
    if (_positionDirty) {
      _scrolled();
    } else {
      _save();
    }
  }

  void _scrolled() {
    if (_restoring || !_scroll.hasClients) return;
    if (_auxiliaryPath != null) {
      _auxiliaryProgress = _scroll.position.maxScrollExtent <= 0
          ? 0
          : (_scroll.offset / _scroll.position.maxScrollExtent).clamp(0, 1);
      return;
    }
    _progress = _scroll.position.maxScrollExtent <= 0
        ? 0
        : (_scroll.offset / _scroll.position.maxScrollExtent).clamp(0, 1);
    _debounce?.cancel();
    _positionDirty = true;
    _debounce = Timer(const Duration(milliseconds: 500), _save);
  }

  void _save() {
    if (widget.incognito ||
        _restoring ||
        _document == null ||
        widget.repository.closed) {
      return;
    }
    widget.repository.store.cache(widget.repository.profile.id, _key, {
      'chapter': _chapter,
      'progress': _progress,
      'fontSize': _fontSize,
      'theme': _theme,
      'font': _font,
    });
    if (_positionDirty) {
      final doc = _document!;
      final href = _chapter < _readingOrder.length
          ? _readingOrder[_chapter]
          : doc.chapters[_chapter].path;
      widget.repository.setEpubProgress(
        widget.book,
        href,
        _progress,
        (_chapter + _progress) / doc.chapters.length,
      );
      _positionDirty = false;
    }
  }

  void _go(int chapter, {String? fragment}) {
    if (_document == null) return;
    _debounce?.cancel();
    _save();
    setState(() {
      _auxiliaryPath = null;
      _chapter = chapter.clamp(0, _document!.chapters.length - 1);
      _progress = 0;
      _pendingAnchor = fragment;
      _contentGeneration++;
      _createFactory();
      _restoring = true;
      _positionDirty = true;
    });
  }

  bool _navigate(EpubLocation location) {
    final doc = _document;
    if (doc == null || !doc.isReadingResource(location.path)) return false;
    final index = doc.chapters.indexWhere(
      (chapter) => chapter.path == location.path,
    );
    if (index >= 0) {
      _go(index, fragment: location.fragment);
    } else {
      _debounce?.cancel();
      _save();
      setState(() {
        _auxiliaryPath = location.path;
        _auxiliaryProgress = 0;
        _pendingAnchor = location.fragment;
        _contentGeneration++;
        _createFactory();
        _restoring = true;
        _positionDirty = false;
      });
    }
    return true;
  }

  void _returnToReading() {
    setState(() {
      _auxiliaryPath = null;
      _pendingAnchor = null;
      _contentGeneration++;
      _createFactory();
      _restoring = true;
      _positionDirty = false;
    });
  }

  bool _followLink(String url) {
    if (_document == null) return false;
    try {
      return _navigate(EpubDocument.locate(_currentPath, url));
    } on FormatException {
      return false;
    }
  }

  void _changeText(VoidCallback change) {
    _save();
    setState(() {
      _restoring = true;
      _contentGeneration++;
      _createFactory();
      change();
    });
  }

  void _retry() {
    _document?.close();
    _document = null;
    _htmlPath = null;
    _html = '';
    setState(() {
      _restoring = true;
      _positionDirty = false;
      _pendingAnchor = null;
      _auxiliaryPath = null;
      _contentGeneration++;
      _createFactory();
      _future = _open();
    });
  }

  void _contents() {
    final doc = _document;
    if (doc == null) return;
    void navigate(EpubLocation location) {
      if (!doc.isReadingResource(location.path)) return;
      Navigator.pop(context);
      _navigate(location);
    }

    bool current(EpubNavigationEntry entry) =>
        entry.location?.path == _currentPath || entry.children.any(current);
    Widget node(EpubNavigationEntry entry) => entry.children.isEmpty
        ? ListTile(
            title: Text(entry.title),
            selected: current(entry),
            onTap: entry.location == null
                ? null
                : () => navigate(entry.location!),
          )
        : ExpansionTile(
            title: Text(entry.title),
            initiallyExpanded: current(entry),
            childrenPadding: const EdgeInsets.only(left: 16),
            children: [
              if (entry.location != null)
                ListTile(
                  title: Text(tr(context, 'Go to Page')),
                  onTap: () => navigate(entry.location!),
                ),
              ...entry.children.map(node),
            ],
          );
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => ReaderSafeArea(
        child: ListView(children: doc.tableOfContents.map(node).toList()),
      ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _save();
    _scroll.dispose();
    _document?.close();
    super.dispose();
  }

  void _settings() {
    var draftSize = _fontSize;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => ReaderSafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tr(context, 'Text Size')),
                Slider(
                  value: draftSize,
                  min: 12,
                  max: 36,
                  onChanged: (v) {
                    update(() => draftSize = v);
                  },
                  onChangeEnd: (v) {
                    _changeText(() => _fontSize = v);
                  },
                ),
                Wrap(
                  spacing: 12,
                  children: [
                    for (final t in ['white', 'sepia', 'black'])
                      ChoiceChip(
                        label: Text(tr(context, t)),
                        selected: _theme == t,
                        onSelected: (_) {
                          _changeText(() => _theme = t);
                          update(() {});
                          _save();
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'serif', label: Text('Serif')),
                    ButtonSegment(
                      value: 'sans-serif',
                      label: Text('Sans Serif'),
                    ),
                  ],
                  selected: {_font},
                  onSelectionChanged: (v) {
                    _changeText(() => _font = v.first);
                    update(() {});
                    _save();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: switch (_theme) {
      'black' => const Color(0xff1c1c1e),
      'white' => Colors.white,
      _ => const Color(0xffefe5d0),
    },
    appBar: AppBar(
      title: Text(widget.book.title),
      actions: [
        if (widget.incognito) const Icon(CupertinoIcons.eye_slash),
        if (_auxiliaryPath != null)
          IconButton(
            tooltip: tr(context, 'Back to Reading'),
            onPressed: _returnToReading,
            icon: const Icon(CupertinoIcons.arrow_uturn_left),
          ),
        IconButton(
          tooltip: tr(context, 'Text Settings'),
          onPressed: _settings,
          icon: const Icon(CupertinoIcons.textformat_size),
        ),
        IconButton(
          tooltip: tr(context, 'Table of Contents'),
          icon: const Icon(CupertinoIcons.list_bullet),
          onPressed: _contents,
        ),
      ],
    ),
    body: FutureBuilder<EpubDocument>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return FailureView(error: snapshot.error!, retry: _retry);
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator.adaptive());
        }
        final doc = snapshot.data!;
        return SafeArea(
          top: false,
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: SelectionArea(
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 20,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: HtmlWidget(
                          _currentHtml,
                          key: ValueKey(_contentGeneration),
                          factoryBuilder: () => _htmlFactory,
                          textStyle: TextStyle(
                            fontSize: _fontSize,
                            height: 1.65,
                            fontFamily: _font,
                            color: _theme == 'black'
                                ? const Color(0xffe8e4dc)
                                : const Color(0xff262321),
                          ),
                          customWidgetBuilder: (element) {
                            if (element.localName != 'img') return null;
                            final src = element.attributes['src'];
                            if (src == null) return null;
                            try {
                              final path = EpubDocument.resolve(
                                _currentPath,
                                src,
                              );
                              return Image.memory(
                                doc.resource(path),
                                cacheWidth:
                                    ((MediaQuery.sizeOf(context).width - 56)
                                                .clamp(1, 720) *
                                            MediaQuery.devicePixelRatioOf(
                                              context,
                                            ) *
                                            2)
                                        .ceil()
                                        .clamp(1, 4096),
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) =>
                                    Text(element.attributes['alt'] ?? 'Image'),
                              );
                            } catch (_) {
                              return Text(
                                element.attributes['alt'] ??
                                    'Image unavailable',
                              );
                            }
                          },
                          onTapUrl: _followLink,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              ReaderSafeArea(
                top: false,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: tr(context, 'Previous Chapter'),
                      onPressed: _chapter > 0 ? () => _go(_chapter - 1) : null,
                      icon: const Icon(CupertinoIcons.chevron_left),
                    ),
                    Expanded(
                      child: Text(
                        _auxiliaryPath == null
                            ? doc.chapters[_chapter].title
                            : tr(context, 'Supplementary Content'),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text('${_chapter + 1} / ${doc.chapters.length}'),
                    IconButton(
                      tooltip: tr(context, 'Next Chapter'),
                      onPressed: _chapter < doc.chapters.length - 1
                          ? () => _go(_chapter + 1)
                          : null,
                      icon: const Icon(CupertinoIcons.chevron_right),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _EpubWidgetFactory extends WidgetFactory {
  _EpubWidgetFactory(this.onRendered);
  final VoidCallback onRendered;

  @override
  Widget buildBodyWidget(BuildContext context, Widget child) {
    WidgetsBinding.instance.addPostFrameCallback((_) => onRendered());
    return super.buildBodyWidget(context, child);
  }
}
