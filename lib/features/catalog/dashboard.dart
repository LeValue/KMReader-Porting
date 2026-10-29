import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/repository.dart';
import '../../core/read_list_reading.dart';
import '../../ui/common.dart';
import '../../ui/strings.dart';
import 'catalog_page.dart';

const dashboardSections = [
  'dashboard.keepReading',
  'dashboard.onDeck',
  'dashboard.readListsInProgress',
  'dashboard.recentlyReleasedBooks',
  'dashboard.recentlyAddedBooks',
  'dashboard.recentlyAddedSeries',
  'dashboard.recentlyUpdatedSeries',
  'dashboard.recentlyReadBooks',
];

const dashboardCardKinds = {
  'large': 'dashboard.cardKind.large',
  'medium': 'dashboard.cardKind.medium',
  'small': 'dashboard.cardKind.small',
  'horizontal': 'dashboard.cardKind.horizontal',
};

/// Shared by the dashboard and See All, so their filters cannot diverge.
class DashboardQuery {
  DashboardQuery(this.title, {this.libraryId, DateTime? now})
    : now = now ?? DateTime.now();
  final String title;
  final String? libraryId;
  final DateTime now;
  String get kind => title.endsWith('Series') ? 'series' : 'books';
  String? get path => switch (title) {
    'dashboard.onDeck' => '/api/v1/books/ondeck',
    'dashboard.recentlyAddedSeries' => '/api/v1/series/new',
    'dashboard.recentlyUpdatedSeries' => '/api/v1/series/updated',
    _ => null,
  };
  String get sort => switch (title) {
    'dashboard.keepReading' ||
    'dashboard.recentlyReadBooks' => 'readProgress.readDate,desc',
    'dashboard.onDeck' => 'metadata.titleSort,asc',
    'dashboard.recentlyReleasedBooks' => 'metadata.releaseDate,desc',
    'dashboard.recentlyUpdatedSeries' => 'lastModified,desc',
    _ => 'created,desc',
  };
  Json? get condition {
    final values = <Json>[
      if (title == 'dashboard.keepReading' ||
          title == 'dashboard.recentlyReadBooks')
        {
          'readStatus': {
            'operator': 'is',
            'value': title == 'dashboard.keepReading' ? 'IN_PROGRESS' : 'READ',
          },
        },
      if (title == 'dashboard.recentlyReleasedBooks')
        {
          'releaseDate': {
            'operator': 'after',
            'dateTime': _cutoff.toUtc().toIso8601String(),
          },
        },
      if (libraryId != null)
        {
          'libraryId': {'operator': 'is', 'value': libraryId},
        },
    ];
    return values.isEmpty
        ? null
        : values.length == 1
        ? values.single
        : {'allOf': values};
  }

  DateTime get _cutoff {
    // Calendar-day cutoff, including March 31 -> February 28/29.
    // Stable during the day so background refresh can reuse the query cache.
    final last = DateTime(now.year, now.month, 0).day;
    return DateTime(now.year, now.month - 1, now.day > last ? last : now.day);
  }
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key, required this.repository});
  final Repository repository;
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final _scroll = ScrollController();
  Repository get repository => widget.repository;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _scope(BuildContext context, List<String> selected) async {
    try {
      final data = await repository.get('/api/v1/libraries', cacheFirst: true);
      if (!context.mounted) return;
      final libraries = {
        for (final value in data as List)
          text(object(value)['id']): text(object(value)['name']),
      };
      final picked = selected.toSet();
      final saved = await showDialog<List<String>>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (dialog, refresh) => AlertDialog(
            title: Text(tr(dialog, 'Libraries')),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CheckboxListTile(
                      title: Text(tr(dialog, 'All Libraries')),
                      value: picked.isEmpty,
                      onChanged: (_) => refresh(picked.clear),
                    ),
                    for (final entry in libraries.entries)
                      CheckboxListTile(
                        title: Text(entry.value),
                        value: picked.contains(entry.key),
                        onChanged: (value) => refresh(() {
                          if (value == true) {
                            picked.add(entry.key);
                          } else {
                            picked.remove(entry.key);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: Text(tr(dialog, 'Cancel')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialog, picked.toList()..sort()),
                child: Text(tr(dialog, 'Done')),
              ),
            ],
          ),
        ),
      );
      if (saved == null || !mounted || repository.closed) return;
      repository.store.setSetting('dashboardLibrary:${repository.profile.id}', {
        'ids': saved,
        'names': [for (final id in saved) libraries[id] ?? id],
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
      repository.refreshContent();
    } catch (error) {
      if (context.mounted) showError(context, error);
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
      final libraries = scope['ids'] is List
          ? (scope['ids'] as List).whereType<String>().toList()
          : [if (text(scope['id']).isNotEmpty) text(scope['id'])];
      final names = scope['names'] is List
          ? (scope['names'] as List).whereType<String>().toList()
          : [if (text(scope['name']).isNotEmpty) text(scope['name'])];
      final library = libraries.join(',');
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
      return ScrollConfiguration(
        behavior: ScrollConfiguration.of(context)
            .copyWith(overscroll: false, scrollbars: false),
        child: Scrollbar(
          controller: _scroll,
          child: RefreshIndicator(
            onRefresh: () async => repository.refreshContent(),
            child: ListView(
              key: const PageStorageKey('dashboard-scroll'),
              controller: _scroll,
              primary: false,
              physics: const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics(),
              ),
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
                          onTap: () => _scope(context, libraries),
                          borderRadius: BorderRadius.circular(10),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    libraries.isEmpty
                                        ? tr(context, 'All Libraries')
                                        : libraries.length == 1
                                        ? (names.firstOrNull ?? libraries.first)
                                        : '${libraries.length} ${tr(context, 'Libraries')}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineLarge,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(
                                  CupertinoIcons.chevron_down,
                                  size: 18,
                                ),
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
                  if (!hidden.contains(title) &&
                      (title != 'dashboard.readListsInProgress' ||
                          repository.readLists.enabled))
                    if (title == 'dashboard.readListsInProgress')
                      _ReadListSection(
                        repository: repository,
                        libraryIds: libraries,
                      )
                    else
                      _DashboardSection(
                        key: ValueKey('$title:$library'),
                        repository: repository,
                        title: title,
                        libraryIds: libraries,
                      ),
              ],
            ),
          ),
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
    this.libraryIds,
  });
  final List<String>? libraryIds;
  final Repository repository;
  final String title;
  DashboardQuery get query =>
      DashboardQuery(title, now: repository.cacheClock());
  String get kind => query.kind;
  String? get path => query.path;
  String get sort => query.sort;
  Json? get condition => query.condition;
  String get cardKind {
    final saved = repository.store.setting<String>(
      'dashboardCard:${repository.profile.id}:$title',
    );
    if (dashboardCardKinds.containsKey(saved)) return saved!;
    return switch (title) {
      'dashboard.keepReading' => 'horizontal',
      'dashboard.recentlyReadBooks' ||
      'dashboard.recentlyAddedSeries' => 'small',
      _ => 'large',
    };
  }

  double cardWidth(BuildContext context) => switch (cardKind) {
    'horizontal' => 250,
    'medium' => 116,
    'small' => MediaQuery.sizeOf(context).width >= 900 ? 100 : 80,
    _ => MediaQuery.sizeOf(context).width >= 900 ? 132 : 152,
  };

  @override
  Widget build(BuildContext context) => AsyncPanel<CatalogPage>(
    pullToRefresh: false,
    loading: SizedBox(
      height:
          (cardKind == 'horizontal' ? 122 : cardWidth(context) * 1.5 + 64) + 84,
      child: const Center(child: CircularProgressIndicator.adaptive()),
    ),
    revision: repository.contentRevision + repository.cacheRevision,
    load: () => repository.catalog(
      kind,
      sort: sort,
      path: path,
      condition: condition,
      libraryIds: libraryIds,
      size: 12,
    ),
    builder: (context, result) => DecoratedBox(
      decoration: BoxDecoration(
        gradient:
            repository.store.setting<bool>(
                  'showDashboardSectionGradientBackground',
                ) ==
                true
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Theme.of(context).colorScheme.surfaceContainerHighest
                      .withValues(alpha: .4),
                  Colors.transparent,
                ],
              )
            : null,
      ),
      child: Column(
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
                if (repository.store.setting<bool>(
                      'showDashboardCardKindMenu',
                    ) !=
                    false)
                  PopupMenuButton<String>(
                    tooltip: tr(context, 'Card Style'),
                    initialValue: cardKind,
                    onSelected: (value) {
                      repository.store.setSetting(
                        'dashboardCard:${repository.profile.id}:$title',
                        value,
                      );
                      repository.catalogChanges.value++;
                    },
                    itemBuilder: (_) => [
                      for (final entry in dashboardCardKinds.entries)
                        CheckedPopupMenuItem(
                          value: entry.key,
                          checked: cardKind == entry.key,
                          child: Text(tr(context, entry.value)),
                        ),
                    ],
                    icon: const Icon(CupertinoIcons.ellipsis, size: 18),
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
                          libraryIds: libraryIds,
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
              height: cardKind == 'horizontal'
                  ? 122
                  : cardWidth(context) * 1.5 + 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                itemCount: result.items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 16),
                itemBuilder: (context, index) {
                  final item = result.items[index];
                  if (cardKind == 'horizontal') {
                    return _ContinueCard(repository: repository, item: item);
                  }
                  return SizedBox(
                    width: cardWidth(context),
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
                    if (item.kind == 'books')
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

class _ReadListSection extends StatelessWidget {
  const _ReadListSection({required this.repository, this.libraryIds});
  final List<String>? libraryIds;
  final Repository repository;
  @override
  Widget build(BuildContext context) => AsyncPanel<List<ReadListContinuation>>(
    pullToRefresh: false,
    revision:
        repository.contentRevision +
        repository.progressRevision +
        repository.cacheRevision,
    load: () => repository.readLists.continuations(libraryIds: libraryIds),
    builder: (context, values) => values.isEmpty
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                child: Text(
                  tr(context, 'dashboard.readListsInProgress'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              SizedBox(
                height: 146,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  itemCount: values.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 16),
                  itemBuilder: (context, index) {
                    final entry = values[index];
                    return SizedBox(
                      width: 300,
                      child: Card(
                        child: InkWell(
                          onTap: () => openItem(
                            context,
                            repository,
                            CatalogItem(
                              'books',
                              entry.book.json,
                              readListId: entry.list.id,
                            ),
                          ),
                          borderRadius: BorderRadius.circular(14),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 50,
                                  height: 76,
                                  child: Cover(
                                    repository: repository,
                                    path:
                                        '/api/v1/books/${Uri.encodeComponent(entry.book.id)}/thumbnail',
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        entry.list.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        entry.book.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        '${entry.read}/${entry.count} ${tr(context, 'Books')}',
                                      ),
                                      LinearProgressIndicator(
                                        value: entry.count == 0
                                            ? 0
                                            : entry.read / entry.count,
                                      ),
                                    ],
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  onSelected: (_) =>
                                      repository.readLists.stop(entry.list.id),
                                  itemBuilder: (_) => [
                                    PopupMenuItem(
                                      value: 'stop',
                                      child: Text(tr(context, 'Stop Reading')),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
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
