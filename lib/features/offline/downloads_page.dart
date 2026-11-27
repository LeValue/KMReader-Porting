import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import '../catalog/catalog_page.dart';
import '../settings/cache_settings.dart';
import '../../ui/wheel_scroll.dart';

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key, required this.repository});
  final Repository repository;

  String _size(BuildContext context, int bytes) {
    final mb = bytes / (1024 * 1024);
    final amount = mb >= 1024 ? mb / 1024 : mb;
    return '${NumberFormat.decimalPatternDigits(locale: Localizations.localeOf(context).toLanguageTag(), decimalDigits: 1).format(amount)} ${mb >= 1024 ? 'GiB' : 'MiB'}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, 'Downloads')),
      actions: [
        if (!repository.profile.isKindle)
          ListenableBuilder(
            listenable: repository,
            builder: (context, _) {
              final paused = repository.downloadQueuePaused;
              return IconButton(
                tooltip: tr(context, paused ? 'Resume Queue' : 'Pause Queue'),
                onPressed: () => repository.setDownloadQueuePaused(!paused),
                icon: Icon(paused ? CupertinoIcons.play : CupertinoIcons.pause),
              );
            },
          ),
        IconButton(
          tooltip: tr(context, 'Cache'),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => CacheSettingsPage(repository: repository),
            ),
          ),
          icon: const Icon(Icons.storage_outlined),
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
        final ready = items.where((row) => row['status'] == 'ready');
        final active = items
            .where((row) => row['status'] == 'downloading')
            .length;
        final waiting = items
            .where((row) => const {'queued', 'paused'}.contains(row['status']))
            .length;
        final size = ready.fold<int>(
          0,
          (sum, row) => sum + integer(row['size']),
        );
        final sections = {
          'Download Queue': items
              .where(
                (row) => const {
                  'queued',
                  'downloading',
                  'paused',
                }.contains(row['status']),
              )
              .toList(),
          'Interrupted Downloads': items
              .where(
                (row) => !const {
                  'queued',
                  'downloading',
                  'paused',
                  'ready',
                }.contains(row['status']),
              )
              .toList(),
          'Completed Downloads': ready.toList(),
        };
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                    child: Wrap(
                      spacing: 14,
                      runSpacing: 6,
                      children: [
                        Text(
                          '${tr(context, 'Completed Downloads')} · ${ready.length} · ${_size(context, size)}',
                        ),
                        if (active > 0)
                          Text('${tr(context, 'Downloading')} · $active'),
                        if (waiting > 0)
                          Text('${tr(context, 'Queued')} · $waiting'),
                        if (repository.downloadQueuePaused)
                          Text(tr(context, 'Queue Paused')),
                      ],
                    ),
                  ),
                ),
                for (final section in sections.entries)
                  if (section.value.isNotEmpty)
                    SliverMainAxisGroup(
                      slivers: [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
                            child: Text(
                              tr(context, section.key),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                        ),
                        SliverList.separated(
                          itemCount: section.value.length,
                          separatorBuilder: (_, _) => const Divider(
                            height: 1,
                            indent: 80,
                            endIndent: 20,
                          ),
                          itemBuilder: (context, index) =>
                              _downloadRow(context, section.value[index]),
                        ),
                      ],
                    ),
              ],
            ).withWheelScrolling(),
          ),
        );
      },
    ),
  );

  Widget _downloadRow(BuildContext context, Json item) {
    final book = repository.overlay(Book(object(item['book'])));
    final progress =
        repository.downloading[book.id] ??
        (item['status'] == 'downloading' && item['fraction'] is num
            ? (item['fraction'] as num).toDouble().clamp(0, 1)
            : null);
    final queued =
        repository.queued(book.id) ||
        const {'queued', 'downloading', 'paused'}.contains(item['status']);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      leading: SizedBox(
        width: 44,
        height: 64,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: Cover(
            repository: repository,
            path: '/api/v1/books/${Uri.encodeComponent(book.id)}/thumbnail',
          ),
        ),
      ),
      title: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      key: ValueKey(book.id),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (book.seriesTitle.isNotEmpty)
            Text(
              book.seriesTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          Text(
            repository.downloadQueuePaused && queued
                ? tr(context, 'Queue Paused')
                : progress != null
                ? '${(progress * 100).round()}%'
                : item['status'] == 'paused'
                ? tr(context, 'Waiting for download conditions')
                : queued
                ? tr(context, 'Queued')
                : item['status'] == 'ready'
                ? _size(context, integer(item['size']))
                : text(item['error'], tr(context, 'Download interrupted')),
          ),
          if (progress != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(value: progress),
            ),
        ],
      ),
      onTap: () =>
          openItem(context, repository, CatalogItem('books', book.json)),
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
  }
}
