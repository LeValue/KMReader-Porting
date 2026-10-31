import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/app_version.dart';
import '../../core/models.dart';
import '../../core/download_policy.dart';
import '../../core/repository.dart';
import '../../core/translation.dart';
import '../../ui/common.dart';
import '../../ui/section_scroll_view.dart';
import '../../ui/strings.dart';
import 'pdf_reader_settings.dart';
import 'browse_settings.dart';
import 'reader_settings.dart';
import 'cache_settings.dart';
import 'service_settings.dart';
import 'appearance_settings.dart';
import 'client_logs_page.dart';
import 'about_page.dart';
import 'system_features_page.dart';
import 'preference_controls.dart';
import 'settings_style.dart';
import '../auth/login_page.dart';
import '../offline/downloads_page.dart';
import '../catalog/dashboard.dart';
import '../catalog/history_page.dart';
import 'api_keys_page.dart';
import 'password_page.dart';
import 'library_editor.dart';
import 'translation_settings.dart';
import 'server_management_page.dart';
import '../catalog/catalog_page.dart';
import '../../ui/wheel_scroll.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.app, required this.repository});
  final AppController app;
  final Repository repository;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _navigator = GlobalKey<NavigatorState>();
  @override
  Widget build(BuildContext context) => Theme(
    data: settingsTheme(Theme.of(context)),
    child: NavigatorPopHandler<Object?>(
      enabled: TickerMode.valuesOf(context).enabled,
      onPopWithResult: (result) => _navigator.currentState!.pop(result),
      child: Navigator(
        key: _navigator,
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) =>
              _SettingsIndex(app: widget.app, repository: widget.repository),
        ),
      ),
    ),
  );
}

class _SettingsIndex extends StatelessWidget {
  const _SettingsIndex({required this.app, required this.repository});
  final AppController app;
  final Repository repository;

  Widget _link(
    BuildContext context,
    String title,
    IconData icon,
    Color color,
    Widget page,
  ) => ListTile(
    leading: Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Icon(icon, color: Colors.white, size: 22),
    ),
    title: Text(tr(context, title)),
    trailing: Icon(
      CupertinoIcons.chevron_right,
      size: 16,
      color: Theme.of(context).hintColor,
    ),
    onTap: () =>
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => page)),
  );

  Widget _group(List<Widget> rows) => Padding(
    padding: const EdgeInsets.only(bottom: 36),
    child: Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 64, endIndent: 22),
            rows[i],
          ],
        ],
      ),
    ),
  );

  Widget _section(String title, SettingsSection section) => _SettingsSection(
    app: app,
    repository: repository,
    title: title,
    section: section,
  );

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: 'Settings',
    showBackButton: false,
    body: SectionScrollView(
      padding: const EdgeInsets.fromLTRB(22, 26, 22, 0),
      children: [
        _group([
          _link(
            context,
            'Appearance',
            CupertinoIcons.paintbrush,
            Colors.blue,
            _section('Appearance', SettingsSection.appearance),
          ),
          _link(
            context,
            'settings.browse.title',
            CupertinoIcons.square_grid_2x2,
            Colors.purple,
            BrowseSettingsPage(preferences: repository.browse),
          ),
          _link(
            context,
            'title.dashboard',
            CupertinoIcons.house,
            Colors.orange,
            _DashboardSettings(repository: repository),
          ),
        ]),
        _group([
          _link(
            context,
            'Reading Stats',
            CupertinoIcons.chart_bar,
            Colors.deepPurple,
            ReadingStatsPage(repository: repository, standalone: true),
          ),
        ]),
        _group([
          _link(
            context,
            'Manga Translation',
            CupertinoIcons.globe,
            Colors.blue,
            TranslationSettingsPage(
              ocr: repository.ocr,
              providers: TranslationProviders(app.store, vault: app.vault),
            ),
          ),
        ]),
        _group([
          _link(
            context,
            'Reader General',
            CupertinoIcons.book,
            Colors.blue,
            ReaderGeneralSettingsPage(repository: repository),
          ),
          _link(
            context,
            'DIVINA Reader',
            CupertinoIcons.photo,
            Colors.green,
            DivinaSettingsPage(repository: repository),
          ),
          _link(
            context,
            'PDF Reader',
            CupertinoIcons.doc,
            Colors.red,
            PdfReaderSettingsPage(store: app.store),
          ),
          _link(
            context,
            'EPUB Theme',
            CupertinoIcons.textformat,
            Colors.deepPurple,
            EpubThemeSettingsPage(repository: repository),
          ),
          _link(
            context,
            'EPUB Settings',
            CupertinoIcons.doc_text,
            Colors.teal,
            EpubSettingsPage(store: app.store),
          ),
        ]),
        _group([
          _link(
            context,
            'Real-time Updates',
            CupertinoIcons.antenna_radiowaves_left_right,
            Colors.orange,
            RealtimeSettingsPage(repository: repository),
          ),
          _link(
            context,
            'System Features',
            CupertinoIcons.desktopcomputer,
            Colors.indigo,
            const SystemFeaturesPage(),
          ),
        ]),
        _group([
          _link(
            context,
            'Network',
            CupertinoIcons.globe,
            Colors.blue,
            NetworkSettingsPage(store: app.store),
          ),
          _link(
            context,
            'Cache',
            CupertinoIcons.archivebox,
            Colors.orange,
            CacheSettingsPage(repository: repository),
          ),
          _link(
            context,
            'Logs',
            CupertinoIcons.doc_text_search,
            Colors.grey,
            const ClientLogsPage(),
          ),
        ]),
        _group([
          _link(
            context,
            'About',
            CupertinoIcons.info_circle,
            Colors.grey,
            const AboutPage(),
          ),
        ]),
        _group([
          _link(
            context,
            'Downloads',
            CupertinoIcons.arrow_down_to_line,
            Colors.green,
            _section('Downloads', SettingsSection.storage),
          ),
        ]),
        _group([
          _link(
            context,
            'Servers',
            CupertinoIcons.person,
            Colors.grey,
            _section('Servers', SettingsSection.accounts),
          ),
          _link(
            context,
            'Server Info',
            CupertinoIcons.tray_2,
            Colors.blueGrey,
            _section('Server Info', SettingsSection.server),
          ),
        ]),
      ],
    ),
  );
}

enum SettingsSection { accounts, storage, appearance, server }

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.app,
    required this.repository,
    required this.title,
    required this.section,
  });
  final AppController app;
  final Repository repository;
  final String title;
  final SettingsSection section;
  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: title,
    body: ListenableBuilder(
      listenable: repository,
      builder: (context, _) => SectionScrollView(
        padding: const EdgeInsets.all(22),
        children: switch (section) {
          SettingsSection.accounts => [
            Text(
              tr(context, 'Servers'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(CupertinoIcons.lock),
                    title: Text(tr(context, 'API Keys')),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ApiKeysPage(repository: repository),
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.password),
                    title: Text(tr(context, 'account.details.changePassword')),
                    enabled: !repository.offline,
                    onTap: () async {
                      final changed = await Navigator.push<bool>(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              PasswordPage(app: app, repository: repository),
                        ),
                      );
                      if (changed == true && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              tr(context, 'account.details.passwordUpdated'),
                            ),
                          ),
                        );
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(CupertinoIcons.clock),
                    title: Text(tr(context, 'History and Statistics')),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ReadingStatsPage(
                          repository: repository,
                          standalone: true,
                        ),
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.manage_history),
                    title: Text(tr(context, 'Authentication Activity')),
                    onTap: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            AuthenticationActivityPage(repository: repository),
                      ),
                    ),
                  ),
                  for (final profile in app.servers)
                    ListTile(
                      leading: Icon(
                        CupertinoIcons.tray_2,
                        color: profile.id == repository.profile.id
                            ? Theme.of(context).colorScheme.secondary
                            : null,
                      ),
                      title: Text(profile.name),
                      subtitle: Text('${profile.url}\n${profile.email}'),
                      isThreeLine: true,
                      onTap: () async {
                        try {
                          await app.activate(profile);
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) async {
                          if (action == 'login' && context.mounted) {
                            Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    LoginPage(app: app, profile: profile),
                              ),
                            );
                          }
                          if (action == 'remove' &&
                              await confirm(
                                context,
                                'Remove Server',
                                'Remove this server and its downloaded files from this device?',
                              )) {
                            try {
                              await app.remove(profile);
                            } catch (e) {
                              if (context.mounted) showError(context, e);
                            }
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'login',
                            child: Text(tr(context, 'Sign In')),
                          ),
                          PopupMenuItem(
                            value: 'remove',
                            child: Text(tr(context, 'Remove Server')),
                          ),
                        ],
                      ),
                    ),
                  ListTile(
                    leading: const Icon(CupertinoIcons.add_circled),
                    title: Text(tr(context, 'Add Server')),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => LoginPage(app: app),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ListenableBuilder(
              listenable: app.deviceLock,
              builder: (context, _) => SwitchListTile(
                secondary: const Icon(Icons.fingerprint),
                title: Text(tr(context, 'App Lock')),
                subtitle: Text(
                  tr(context, 'Use biometrics, device PIN or Windows Hello'),
                ),
                value: app.deviceLock.enabled,
                onChanged: app.deviceLock.busy
                    ? null
                    : (value) async {
                        await app.deviceLock.configure(
                          value,
                          tr(context, 'Confirm app lock settings'),
                        );
                        if (context.mounted && app.deviceLock.error != null) {
                          showError(context, app.deviceLock.error!);
                        }
                      },
              ),
            ),
          ],
          SettingsSection.appearance => [
            AppearanceSettings(app: app, repository: repository),
          ],
          SettingsSection.server => [
            Text('Komga', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(CupertinoIcons.info_circle),
                    title: Text(tr(context, 'Server Info')),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ServerPage(repository: repository),
                      ),
                    ),
                  ),
                  if (repository.profile.admin) ...[
                    ListTile(
                      leading: const Icon(Icons.admin_panel_settings_outlined),
                      title: Text(tr(context, 'Server Management')),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              ServerManagementPage(repository: repository),
                        ),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.copy_all),
                      title: Text(tr(context, 'Duplicate Files')),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => Scaffold(
                            appBar: AppBar(
                              title: Text(tr(context, 'Duplicate Files')),
                            ),
                            body: CatalogPageView(
                              repository: repository,
                              kind: 'books',
                              path: '/api/v1/books/duplicates',
                              title: 'Duplicate Files',
                              searchEnabled: false,
                              initialSort: 'fileSize,desc',
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (repository.profile.admin)
                    ListTile(
                      leading: const Icon(CupertinoIcons.wrench),
                      title: Text(tr(context, 'Library Management')),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              LibraryManagement(repository: repository),
                        ),
                      ),
                    ),
                  ListTile(
                    leading: const Icon(CupertinoIcons.doc_text),
                    title: Text(tr(context, 'Licenses')),
                    onTap: () => showLicensePage(
                      context: context,
                      applicationName: 'KMReader',
                      applicationVersion: '$appVersion ($appBuildNumber)',
                      applicationLegalese: 'Based on KMReader by everpcpc (MIT).\nPorting for Android and Windows.',
                    ),
                  ),
                  ListTile(
                    leading: const Icon(CupertinoIcons.square_arrow_right),
                    title: Text(tr(context, 'Disconnect')),
                    onTap: app.disconnect,
                  ),
                ],
              ),
            ),
          ],
          SettingsSection.storage => [
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(CupertinoIcons.wifi_slash),
                    title: Text(tr(context, 'Offline Mode')),
                    value: repository.offline,
                    onChanged: repository.setOffline,
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.downloading),
                    title: Text(tr(context, 'Background Downloads')),
                    subtitle: Text(
                      tr(context, 'Continue downloads when the app is closed'),
                    ),
                    value: app.backgroundDownloads.policy.background,
                    onChanged: (value) {
                      final policy = app.backgroundDownloads.policy;
                      app.backgroundDownloads.setPolicy(
                        DownloadPolicy(
                          background: value,
                          unmetered: policy.unmetered,
                          charging: policy.charging,
                        ),
                      );
                      repository.changed();
                    },
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.wifi),
                    title: Text(tr(context, 'Unmetered Downloads Only')),
                    value: app.backgroundDownloads.policy.unmetered,
                    onChanged: (value) {
                      final policy = app.backgroundDownloads.policy;
                      app.backgroundDownloads.setPolicy(
                        DownloadPolicy(
                          background: policy.background,
                          unmetered: value,
                          charging: policy.charging,
                        ),
                      );
                      repository.changed();
                    },
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.battery_charging_full),
                    title: Text(tr(context, 'Download While Charging')),
                    value: app.backgroundDownloads.policy.charging,
                    onChanged: (value) {
                      final policy = app.backgroundDownloads.policy;
                      app.backgroundDownloads.setPolicy(
                        DownloadPolicy(
                          background: policy.background,
                          unmetered: policy.unmetered,
                          charging: value,
                        ),
                      );
                      repository.changed();
                    },
                  ),
                  ListTile(
                    leading: repository.metadataIndexing
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.manage_search),
                    title: Text(tr(context, 'Prepare Offline Catalog')),
                    subtitle: Text(
                      repository.metadataIndexError ??
                          (repository.metadataIndexing
                              ? '${repository.metadataIndexed} ${tr(context, 'items')}'
                              : ('${repository.store.offlineCatalog.count(repository.profile.id, 'books')} ${tr(context, 'Books')} • ${repository.store.offlineCatalog.count(repository.profile.id, 'series')} ${tr(context, 'Series')}')),
                    ),
                    trailing: repository.metadataIndexing
                        ? IconButton(
                            tooltip: tr(context, 'Cancel'),
                            icon: const Icon(Icons.close),
                            onPressed: repository.cancelMetadataIndex,
                          )
                        : null,
                    onTap: repository.offline || repository.metadataIndexing
                        ? null
                        : repository.prepareOfflineCatalog,
                  ),
                  ListTile(
                    leading: const Icon(CupertinoIcons.arrow_down_to_line),
                    title: Text(tr(context, 'Downloads')),
                    trailing: const Icon(
                      CupertinoIcons.chevron_right,
                      size: 16,
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => DownloadsPage(repository: repository),
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(CupertinoIcons.arrow_2_circlepath),
                    title: Text(tr(context, 'Sync Progress')),
                    subtitle: Text(
                      '${repository.pendingCount} ${tr(context, 'pending')}',
                    ),
                    onTap: repository.sync,
                  ),
                  if (app.backgroundDownloads.failure != null)
                    ListTile(
                      leading: const Icon(Icons.sync_problem),
                      title: Text(
                        tr(context, 'Background Downloads Unavailable'),
                      ),
                      subtitle: Text(app.backgroundDownloads.failure!),
                    ),
                  if (repository.syncFailure != null)
                    ListTile(
                      title: Text(repository.syncFailure!),
                      subtitle: Text(
                        tr(context, 'Your local changes are retained.'),
                      ),
                      trailing: repository.conflicts.isEmpty
                          ? null
                          : PopupMenuButton<String>(
                              onSelected: (value) async {
                                if (value == 'server') {
                                  repository.acceptServerProgress();
                                }
                                if (value == 'device' &&
                                    await confirm(
                                      context,
                                      'Use Device Progress',
                                      'Replace newer server progress with the progress on this device?',
                                    )) {
                                  await repository.sync(force: true);
                                }
                              },
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 'server',
                                  child: Text(
                                    tr(context, 'Use Server Progress'),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'device',
                                  child: Text(
                                    tr(context, 'Use Device Progress'),
                                  ),
                                ),
                              ],
                            ),
                    ),
                ],
              ),
            ),
          ],
        },
      ),
    ),
  );
}

class _DashboardSettings extends StatefulWidget {
  const _DashboardSettings({required this.repository});
  final Repository repository;
  @override
  State<_DashboardSettings> createState() => _DashboardSettingsState();
}

class _DashboardSettingsState extends State<_DashboardSettings> {
  @override
  Widget build(BuildContext context) {
    final key = 'dashboardHidden:${widget.repository.profile.id}';
    final hidden = widget.repository.store.setting<List<dynamic>>(key) ?? [];
    final saved =
        widget.repository.store.setting<List<dynamic>>(
          'dashboardOrder:${widget.repository.profile.id}',
        ) ??
        [];
    final order = [
      ...saved.whereType<String>().where(dashboardSections.contains),
      ...dashboardSections.where((s) => !saved.contains(s)),
    ];
    return SettingsScaffold(
      title: 'Dashboard Sections',
      actions: [
        IconButton(
          tooltip: tr(context, 'dashboard.reset'),
          icon: const Icon(Icons.restore),
          onPressed: () {
            setState(() {
              widget.repository.store.setSetting(key, <String>[]);
              widget.repository.store.setSetting(
                'dashboardOrder:${widget.repository.profile.id}',
                dashboardSections,
              );
            });
            widget.repository.catalogChanges.value++;
          },
        ),
      ],
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 0),
            child: PreferencePage(
              title: 'Dashboard',
              embedded: true,
              store: widget.repository.store,
              onChanged: (_) {
                widget.repository.changed();
                setState(() {});
              },
              specs: const [
                PreferenceSpec(
                  'showDashboardCardKindMenu',
                  'settings.dashboard.cardKindMenu.title',
                  true,
                ),
                PreferenceSpec(
                  'showDashboardSectionGradientBackground',
                  'settings.dashboard.sectionBackground.title',
                  false,
                ),
              ],
            ),
          ),
          Expanded(
            child: ReorderableListView(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 28),
              buildDefaultDragHandles: false,
              onReorderItem: (old, target) {
                final updated = [...order];
                updated.insert(target, updated.removeAt(old));
                setState(
                  () => widget.repository.store.setSetting(
                    'dashboardOrder:${widget.repository.profile.id}',
                    updated,
                  ),
                );
                widget.repository.catalogChanges.value++;
              },
              children: [
                for (final section in order)
                  Row(
                    key: ValueKey(section),
                    children: [
                      Expanded(
                        child: SwitchListTile(
                          title: Text(tr(context, section)),
                          value: !hidden.contains(section),
                          onChanged: (value) {
                            setState(() {
                              if (value) {
                                hidden.remove(section);
                              } else {
                                hidden.add(section);
                              }
                              widget.repository.store.setSetting(key, hidden);
                            });
                            widget.repository.catalogChanges.value++;
                          },
                        ),
                      ),
                      ReorderableDragStartListener(
                        index: order.indexOf(section),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Tooltip(
                            message: tr(context, 'Reorder'),
                            child: const Icon(CupertinoIcons.line_horizontal_3),
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ).withWheelScrolling(),
          ),
        ],
      ),
    );
  }
}

class ServerPage extends StatelessWidget {
  const ServerPage({super.key, required this.repository});
  final Repository repository;
  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: 'Server Info',
    body: AsyncPanel<dynamic>(
      load: () => repository.get('/actuator/info'),
      builder: (context, value) => SectionScrollView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            repository.profile.name,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 16),
          ..._rows(object(value)),
        ],
      ),
    ),
  );
  List<Widget> _rows(Json data, [String prefix = '']) => [
    for (final entry in data.entries)
      if (entry.value is Map)
        ..._rows(object(entry.value), '$prefix${entry.key}.')
      else
        ListTile(
          title: Text('$prefix${entry.key}'),
          subtitle: SelectableText('${entry.value}'),
        ),
  ];
}

class LibraryManagement extends StatefulWidget {
  const LibraryManagement({super.key, required this.repository});
  final Repository repository;
  @override
  State<LibraryManagement> createState() => _LibraryManagementState();
}

class _LibraryManagementState extends State<LibraryManagement> {
  int _revision = 0;
  Future<void> _edit([Json? library]) async {
    try {
      Json? fresh;
      if (library != null) {
        fresh = object(
          await widget.repository.api.request(
            '/api/v1/libraries/${Uri.encodeComponent(text(library['id']))}',
          ),
        );
      }
      if (!mounted) return;
      final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              LibraryEditor(repository: widget.repository, library: fresh),
        ),
      );
      if (saved == true && mounted) setState(() => _revision++);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, 'Library Management')),
      actions: [
        IconButton(
          tooltip: tr(context, 'Add Library'),
          onPressed: widget.repository.offline ? null : _edit,
          icon: const Icon(CupertinoIcons.add),
        ),
      ],
    ),
    body: AsyncPanel<dynamic>(
      key: ValueKey(_revision),
      load: () => widget.repository.get('/api/v1/libraries'),
      builder: (context, data) => ListView(
        children: [
          for (final value in data as List)
            ListTile(
              leading: const Icon(CupertinoIcons.book),
              title: Text(text(object(value)['name'])),
              subtitle: Text(text(object(value)['root'])),
              onTap: () => _edit(object(value)),
              trailing: PopupMenuButton<String>(
                onSelected: (action) async {
                  if (action == 'edit') {
                    await _edit(object(value));
                    return;
                  }
                  if (!await confirm(
                    context,
                    'Library Management',
                    action == 'delete'
                        ? 'Remove this library and its catalog from the server? Files on disk are kept.'
                        : action == 'empty-trash'
                        ? 'Permanently remove unavailable books and their metadata from the catalog?'
                        : 'Run this action on the selected library?',
                  )) {
                    return;
                  }
                  try {
                    await widget.repository.api.request(
                      '/api/v1/libraries/${Uri.encodeComponent(object(value)['id'])}${action == 'delete' ? '' : '/${action == 'deep-scan' ? 'scan' : action}'}',
                      method: action == 'delete' ? 'DELETE' : 'POST',
                      query: action == 'deep-scan' ? {'deep': true} : null,
                    );
                    widget.repository.refreshContent();
                    if (mounted) setState(() => _revision++);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            tr(
                              context,
                              action == 'delete' ? 'Deleted' : 'Task queued',
                            ),
                          ),
                        ),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                itemBuilder: (_) => [
                  for (final e in {
                    'edit': 'Edit Library',
                    'scan': 'Scan',
                    'deep-scan': 'Deep Scan',
                    'analyze': 'Analyze',
                    'metadata/refresh': 'Refresh Metadata',
                    'empty-trash': 'Empty Trash',
                    'delete': 'Delete Library',
                  }.entries)
                    PopupMenuItem(
                      value: e.key,
                      child: Text(tr(context, e.value)),
                    ),
                ],
              ),
            ),
        ],
      ).withWheelScrolling(),
    ),
  );
}
