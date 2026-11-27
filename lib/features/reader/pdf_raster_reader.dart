import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/reader_chrome.dart';
import '../../ui/strings.dart';
import 'pdf_raster_pages.dart';
import 'pdf_preferences.dart';
import 'reader_display.dart';
import 'reader_page.dart';

class PdfRasterReader extends StatefulWidget {
  const PdfRasterReader({
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
  State<PdfRasterReader> createState() => _PdfRasterReaderState();
}

class _PdfRasterReaderState extends State<PdfRasterReader> {
  late Future<PdfRasterPages> _future;
  PdfRasterPages? _source;
  int _passwordAttempts = 0;
  @override
  void initState() {
    super.initState();
    _future = _open();
  }

  Future<String?> _password() async {
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

  Future<PdfRasterPages> _open() async {
    await pdfrxFlutterInitialize();
    if (!mounted) throw StateError('PDF reader closed.');
    final document = await PdfDocument.openFile(
      widget.file.path,
      passwordProvider: _password,
    );
    final source = PdfRasterPages(
      document,
      quality: PdfRasterQuality.parse(
        widget.repository.store.setting<String>('pdfOfflineRenderQuality'),
      ),
    );
    if (!mounted) {
      await source.close();
      throw StateError('PDF reader closed.');
    }
    _source = source;
    return source;
  }

  Future<int?> _outline(BuildContext context, PdfRasterPages source) async {
    final List<PdfOutlineNode> nodes;
    try {
      nodes = await source.outline();
    } catch (error) {
      if (context.mounted) showError(context, error);
      return null;
    }
    if (!context.mounted) return null;
    return showModalBottomSheet<int>(
      context: context,
      sheetAnimationStyle: readerSheetAnimation(context),
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (sheet) {
        void open(int page) => Navigator.pop(sheet, page);
        Widget row(PdfOutlineNode node) {
          final page = node.dest?.pageNumber;
          if (node.children.isEmpty) {
            return ListTile(
              title: Text(node.title),
              onTap: page == null ? null : () => open(page),
            );
          }
          return ExpansionTile(
            title: Text(node.title),
            children: [
              if (page != null)
                ListTile(
                  title: Text('${tr(sheet, 'Page')} $page'),
                  leading: const Icon(Icons.subdirectory_arrow_right),
                  onTap: () => open(page),
                ),
              ...node.children.map(row),
            ],
          );
        }

        return ReaderSafeArea(
          top: false,
          child: SizedBox(
            height: MediaQuery.sizeOf(sheet).height * .65,
            child: Column(
              children: [
                ListTile(
                  title: Text(tr(sheet, 'Table of Contents')),
                  trailing: CloseButton(onPressed: () => Navigator.pop(sheet)),
                ),
                Expanded(
                  child: nodes.isEmpty
                      ? const EmptyView(title: 'No Table of Contents')
                      : ListView.builder(
                          itemCount: nodes.length,
                          itemBuilder: (_, index) => row(nodes[index]),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    if (_source != null) unawaited(_source!.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PdfRasterPages>(
    future: _future,
    builder: (context, snapshot) {
      if (!snapshot.hasData) {
        return Scaffold(
          appBar: AppBar(title: Text(widget.book.title)),
          body: snapshot.hasError
              ? FailureView(
                  error: snapshot.error!,
                  retry: () => setState(() => _future = _open()),
                )
              : const Center(child: CircularProgressIndicator.adaptive()),
        );
      }
      final source = snapshot.data!;
      final store = widget.repository.store;
      return ReaderPage(
        readDefaultPreferences: () {
          final saved = object(store.setting<dynamic>('pdfDefault'));
          final defaults = PdfPreferences.fromJson(saved);
          final presentation = defaults.presentation;
          final hasLayout = saved.containsKey('presentation');
          return ReaderPreferences.fromJson(
            object(store.setting<dynamic>('readerDefault')),
          ).copy(
            background: defaults.background,
            direction: defaults.rtl
                ? ReadingDirection.rtl
                : ReadingDirection.ltr,
            useSeriesDirection: defaults.useSeriesDirection,
            spread: hasLayout ? presentation.isDual : null,
            pageLayout: !hasLayout
                ? null
                : presentation == PdfPresentation.auto
                ? 'auto'
                : presentation.isDual
                ? 'dual-forced'
                : 'single',
            mode:
                defaults.vertical ||
                    presentation == PdfPresentation.singleContinuous ||
                    presentation == PdfPresentation.dualContinuous
                ? ReadingMode.vertical
                : ReadingMode.paged,
            soloCover: defaults.coverSolo,
            splitWide: hasLayout ? 'none' : null,
            controlsGradient: defaults.controlsGradient,
            showProgress: defaults.showProgress,
          );
        },
        repository: widget.repository,
        book: Book({
          ...widget.book.json,
          'media': {
            ...widget.book.media,
            'pagesCount': source.document.pages.length,
          },
        }),
        rasterPages: source,
        incognito: widget.incognito,
        onNextBook: widget.onNextBook,
        documentNavigation: (
          search: (context) => showModalBottomSheet<int>(
            context: context,
            sheetAnimationStyle: readerSheetAnimation(context),
            isScrollControlled: true,
            constraints: const BoxConstraints(maxWidth: 640),
            builder: (_) => _PdfSearchSheet(source: source),
          ),
          outline: (context) => _outline(context, source),
        ),
      );
    },
  );
}

class _PdfSearchSheet extends StatefulWidget {
  const _PdfSearchSheet({required this.source});
  final PdfRasterPages source;

  @override
  State<_PdfSearchSheet> createState() => _PdfSearchSheetState();
}

class _PdfSearchSheetState extends State<_PdfSearchSheet> {
  final _input = TextEditingController();
  final _hits = <({int page, String before, String term, String after})>[];
  int _generation = 0;
  bool _used = false, _busy = false, _failed = false;

  Future<void> _search() async {
    final term = _input.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (term.isEmpty) return;
    final generation = ++_generation;
    bool current() => mounted && generation == _generation;
    FocusScope.of(context).unfocus();
    setState(() {
      _hits.clear();
      _used = _busy = true;
      _failed = false;
    });
    final matchTerm = RegExp(RegExp.escape(term), caseSensitive: false);
    try {
      for (final page in widget.source.document.pages) {
        final text = await widget.source.textForPage(page.pageNumber);
        if (!current()) return;
        final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
        final match = matchTerm.firstMatch(line);
        if (match != null) {
          final start = (match.start - 45).clamp(0, line.length);
          final end = (match.end + 65).clamp(0, line.length);
          setState(() {
            _hits.add((
              page: page.pageNumber,
              before:
                  '${start > 0 ? '…' : ''}${line.substring(start, match.start)}',
              term: match[0]!,
              after:
                  '${line.substring(match.end, end)}${end < line.length ? '…' : ''}',
            ));
          });
        }
      }
    } catch (_) {
      if (current()) setState(() => _failed = true);
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final screen = MediaQuery.sizeOf(context).height;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: ReaderSafeArea(
        top: false,
        child: SizedBox(
          height: keyboard > 0 ? 64 : screen * .62,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 4, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _search(),
                        decoration: InputDecoration(
                          hintText: tr(context, 'Search in book'),
                          isDense: true,
                          prefixIcon: IconButton(
                            tooltip: tr(context, 'Search'),
                            onPressed: _search,
                            icon: const Icon(Icons.search, size: 20),
                          ),
                        ),
                      ),
                    ),
                    CloseButton(onPressed: () => Navigator.pop(context)),
                  ],
                ),
              ),
              if (keyboard == 0) ...[
                if (_busy) const LinearProgressIndicator(),
                Expanded(
                  child: _hits.isEmpty && _used && !_busy
                      ? Center(
                          child: Text(
                            tr(
                              context,
                              _failed ? 'Search unavailable' : 'No results',
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(12),
                          itemCount: _hits.length,
                          separatorBuilder: (_, _) => const Divider(height: 12),
                          itemBuilder: (context, index) {
                            final hit = _hits[index];
                            return ListTile(
                              title: Text('${tr(context, 'Page')} ${hit.page}'),
                              subtitle: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(text: hit.before),
                                    TextSpan(
                                      text: hit.term,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    TextSpan(text: hit.after),
                                  ],
                                ),
                              ),
                              onTap: () => Navigator.pop(context, hit.page),
                            );
                          },
                        ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
