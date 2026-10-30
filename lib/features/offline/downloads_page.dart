import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../catalog/catalog_page.dart';
import '../../ui/wheel_scroll.dart';

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key, required this.repository});
  final Repository repository;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, 'Downloads')),
      actions: [
        IconButton(
          tooltip: tr(context, 'Resume Queue'),
          onPressed: repository.resumeDownloads,
          icon: const Icon(CupertinoIcons.play),
        ),
        PopupMenuButton<int>(
          tooltip: tr(context, 'Simultaneous Downloads'),
          onSelected: repository.setDownloadConcurrency,
          itemBuilder: (_) => [
            for (final n in [1, 2, 3])
              CheckedPopupMenuItem(
                value: n,
                checked: repository.downloadConcurrency == n,
                child: Text('$n ${tr(context, 'Simultaneous Downloads')}'),
              ),
          ],
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: repository,
      builder: (context, _) {
        final items = repository.store.downloads(repository.profile.id);
        if (items.isEmpty) {
          return const EmptyView(
            title: 'No Downloads',
            message: 'Download a book to read it offline.',
            icon: CupertinoIcons.arrow_down_to_line,
          );
        }
        return ListView.separated(
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(indent: 80),
          itemBuilder: (context, index) {
            final item = items[index];
            final book = repository.overlay(Book(object(item['book'])));
            final progress =
                repository.downloading[book.id] ??
                (item['status'] == 'downloading' && item['fraction'] is num
                    ? (item['fraction'] as num).toDouble().clamp(0, 1)
                    : null);
            final queued = repository.queued(book.id);
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 8,
              ),
              leading: SizedBox(
                width: 44,
                height: 64,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: Cover(
                    repository: repository,
                    path:
                        '/api/v1/books/${Uri.encodeComponent(book.id)}/thumbnail',
                  ),
                ),
              ),
              title: Text(book.title),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    progress != null
                        ? '${(progress * 100).round()}%'
                        : item['status'] == 'paused'
                        ? tr(context, 'Waiting for download conditions')
                        : queued
                        ? tr(context, 'Queued')
                        : item['status'] == 'ready'
                        ? '${(integer(item['size']) / 1024 / 1024).toStringAsFixed(1)} MB'
                        : text(
                            item['error'],
                            tr(context, 'Download interrupted'),
                          ),
                  ),
                  if (progress != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: LinearProgressIndicator(value: progress),
                    ),
                ],
              ),
              onTap: () => openItem(
                context,
                repository,
                CatalogItem('books', book.json),
              ),
              trailing: progress != null || queued
                  ? IconButton(
                      tooltip: tr(context, 'Cancel'),
                      onPressed: () => repository.cancelDownload(book.id),
                      icon: const Icon(CupertinoIcons.xmark),
                    )
                  : PopupMenuButton<String>(
                      onSelected: (value) async {
                        if (value == 'retry') {
                          unawaited(
                            repository.download(book).catchError((Object e) {
                              if (context.mounted) showError(context, e);
                            }),
                          );
                        }
                        if (value == 'remove' &&
                            await confirm(
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
                      },
                      itemBuilder: (_) => [
                        if (item['status'] != 'ready')
                          PopupMenuItem(
                            value: 'retry',
                            child: Text(tr(context, 'Retry')),
                          ),
                        PopupMenuItem(
                          value: 'remove',
                          child: Text(tr(context, 'Remove Download')),
                        ),
                      ],
                    ),
            );
          },
        ).withWheelScrolling();
      },
    ),
  );
}
