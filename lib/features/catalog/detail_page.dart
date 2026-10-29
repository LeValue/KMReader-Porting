import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../reader/reader_page.dart';
import 'catalog_page.dart';
import 'list_actions.dart';
import 'list_editor.dart';
import 'metadata_editor.dart';
import 'komf_page.dart';
import '../../core/catalog_tools.dart';

class DetailPage extends StatelessWidget {
  const DetailPage({super.key, required this.repository, required this.item});
  final Repository repository;
  final CatalogItem item;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: repository.catalogChanges,
    builder: (context, _) {
      final key = item.kind == 'books'
          ? 'book:${item.id}'
          : 'detail:${item.kind}:${item.id}';
      final cached = repository.store.cached(repository.profile.id, key);
      final current = cached == null
          ? item
          : CatalogItem(item.kind, object(cached), readListId: item.readListId);
      return _DetailContent(repository: repository, item: current);
    },
  );
}

class _DetailContent extends StatelessWidget {
  const _DetailContent({required this.repository, required this.item});
  final Repository repository;
  final CatalogItem item;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(item.title),
      actions: [
        if (repository.profile.admin && ['books', 'series'].contains(item.kind))
          KomfButton(repository: repository, item: item),
        if (item.kind == 'readlists' || item.kind == 'collections')
          IconButton(
            tooltip: tr(
              context,
              CatalogTools(repository).pinned(item.kind).contains(item.id)
                  ? 'Unpin'
                  : 'Pin',
            ),
            onPressed: () => CatalogTools(repository).pin(item.kind, item.id),
            icon: Icon(
              CatalogTools(repository).pinned(item.kind).contains(item.id)
                  ? CupertinoIcons.pin_fill
                  : CupertinoIcons.pin,
            ),
          ),
        if (repository.profile.admin)
          IconButton(
            tooltip: tr(context, 'Edit'),
            onPressed: () async {
              if (item.kind == 'books' || item.kind == 'series') {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        MetadataEditor(repository: repository, item: item),
                  ),
                );
              } else {
                final result = await Navigator.push<String>(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        ListEditor(repository: repository, item: item),
                  ),
                );
                if (result == 'deleted' && context.mounted) {
                  Navigator.pop(context);
                }
              }
            },
            icon: const Icon(CupertinoIcons.pencil),
          ),
      ],
    ),
    body: item.kind == 'books'
        ? ListenableBuilder(
            listenable: repository.catalogChanges,
            builder: (context, _) => AsyncPanel<Book>(
              revision: repository.cacheRevision + repository.contentRevision,
              load: () => repository.book(item.id),
              builder: (context, book) => ListenableBuilder(
                listenable: repository,
                builder: (context, _) => _BookDetail(
                  repository: repository,
                  book: repository.overlay(book),
                  readListId: item.readListId,
                ),
              ),
            ),
          )
        : Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 90,
                      height: 130,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Cover(
                          repository: repository,
                          path: item.thumbnail,
                        ),
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          const SizedBox(height: 12),
                          Text(item.subtitle),
                          if (item.kind == 'series')
                            TextButton.icon(
                              onPressed: () => addToList(
                                context,
                                repository,
                                'collections',
                                item.id,
                              ),
                              icon: const Icon(CupertinoIcons.add),
                              label: Text(tr(context, 'Add to Collection')),
                            ),
                          const SizedBox(height: 12),
                          if (object(item.json['metadata'])['status'] != null)
                            Text(text(object(item.json['metadata'])['status'])),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: CatalogPageView(
                  repository: repository,
                  kind: item.kind == 'collections' ? 'series' : 'books',
                  readListId: item.kind == 'readlists' ? item.id : null,
                  searchEnabled: item.kind != 'readlists',
                  path: item.kind == 'readlists'
                      ? '/api/v1/readlists/${Uri.encodeComponent(item.id)}/books'
                      : null,
                  condition: item.kind == 'series'
                      ? {
                          'seriesId': {'operator': 'is', 'value': item.id},
                        }
                      : item.kind == 'collections'
                      ? {
                          'collectionId': {'operator': 'is', 'value': item.id},
                        }
                      : null,
                ),
              ),
            ],
          ),
  );
}

class _BookDetail extends StatelessWidget {
  const _BookDetail({
    required this.repository,
    required this.book,
    this.readListId,
  });
  final String? readListId;
  final Repository repository;
  final Book book;
  Future<void> _download(BuildContext context) async {
    try {
      await repository.download(book);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authors = (book.metadata['authors'] as List? ?? [])
        .map((v) => text(object(v)['name']))
        .toSet()
        .join(', ');
    final downloaded = repository.store.download(
      repository.profile.id,
      book.id,
    );
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 800;
            final cover = Hero(
              tag: 'cover:${book.id}',
              child: SizedBox(
                width: wide ? 240 : 180,
                height: wide ? 340 : 255,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Cover(
                    repository: repository,
                    path:
                        '/api/v1/books/${Uri.encodeComponent(book.id)}/thumbnail',
                  ),
                ),
              ),
            );
            final details = Column(
              crossAxisAlignment: wide
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              children: [
                if (book.seriesTitle.isNotEmpty)
                  Text(
                    book.seriesTitle,
                    style: TextStyle(color: Theme.of(context).hintColor),
                  ),
                const SizedBox(height: 8),
                Text(
                  book.title,
                  style: Theme.of(context).textTheme.headlineLarge,
                  textAlign: wide ? TextAlign.start : TextAlign.center,
                ),
                if (authors.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(authors),
                ],
                const SizedBox(height: 12),
                Text(
                  '${book.pages} ${tr(context, 'Pages')} · ${text(book.json['size'])}',
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: wide ? WrapAlignment.start : WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ReaderPage(
                            repository: repository,
                            book: book,
                            readListId: readListId,
                          ),
                        ),
                      ),
                      icon: const Icon(CupertinoIcons.book, size: 18),
                      label: Text(
                        tr(
                          context,
                          book.page > 0 && !book.completed
                              ? 'Continue Reading'
                              : 'Read Now',
                        ),
                      ),
                    ),
                    if (repository.downloading.containsKey(book.id))
                      OutlinedButton.icon(
                        onPressed: () => repository.cancelDownload(book.id),
                        icon: const Icon(CupertinoIcons.xmark),
                        label: Text(
                          '${(repository.downloading[book.id]! * 100).round()}%',
                        ),
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: () async {
                          if (downloaded?['status'] == 'ready') {
                            if (await confirm(
                              context,
                              'Remove Download',
                              'The downloaded files will be removed from this device.',
                            )) {
                              try {
                                await repository.removeDownload(book.id);
                              } catch (e) {
                                if (context.mounted) showError(context, e);
                              }
                            }
                          } else {
                            unawaited(_download(context));
                          }
                        },
                        icon: Icon(
                          downloaded?['status'] == 'ready'
                              ? CupertinoIcons.checkmark_circle
                              : CupertinoIcons.arrow_down_to_line,
                        ),
                        label: Text(
                          tr(
                            context,
                            downloaded?['status'] == 'ready'
                                ? 'Downloaded'
                                : 'Download',
                          ),
                        ),
                      ),
                    PopupMenuButton<String>(
                      tooltip: tr(context, 'More'),
                      onSelected: (value) async {
                        if (value == 'list') {
                          await addToList(
                            context,
                            repository,
                            'readlists',
                            book.id,
                          );
                          return;
                        }
                        if (value == 'read') {
                          repository.setProgress(
                            book,
                            book.pages > 0 ? book.pages : 1,
                            completed: true,
                          );
                        }
                        if (value == 'unread') {
                          repository.setProgress(book, 0, reset: true);
                        }
                        if (value == 'peek') {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => ReaderPage(
                                repository: repository,
                                book: book,
                                incognito: true,
                                readListId: readListId,
                              ),
                            ),
                          );
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'list',
                          child: Text(tr(context, 'Add to Read List')),
                        ),
                        PopupMenuItem(
                          value: 'read',
                          child: Text(tr(context, 'Mark as Read')),
                        ),
                        PopupMenuItem(
                          value: 'unread',
                          child: Text(tr(context, 'Mark as Unread')),
                        ),
                        PopupMenuItem(
                          value: 'peek',
                          child: Text(tr(context, 'Incognito Reading')),
                        ),
                      ],
                    ),
                  ],
                ),
                if (book.page > 0) ...[
                  const SizedBox(height: 20),
                  SizedBox(
                    width: 260,
                    child: LinearProgressIndicator(value: book.fraction),
                  ),
                  const SizedBox(height: 8),
                  Text('${book.page} / ${book.pages} ${tr(context, 'Pages')}'),
                ],
                if (downloaded?['status'] == 'failed')
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      text(downloaded?['error']),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            );
            return wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      cover,
                      const SizedBox(width: 32),
                      Expanded(child: details),
                    ],
                  )
                : Column(
                    children: [cover, const SizedBox(height: 24), details],
                  );
          },
        ),
        const SizedBox(height: 32),
        if (text(book.metadata['summary']).isNotEmpty) ...[
          Text(
            tr(context, 'Summary'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          SelectableText(text(book.metadata['summary'])),
          const SizedBox(height: 24),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tag in book.metadata['tags'] as List? ?? [])
              Chip(label: Text('$tag')),
          ],
        ),
        const SizedBox(height: 12),
        if (book.seriesId.isNotEmpty)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr(context, 'View Series')),
            trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
            onTap: () async {
              try {
                final series = await repository.get(
                  '/api/v1/series/${Uri.encodeComponent(book.seriesId)}',
                );
                if (context.mounted) {
                  openItem(
                    context,
                    repository,
                    CatalogItem('series', object(series)),
                  );
                }
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
          ),
      ],
    );
  }
}
