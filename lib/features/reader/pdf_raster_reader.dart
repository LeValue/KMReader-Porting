import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'pdf_raster_pages.dart';
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
    await pdfrxInitialize();
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
      return ReaderPage(
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
      );
    },
  );
}
