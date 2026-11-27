import 'dart:async';
import 'dart:io';

import 'shell_navigation.dart';
import '../features/local/local_library_page.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/app_controller.dart';
import '../core/catalog_tools.dart';
import '../core/download_notifications.dart';
import '../core/models.dart';
import '../core/repository.dart';
import '../core/system_actions.dart';
import '../core/kindle/repository.dart';
import '../features/kindle/kindle_import_page.dart';
import '../features/catalog/catalog_page.dart';
import '../features/catalog/dashboard.dart';
import '../features/catalog/smart_lists_page.dart';
import '../features/offline/downloads_page.dart';
import '../features/settings/settings_page.dart';
import 'common.dart';
import 'strings.dart';
import 'wheel_scroll.dart';

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
  var _settings = GlobalKey<SettingsPageState>();
  StreamSubscription<void>? _systemActions;
  StreamSubscription<void>? _downloadNotifications;
  bool _openingNotification = false;

  Future<void> _routeDownloadNotification() async {
    final id = DownloadNotifications.pending;
    final app = widget.app;
    if (id == null ||
        !mounted ||
        _openingNotification ||
        app.deviceLock.locked) {
      return;
    }
    final profile = app.visibleServers
        .where((value) => value.id == id && !value.isProtected)
        .firstOrNull;
    if (profile == null ||
        app.store.setting<bool>(DownloadNotifications.setting) != true ||
        app.store.setting<bool>('privacyProtection') == true) {
      DownloadNotifications.discard(id);
      return;
    }
    if (widget.repository.profile.id == id) {
      DownloadNotifications.discard(id);
      _openAction(SystemAction.downloads);
      return;
    }
    _openingNotification = true;
    try {
      await app.activate(profile);
    } catch (failure) {
      DownloadNotifications.discard(id);
      if (mounted) showError(context, failure);
    } finally {
      _openingNotification = false;
    }
  }

  void _onUnlock() {
    if (DownloadNotifications.pending != null &&
        !widget.app.deviceLock.locked) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _routeDownloadNotification(),
      );
    }
  }

  Future<void> _routeAndroidAction() async {
    final action = await AndroidSystemActions.take();
    if (mounted && action != null) _openAction(action);
  }

  void _openAction(SystemAction action) {
    final repository = widget.repository;
    if (repository.closed) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => switch (action) {
          SystemAction.search => CatalogSearchPage(repository: repository),
          SystemAction.downloads => DownloadsPage(repository: repository),
          SystemAction.reading => Scaffold(
            appBar: AppBar(title: Text(tr(context, 'dashboard.keepReading'))),
            body: CatalogPageView(
              repository: repository,
              kind: 'books',
              condition: DashboardQuery('dashboard.keepReading').condition,
              initialSort: DashboardQuery('dashboard.keepReading').sort,
              libraryIds: dashboardLibraryIds(repository),
            ),
          ),
        },
      ),
    );
  }

  void _importKindle() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          KindleImportPage(repository: widget.repository as KindleRepository),
    ),
  );
  void _openServers() {
    setState(() => _index = 4);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _settings.currentState?.openServers();
    });
  }

  @override
  void initState() {
    super.initState();
    widget.repository.eventNotices.addListener(_notice);
    if (DownloadNotifications.supported) {
      widget.app.deviceLock.addListener(_onUnlock);
      _downloadNotifications = DownloadNotifications.events.listen(
        (_) => _routeDownloadNotification(),
      );
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _routeDownloadNotification(),
      );
    }
    if (Platform.isAndroid) {
      _systemActions = AndroidSystemActions.events.listen(
        (_) => _routeAndroidAction(),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_routeAndroidAction());
      });
    }
  }

  void _notice() {
    final message = widget.repository.eventNotices.value;
    if (mounted && message != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr(context, message))));
    }
  }

  @override
  void dispose() {
    unawaited(_systemActions?.cancel());
    unawaited(_downloadNotifications?.cancel());
    if (DownloadNotifications.supported) {
      widget.app.deviceLock.removeListener(_onUnlock);
    }
    widget.repository.eventNotices.removeListener(_notice);
    super.dispose();
  }

  @override
  void didUpdateWidget(AppShell old) {
    super.didUpdateWidget(old);
    if (old.repository != widget.repository) {
      old.repository.eventNotices.removeListener(_notice);
      widget.repository.eventNotices.addListener(_notice);
      _visited.clear();
      _settings = GlobalKey<SettingsPageState>();
    }
  }

  static const _labels = [
    'title.dashboard',
    'Library',
    'Lists',
    'Local Books',
    'Settings',
  ];
  static const _icons = [
    CupertinoIcons.house,
    CupertinoIcons.book,
    CupertinoIcons.rectangle_stack,
    CupertinoIcons.folder,
    CupertinoIcons.gear,
  ];
  Widget _withPlatformShortcuts(Widget child) {
    if (defaultTargetPlatform != TargetPlatform.windows) return child;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            _openAction(SystemAction.search),
        const SingleActivator(LogicalKeyboardKey.keyJ, control: true): () =>
            _openAction(SystemAction.downloads),
        for (final (index, key) in const [
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.digit2,
          LogicalKeyboardKey.digit3,
          LogicalKeyboardKey.digit4,
          LogicalKeyboardKey.digit5,
        ].indexed)
          SingleActivator(key, alt: true): () => setState(() => _index = index),
      },
      child: Focus(autofocus: true, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide =
        MediaQuery.sizeOf(context).width >= 900 &&
        widget.app.store.setting<bool>('useClassicPadNavigation') != false;
    final repository = widget.repository;
    _visited.putIfAbsent(
      _index,
      () => switch (_index) {
        0 => Dashboard(repository: repository),
        1 => _LibraryBrowser(repository: repository),
        2 => _ListsPage(repository: repository),
        3 => LocalLibraryPage(app: widget.app),
        _ => SettingsPage(
          key: _settings,
          app: widget.app,
          repository: repository,
        ),
      },
    );
    final content = IndexedStack(
      index: _index,
      children: [
        for (var i = 0; i < _labels.length; i++)
          TickerMode(
            enabled: i == _index,
            child: _visited[i] ?? const SizedBox.shrink(),
          ),
      ],
    );
    final scaffold = Scaffold(
      appBar: wide || _index == 4
          ? null
          : AppBar(
              title: Text(tr(context, _labels[_index])),
              actions: [
                if (repository is KindleRepository)
                  IconButton(
                    tooltip: tr(context, 'Send to Kindle'),
                    onPressed: _importKindle,
                    icon: const Icon(Icons.upload_file),
                  ),
                IconButton(
                  tooltip: tr(context, 'Search'),
                  onPressed: () => _openAction(SystemAction.search),
                  icon: const Icon(CupertinoIcons.search),
                ),
                IconButton(
                  tooltip: tr(context, 'Downloads'),
                  onPressed: () => _openAction(SystemAction.downloads),
                  icon: const Icon(CupertinoIcons.arrow_down_to_line),
                ),
              ],
            ),
      body: SafeArea(
        child: Row(
          children: [
            if (wide)
              SizedBox(
                width: MediaQuery.sizeOf(context).width >= 1100 ? 304 : 260,
                child: Material(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
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
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.only(bottom: 12),
                          children: [
                            for (var i = 0; i < _labels.length; i++)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 2,
                                ),
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                  minTileHeight: 44,
                                  selected: _index == i,
                                  selectedTileColor: Theme.of(context)
                                      .colorScheme
                                      .secondaryContainer,
                                  selectedColor: Theme.of(context)
                                      .colorScheme
                                      .onSecondaryContainer,
                                  leading: Icon(_icons[i], size: 21),
                                  title: Text(tr(context, _labels[i])),
                                  onTap: () => setState(() => _index = i),
                                ),
                              ),
                            const Divider(indent: 20, endIndent: 20),
                            if (repository is KindleRepository)
                              ListTile(
                                leading: const Icon(
                                  Icons.upload_file,
                                  size: 21,
                                ),
                                title: Text(tr(context, 'Send to Kindle')),
                                onTap: _importKindle,
                              ),
                            ListTile(
                              leading: const Icon(
                                CupertinoIcons.arrow_down_to_line,
                                size: 21,
                              ),
                              title: Text(tr(context, 'Downloads')),
                              onTap: () => _openAction(SystemAction.downloads),
                            ),
                            if (repository.supportsRemoteLists)
                              _PinnedSidebarLists(repository: repository),
                          ],
                        ).withWheelScrolling(),
                      ),
                      const Divider(height: 1, indent: 20, endIndent: 20),
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
                          onTap: _openServers,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: Column(
                children: [
                  if (wide && _index != 4)
                    SizedBox(
                      height: 64,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                tr(context, _labels[_index]),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            IconButton(
                              tooltip: tr(context, 'Search'),
                              onPressed: () => _openAction(SystemAction.search),
                              icon: const Icon(CupertinoIcons.search),
                            ),
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
                                  : tr(
                                      context,
                                      'Pending changes ({count})',
                                    ).replaceAll(
                                      '{count}',
                                      NumberFormat.decimalPattern(
                                        Localizations.localeOf(context)
                                            .toString(),
                                      ).format(repository.pendingCount),
                                    ),
                            ),
                            leading: Icon(
                              repository.offline
                                  ? CupertinoIcons.wifi_slash
                                  : CupertinoIcons.arrow_2_circlepath,
                            ),
                            actions: [
                              TextButton(
                                onPressed: () {
                                  if (repository.offline) {
                                    repository.setOffline(false);
                                  } else {
                                    repository.sync();
                                  }
                                },
                                child: Text(
                                  tr(
                                    context,
                                    repository.offline
                                        ? 'Reconnect'
                                        : 'Sync Progress',
                                  ),
                                ),
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
          : ShellNavigationBar(
              selectedIndex: _index,
              onSelected: (i) => setState(() => _index = i),
              labels: [for (final label in _labels) tr(context, label)],
              icons: _icons,
            ),
    );
    return _withPlatformShortcuts(scaffold);
  }
}

class _PinnedSidebarLists extends StatelessWidget {
  const _PinnedSidebarLists({required this.repository});
  final Repository repository;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: repository.catalogChanges,
    builder: (context, _) {
      final tools = CatalogTools(repository);
      final items = [
        for (final kind in ['readlists', 'collections'])
          for (final id in tools.pinned(kind))
            if (repository.store.cached(
                  repository.profile.id,
                  'detail:$kind:$id',
                )
                case final Map data)
              CatalogItem(kind, object(data)),
      ];
      if (items.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(indent: 20, endIndent: 20),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 2),
            child: Text(
              tr(context, 'Pinned Lists'),
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          for (final item in items)
            ListTile(
              dense: true,
              leading: Icon(
                item.kind == 'readlists'
                    ? CupertinoIcons.list_bullet
                    : CupertinoIcons.rectangle_stack,
                size: 19,
              ),
              title: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => openItem(context, repository, item),
            ),
        ],
      );
    },
  );
}

class _LibraryBrowser extends StatelessWidget {
  const _LibraryBrowser({required this.repository});
  final Repository repository;
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: repository.supportsSeries ? 3 : 2,
    child: Column(
      children: [
        TabBar(
          tabs: [
            if (repository.supportsSeries) Tab(text: tr(context, 'Series')),
            Tab(text: tr(context, 'Books')),
            Tab(text: tr(context, 'Libraries')),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              if (repository.supportsSeries)
                CatalogPageView(
                  repository: repository,
                  preferenceScope: 'library',
                ),
              CatalogPageView(
                repository: repository,
                kind: 'books',
                preferenceScope: 'library',
              ),
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
                                preferenceScope:
                                    'library:${object(value)['id']}',
                                kind: repository.supportsSeries
                                    ? 'series'
                                    : 'books',
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
                ).withWheelScrolling(),
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
  Widget build(BuildContext context) => !repository.supportsRemoteLists
      ? SmartListsPage(repository: repository)
      : DefaultTabController(
          length: 3,
          child: Column(
            children: [
              TabBar(
                tabs: [
                  Tab(text: tr(context, 'Read Lists')),
                  Tab(text: tr(context, 'Collections')),
                  Tab(text: tr(context, 'Smart Lists')),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    CatalogPageView(
                      repository: repository,
                      kind: 'readlists',
                      preferenceScope: 'lists',
                      path: '/api/v1/readlists',
                    ),
                    CatalogPageView(
                      repository: repository,
                      kind: 'collections',
                      preferenceScope: 'lists',
                      path: '/api/v1/collections',
                    ),
                    SmartListsPage(repository: repository),
                  ],
                ),
              ),
            ],
          ),
        );
}
