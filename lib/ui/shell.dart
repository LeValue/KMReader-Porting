import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/models.dart';
import '../core/repository.dart';
import '../features/catalog/catalog_page.dart';
import '../features/catalog/dashboard.dart';
import '../features/offline/downloads_page.dart';
import '../features/settings/settings_page.dart';
import 'common.dart';
import 'strings.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.app, required this.repository});
  final AppController app;
  final Repository repository;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  final _visited = <int, Widget>{};
  @override
  void didUpdateWidget(AppShell old) {
    super.didUpdateWidget(old);
    if (old.repository != widget.repository) _visited.clear();
  }

  static const _labels = [
    'title.dashboard',
    'Library',
    'Lists',
    'Search',
    'Settings',
  ];
  static const _icons = [
    CupertinoIcons.house,
    CupertinoIcons.book,
    CupertinoIcons.rectangle_stack,
    CupertinoIcons.search,
    CupertinoIcons.gear,
  ];
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final repository = widget.repository;
    _visited.putIfAbsent(
      _index,
      () => switch (_index) {
        0 => Dashboard(repository: repository),
        1 => _LibraryBrowser(repository: repository),
        2 => _ListsPage(repository: repository),
        3 => _SearchPage(repository: repository),
        _ => SettingsPage(app: widget.app, repository: repository),
      },
    );
    final content = IndexedStack(
      index: _index,
      children: [
        for (var i = 0; i < 5; i++)
          TickerMode(
            enabled: i == _index,
            child: _visited[i] ?? const SizedBox.shrink(),
          ),
      ],
    );
    return Scaffold(
      appBar: wide
          ? null
          : AppBar(
              title: Text(tr(context, _labels[_index])),
              actions: [
                IconButton(
                  tooltip: tr(context, 'Downloads'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => DownloadsPage(repository: repository),
                    ),
                  ),
                  icon: const Icon(CupertinoIcons.arrow_down_to_line),
                ),
              ],
            ),
      body: SafeArea(
        child: Row(
          children: [
            if (wide)
              SizedBox(
                width: 238,
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 24, 20, 26),
                        child: Row(
                          children: [
                            Image.asset('assets/logo.png', height: 30),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'KMReader',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 20,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      for (var i = 0; i < _labels.length; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 2,
                          ),
                          child: ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            selected: _index == i,
                            selectedTileColor: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: .08),
                            leading: Icon(_icons[i], size: 21),
                            title: Text(tr(context, _labels[i])),
                            onTap: () => setState(() => _index = i),
                          ),
                        ),
                      const Divider(indent: 20, endIndent: 20),
                      ListTile(
                        leading: const Icon(
                          CupertinoIcons.arrow_down_to_line,
                          size: 21,
                        ),
                        title: Text(tr(context, 'Downloads')),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                DownloadsPage(repository: repository),
                          ),
                        ),
                      ),
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const CircleAvatar(
                            radius: 18,
                            child: Icon(CupertinoIcons.person, size: 20),
                          ),
                          title: Text(
                            repository.profile.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            repository.profile.email,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => setState(() => _index = 4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: Column(
                children: [
                  if (wide)
                    SizedBox(
                      height: 64,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Row(
                          children: [
                            Text(
                              tr(context, _labels[_index]),
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const Spacer(),
                            IconButton(
                              tooltip: tr(context, 'Refresh'),
                              onPressed: repository.refreshContent,
                              icon: const Icon(CupertinoIcons.arrow_clockwise),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ListenableBuilder(
                    listenable: repository,
                    builder: (context, _) =>
                        repository.offline || repository.pendingCount > 0
                        ? MaterialBanner(
                            content: Text(
                              repository.offline
                                  ? tr(context, 'Offline Mode')
                                  : '${repository.pendingCount} ${tr(context, 'changes waiting to sync')}',
                            ),
                            leading: Icon(
                              repository.offline
                                  ? CupertinoIcons.wifi_slash
                                  : CupertinoIcons.arrow_2_circlepath,
                            ),
                            actions: [
                              TextButton(
                                onPressed: () {
                                  repository.setOffline(false);
                                  repository.sync();
                                },
                                child: Text(tr(context, 'Reconnect')),
                              ),
                            ],
                          )
                        : const SizedBox.shrink(),
                  ),
                  Expanded(child: content),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              labelTextStyle: const WidgetStatePropertyAll(
                TextStyle(fontSize: 11),
              ),
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (var i = 0; i < _labels.length; i++)
                  NavigationDestination(
                    icon: Icon(_icons[i]),
                    label: tr(context, _labels[i]),
                  ),
              ],
            ),
    );
  }
}

class _LibraryBrowser extends StatelessWidget {
  const _LibraryBrowser({required this.repository});
  final Repository repository;
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Column(
      children: [
        TabBar(
          tabs: [
            Tab(text: tr(context, 'Series')),
            Tab(text: tr(context, 'Books')),
            Tab(text: tr(context, 'Libraries')),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              CatalogPageView(repository: repository),
              CatalogPageView(repository: repository, kind: 'books'),
              AsyncPanel<dynamic>(
                load: () =>
                    repository.get('/api/v1/libraries', cacheFirst: true),
                builder: (context, data) => ListView(
                  children: [
                    for (final value in data as List)
                      ListTile(
                        leading: const Icon(CupertinoIcons.book),
                        title: Text(text(object(value)['name'])),
                        trailing: const Icon(
                          CupertinoIcons.chevron_right,
                          size: 16,
                        ),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => Scaffold(
                              appBar: AppBar(
                                title: Text(text(object(value)['name'])),
                              ),
                              body: CatalogPageView(
                                repository: repository,
                                condition: {
                                  'libraryId': {
                                    'operator': 'is',
                                    'value': object(value)['id'],
                                  },
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ListsPage extends StatelessWidget {
  const _ListsPage({required this.repository});
  final Repository repository;
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Column(
      children: [
        TabBar(
          tabs: [
            Tab(text: tr(context, 'Read Lists')),
            Tab(text: tr(context, 'Collections')),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              CatalogPageView(
                repository: repository,
                kind: 'readlists',
                path: '/api/v1/readlists',
              ),
              CatalogPageView(
                repository: repository,
                kind: 'collections',
                path: '/api/v1/collections',
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SearchPage extends StatelessWidget {
  const _SearchPage({required this.repository});
  final Repository repository;
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Column(
      children: [
        TabBar(
          tabs: [
            Tab(text: tr(context, 'Series')),
            Tab(text: tr(context, 'Books')),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              CatalogPageView(repository: repository),
              CatalogPageView(repository: repository, kind: 'books'),
            ],
          ),
        ),
      ],
    ),
  );
}
