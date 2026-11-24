import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/local_library.dart';
import '../../core/models.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../reader/document_readers.dart';
import '../reader/reader_page.dart';

class LocalLibraryPage extends StatefulWidget {
  const LocalLibraryPage({
    super.key,
    required this.app,
    this.standalone = false,
  });
  final AppController app;
  final bool standalone;
  @override
  State<LocalLibraryPage> createState() => _LocalLibraryPageState();
}

class _LocalLibraryPageState extends State<LocalLibraryPage> {
  bool _importing = false;
  LocalLibrary get library => widget.app.localLibrary;
  Future<void> _import() async {
    if (_importing) return;
    setState(() => _importing = true);
    final errors = <String>[];
    try {
      final files = await openFiles(
        // Android providers can label CB7/CBR as generic binary files.
        acceptedTypeGroups: Platform.isAndroid
            ? const []
            : const [
                XTypeGroup(
                  label: 'EPUB / PDF / Comics',
                  extensions: LocalLibrary.extensions,
                ),
              ],
      );
      if (!mounted) return;
      for (final file in files) {
        try {
          await library.importFile(file);
        } on FormatException catch (error) {
          if (mounted)
            errors.add('${file.name}: ${tr(context, error.message)}');
        } catch (_) {
          if (mounted)
            errors.add(
              '${file.name}: ${tr(context, 'Could not import this file.')}',
            );
        }
      }
      if (mounted && errors.isNotEmpty) showError(context, errors.join('\n'));
    } catch (_) {
      if (mounted) showError(context, 'Could not open the file picker.');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _open(Book book) async {
    final file = library.bookFile(book);
    if (!await file.exists()) {
      if (mounted)
        showError(
          context,
          'The imported copy is missing. Select the original file to restore it.',
        );
      return;
    }
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => book.format == 'comic'
            ? ReaderPage(
                repository: library,
                book: book,
                rasterPages: LocalComicPages(file),
              )
            : DocumentReader(
                repository: library,
                book: book,
                load: () async => file,
                incognito: false,
              ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _remove(Book book) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'Remove Local Book')),
        content: Text(
          tr(
            context,
            'Only the imported copy is removed. The original file stays on your device.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'Remove')),
          ),
        ],
      ),
    );
    if (remove != true) return;
    try {
      await library.remove(book);
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: widget.standalone
        ? AppBar(title: Text(tr(context, 'Local Books')))
        : null,
    body: ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final books = library.books;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr(
                        context,
                        'Import EPUB, PDF or comic archives (CBZ, CBR, CB7, CBT).',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _importing ? null : _import,
                    icon: const Icon(Icons.add),
                    label: Text(tr(context, 'Import Files')),
                  ),
                ],
              ),
            ),
            if (_importing) const LinearProgressIndicator(),
            Expanded(
              child: books.isEmpty
                  ? Center(child: Text(tr(context, 'No local books yet')))
                  : ListView.builder(
                      itemCount: books.length,
                      itemBuilder: (context, index) {
                        final book = books[index];
                        return ListTile(
                          leading: Icon(
                            book.format == 'comic'
                                ? Icons.collections_bookmark_outlined
                                : Icons.menu_book_outlined,
                          ),
                          title: Text(book.title),
                          subtitle: Text(
                            '${book.format.toUpperCase()}${book.page > 0 ? ' · ${book.page} / ${book.pages}' : ''}',
                          ),
                          onTap: () => _open(book),
                          trailing: IconButton(
                            tooltip: tr(context, 'Remove'),
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _remove(book),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    ),
  );
}
