import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/repository.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'catalog_page.dart';

const dashboardSections = [
  'dashboard.keepReading',
  'dashboard.onDeck',
  'dashboard.recentlyAddedBooks',
  'dashboard.recentlyAddedSeries',
  'dashboard.recentlyUpdatedSeries',
];

class Dashboard extends StatelessWidget {
  const Dashboard({super.key, required this.repository});
  final Repository repository;
  Future<void> _scope(BuildContext context, String selected) async {
    try {
      final data = await repository.get('/api/v1/libraries', cacheFirst: true);
      if (!context.mounted) return;
      final choices = {
        '': tr(context, 'All Libraries'),
        for (final v in data as List)
          text(object(v)['id']): text(object(v)['name']),
      };
      final value = await chooseValue(
        context,
        title: 'Libraries',
        selected: selected,
        choices: choices,
        translateChoices: false,
      );
      if (value == null || !context.mounted || repository.closed) return;
      repository.store.setSetting('dashboardLibrary:${repository.profile.id}', {
        'id': value,
        'name': choices[value],
      });
      repository.refreshContent();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: repository.catalogChanges,
    builder: (context, _) {
      final scope = object(
        repository.store.setting<dynamic>(
          'dashboardLibrary:${repository.profile.id}',
        ),
      );
      final library = text(scope['id']);
      final hidden =
          repository.store.setting<List<dynamic>>(
            'dashboardHidden:${repository.profile.id}',
          ) ??
          [];
      final saved =
          repository.store.setting<List<dynamic>>(
            'dashboardOrder:${repository.profile.id}',
          ) ??
          [];
      final order = [
        ...saved.whereType<String>().where(dashboardSections.contains),
        ...dashboardSections.where((s) => !saved.contains(s)),
      ];
      return RefreshIndicator(
        onRefresh: () async => repository.refreshContent(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 28),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    button: true,
                    child: InkWell(
                      onTap: () => _scope(context, library),
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                library.isEmpty
                                    ? tr(context, 'All Libraries')
                                    : text(scope['name']),
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineLarge,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(CupertinoIcons.chevron_down, size: 18),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        CupertinoIcons.tray_2,
                        size: 14,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
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
            for (final title in order)
              if (!hidden.contains(title))
                _DashboardSection(
                  key: ValueKey('$title:$library'),
                  repository: repository,
                  title: title,
                  libraryId: library.isEmpty ? null : library,
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
    this.libraryId,
  });
  final Repository repository;
  final String title;
  final String? libraryId;
  String get kind => title.endsWith('Series') ? 'series' : 'books';
  String? get path => switch (title) {
    'dashboard.onDeck' => '/api/v1/books/ondeck',
    'dashboard.recentlyAddedSeries' => '/api/v1/series/new',
    'dashboard.recentlyUpdatedSeries' => '/api/v1/series/updated',
    _ => null,
  };
  String get sort => switch (title) {
    'dashboard.keepReading' => 'readProgress.lastModified,desc',
    'dashboard.onDeck' => 'metadata.titleSort,asc',
    'dashboard.recentlyUpdatedSeries' => 'lastModified,desc',
    _ => 'created,desc',
  };
  Json? get condition {
    final values = [
      if (title == 'dashboard.keepReading')
        {
          'readStatus': {'operator': 'is', 'value': 'IN_PROGRESS'},
        },
      if (libraryId != null)
        {
          'libraryId': {'operator': 'is', 'value': libraryId},
        },
    ];
    return values.isEmpty
        ? null
        : values.length == 1
        ? values.first
        : {'allOf': values};
  }

  @override
  Widget build(BuildContext context) => AsyncPanel<CatalogPage>(
    revision: repository.contentRevision + repository.cacheRevision,
    load: () => repository.catalog(
      kind,
      sort: sort,
      path: path,
      condition: condition,
      libraryId: libraryId,
      size: 12,
    ),
    builder: (context, result) => Column(
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
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: Text(tr(context, title))),
                      body: CatalogPageView(
                        repository: repository,
                        kind: kind,
                        path: path,
                        condition: condition,
                        libraryId: libraryId,
                        initialSort: sort,
                      ),
                    ),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(tr(context, 'See All')),
                    const Icon(CupertinoIcons.chevron_right, size: 12),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (result.items.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Text(
              tr(
                context,
                title == 'dashboard.keepReading'
                    ? 'Start reading to see your books here.'
                    : 'No Results',
              ),
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          )
        else
          SizedBox(
            height: title == 'dashboard.keepReading'
                ? 122
                : MediaQuery.sizeOf(context).width >= 900
                ? 252
                : 292,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              itemCount: result.items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 16),
              itemBuilder: (context, index) {
                final item = result.items[index];
                if (title == 'dashboard.keepReading') {
                  return _ContinueCard(repository: repository, item: item);
                }
                return SizedBox(
                  width: MediaQuery.sizeOf(context).width >= 900 ? 132 : 152,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: RepaintBoundary(
                      child: BookCard(repository: repository, item: item),
                    ),
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 12),
      ],
    ),
  );
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.repository, required this.item});
  final Repository repository;
  final CatalogItem item;
  @override
  Widget build(BuildContext context) => SizedBox(
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
                  child: Cover(repository: repository, path: item.thumbnail),
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
                      value: repository.overlay(item.book).fraction,
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
