import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'catalog_page.dart';

class Dashboard extends StatelessWidget {
  const Dashboard({super.key, required this.repository});
  final Repository repository;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: repository,
    builder: (context, _) {
      final sections = <(String, String, String?, Json?, String)>[
        (
          'dashboard.keepReading',
          'books',
          null,
          {
            'readStatus': {'operator': 'is', 'value': 'IN_PROGRESS'},
          },
          'readProgress.lastModified,desc',
        ),
        (
          'dashboard.onDeck',
          'books',
          '/api/v1/books/ondeck',
          null,
          'metadata.titleSort,asc',
        ),
        ('dashboard.recentlyAddedBooks', 'books', null, null, 'created,desc'),
        (
          'dashboard.recentlyAddedSeries',
          'series',
          '/api/v1/series/new',
          null,
          'created,desc',
        ),
        (
          'dashboard.recentlyUpdatedSeries',
          'series',
          '/api/v1/series/updated',
          null,
          'lastModified,desc',
        ),
      ];
      final hidden =
          repository.store.setting<List<dynamic>>(
            'dashboardHidden:${repository.profile.id}',
          ) ??
          [];
      return RefreshIndicator(
        onRefresh: () async => repository.refreshContent(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 28),
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Theme.of(context).colorScheme.primary
                        .withValues(alpha: .05),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(context, 'All Libraries'),
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        CupertinoIcons.tray_2,
                        size: 14,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          repository.profile.name,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.secondary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            for (final section in sections)
              if (!hidden.contains(section.$1))
                _DashboardSection(
                  key: ValueKey('${section.$1}:${repository.contentRevision}'),
                  repository: repository,
                  title: section.$1,
                  kind: section.$2,
                  path: section.$3,
                  condition: section.$4,
                  sort: section.$5,
                ),
          ],
        ),
      );
    },
  );
}

class _DashboardSection extends StatelessWidget {
  const _DashboardSection({
    super.key,
    required this.repository,
    required this.title,
    required this.kind,
    this.path,
    this.condition,
    required this.sort,
  });
  final Repository repository;
  final String title, kind, sort;
  final String? path;
  final Json? condition;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                tr(context, title),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: Text(tr(context, title))),
                    body: CatalogPageView(
                      repository: repository,
                      kind: kind,
                      condition: condition,
                      path: path,
                    ),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Text(tr(context, 'See All')),
                  const Icon(CupertinoIcons.chevron_right, size: 12),
                ],
              ),
            ),
          ],
        ),
      ),
      SizedBox(
        height: title == 'dashboard.keepReading'
            ? 122
            : MediaQuery.sizeOf(context).width >= 900
            ? 252
            : 292,
        child: AsyncPanel<CatalogPage>(
          load: () => repository.catalog(
            kind,
            sort: sort,
            path: path,
            condition: condition,
          ),
          builder: (context, result) {
            if (result.items.isEmpty) {
              return ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  Container(
                    width:
                        MediaQuery.sizeOf(context).width.clamp(200, 700) - 48,
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Text(
                        tr(
                          context,
                          title == 'dashboard.keepReading'
                              ? 'Start reading to see your books here.'
                              : 'No Results',
                        ),
                        style: TextStyle(color: Theme.of(context).hintColor),
                      ),
                    ),
                  ),
                ],
              );
            }
            return ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              itemCount: result.items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 16),
              itemBuilder: (context, index) {
                final item = result.items[index];
                if (title == 'dashboard.keepReading') {
                  return SizedBox(
                    width: 250,
                    child: Card(
                      child: InkWell(
                        onTap: () => openItem(context, repository, item),
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 48,
                                height: 72,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Cover(
                                    repository: repository,
                                    path: item.thumbnail,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      item.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      item.subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                    const SizedBox(height: 12),
                                    LinearProgressIndicator(
                                      value: repository
                                          .overlay(item.book)
                                          .fraction,
                                      minHeight: 3,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }
                return SizedBox(
                  width: MediaQuery.sizeOf(context).width >= 900 ? 132 : 152,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: BookCard(repository: repository, item: item),
                  ),
                );
              },
            );
          },
        ),
      ),
      const SizedBox(height: 12),
    ],
  );
}
